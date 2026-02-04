--!strict
-- StatsPanelController - Tab toggle stats panel (general + spell detail)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local PlayerBalance = require(sharedFolder:WaitForChild("PlayerBalance"))
local UpgradeDefs = require(sharedFolder:WaitForChild("UpgradeDefs"))

local remotes = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS")
local entitySync = remotes:WaitForChild("EntitySync")
local entityUpdate = remotes:WaitForChild("EntityUpdate")
local entityUpdateUnreliable = remotes:FindFirstChild("EntityUpdateUnreliable")
local entityDespawn = remotes:FindFirstChild("EntityDespawn")
local requestInitialSync = remotes:WaitForChild("RequestInitialSync")
local powerupEffectUpdate = ReplicatedStorage:WaitForChild("RemoteEvents"):FindFirstChild("PowerupEffectUpdate")
local buffDurationUpdate = ReplicatedStorage:WaitForChild("RemoteEvents"):FindFirstChild("BuffDurationUpdate")
local gameTimeUpdate = ReplicatedStorage:WaitForChild("RemoteEvents"):FindFirstChild("GameTimeUpdate")

local playerEntityId: number? = nil
local playerComponentState: {[string]: any} = {}

local sharedComponents: {[string]: {[number]: any}} = {
	EntityType = {},
	AI = {},
	Visual = {},
	ItemData = {},
	AbilityData = {},
	AbilityDamageStats = {},
	SessionStats = {},
}

local function shallowCopy<T>(original: {[any]: T}): {[any]: T}
	local copy: {[any]: T} = {}
	for key, value in pairs(original) do
		copy[key] = value
	end
	return copy
end

local function applySharedDefinitions(sharedData: any)
	if typeof(sharedData) ~= "table" then
		return
	end

	for componentName, entries in pairs(sharedData) do
		local bucket = sharedComponents[componentName]
		if bucket and typeof(entries) == "table" then
			for id, value in pairs(entries) do
				local numericId = tonumber(id)
				if numericId then
					bucket[numericId] = value
				end
			end
		end
	end
end

local function resolveEntityData(entityData: {[string]: any}): {[string]: any}
	local needsResolve = false
	for componentName, value in pairs(entityData) do
		if typeof(value) == "number" then
			local bucket = sharedComponents[componentName]
			if bucket and bucket[value] ~= nil then
				needsResolve = true
				break
			end
		end
	end
	if not needsResolve then
		return entityData
	end

	local resolved = shallowCopy(entityData)
	for componentName, value in pairs(entityData) do
		if typeof(value) == "number" then
			local bucket = sharedComponents[componentName]
			if bucket and bucket[value] then
				resolved[componentName] = bucket[value]
			end
		end
	end
	return resolved
end

local function isPlayerEntityPayload(data: any): boolean
	if typeof(data) ~= "table" then
		return false
	end
	local entityType = data.EntityType
	if typeof(entityType) == "number" then
		entityType = sharedComponents.EntityType[entityType]
	end
	if data.PlayerStats and data.PlayerStats.player == localPlayer then
		return true
	end
	if entityType and typeof(entityType) == "table" then
		if entityType.type == "Player" and entityType.player == localPlayer then
			return true
		end
	end
	return false
end

local needsRefresh = false
local lastRefresh = 0
local REFRESH_INTERVAL = 0.25
local serverGameTime: number? = nil

local function handlePlayerEntityData(entityId: number, entityData: {[string]: any})
	local entityType = entityData.EntityType
	if entityType and typeof(entityType) == "table" then
		if entityType.type ~= "Player" then
			return
		end
		if entityType.player ~= localPlayer then
			return
		end
		playerEntityId = entityId
	end

	if playerEntityId and entityId ~= playerEntityId then
		return
	end

	playerEntityId = playerEntityId or entityId

	for componentName, value in pairs(entityData) do
		playerComponentState[componentName] = value
	end
	needsRefresh = true
end

local function processSnapshot(snapshot: any)
	if typeof(snapshot) ~= "table" then
		return
	end

	applySharedDefinitions(snapshot.shared)

	local entities = snapshot.entities
	if typeof(entities) ~= "table" then
		return
	end

	if playerEntityId then
		local direct = entities[playerEntityId] or entities[tostring(playerEntityId)]
		if typeof(direct) == "table" then
			handlePlayerEntityData(playerEntityId, resolveEntityData(direct))
			return
		end
		playerEntityId = nil
		table.clear(playerComponentState)
	end

	for entityId, data in pairs(entities) do
		if typeof(data) == "table" then
			local resolved = resolveEntityData(data)
			if isPlayerEntityPayload(resolved) then
				handlePlayerEntityData(tonumber(entityId) or entityId, resolved)
				return
			end
		end
	end
end

local function processUpdates(message: any)
	if typeof(message) ~= "table" then
		return
	end

	applySharedDefinitions(message.shared)

	local entities = message.entities
	if typeof(entities) == "table" then
		if playerEntityId then
			local direct = entities[playerEntityId] or entities[tostring(playerEntityId)]
			if typeof(direct) == "table" then
				handlePlayerEntityData(playerEntityId, resolveEntityData(direct))
				entities = nil
			else
				playerEntityId = nil
				table.clear(playerComponentState)
			end
		else
			for entityId, data in pairs(entities) do
				local resolved = resolveEntityData(data)
				if isPlayerEntityPayload(resolved) then
					handlePlayerEntityData(tonumber(entityId) or entityId, resolved)
					break
				end
			end
		end
	end

	local updates = message.updates
	if typeof(updates) == "table" then
		for _, updateData in ipairs(updates) do
			if typeof(updateData) == "table" and updateData.id then
				if playerEntityId then
					if updateData.id == playerEntityId then
						handlePlayerEntityData(updateData.id, resolveEntityData(updateData))
					end
				else
					local resolved = resolveEntityData(updateData)
					if isPlayerEntityPayload(resolved) then
						handlePlayerEntityData(updateData.id, resolved)
					end
				end
			end
		end
	end

	local resyncs = message.resyncs
	if typeof(resyncs) == "table" then
		for _, updateData in ipairs(resyncs) do
			if typeof(updateData) == "table" and updateData.id then
				if playerEntityId then
					if updateData.id == playerEntityId then
						handlePlayerEntityData(updateData.id, resolveEntityData(updateData))
					end
				else
					local resolved = resolveEntityData(updateData)
					if isPlayerEntityPayload(resolved) then
						handlePlayerEntityData(updateData.id, resolved)
					end
				end
			end
		end
	end
end

entitySync.OnClientEvent:Connect(processSnapshot)
entityUpdate.OnClientEvent:Connect(processUpdates)
if entityUpdateUnreliable and entityUpdateUnreliable:IsA("UnreliableRemoteEvent") then
	entityUpdateUnreliable.OnClientEvent:Connect(processUpdates)
end
if entityDespawn and entityDespawn:IsA("RemoteEvent") then
	entityDespawn.OnClientEvent:Connect(function(despawns: any)
		if not playerEntityId then
			return
		end
		if typeof(despawns) == "table" then
			for _, entityId in ipairs(despawns) do
				if entityId == playerEntityId then
					playerEntityId = nil
					table.clear(playerComponentState)
					needsRefresh = true
					break
				end
			end
		elseif despawns == playerEntityId then
			playerEntityId = nil
			table.clear(playerComponentState)
			needsRefresh = true
		end
	end)
end
if powerupEffectUpdate and powerupEffectUpdate:IsA("RemoteEvent") then
	powerupEffectUpdate.OnClientEvent:Connect(function()
		needsRefresh = true
	end)
end
if buffDurationUpdate and buffDurationUpdate:IsA("RemoteEvent") then
	buffDurationUpdate.OnClientEvent:Connect(function()
		needsRefresh = true
	end)
end
if gameTimeUpdate and gameTimeUpdate:IsA("RemoteEvent") then
	gameTimeUpdate.OnClientEvent:Connect(function(gameTime: any)
		if typeof(gameTime) == "number" then
			serverGameTime = gameTime
			needsRefresh = true
		end
	end)
end

local function fetchInitialSnapshot()
	local ok, snapshot = pcall(function()
		return requestInitialSync:InvokeServer()
	end)
	if ok then
		processSnapshot(snapshot)
	end
end

local ROW_HEIGHT = 0.035

local screenGui = playerGui:WaitForChild("StatsPanelGui") :: ScreenGui
screenGui.Enabled = false

local leftPanel = screenGui:WaitForChild("GeneralStatsPanel") :: Frame
local rightPanel = screenGui:WaitForChild("SpellStatsPanel") :: Frame

local generalList = leftPanel:WaitForChild("GeneralList") :: ScrollingFrame
local generalLayout = generalList:FindFirstChildOfClass("UIListLayout")
if not generalLayout then
	generalLayout = Instance.new("UIListLayout")
	generalLayout.Padding = UDim.new(0, 6)
	generalLayout.SortOrder = Enum.SortOrder.LayoutOrder
	generalLayout.Parent = generalList
end

local spellListFrame = rightPanel:WaitForChild("SpellListFrame") :: Frame
local spellList = spellListFrame:WaitForChild("SpellList") :: ScrollingFrame
local spellListLayout = spellList:FindFirstChildOfClass("UIListLayout")
if not spellListLayout then
	spellListLayout = Instance.new("UIListLayout")
	spellListLayout.Padding = UDim.new(0, 8)
	spellListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	spellListLayout.Parent = spellList
end

local spellDetailFrame = rightPanel:WaitForChild("SpellDetailFrame") :: Frame
spellDetailFrame.Visible = false
local backButton = spellDetailFrame:WaitForChild("BackButton") :: TextButton
local detailScroll = spellDetailFrame:WaitForChild("DetailScroll") :: ScrollingFrame
local detailLayout = detailScroll:FindFirstChildOfClass("UIListLayout")
if not detailLayout then
	detailLayout = Instance.new("UIListLayout")
	detailLayout.Padding = UDim.new(0, 6)
	detailLayout.SortOrder = Enum.SortOrder.LayoutOrder
	detailLayout.Parent = detailScroll
end

local function formatNumber(value: number, decimals: number?): string
	local places = decimals or 1
	local fmt = "%." .. tostring(places) .. "f"
	return string.format(fmt, value)
end

local function formatInt(value: number?): string
	local raw = value or 0
	return tostring(math.floor(raw + 0.0001))
end

local function normalizeKey(value: any): string
	local text = string.lower(tostring(value or ""))
	text = text:gsub("%s+", "")
	return text
end

local function getAbilityDamage(damageStats: any, sessionStats: any, abilityId: string, abilityRecord: any): (number, boolean)
	local found = false
	if sessionStats and typeof(sessionStats) == "table" then
		local perAbility = sessionStats.perAbility
		if perAbility and typeof(perAbility) == "table" then
			local direct = perAbility[abilityId]
			if typeof(direct) == "number" then
				return direct, true
			end
			local normalizedId = normalizeKey(abilityId)
			local nameKey = abilityRecord and (abilityRecord.name or abilityRecord.Name) or nil
			local normalizedName = normalizeKey(nameKey)
			for key, value in pairs(perAbility) do
				if typeof(value) == "number" then
					local normalizedKey = normalizeKey(key)
					if normalizedKey == normalizedId then
						return value, true
					end
					if normalizedName ~= "" and normalizedKey == normalizedName then
						return value, true
					end
				end
			end
		end
	end
	if not damageStats or typeof(damageStats) ~= "table" then
		return 0, false
	end
	local direct = damageStats[abilityId]
	if typeof(direct) == "number" then
		return direct, true
	end
	local normalizedId = normalizeKey(abilityId)
	local nameKey = abilityRecord and (abilityRecord.name or abilityRecord.Name) or nil
	local normalizedName = normalizeKey(nameKey)
	for key, value in pairs(damageStats) do
		if typeof(value) == "number" then
			local normalizedKey = normalizeKey(key)
			if normalizedKey == normalizedId then
				return value, true
			end
			if normalizedName ~= "" and normalizedKey == normalizedName then
				return value, true
			end
		end
	end
	return 0, false
end

local function formatPercent(value: number, decimals: number?): string
	local places = decimals or 1
	local fmt = "%." .. tostring(places) .. "f%%"
	return string.format(fmt, value * 100)
end

local function formatCountWithFloor(value: number?, decimals: number?): string
	local raw = value or 0
	local floored = math.floor(raw + 0.0001)
	return string.format("%s (%d)", formatNumber(raw, decimals or 1), floored)
end

local function formatPercentFromMultiplier(multiplier: number, base: number): string
	if base <= 0 then
		return "0%"
	end
	local delta = (multiplier / base) - 1
	local sign = delta >= 0 and "+" or ""
	return string.format("%s%.1f%%", sign, delta * 100)
end

local function formatMultiplierPercent(multiplier: number): string
	return string.format("%.1f%%", multiplier * 100)
end

local function getGameTimeNow(): number
	return serverGameTime or workspace:GetServerTimeNow()
end

local function computeBuffMultiplier(buffState: any, field: string, now: number): number
	if not buffState or typeof(buffState) ~= "table" then
		return 1.0
	end
	local buffs = buffState.buffs
	if typeof(buffs) ~= "table" then
		return 1.0
	end
	local multiplier = 1.0
	for _, buff in pairs(buffs) do
		if typeof(buff) == "table" then
			if buff.endTime == nil or buff.endTime > now then
				multiplier = multiplier * (buff[field] or 1.0)
			end
		end
	end
	return multiplier
end

local function computeTotalSpeedMultiplier(effects: any): number
	local baseMult = (effects and effects.moveSpeedMultiplier) or 1.0
	local buffsMult = 1.0
	if effects and typeof(effects.activeSpeedBuffs) == "table" then
		for _, buffData in pairs(effects.activeSpeedBuffs) do
			if typeof(buffData) == "table" then
				buffsMult = buffsMult * (buffData.multiplier or 1.0)
			end
		end
	end
	return baseMult * buffsMult
end

local function computeAbilityStats(abilityRecord: any, passiveEffects: any, buffState: any): {[string]: any}
	local stats: {[string]: any} = {}
	for key, value in pairs(abilityRecord) do
		if type(value) == "number" or type(value) == "boolean" then
			stats[key] = value
		end
	end

	local baseStats = abilityRecord.baseStats or {}

	if passiveEffects then
		if stats.damage and passiveEffects.damageMultiplier then
			stats.damage = stats.damage * passiveEffects.damageMultiplier
		end
		if stats.explosionDamage and passiveEffects.damageMultiplier then
			stats.explosionDamage = stats.explosionDamage * passiveEffects.damageMultiplier
		end
		if stats.cooldown and passiveEffects.cooldownMultiplier then
			stats.cooldown = stats.cooldown * passiveEffects.cooldownMultiplier
		end
		if stats.scale == nil then
			stats.scale = 1.0
		end
		if passiveEffects.sizeMultiplier then
			stats.scale = stats.scale * passiveEffects.sizeMultiplier
		end
		if stats.duration and passiveEffects.durationMultiplier then
			stats.duration = stats.duration * passiveEffects.durationMultiplier
		end
		if stats.penetration and passiveEffects.penetrationMultiplier then
			stats.penetration = math.max(0, math.floor(stats.penetration * passiveEffects.penetrationMultiplier + 0.0001))
		end
		local projectileCountBonus = passiveEffects.projectileCountBonus or 0
		if stats.projectileCount and projectileCountBonus ~= 0 then
			local baseCount = baseStats.projectileCount or stats.projectileCount
			local rawBase = stats.projectileCountRaw or stats.projectileCount
			local bonusMultiplier = stats.projectileCountMultiplier or 1
			local maxCount = math.floor(baseCount * UpgradeDefs.SoftCaps.countMaxMultiplier + 0.0001)
			local rawCount = rawBase + (projectileCountBonus * bonusMultiplier)
			if rawBase > maxCount then
				stats.projectileCountRaw = rawCount
				stats.projectileCount = math.floor(rawCount + 0.0001)
			else
				stats.projectileCountRaw = math.min(maxCount, rawCount)
				stats.projectileCount = math.min(maxCount, math.floor(rawCount + 0.0001))
			end
		end
	end

	local now = getGameTimeNow()
	local damageBuffMult = computeBuffMultiplier(buffState, "damageMultiplier", now)
	local cooldownBuffMult = computeBuffMultiplier(buffState, "cooldownMultiplier", now)

	if stats.damage then
		stats.damage = stats.damage * damageBuffMult
	end
	if stats.explosionDamage then
		stats.explosionDamage = stats.explosionDamage * damageBuffMult
	end
	if stats.cooldown then
		stats.cooldown = stats.cooldown * cooldownBuffMult
	end

	if buffState and typeof(buffState.buffs) == "table" then
		local arcaneBuff = buffState.buffs["ArcaneRune"]
		if arcaneBuff and (arcaneBuff.endTime == nil or arcaneBuff.endTime > now) then
			local homingMult = arcaneBuff.homingMultiplier or 1.0
			if stats.homingStrength then
				stats.homingStrength = stats.homingStrength * homingMult
			end
			if stats.homingDistance then
				stats.homingDistance = stats.homingDistance * homingMult
			end
			if stats.homingMaxAngle then
				stats.homingMaxAngle = stats.homingMaxAngle * homingMult
			end
			local penetrationMult = arcaneBuff.penetrationMultiplier or 1.0
			if stats.penetration then
				stats.penetration = stats.penetration * penetrationMult
			end
			local durationMult = arcaneBuff.durationMultiplier or 1.0
			if stats.duration then
				stats.duration = stats.duration * durationMult
			end
			local speedMult = arcaneBuff.projectileSpeedMultiplier or 1.0
			if stats.projectileSpeed then
				stats.projectileSpeed = stats.projectileSpeed * speedMult
			end
		end
	end

	return stats
end

local function createStatRow(parent: Instance, label: string): TextLabel
	local row = Instance.new("Frame")
	row.Name = label .. "Row"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, ROW_HEIGHT, 0)
	row.Parent = parent

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "Name"
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(0.58, 0, 1, 0)
	nameLabel.Font = Enum.Font.GothamMedium
	nameLabel.TextSize = 13
	nameLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Text = label
	nameLabel.Parent = row

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "Value"
	valueLabel.BackgroundTransparency = 1
	valueLabel.Size = UDim2.new(0.42, 0, 1, 0)
	valueLabel.Position = UDim2.new(0.58, 0, 0, 0)
	valueLabel.Font = Enum.Font.Gotham
	valueLabel.TextSize = 13
	valueLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.Text = "-"
	valueLabel.Parent = row

	return valueLabel
end

local generalRows: {[string]: TextLabel} = {}
local lastAbilityData: any = nil
local lastDamageStats: any = nil
local lastSpellDamageById: {[string]: number} = {}
local lastTotalDamage: number = 0

local DEFAULT_TEXT_COLOR = Color3.fromRGB(200, 200, 200)
local BUFF_TEXT_COLOR = Color3.fromRGB(120, 180, 255)

local function setGeneralRow(id: string, label: string, value: string, highlight: boolean?)
	local row = generalRows[id]
	if not row then
		row = createStatRow(generalList, label)
		generalRows[id] = row
	end
	row.Text = value
	local nameLabel = row.Parent:FindFirstChild("Name")
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = label
		nameLabel.TextColor3 = highlight and BUFF_TEXT_COLOR or DEFAULT_TEXT_COLOR
	end
	if highlight then
		row.TextColor3 = BUFF_TEXT_COLOR
	else
		row.TextColor3 = DEFAULT_TEXT_COLOR
	end
end

local function updateGeneralStats()
	local effects = playerComponentState.PassiveEffects or {}
	local buffState = playerComponentState.BuffState or {}
	local now = getGameTimeNow()

	local damageBuffMult = computeBuffMultiplier(buffState, "damageMultiplier", now)
	local cooldownBuffMult = computeBuffMultiplier(buffState, "cooldownMultiplier", now)
	local durationBuffMult = computeBuffMultiplier(buffState, "durationMultiplier", now)
	local penetrationBuffMult = computeBuffMultiplier(buffState, "penetrationMultiplier", now)
	local hasDamageBuff = math.abs(damageBuffMult - 1.0) > 1e-4
	local hasCooldownBuff = math.abs(cooldownBuffMult - 1.0) > 1e-4
	local hasDurationBuff = math.abs(durationBuffMult - 1.0) > 1e-4
	local hasPenetrationBuff = math.abs(penetrationBuffMult - 1.0) > 1e-4
	local hasSpeedBuff = false
	if effects and typeof(effects.activeSpeedBuffs) == "table" then
		for _, buffData in pairs(effects.activeSpeedBuffs) do
			if typeof(buffData) == "table" then
				if not buffData.endTime or buffData.endTime > now then
					hasSpeedBuff = true
					break
				end
			end
		end
	end
	local arcaneBuff = buffState and buffState.buffs and buffState.buffs["ArcaneRune"]
	local arcaneActive = arcaneBuff and (arcaneBuff.endTime == nil or arcaneBuff.endTime > now) or false

	local damageMult = (effects.damageMultiplier or PlayerBalance.BaseDamageMultiplier or 1.0) * damageBuffMult
	local cooldownMult = (effects.cooldownMultiplier or PlayerBalance.BaseCooldownMultiplier or 1.0) * cooldownBuffMult
	local expMult = effects.expMultiplier or PlayerBalance.BaseExpMultiplier or 1.0
	local totalSpeedMult = computeTotalSpeedMultiplier(effects)

	local baseHealth = PlayerBalance.BaseMaxHealth or 100
	local baseWalk = PlayerBalance.BaseWalkSpeed or 16
	local basePickup = PlayerBalance.BasePickupRange or 20
	local baseRegen = PlayerBalance.HealthRegenRate or 0
	local baseRegenDelay = PlayerBalance.HealthRegenDelay or 0

	local healthMult = effects.healthMultiplier or 1.0
	local finalHealth = baseHealth * healthMult
	local finalSpeed = baseWalk * totalSpeedMult
	local finalPickup = basePickup * (effects.pickupRangeMultiplier or 1.0)
	local finalRegen = baseRegen * (effects.regenMultiplier or 1.0)
	local finalRegenDelay = baseRegenDelay * (effects.regenDelayMultiplier or 1.0)
	local finalDurationMult = (effects.durationMultiplier or 1.0) * durationBuffMult
	local finalPenetrationMult = (effects.penetrationMultiplier or 1.0) * penetrationBuffMult

	-- Health section
	setGeneralRow("health", "Max Health", formatNumber(finalHealth, 1), false)
	setGeneralRow("armor", "Armor", formatPercent(effects.armorReduction or 0), false)
	setGeneralRow("regen", "Regen / sec", formatNumber(finalRegen, 2), false)
	setGeneralRow("regenDelay", "Regen Delay", formatNumber(finalRegenDelay, 2) .. "s", false)
	setGeneralRow("lifesteal", "Lifesteal", formatPercent(effects.lifesteal or 0, 2), false)

	-- Damage section
	setGeneralRow("damageMult", "Damage", formatMultiplierPercent(damageMult), hasDamageBuff)
	setGeneralRow("critChance", "Crit Chance", formatPercent(effects.critChance or 0), false)
	setGeneralRow("critDamage", "Crit Damage", string.format("x%.2f", 2 + (effects.critDamage or 0)), false)
	setGeneralRow("cooldown", "Cooldown", formatMultiplierPercent(cooldownMult), hasCooldownBuff)
	setGeneralRow("abilitySize", "Ability Size", formatMultiplierPercent(effects.sizeMultiplier or 1.0), false)
	setGeneralRow("abilityDuration", "Ability Duration", formatMultiplierPercent(finalDurationMult), arcaneActive == true or hasDurationBuff)
	setGeneralRow("penetration", "Penetration", formatMultiplierPercent(finalPenetrationMult), arcaneActive == true or hasPenetrationBuff)
	setGeneralRow("projectileCountBonus", "Projectile Count Bonus", formatCountWithFloor(effects.projectileCountBonus or 0, 1), false)

	-- Speed section
	setGeneralRow("moveSpeed", "Move Speed", formatNumber(finalSpeed, 1), hasSpeedBuff)
	setGeneralRow("mobilityCooldown", "Mobility Cooldown", formatMultiplierPercent(effects.mobilityCooldownMultiplier or 1.0), false)
	setGeneralRow("mobilityDistance", "Mobility Distance", formatMultiplierPercent(effects.mobilityDistanceMultiplier or 1.0), hasSpeedBuff)

	-- Utility section
	setGeneralRow("pickupRange", "Pickup Range", formatNumber(finalPickup, 1), false)
	setGeneralRow("expGain", "Exp Gain", formatMultiplierPercent(expMult), false)
	setGeneralRow("luck", "Luck", formatPercent(effects.luck or 0), false)

	-- Totals at the bottom
	local totalDamage = 0
	local sessionStats = playerComponentState.SessionStats
	if typeof(sessionStats) == "number" then
		sessionStats = sharedComponents.SessionStats[sessionStats]
	end
	if sessionStats and typeof(sessionStats) == "table" then
		totalDamage = sessionStats.totalDamage or 0
	else
		local damageStats = playerComponentState.AbilityDamageStats
		if typeof(damageStats) == "number" then
			damageStats = sharedComponents.AbilityDamageStats[damageStats]
		end
		if damageStats == nil then
			damageStats = lastDamageStats
		end
		if damageStats and typeof(damageStats) == "table" then
			for _, value in pairs(damageStats) do
				if typeof(value) == "number" then
					totalDamage += value
				end
			end
		end
	end
	if totalDamage > 0 then
		lastTotalDamage = totalDamage
	elseif lastTotalDamage > 0 then
		totalDamage = lastTotalDamage
	end
	setGeneralRow("totalDamage", "Total Damage", formatInt(totalDamage), false)
end

local spellButtons: {[string]: TextButton} = {}
local activeDetailId: string? = nil

local function clearSpellList()
	for _, button in pairs(spellButtons) do
		button:Destroy()
	end
	table.clear(spellButtons)
end

local function showSpellList()
	spellDetailFrame.Visible = false
	spellListFrame.Visible = true
	activeDetailId = nil
end

local function showSpellDetail()
	spellDetailFrame.Visible = true
	spellListFrame.Visible = false
end

backButton.Activated:Connect(showSpellList)

local function rebuildDetail(abilityId: string)
	local abilityData = playerComponentState.AbilityData
	if typeof(abilityData) == "number" then
		abilityData = sharedComponents.AbilityData[abilityData]
	end
	for _, child in ipairs(detailScroll:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	detailScroll.Visible = true
	if not abilityData or not abilityData.abilities then
		abilityData = lastAbilityData
	end
	if not abilityData or not abilityData.abilities then
		local valueLabel = createStatRow(detailScroll, "No data")
		valueLabel.Text = "Ability stats not available yet"
		return
	end
	local abilityRecord = abilityData.abilities[abilityId]
	if not abilityRecord then
		local valueLabel = createStatRow(detailScroll, "No data")
		valueLabel.Text = "Ability stats not available yet"
		return
	end

	local passiveEffects = playerComponentState.PassiveEffects
	local buffState = playerComponentState.BuffState
	local damageStats = playerComponentState.AbilityDamageStats
	if typeof(damageStats) == "number" then
		damageStats = sharedComponents.AbilityDamageStats[damageStats]
	end
	if damageStats == nil then
		damageStats = lastDamageStats
	end
	local finalStats = computeAbilityStats(abilityRecord, passiveEffects, buffState)
	local baseStats = abilityRecord.baseStats or {}

	local now = getGameTimeNow()
	local damageBuffMult = computeBuffMultiplier(buffState, "damageMultiplier", now)
	local cooldownBuffMult = computeBuffMultiplier(buffState, "cooldownMultiplier", now)
	local hasDamageBuff = math.abs(damageBuffMult - 1.0) > 1e-4
	local hasCooldownBuff = math.abs(cooldownBuffMult - 1.0) > 1e-4
	local arcaneBuff = buffState and buffState.buffs and buffState.buffs["ArcaneRune"]
	local arcaneActive = arcaneBuff and (arcaneBuff.endTime == nil or arcaneBuff.endTime > now) or false
	local durationBuffMult = computeBuffMultiplier(buffState, "durationMultiplier", now)
	local penetrationBuffMult = computeBuffMultiplier(buffState, "penetrationMultiplier", now)
	local speedBuffMult = computeBuffMultiplier(buffState, "projectileSpeedMultiplier", now)
	local hasDurationBuff = math.abs(durationBuffMult - 1.0) > 1e-4
	local hasPenetrationBuff = math.abs(penetrationBuffMult - 1.0) > 1e-4
	local hasSpeedBuff = math.abs(speedBuffMult - 1.0) > 1e-4

	local function addRow(label: string, value: string, highlight: boolean?)
		local valueLabel = createStatRow(detailScroll, label)
		valueLabel.Text = value
		local nameLabel = valueLabel.Parent:FindFirstChild("Name")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.TextColor3 = highlight and BUFF_TEXT_COLOR or DEFAULT_TEXT_COLOR
		end
		if highlight then
			valueLabel.TextColor3 = BUFF_TEXT_COLOR
		else
			valueLabel.TextColor3 = DEFAULT_TEXT_COLOR
		end
	end

	addRow("Level", tostring(abilityRecord.level or 1), false)
	if abilityRecord.selectedAttribute then
		addRow("Attribute", tostring(abilityRecord.selectedAttribute), false)
	end

	local baseDamage = baseStats.damage or abilityRecord.damage or 0
	local finalDamage = finalStats.damage or baseDamage
	local damagePct = baseDamage > 0 and formatPercent((finalDamage / baseDamage) - 1) or "0%"
	addRow("Base Damage", formatNumber(baseDamage, 1), false)
	addRow("Final Damage", string.format("%s (%s)", formatNumber(finalDamage, 1), damagePct), hasDamageBuff)

	if baseStats.explosionDamage or finalStats.explosionDamage then
		local baseExplosion = baseStats.explosionDamage or 0
		local finalExplosion = finalStats.explosionDamage or baseExplosion
		local explosionPct = baseExplosion > 0 and formatPercent((finalExplosion / baseExplosion) - 1) or "0%"
		addRow("Explosion Damage", string.format("%s (%s)", formatNumber(finalExplosion, 1), explosionPct), hasDamageBuff)
	end

	if finalStats.cooldown then
		local baseCooldown = baseStats.cooldown or finalStats.cooldown
		addRow("Cooldown", string.format("%ss (base %ss)", formatNumber(finalStats.cooldown, 2), formatNumber(baseCooldown, 2)), hasCooldownBuff)
	end
	if finalStats.projectileSpeed then
		addRow("Projectile Speed", formatNumber(finalStats.projectileSpeed, 1), arcaneActive == true or hasSpeedBuff)
	end
	if finalStats.projectileCount then
		if abilityId == "Refractions" then
			local shots = finalStats.shotAmountRaw or finalStats.shotAmount or 1
			local count = finalStats.projectileCountRaw or finalStats.projectileCount or 1
			local rawLaser = math.max(1, count + shots - 1)
			local laserCount = math.max(1, math.floor(rawLaser + 0.0001))
			addRow("Projectile Bonus", string.format("%s (%d)", formatNumber(rawLaser, 1), laserCount), false)
		else
			local rawCount = finalStats.projectileCountRaw or finalStats.projectileCount
			addRow("Projectile Count", formatCountWithFloor(rawCount, 1), false)
		end
	end
	if finalStats.shotAmount and abilityId ~= "Refractions" then
		local rawShot = finalStats.shotAmountRaw or finalStats.shotAmount
		addRow("Shot Amount", formatCountWithFloor(rawShot, 1), false)
	end
	if finalStats.pulseInterval then
		addRow("Pulse Interval", formatNumber(finalStats.pulseInterval, 2) .. "s", false)
	end
	if finalStats.penetration then
		addRow("Penetration", tostring(finalStats.penetration), arcaneActive == true or hasPenetrationBuff)
	end
	if finalStats.duration then
		addRow("Duration", formatNumber(finalStats.duration, 2) .. "s", arcaneActive == true or hasDurationBuff)
	end
	if finalStats.scale then
		addRow("Size", formatNumber(finalStats.scale, 2) .. "x", false)
	end
	local sessionStats = playerComponentState.SessionStats
	if typeof(sessionStats) == "number" then
		sessionStats = sharedComponents.SessionStats[sessionStats]
	end
	local totalDamage, hasValue = getAbilityDamage(damageStats, sessionStats, abilityId, abilityRecord)
	if hasValue then
		lastSpellDamageById[abilityId] = totalDamage
	elseif lastSpellDamageById[abilityId] and lastSpellDamageById[abilityId] > 0 then
		totalDamage = lastSpellDamageById[abilityId]
	end
	addRow("Damage Done", formatInt(totalDamage), false)
end

local function updateSpellList()
	local abilityData = playerComponentState.AbilityData
	if typeof(abilityData) == "number" then
		abilityData = sharedComponents.AbilityData[abilityData]
	end
	if not abilityData or not abilityData.abilities then
		return
	end
	lastAbilityData = abilityData
	local damageStats = playerComponentState.AbilityDamageStats
	if typeof(damageStats) == "number" then
		damageStats = sharedComponents.AbilityDamageStats[damageStats]
	end
	if damageStats and typeof(damageStats) == "table" then
		lastDamageStats = damageStats
	end

	local seen: {[string]: boolean} = {}
	for abilityId, record in pairs(abilityData.abilities) do
		if record and record.enabled then
			local abilityKey = tostring(abilityId)
			local displayName = record.name or record.Name or abilityId
			if record.selectedAttribute then
				displayName = string.format("%s [%s]", displayName, record.selectedAttribute)
			end

			local button = spellButtons[abilityKey]
			if not button then
				button = Instance.new("TextButton")
				button.Name = abilityKey .. "Button"
				button.Size = UDim2.new(1, 0, 0, 28)
				button.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
				button.BackgroundTransparency = 0.4
				button.BorderSizePixel = 0
				button.Font = Enum.Font.GothamMedium
				button.TextSize = 14
				button.TextColor3 = Color3.fromRGB(230, 230, 230)
				button.TextXAlignment = Enum.TextXAlignment.Left
				button.Parent = spellList

				local padding = Instance.new("UIPadding")
				padding.PaddingLeft = UDim.new(0.03, 0)
				padding.PaddingRight = UDim.new(0.03, 0)
				padding.Parent = button

				button.Activated:Connect(function()
					activeDetailId = abilityKey
					rebuildDetail(abilityKey)
					showSpellDetail()
				end)

				spellButtons[abilityKey] = button
			end

			if button.Text ~= displayName then
				button.Text = displayName
			end

			seen[abilityKey] = true
		end
	end

	for abilityId, button in pairs(spellButtons) do
		if not seen[abilityId] then
			button:Destroy()
			spellButtons[abilityId] = nil
		end
	end
end

local function refreshUI()
	updateGeneralStats()
	updateSpellList()
	if activeDetailId then
		rebuildDetail(activeDetailId)
	end
end

local function toggleGui()
	screenGui.Enabled = not screenGui.Enabled
	if screenGui.Enabled then
		if not playerEntityId then
			fetchInitialSnapshot()
		end
		needsRefresh = true
		refreshUI()
	end
end

ContextActionService:BindActionAtPriority(
	"ToggleStatsPanel",
	function(_, state, _input)
		if state == Enum.UserInputState.Begin then
			toggleGui()
		end
		return Enum.ContextActionResult.Sink
	end,
	false,
	Enum.ContextActionPriority.High.Value,
	Enum.KeyCode.H
)

RunService.Heartbeat:Connect(function()
	if not screenGui.Enabled then
		return
	end
	local now = os.clock()
	if now - lastRefresh >= REFRESH_INTERVAL then
		lastRefresh = now
		needsRefresh = false
		refreshUI()
	end
end)
