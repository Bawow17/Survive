--!strict
-- StatsPanelController - H toggle general stats panel

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local PlayerBalance = require(sharedFolder:WaitForChild("PlayerBalance"))
local CombatScaling = require(sharedFolder:WaitForChild("CombatScaling"))

local remotes = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS")
local entitySync = remotes:WaitForChild("EntitySync")
local entityUpdate = remotes:WaitForChild("EntityUpdate")
local entityUpdateUnreliable = remotes:FindFirstChild("EntityUpdateUnreliable")
local entityDespawn = remotes:FindFirstChild("EntityDespawn")
local requestInitialSync = remotes:WaitForChild("RequestInitialSync")
local gameTimeUpdate = ReplicatedStorage:WaitForChild("RemoteEvents"):FindFirstChild("GameTimeUpdate")

local playerEntityId: number? = nil
local playerComponentState: {[string]: any} = {}
local lastRefresh = 0
local REFRESH_INTERVAL = 0.25
local serverGameTime: number? = nil
local lastCooldownBaseMult: number? = nil
local lastDamageStats: any = nil
local lastTotalDamage: number = 0

local sharedComponents: {[string]: {[number]: any}} = {
	EntityType = {},
	AbilityDamageStats = {},
	SessionStats = {},
	Level = {},
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
			if bucket and bucket[value] ~= nil then
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

local function handlePlayerEntityData(entityId: number, entityData: {[string]: any})
	local entityType = entityData.EntityType
	if entityType and typeof(entityType) == "table" then
		if entityType.type ~= "Player" or entityType.player ~= localPlayer then
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
					lastCooldownBaseMult = nil
					break
				end
			end
		elseif despawns == playerEntityId then
			playerEntityId = nil
			table.clear(playerComponentState)
			lastCooldownBaseMult = nil
		end
	end)
end
if gameTimeUpdate and gameTimeUpdate:IsA("RemoteEvent") then
	gameTimeUpdate.OnClientEvent:Connect(function(gameTime: any)
		if typeof(gameTime) == "number" then
			serverGameTime = gameTime
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
local rightPanel = screenGui:FindFirstChild("SpellStatsPanel")
if rightPanel and rightPanel:IsA("GuiObject") then
	rightPanel.Visible = false
end

local generalList = leftPanel:WaitForChild("GeneralList") :: ScrollingFrame
local generalLayout = generalList:FindFirstChildOfClass("UIListLayout")
if not generalLayout then
	generalLayout = Instance.new("UIListLayout")
	generalLayout.Padding = UDim.new(0, 6)
	generalLayout.SortOrder = Enum.SortOrder.LayoutOrder
	generalLayout.Parent = generalList
end

local function formatNumber(value: number, decimals: number?): string
	local places = decimals or 1
	local fmt = "%." .. tostring(places) .. "f"
	return string.format(fmt, value)
end

local function formatInt(value: number?): string
	local raw = value or 0
	local rounded = math.floor(raw + 0.0001)
	local sign = ""
	if rounded < 0 then
		sign = "-"
		rounded = -rounded
	end
	local text = tostring(rounded)
	local withCommas = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if withCommas:sub(1, 1) == "," then
		withCommas = withCommas:sub(2)
	end
	return sign .. withCommas
end

local function formatPercent(value: number, decimals: number?): string
	local places = decimals or 1
	local fmt = "%." .. tostring(places) .. "f%%"
	return string.format(fmt, value * 100)
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
	local totalBonus = baseMult - 1.0
	if effects and typeof(effects.activeSpeedBuffs) == "table" then
		for _, buffData in pairs(effects.activeSpeedBuffs) do
			if typeof(buffData) == "table" then
				totalBonus += (buffData.multiplier or 1.0) - 1.0
			end
		end
	end
	return math.max(0, 1.0 + totalBonus)
end

local function resolveLevelComponent(): any
	local levelData = playerComponentState.Level
	if typeof(levelData) == "number" then
		return sharedComponents.Level[levelData]
	end
	return levelData
end

local function resolvePlayerLevel(): number
	local levelData = resolveLevelComponent()
	if typeof(levelData) == "table" and typeof(levelData.current) == "number" then
		return math.max(1, math.floor(levelData.current))
	end
	if typeof(levelData) == "number" then
		return math.max(1, math.floor(levelData))
	end
	return 1
end

local function resolveAbilityDamageStats(): any
	local damageStats = playerComponentState.AbilityDamageStats
	if typeof(damageStats) == "number" then
		damageStats = sharedComponents.AbilityDamageStats[damageStats]
	end
	return damageStats
end

local function resolveSessionStats(): any
	local sessionStats = playerComponentState.SessionStats
	if typeof(sessionStats) == "number" then
		sessionStats = sharedComponents.SessionStats[sessionStats]
	end
	return sessionStats
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

local DEFAULT_TEXT_COLOR = Color3.fromRGB(200, 200, 200)
local BUFF_TEXT_COLOR = Color3.fromRGB(120, 180, 255)

local GENERAL_ROW_IDS: {[string]: boolean} = {
	health = true,
	armor = true,
	regen = true,
	regenDelay = true,
	lifesteal = true,
	baseDamage = true,
	damage = true,
	critChance = true,
	critDamage = true,
	cooldown = true,
	moveSpeed = true,
	totalDamage = true,
}

local function setGeneralRow(id: string, label: string, value: string, layoutOrder: number, highlight: boolean?)
	local row = generalRows[id]
	if not row then
		row = createStatRow(generalList, label)
		generalRows[id] = row
	end

	local rowFrame = row.Parent
	if rowFrame and rowFrame:IsA("Frame") then
		rowFrame.LayoutOrder = layoutOrder
	end

	row.Text = value

	local nameLabel = row.Parent and row.Parent:FindFirstChild("Name")
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = label
		nameLabel.TextColor3 = highlight and BUFF_TEXT_COLOR or DEFAULT_TEXT_COLOR
	end
	row.TextColor3 = highlight and BUFF_TEXT_COLOR or DEFAULT_TEXT_COLOR
end

local function pruneGeneralRows()
	for id, row in pairs(generalRows) do
		if not GENERAL_ROW_IDS[id] then
			local rowFrame = row.Parent
			if rowFrame then
				rowFrame:Destroy()
			else
				row:Destroy()
			end
			generalRows[id] = nil
		end
	end
end

local function updateGeneralStats()
	local effects = playerComponentState.PassiveEffects or {}
	local buffState = playerComponentState.BuffState or {}
	local now = getGameTimeNow()

	local damageBuffMult = computeBuffMultiplier(buffState, "damageMultiplier", now)
	local cooldownBuffMult = computeBuffMultiplier(buffState, "cooldownMultiplier", now)
	local hasDamageBuff = math.abs(damageBuffMult - 1.0) > 1e-4
	local hasCooldownBuff = math.abs(cooldownBuffMult - 1.0) > 1e-4

	local hasSpeedBuff = false
	if typeof(effects.activeSpeedBuffs) == "table" then
		for _, buffData in pairs(effects.activeSpeedBuffs) do
			if typeof(buffData) == "table" then
				if not buffData.endTime or buffData.endTime > now then
					hasSpeedBuff = true
					break
				end
			end
		end
	end

	local baseDamageMultiplier = effects.damageMultiplier
	if typeof(baseDamageMultiplier) ~= "number" then
		baseDamageMultiplier = PlayerBalance.BaseDamageMultiplier or 1.0
	end
	local effectiveDamageMultiplier = baseDamageMultiplier * damageBuffMult

	local baseCooldown = effects.cooldownMultiplier
	if typeof(baseCooldown) ~= "number" then
		baseCooldown = PlayerBalance.BaseCooldownMultiplier or 1.0
		if lastCooldownBaseMult ~= nil then
			baseCooldown = lastCooldownBaseMult
		end
	else
		lastCooldownBaseMult = baseCooldown
	end
	local cooldownMult = baseCooldown * cooldownBuffMult
	local totalSpeedMult = computeTotalSpeedMultiplier(effects)

	local baseHealth = PlayerBalance.BaseMaxHealth or 100
	local baseWalk = PlayerBalance.BaseWalkSpeed or 16
	local baseRegen = PlayerBalance.HealthRegenRate or 0
	local baseRegenDelay = PlayerBalance.HealthRegenDelay or 0

	local healthMult = effects.healthMultiplier or 1.0
	local healthFlat = effects.healthFlatBonus or 0
	local finalHealth = baseHealth * healthMult + healthFlat
	local finalSpeed = baseWalk * totalSpeedMult
	local regenFlat = effects.regenFlatBonus or 0
	local finalRegen = (baseRegen * (effects.regenMultiplier or 1.0)) + regenFlat
	local finalRegenDelay = baseRegenDelay * (effects.regenDelayMultiplier or 1.0)

	local playerLevel = resolvePlayerLevel()
	local baseDamage = CombatScaling.getBaseDamageAtLevel(playerLevel, PlayerBalance)
	local finalDamage = baseDamage * effectiveDamageMultiplier

	local totalDamage = 0
	local sessionStats = resolveSessionStats()
	if sessionStats and typeof(sessionStats) == "table" then
		totalDamage = sessionStats.totalDamage or 0
	else
		local damageStats = resolveAbilityDamageStats()
		if damageStats and typeof(damageStats) == "table" then
			lastDamageStats = damageStats
		else
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

	setGeneralRow("health", "Max Health", formatNumber(finalHealth, 1), 1, false)
	setGeneralRow("armor", "Armor", formatPercent(effects.armorReduction or 0), 2, false)
	setGeneralRow("regen", "Regen / sec", formatNumber(finalRegen, 2), 3, false)
	setGeneralRow("regenDelay", "Regen Delay", formatNumber(finalRegenDelay, 2) .. "s", 4, false)
	setGeneralRow("lifesteal", "Lifesteal", formatPercent(effects.lifesteal or 0, 2), 5, false)
	setGeneralRow("baseDamage", "Base Damage", formatNumber(baseDamage, 1), 6, false)
	setGeneralRow("damage", "Damage", formatNumber(finalDamage, 1), 7, hasDamageBuff)
	setGeneralRow("critChance", "Crit Chance", formatPercent(effects.critChance or 0), 8, false)
	setGeneralRow("critDamage", "Crit Damage", string.format("x%.2f", 2 + (effects.critDamage or 0)), 9, false)
	setGeneralRow("cooldown", "Cooldown", formatMultiplierPercent(cooldownMult), 10, hasCooldownBuff)
	setGeneralRow("moveSpeed", "Move Speed", formatNumber(finalSpeed, 1), 11, hasSpeedBuff)
	setGeneralRow("totalDamage", "Total Damage", formatInt(totalDamage), 12, false)

	pruneGeneralRows()
end

local function refreshUI()
	updateGeneralStats()
end

local function toggleGui()
	screenGui.Enabled = not screenGui.Enabled
	if screenGui.Enabled then
		if rightPanel and rightPanel:IsA("GuiObject") then
			rightPanel.Visible = false
		end
		if not playerEntityId then
			fetchInitialSnapshot()
		end
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
		refreshUI()
	end
end)
