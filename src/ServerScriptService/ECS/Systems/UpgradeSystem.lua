
--!strict
-- UpgradeSystem - New rarity-based upgrade system with roll budgets and soft caps

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local AbilityRegistry = require(game.ServerScriptService.Abilities.AbilityRegistry)
local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)
local UpgradeDefs = require(game.ServerScriptService.Balance.Upgrades.UpgradeDefs)
local DashConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.Dash)
local IceTracerConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.IceTracer)
local ShieldBashConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.ShieldBash)
local DoubleJumpConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.DoubleJump)
local BlinkConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.Blink)
local ManaGrappleConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.ManaGrapple)

local UpgradeSystem = {}

local world: any
local Components: any
local DirtyService: any

local Upgrades: any
local PassiveEffects: any
local PlayerStats: any
local AbilityData: any
local AttributeSelections: any
local AfterimageClones: any

local RNG = Random.new()
local ABILITY_REPEAT_BIAS = 0.25
local PASSIVE_REPEAT_BIAS = 0.25
local RARITY_ORDER = {
	Common = 1,
	Rare = 2,
	Epic = 3,
	Legendary = 4,
}

local playerQuery: any
local REBUILD_INTERVAL = 1.0
local rebuildAccumulator = 0
local applyMobilityUpgrade: ((number, string) -> boolean)?

local function clamp01(value: number): number
	return math.clamp(value, 0, 1)
end

function UpgradeSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService

	Upgrades = Components.Upgrades
	PassiveEffects = Components.PassiveEffects
	PlayerStats = Components.PlayerStats
	AbilityData = Components.AbilityData
	AttributeSelections = Components.AttributeSelections
	AfterimageClones = Components.AfterimageClones

	playerQuery = world:query(Components.PlayerStats):cached()
end

-- Auto-equip starter mobility for new players (called on player spawn)
local function equipStarterDash(playerEntity: number)
	if applyMobilityUpgrade and applyMobilityUpgrade(playerEntity, "IceTracer") then
		return
	end

	-- Fallback if starter mobility fails to apply.
	local fallbackData = {
		equippedMobility = "IceTracer",
		distance = IceTracerConfig.distance,
		cooldown = IceTracerConfig.cooldown,
		duration = IceTracerConfig.duration,
		iceTracerPathPath = IceTracerConfig.iceTracerPathModelPath and ("ReplicatedStorage." .. IceTracerConfig.iceTracerPathModelPath) or nil,
		iceTracerBeam1Path = IceTracerConfig.iceTracerBeam1ModelPath and ("ReplicatedStorage." .. IceTracerConfig.iceTracerBeam1ModelPath) or nil,
		iceTracerBeam2Path = IceTracerConfig.iceTracerBeam2ModelPath and ("ReplicatedStorage." .. IceTracerConfig.iceTracerBeam2ModelPath) or nil,
		iceTracerAnimationPath = IceTracerConfig.iceTracerAnimationModelPath and ("ReplicatedStorage." .. IceTracerConfig.iceTracerAnimationModelPath) or nil,
		iceTracerPathSpacing = IceTracerConfig.pathSpacing,
		iceTracerRampFrames = IceTracerConfig.rampFrames,
		iceTracerTotalFrames = IceTracerConfig.totalFrames,
		iceTracerLookAheadDistance = IceTracerConfig.lookAheadDistance,
		iceTracerPartLifetime = IceTracerConfig.pathPartLifetime,
	}
	DirtyService.setIfChanged(world, playerEntity, Components.MobilityData, fallbackData, "MobilityData")
	DirtyService.setIfChanged(world, playerEntity, Components.MobilityCooldown, { lastUsedTime = 0 }, "MobilityCooldown")
end

UpgradeSystem.equipStarterDash = equipStarterDash

local function parseModifier(value: any, baseValue: number): number
	if type(value) == "number" then
		return value
	end

	local str = tostring(value)
	local addPercent = str:match("^%+(%d+%.?%d*)%%$")
	if addPercent then
		local percent = tonumber(addPercent)
		return baseValue * (1 + percent / 100)
	end

	local subPercent = str:match("^%-(%d+%.?%d*)%%$")
	if subPercent then
		local percent = tonumber(subPercent)
		return baseValue * (1 - percent / 100)
	end

	local setPercent = str:match("^(%d+%.?%d*)%%$")
	if setPercent then
		local percent = tonumber(setPercent)
		return baseValue * (percent / 100)
	end

	local addNum = str:match("^([%+%-]%d+%.?%d*)$")
	if addNum then
		local num = tonumber(addNum)
		return baseValue + num
	end

	local mulNum = str:match("^%*(%d+%.?%d*)$")
	if mulNum then
		local num = tonumber(mulNum)
		return baseValue * num
	end

	warn("[UpgradeSystem] Could not parse modifier:", value)
	return baseValue
end

local function ensureUpgradeState(playerEntity: number): any
	local upgrades = world:get(playerEntity, Upgrades)
	if not upgrades then
		upgrades = {
			abilities = {},
			passives = {
				stats = {},
				counts = {},
			},
		}
		world:set(playerEntity, Upgrades, upgrades)
	end

	if not upgrades.abilities then
		upgrades.abilities = {}
	end
	if not upgrades.passives then
		upgrades.passives = { stats = {}, counts = {}, levels = {} }
	end
	if not upgrades.passives.stats then
		upgrades.passives.stats = {}
	end
	if not upgrades.passives.counts then
		upgrades.passives.counts = {}
	end
	if not upgrades.passives.statStacks then
		upgrades.passives.statStacks = {}
	end
	if not upgrades.passives.levels then
		upgrades.passives.levels = {}
	end

	return upgrades
end

local function ensureAbilityUpgradeState(upgrades: any, abilityId: string): any
	local abilityState = upgrades.abilities[abilityId]
	if not abilityState then
		abilityState = {
			level = 0,
			stats = {},
			counts = {},
		}
		upgrades.abilities[abilityId] = abilityState
	end
	if not abilityState.stats then
		abilityState.stats = {}
	end
	if not abilityState.counts then
		abilityState.counts = {}
	end
	if not abilityState.statStacks then
		abilityState.statStacks = {}
	end
	return abilityState
end

local function applySoftCap(rawValue: number, cap: number?, curveK: number?): number
	if not cap or cap <= 0 then
		return rawValue
	end
	if rawValue <= 0 then
		return 0
	end
	local k = curveK or UpgradeDefs.SoftCaps.curveK
	return cap * (1 - math.exp(-k * rawValue / cap))
end

local function computeStackMultiplier(values: {number}?): number
	if not values or #values == 0 then
		return 1
	end
	local mult = 1
	for _, value in ipairs(values) do
		if typeof(value) == "number" then
			local clamped = math.clamp(value, -0.95, 0.95)
			mult = mult * (1 - clamped)
		end
	end
	return mult
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function formatPercent(value: number): string
	local percent = value * 100
	if percent < 1 then
		return string.format("%.2f%%", percent)
	end
	return string.format("%.1f%%", percent)
end

local passiveStatById: {[string]: any} = {}
for _, def in pairs(UpgradeDefs.PassiveStats) do
	if def.id then
		passiveStatById[def.id] = def
	end
end

local abilityStatById: {[string]: any} = {}
for _, def in pairs(UpgradeDefs.AbilityStats) do
	if def.id then
		abilityStatById[def.id] = def
	end
end

local countStatFields: {[string]: boolean} = {}
for _, def in pairs(UpgradeDefs.AbilityStats) do
	if def.kind == "count" and type(def.field) == "string" then
		countStatFields[def.field] = true
	end
end
countStatFields.projectileCount = true
countStatFields.shotAmount = true

local function getOwnedAbilities(playerEntity: number): {string}
	local abilityIds = {}
	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or not abilityData.abilities then
		return abilityIds
	end
	for abilityId, record in pairs(abilityData.abilities) do
		if record and record.enabled then
			table.insert(abilityIds, abilityId)
		end
	end
	return abilityIds
end

local function hasAbilityUnlocked(playerEntity: number, abilityId: string): boolean
	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or not abilityData.abilities then
		return false
	end
	local ability = abilityData.abilities[abilityId]
	return ability ~= nil and ability.enabled == true
end

local function getLuckValue(playerEntity: number): number
	local effects = world:get(playerEntity, PassiveEffects)
	if effects and typeof(effects.luck) == "number" then
		return 1 + effects.luck
	end
	return 1
end

local function getRarityWeights(luckValue: number): {[string]: number}
	local commonWeight = UpgradeDefs.Rarities.Common.weight
	local rareWeight = UpgradeDefs.Rarities.Rare.weight
	local epicWeight = UpgradeDefs.Rarities.Epic.weight
	local legendaryWeight = UpgradeDefs.Rarities.Legendary.weight

	local luckBonus = math.max(0, (luckValue or 1) - 1)
	local epicMult = math.min(1 + luckBonus, UpgradeDefs.Luck.maxEpicMultiplier)
	local legendaryMult = math.min(1 + luckBonus, UpgradeDefs.Luck.maxLegendaryMultiplier)

	epicWeight = epicWeight * epicMult
	legendaryWeight = legendaryWeight * legendaryMult

	local remaining = 1 - epicWeight - legendaryWeight
	if remaining < 0 then
		local total = commonWeight + rareWeight + epicWeight + legendaryWeight
		if total <= 0 then
			return {
				Common = 0.5,
				Rare = 0.3,
				Epic = 0.15,
				Legendary = 0.05,
			}
		end
		return {
			Common = commonWeight / total,
			Rare = rareWeight / total,
			Epic = epicWeight / total,
			Legendary = legendaryWeight / total,
		}
	end

	local baseCommon = UpgradeDefs.Rarities.Common.weight
	local baseRare = UpgradeDefs.Rarities.Rare.weight
	local totalBase = baseCommon + baseRare
	local commonRatio = if totalBase > 0 then baseCommon / totalBase else 0.5
	commonWeight = remaining * commonRatio
	rareWeight = remaining * (1 - commonRatio)

	return {
		Common = commonWeight,
		Rare = rareWeight,
		Epic = epicWeight,
		Legendary = legendaryWeight,
	}
end

local function isRarityAtLeast(rarityId: string, minRarityId: string): boolean
	local rIndex = RARITY_ORDER[rarityId] or 1
	local minIndex = RARITY_ORDER[minRarityId] or 1
	return rIndex >= minIndex
end

local function clampRarityId(rarityId: string, minRarityId: string): string
	if not minRarityId then
		return rarityId
	end
	if isRarityAtLeast(rarityId, minRarityId) then
		return rarityId
	end
	return minRarityId
end

local function getRarityScale(rarityId: string): number
	if UpgradeDefs.RarityScales and UpgradeDefs.RarityScales[rarityId] then
		return UpgradeDefs.RarityScales[rarityId]
	end
	local rarity = UpgradeDefs.Rarities[rarityId]
	return (rarity and rarity.scale) or 1
end

local function getStatValue(def: any, rarityId: string): number
	if def.rarityValues then
		return def.rarityValues[rarityId] or 0
	end
	local baseValue = def.baseValue or def.max or 0
	return baseValue * getRarityScale(rarityId)
end

local function rollRarity(playerEntity: number): any
	local luckValue = getLuckValue(playerEntity)
	local weights = getRarityWeights(luckValue)
	local roll = RNG:NextNumber()
	local cumulative = 0

	for _, rarity in ipairs({UpgradeDefs.Rarities.Common, UpgradeDefs.Rarities.Rare, UpgradeDefs.Rarities.Epic, UpgradeDefs.Rarities.Legendary}) do
		local weight = weights[rarity.id] or 0
		cumulative += weight
		if roll <= cumulative then
			return rarity
		end
	end

	return UpgradeDefs.Rarities.Common
end
local function weightedPick(list: {any}, weightFn: (any) -> number): (any?, number?)
	local totalWeight = 0
	for _, item in ipairs(list) do
		totalWeight += math.max(0, weightFn(item))
	end
	if totalWeight <= 0 then
		return nil, nil
	end
	local roll = RNG:NextNumber() * totalWeight
	local acc = 0
	for index, item in ipairs(list) do
		acc += math.max(0, weightFn(item))
		if roll <= acc then
			return item, index
		end
	end
	return list[#list], #list
end

local function rollAbilityStatCount(rarity: any, poolSize: number): number
	local rarityId = rarity and rarity.id or "Common"
	if poolSize <= 1 then
		return 1
	end

	-- Legendary: exactly 1/3 chance for 1, 2, or 3 stats
	if rarityId == "Legendary" then
		local roll = RNG:NextNumber()
		if roll < (1 / 3) then
			return 1
		elseif roll < (2 / 3) then
			return math.min(2, poolSize)
		else
			return math.min(3, poolSize)
		end
	end

	local weights = UpgradeDefs.AbilityStatCountWeights and UpgradeDefs.AbilityStatCountWeights[rarityId]
	if not weights then
		local minStats = math.min(rarity.minStats or 1, poolSize)
		local maxStats = math.min(rarity.maxStats or minStats, poolSize)
		return RNG:NextInteger(minStats, maxStats)
	end

	local choices = {}
	local total = 0
	for count = 1, 3 do
		if count <= poolSize then
			local w = weights[count] or 0
			if w > 0 then
				total += w
				table.insert(choices, {count = count, weight = w, cumulative = total})
			end
		end
	end

	if total <= 0 then
		return math.min(1, poolSize)
	end

	local roll = RNG:NextNumber() * total
	for _, entry in ipairs(choices) do
		if roll <= entry.cumulative then
			return entry.count
		end
	end

	return choices[#choices].count
end

local function pickAbilityStatDefs(abilityBalance: any, upgrades: any, abilityId: string, choiceRarityId: string): {any}
	local statPool = {}
	local abilityState = ensureAbilityUpgradeState(upgrades, abilityId)
	for _, def in pairs(UpgradeDefs.AbilityStats) do
		if def.minRarity and not isRarityAtLeast(choiceRarityId, def.minRarity) then
			continue
		end
		if abilityBalance and abilityBalance.upgradeStatBlacklist and abilityBalance.upgradeStatBlacklist[def.id] then
			continue
		end
		if abilityBalance and abilityBalance.upgradeStatWhitelist and not abilityBalance.upgradeStatWhitelist[def.id] then
			continue
		end
		local baseValue = abilityBalance[def.field]
		if typeof(baseValue) ~= "number" then
			continue
		end
		if def.kind == "count" then
			local baseCount = math.max(0, math.floor(baseValue + 0.5))
			local maxBonus = math.max(0, math.floor(baseCount * (UpgradeDefs.SoftCaps.countMaxMultiplier - 1) + 0.0001))
			local currentBonus = abilityState.counts[def.id] or 0
			if maxBonus <= 0 then
				continue
			end
			local remainingRatio = clamp01((maxBonus - currentBonus) / maxBonus)
			if remainingRatio <= 0 then
				continue
			end
			def._selectionWeight = (def.weight or 1) * remainingRatio
		else
			def._selectionWeight = def.weight or 1
		end
		table.insert(statPool, def)
	end
	return statPool
end

local function pickPassiveStatDefs(upgrades: any, playerEntity: number, choiceRarityId: string): {any}
	local statPool = {}
	local mobilityData = world and Components and world:get(playerEntity, Components.MobilityData) or nil
	local equippedMobility = mobilityData and mobilityData.equippedMobility or nil
	for _, def in pairs(UpgradeDefs.PassiveStats) do
		if def.minRarity and not isRarityAtLeast(choiceRarityId, def.minRarity) then
			continue
		end
		if def.hidden then
			continue
		end
		if def.id == "critDamage" then
			local currentCrit = upgrades.passives.stats.critChance or 0
			if currentCrit <= 0 then
				continue
			end
		end
		if def.id == "dashDistance" and not equippedMobility then
			continue
		end
		if def.id == "mobilityCooldown" and not equippedMobility then
			continue
		end
		if def.kind == "count" then
			local currentBonus = upgrades.passives.counts[def.id] or 0
			local maxBonus = math.floor(UpgradeDefs.SoftCaps.countMaxMultiplier - 1 + 0.0001)
			if maxBonus <= 0 then
				continue
			end
			local remainingRatio = clamp01((maxBonus - currentBonus) / maxBonus)
			if remainingRatio <= 0 then
				continue
			end
			def._selectionWeight = (def.weight or 1) * remainingRatio
		else
			def._selectionWeight = def.weight or 1
		end
		table.insert(statPool, def)
	end
	return statPool
end

local function rollStatValues(
	selectedStats: {any},
	rarity: any,
	playerEntity: number?,
	forcedStatRarityId: string?
): ({[string]: number}, {[string]: number}, {[string]: string})
	local rolls: {[string]: number} = {}
	local counts: {[string]: number} = {}
	local statRarities: {[string]: string} = {}
	local choiceRarityId = (rarity and rarity.id) or "Common"
	if forcedStatRarityId and forcedStatRarityId ~= "" then
		choiceRarityId = forcedStatRarityId
	end

	local function rollRarityId(): string
		if forcedStatRarityId and forcedStatRarityId ~= "" then
			return forcedStatRarityId
		end
		if playerEntity then
			return rollRarity(playerEntity).id
		end
		return choiceRarityId
	end

	local function applyStat(def: any, rarityId: string)
		local finalRarity = clampRarityId(rarityId, def.minRarity)
		local value = getStatValue(def, finalRarity)
		statRarities[def.id] = finalRarity
		if def.kind == "count" then
			counts[def.id] = (counts[def.id] or 0) + value
		else
			rolls[def.id] = (rolls[def.id] or 0) + value
		end
	end

	local guaranteedIndex = nil
	if #selectedStats > 1 then
		guaranteedIndex = RNG:NextInteger(1, #selectedStats)
	end

	for index, def in ipairs(selectedStats) do
		if def.kind == "paired" then
			local subStats = def.subStats or {}
			if #subStats > 0 then
				local guaranteedSubIndex = RNG:NextInteger(1, #subStats)
				for subIndex, subId in ipairs(subStats) do
					local subDef = passiveStatById[subId]
					if subDef then
						local rarityId = if subIndex == guaranteedSubIndex then choiceRarityId else rollRarityId()
						local finalRarity = clampRarityId(rarityId, subDef.minRarity)
						local value = getStatValue(subDef, finalRarity)
						statRarities[subDef.id] = finalRarity
						if subDef.kind == "count" then
							counts[subDef.id] = (counts[subDef.id] or 0) + value
						else
							rolls[subDef.id] = (rolls[subDef.id] or 0) + value
						end
					end
				end
			end
		else
			local rarityId: string
			if #selectedStats == 1 then
				rarityId = choiceRarityId
			elseif guaranteedIndex and index == guaranteedIndex then
				rarityId = choiceRarityId
			else
				rarityId = rollRarityId()
			end
			applyStat(def, rarityId)
		end
	end

	return rolls, counts, statRarities
end

local function buildStatDescription(statDefs: {any}, rolls: {[string]: number}, counts: {[string]: number}, statRarities: {[string]: string}?): (string, {any})
	local parts = {}
	local textParts = {}

	local function formatFlat(value: number): string
		if math.abs(value - math.floor(value + 0.0001)) < 1e-4 then
			return string.format("%d", math.floor(value + 0.0001))
		end
		return string.format("%.1f", value)
	end

	local function pushPart(valueText: string, nameText: string, statId: string, rarityId: string?)
		local text = if valueText ~= "" then string.format("%s %s", valueText, nameText) else nameText
		local part = {
			text = text,
			valueText = valueText,
			nameText = nameText,
			statId = statId,
			rarityId = rarityId,
		}
		if rarityId and UpgradeDefs.Rarities[rarityId] then
			part.color = UpgradeDefs.Rarities[rarityId].color
		end
		table.insert(parts, part)
		table.insert(textParts, text)
	end

	for _, def in ipairs(statDefs) do
		if def.kind == "count" then
			local countValue = counts[def.id]
			if countValue and countValue > 0 then
				local displayValue: string
				if countValue % 1 == 0 then
					displayValue = string.format("%d", countValue)
				else
					displayValue = string.format("%.1f", countValue)
				end
				pushPart("+" .. displayValue, def.display, def.id, statRarities and statRarities[def.id])
			end
		elseif def.kind == "paired" then
			local subStats = def.subStats or {}
			for _, subId in ipairs(subStats) do
				local subDef = passiveStatById[subId]
				if subDef then
					local value = rolls[subDef.id]
					if value and value > 0 then
						local rarityId = statRarities and statRarities[subDef.id]
						if subDef.kind == "flat" then
							pushPart("+" .. formatFlat(value), subDef.display, subDef.id, rarityId)
						elseif subDef.effect == "reduce" then
							pushPart("-" .. formatPercent(value), subDef.display, subDef.id, rarityId)
						else
							pushPart("+" .. formatPercent(value), subDef.display, subDef.id, rarityId)
						end
					end
				end
			end
		else
			local value = rolls[def.id]
			if value and value > 0 then
				local rarityId = statRarities and statRarities[def.id]
				if def.kind == "flat" then
					pushPart("+" .. formatFlat(value), def.display, def.id, rarityId)
				elseif def.effect == "reduce" then
					pushPart("-" .. formatPercent(value), def.display, def.id, rarityId)
				else
					pushPart("+" .. formatPercent(value), def.display, def.id, rarityId)
				end
				if def.id == "expGain" then
					pushPart("+" .. formatPercent(value * 0.2), "Pickup Range", "pickupRange", rarityId)
				end
			end
		end
	end
	return table.concat(textParts, ", "), parts
end

local function assignPartColors(parts: {any}, baseRarity: any): {any}
	if not parts or #parts == 0 or not baseRarity then
		return parts
	end

	local needsColor = false
	for _, part in ipairs(parts) do
		if part.color == nil then
			needsColor = true
			break
		end
	end
	if not needsColor then
		return parts
	end

	local anyScore = false
	local ranked = {}
	for index, part in ipairs(parts) do
		local score = part.score
		if typeof(score) == "number" and score > 0 then
			anyScore = true
		end
		table.insert(ranked, {index = index, score = score or 0})
	end

	local rarityOrder = {
		UpgradeDefs.Rarities.Common,
		UpgradeDefs.Rarities.Rare,
		UpgradeDefs.Rarities.Epic,
		UpgradeDefs.Rarities.Legendary,
	}
	local rarityIndex = {
		Common = 1,
		Rare = 2,
		Epic = 3,
		Legendary = 4,
	}
	local baseIndex = rarityIndex[baseRarity.id] or 1

	if not anyScore then
		for _, part in ipairs(parts) do
			if part.color == nil then
				part.color = baseRarity.color
			end
		end
		return parts
	end

	table.sort(ranked, function(a, b)
		return a.score > b.score
	end)

	for rank, entry in ipairs(ranked) do
		local targetIndex = 1
		if baseIndex <= 1 then
			targetIndex = 1
		elseif rank == 1 then
			targetIndex = baseIndex
		elseif rank == 2 then
			if baseIndex >= 3 then
				targetIndex = 2
			else
				targetIndex = 1
			end
		else
			targetIndex = 1
		end

		local rarity = rarityOrder[targetIndex] or UpgradeDefs.Rarities.Common
		if parts[entry.index].color == nil then
			parts[entry.index].color = rarity.color
		end
	end

	return parts
end

local function getHighestRarityId(statRarities: {[string]: string}?, fallbackId: string): string
	if not statRarities then
		return fallbackId
	end
	local bestId = fallbackId
	local bestIndex = RARITY_ORDER[bestId] or 1
	for _, rarityId in pairs(statRarities) do
		local index = RARITY_ORDER[rarityId] or 1
		if index > bestIndex then
			bestIndex = index
			bestId = rarityId
		end
	end
	return bestId
end

local function trimStatRolls(rolls: {[string]: number}, counts: {[string]: number}, maxStats: number): ({[string]: number}, {[string]: number})
	local entries = {}
	for statId, value in pairs(rolls) do
		table.insert(entries, {id = statId, value = math.abs(value), kind = "roll"})
	end
	for statId, value in pairs(counts) do
		table.insert(entries, {id = statId, value = math.abs(value), kind = "count"})
	end

	if #entries <= maxStats then
		return rolls, counts
	end

	table.sort(entries, function(a, b)
		return a.value > b.value
	end)

	local keepRolls: {[string]: boolean} = {}
	local keepCounts: {[string]: boolean} = {}
	for i = 1, math.min(maxStats, #entries) do
		local entry = entries[i]
		if entry.kind == "count" then
			keepCounts[entry.id] = true
		else
			keepRolls[entry.id] = true
		end
	end

	local trimmedRolls: {[string]: number} = {}
	for statId, value in pairs(rolls) do
		if keepRolls[statId] then
			trimmedRolls[statId] = value
		end
	end

	local trimmedCounts: {[string]: number} = {}
	for statId, value in pairs(counts) do
		if keepCounts[statId] then
			trimmedCounts[statId] = value
		end
	end

	return trimmedRolls, trimmedCounts
end

local function countSelectedAttributes(playerEntity: number): number
	local selectionCount = 0
	local attributeSelections = world:get(playerEntity, AttributeSelections)
	if attributeSelections then
		for _ in pairs(attributeSelections) do
			selectionCount += 1
		end
	end

	local abilityData = world:get(playerEntity, AbilityData)
	local abilityCount = 0
	if abilityData and abilityData.abilities then
		for _, abilityRecord in pairs(abilityData.abilities) do
			if abilityRecord and abilityRecord.selectedAttribute then
				abilityCount += 1
			end
		end
	end

	return math.max(selectionCount, abilityCount)
end

local function getAvailableAttributesForAbility(playerEntity: number, abilityId: string): {{id: string, data: any}}
	local available = {}

	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or not abilityData.abilities or not abilityData.abilities[abilityId] then
		return available
	end

	local abilityRecord = abilityData.abilities[abilityId]
	if abilityRecord.selectedAttribute then
		return available
	end

	local abilityLevel = abilityRecord.level or 0
	if abilityLevel < 15 then
		return available
	end

	local attributeSelections = world:get(playerEntity, AttributeSelections)
	if attributeSelections and attributeSelections[abilityId] then
		return available
	end

	local success, attributesModule = pcall(function()
		return require(game.ServerScriptService.Abilities[abilityId].Attributes)
	end)

	if not success or not attributesModule then
		return available
	end

	for attributeId, attributeData in pairs(attributesModule) do
		if type(attributeData) == "table" and attributeData.id then
			table.insert(available, {
				id = attributeData.id,
				data = attributeData,
			})
		end
	end

	return available
end
local function buildAbilityUpgradeChoice(
	playerEntity: number,
	abilityId: string,
	upgrades: any,
	forcedChoiceRarityId: string?,
	forcedStatRarityId: string?
): any?
	local ability = AbilityRegistry.get(abilityId)
	if not ability then
		return nil
	end
	local abilityState = ensureAbilityUpgradeState(upgrades, abilityId)
	local rarity = if forcedChoiceRarityId and UpgradeDefs.Rarities[forcedChoiceRarityId]
		then UpgradeDefs.Rarities[forcedChoiceRarityId]
		else rollRarity(playerEntity)
	local statPool = pickAbilityStatDefs(ability.balance, upgrades, abilityId, rarity.id)
	if #statPool == 0 then
		return nil
	end

	local statCount = rollAbilityStatCount(rarity, #statPool)

	local selected = {}
	local pool = table.clone(statPool)
	for _ = 1, statCount do
		local pick, index = weightedPick(pool, function(def)
			return def._selectionWeight or def.weight or 1
		end)
		if not pick or not index then
			break
		end
		table.insert(selected, pick)
		table.remove(pool, index)
	end

	if #selected == 0 then
		return nil
	end

	local rolls, counts, statRarities = rollStatValues(selected, rarity, playerEntity, forcedStatRarityId)
	local desc, descParts = buildStatDescription(selected, rolls, counts, statRarities)
	local finalRarityId = getHighestRarityId(statRarities, rarity.id)
	local finalRarity = UpgradeDefs.Rarities[finalRarityId] or rarity
	assignPartColors(descParts, finalRarity)
	local abilityName = ability.balance.Name or abilityId

	local choiceId = HttpService:GenerateGUID(false)
	return {
		id = choiceId,
		category = "ability",
		abilityId = abilityId,
		name = abilityName,
		desc = desc,
		descParts = descParts,
		color = finalRarity.color,
		rarity = finalRarity.id,
		level = (abilityState.level or 0) + 1,
		rolls = rolls,
		counts = counts,
	}
end

local function buildPassiveUpgradeChoice(playerEntity: number, upgrades: any, biased: boolean?): any?
	local rarity = rollRarity(playerEntity)
	local statPool = pickPassiveStatDefs(upgrades, playerEntity, rarity.id)
	if #statPool == 0 then
		return nil
	end

	local selectedDef, _ = weightedPick(statPool, function(def)
		local baseWeight = def._selectionWeight or def.weight or 1
		if not biased then
			return baseWeight
		end
		local levels = upgrades.passives.levels or {}
		local level = levels[def.id] or 0
		if def.kind == "paired" then
			level = 0
			for _, subId in ipairs(def.subStats or {}) do
				level = math.max(level, levels[subId] or 0)
			end
		end
		return baseWeight * (1 + level * PASSIVE_REPEAT_BIAS)
	end)
	if not selectedDef then
		return nil
	end

	local rolls, counts, statRarities = rollStatValues({selectedDef}, rarity, playerEntity)
	local desc, descParts = buildStatDescription({selectedDef}, rolls, counts, statRarities)
	local finalRarityId = getHighestRarityId(statRarities, rarity.id)
	local finalRarity = UpgradeDefs.Rarities[finalRarityId] or rarity
	assignPartColors(descParts, finalRarity)

	local choiceId = HttpService:GenerateGUID(false)
	local levels = upgrades.passives.levels or {}
	local levelValue = levels[selectedDef.id] or 0
	if selectedDef.kind == "paired" then
		levelValue = 0
		for _, subId in ipairs(selectedDef.subStats or {}) do
			levelValue = math.max(levelValue, levels[subId] or 0)
		end
	end
	return {
		id = choiceId,
		category = "passive",
		statId = selectedDef.id,
		name = selectedDef.display,
		desc = desc,
		descParts = descParts,
		color = finalRarity.color,
		rarity = finalRarity.id,
		level = levelValue + 1,
		rolls = rolls,
		counts = counts,
	}
end

local function buildUnlockChoices(playerEntity: number): {any}
	local choices = {}
	for _, ability in pairs(AbilityRegistry.getUnlockableAbilities()) do
		if not hasAbilityUnlocked(playerEntity, ability.id) then
			table.insert(choices, {
				id = "unlock_" .. ability.id,
				category = "ability_unlock",
				abilityId = ability.id,
				name = "Unlock " .. (ability.balance.Name or ability.id),
				desc = "Unlock this ability.",
				color = ability.balance.color,
			})
		end
	end
	return choices
end

local function buildAttributeChoice(playerEntity: number, playerLevel: number): any?
	local attributeLevelInterval = 10
	local maxAttributeSlots = 5
	local slotsAvailable = math.min(math.floor(playerLevel / attributeLevelInterval), maxAttributeSlots)
	local slotsUsed = countSelectedAttributes(playerEntity)
	if slotsAvailable <= 0 or slotsUsed >= slotsAvailable then
		return nil
	end

	local availableAttributes = {}
	for _, abilityId in ipairs(getOwnedAbilities(playerEntity)) do
		local attributes = getAvailableAttributesForAbility(playerEntity, abilityId)
		if #attributes > 0 then
			table.insert(availableAttributes, {
				abilityId = abilityId,
				attributes = attributes,
			})
		end
	end

	if #availableAttributes == 0 then
		return nil
	end

	local pickedAbility = availableAttributes[RNG:NextInteger(1, #availableAttributes)]
	local randomAttr = pickedAbility.attributes[RNG:NextInteger(1, #pickedAbility.attributes)]

	return {
		id = pickedAbility.abilityId .. "_attr_" .. randomAttr.id,
		abilityId = pickedAbility.abilityId,
		attributeId = randomAttr.id,
		name = randomAttr.data.name,
		desc = randomAttr.data.desc,
		category = "attribute",
		color = randomAttr.data.color,
	}
end

local function buildMobilityChoices(playerEntity: number): {any}
	local choices = {}
	local mobilityData = world:get(playerEntity, Components.MobilityData)
	local hasMobilityUpgrade = mobilityData and mobilityData.equippedMobility ~= nil and mobilityData.equippedMobility ~= "IceTracer"
	if hasMobilityUpgrade then
		return choices
	end

	local levelComponent = world:get(playerEntity, Components.Level)
	local playerLevel = levelComponent and levelComponent.current or 1
	local mobilityUnlockLevel = ShieldBashConfig.minLevel or 15

	if playerLevel >= mobilityUnlockLevel then
		table.insert(choices, {
			id = "mobility_Dash",
			category = "mobility",
			mobilityId = "Dash",
			name = DashConfig.displayName,
			desc = DashConfig.description,
			color = DashConfig.color,
		})
	end

	if playerLevel >= ShieldBashConfig.minLevel then
		table.insert(choices, {
			id = "mobility_ShieldBash",
			category = "mobility",
			mobilityId = "ShieldBash",
			name = ShieldBashConfig.displayName,
			desc = ShieldBashConfig.description,
			color = ShieldBashConfig.color,
		})
	end

	if playerLevel >= DoubleJumpConfig.minLevel then
		table.insert(choices, {
			id = "mobility_DoubleJump",
			category = "mobility",
			mobilityId = "DoubleJump",
			name = DoubleJumpConfig.displayName,
			desc = DoubleJumpConfig.description,
			color = DoubleJumpConfig.color,
		})
	end

	if playerLevel >= BlinkConfig.minLevel then
		table.insert(choices, {
			id = "mobility_Blink",
			category = "mobility",
			mobilityId = "Blink",
			name = BlinkConfig.displayName,
			desc = BlinkConfig.description,
			color = BlinkConfig.color,
		})
	end

	if playerLevel >= ManaGrappleConfig.minLevel then
		table.insert(choices, {
			id = "mobility_ManaGrapple",
			category = "mobility",
			mobilityId = "ManaGrapple",
			name = ManaGrappleConfig.displayName,
			desc = ManaGrappleConfig.description,
			color = ManaGrappleConfig.color,
		})
	end

	return choices
end

function UpgradeSystem.selectUpgradeChoices(playerEntity: number, level: number, count: number): {any}
	count = count or 6
	local upgrades = ensureUpgradeState(playerEntity)
	local ownedAbilities = getOwnedAbilities(playerEntity)
	local unlockChoices = buildUnlockChoices(playerEntity)
	local mobilityChoices = buildMobilityChoices(playerEntity)
	local choices = {}

	local usedAbilities: {[string]: boolean} = {}
	local usedPassives: {[string]: boolean} = {}
	local usedUnlock = false
	local usedKeys: {[string]: boolean} = {}

	local function getChoiceKey(choice: any): string?
		if not choice then
			return nil
		end
		if choice.category == "passive" and choice.statId then
			return "passive:" .. tostring(choice.statId)
		end
		if choice.category == "ability" and choice.abilityId then
			return "ability:" .. tostring(choice.abilityId)
		end
		if choice.category == "mobility" and choice.mobilityId then
			return "mobility:" .. tostring(choice.mobilityId)
		end
		if choice.category == "ability_unlock" and choice.abilityId then
			return "unlock:" .. tostring(choice.abilityId)
		end
		if choice.category == "attribute" and choice.attributeId then
			return "attribute:" .. tostring(choice.abilityId) .. ":" .. tostring(choice.attributeId)
		end
		if choice.id then
			return "id:" .. tostring(choice.id)
		end
		return nil
	end

	local function markChoice(choice: any): boolean
		local key = getChoiceKey(choice)
		if key and usedKeys[key] then
			return false
		end
		if key then
			usedKeys[key] = true
		end
		if choice.category == "ability" and choice.abilityId then
			usedAbilities[choice.abilityId] = true
		elseif choice.category == "passive" and choice.statId then
			usedPassives[choice.statId] = true
		elseif choice.category == "ability_unlock" then
			usedUnlock = true
		end
		return true
	end

	local function pickAbilityUpgrade(biased: boolean?): any?
		local available = {}
		for _, abilityId in ipairs(ownedAbilities) do
			if not usedAbilities[abilityId] then
				table.insert(available, abilityId)
			end
		end
		if #available == 0 then
			return nil
		end
		local abilityId = available[1]
		if biased then
			local totalWeight = 0
			for _, candidate in ipairs(available) do
				local abilityState = ensureAbilityUpgradeState(upgrades, candidate)
				local levelValue = abilityState.level or 0
				totalWeight += 1 + levelValue * ABILITY_REPEAT_BIAS
			end
			local roll = RNG:NextNumber() * totalWeight
			local acc = 0
			for _, candidate in ipairs(available) do
				local abilityState = ensureAbilityUpgradeState(upgrades, candidate)
				local levelValue = abilityState.level or 0
				acc += 1 + levelValue * ABILITY_REPEAT_BIAS
				if roll <= acc then
					abilityId = candidate
					break
				end
			end
		else
			abilityId = available[RNG:NextInteger(1, #available)]
		end
		local choice = buildAbilityUpgradeChoice(playerEntity, abilityId, upgrades)
		if choice then
			usedAbilities[abilityId] = true
		end
		return choice
	end

	local attributeChoice = buildAttributeChoice(playerEntity, level)
	local biasedTarget = math.min(3, count)
	local randomTarget = count - biasedTarget
	local biasedChoices = {}
	local randomChoices = {}

	local function addChoiceTo(list: {any}, choice: any?): boolean
		if not choice then
			return false
		end
		if not markChoice(choice) then
			return false
		end
		table.insert(list, choice)
		return true
	end

	if attributeChoice then
		if randomTarget > 0 then
			addChoiceTo(randomChoices, attributeChoice)
		elseif biasedTarget > 0 then
			addChoiceTo(biasedChoices, attributeChoice)
		end
	end

	if #mobilityChoices > 0 and #randomChoices < randomTarget then
		local mobilityPick = mobilityChoices[RNG:NextInteger(1, #mobilityChoices)]
		addChoiceTo(randomChoices, mobilityPick)
	end

	local function pickChoice(biased: boolean, isWild: boolean?): any?
		local roll = RNG:NextNumber()
		local pickCategory: string
		if roll < 0.55 and #ownedAbilities > 0 then
			pickCategory = "ability"
		elseif roll < 0.80 then
			pickCategory = "passive"
		elseif #unlockChoices > 0 and not usedUnlock then
			pickCategory = "unlock"
		else
			pickCategory = "passive"
		end

		local choice: any? = nil
		if pickCategory == "ability" and #ownedAbilities > 0 then
			choice = pickAbilityUpgrade(biased and not isWild)
			if not choice then
				if #unlockChoices > 0 and not usedUnlock and RNG:NextNumber() < 0.35 then
					choice = unlockChoices[RNG:NextInteger(1, #unlockChoices)]
				else
					choice = buildPassiveUpgradeChoice(playerEntity, upgrades, biased and not isWild)
				end
			end
		elseif pickCategory == "unlock" and #unlockChoices > 0 then
			choice = unlockChoices[RNG:NextInteger(1, #unlockChoices)]
		else
			choice = buildPassiveUpgradeChoice(playerEntity, upgrades, biased and not isWild)
		end

		if choice and not markChoice(choice) then
			choice = nil
		end

		if not choice then
			local fallback = buildPassiveUpgradeChoice(playerEntity, upgrades)
			if not fallback and #unlockChoices > 0 and not usedUnlock then
				fallback = unlockChoices[RNG:NextInteger(1, #unlockChoices)]
			end
			if not fallback and #ownedAbilities > 0 then
				local abilityId = ownedAbilities[RNG:NextInteger(1, #ownedAbilities)]
				fallback = buildAbilityUpgradeChoice(playerEntity, abilityId, upgrades)
			end
			if fallback and not markChoice(fallback) then
				fallback = nil
			end
			choice = fallback
		end

		return choice
	end

	local function fillChoices(target: number, biased: boolean, list: {any})
		local attempts = 0
		local maxAttempts = target * 10
		local wildSlot = target > 0 and RNG:NextInteger(1, target) or nil
		local slotIndex = 0
		while #list < target and attempts < maxAttempts do
			attempts += 1
			slotIndex += 1
			local isWild = wildSlot and slotIndex == wildSlot
			local choice = pickChoice(biased, isWild)
			if choice then
				table.insert(list, choice)
			else
				break
			end
		end
	end

	fillChoices(biasedTarget, true, biasedChoices)
	if #biasedChoices < biasedTarget then
		fillChoices(biasedTarget, false, biasedChoices)
	end

	fillChoices(randomTarget, false, randomChoices)

	for _, choice in ipairs(biasedChoices) do
		table.insert(choices, choice)
	end
	for _, choice in ipairs(randomChoices) do
		table.insert(choices, choice)
	end

	-- Final safety: if we still have fewer than requested, fill with unique passives.
	if #choices < count then
		local attempts = 0
		local maxAttempts = count * 5
		while #choices < count and attempts < maxAttempts do
			attempts += 1
			local rarity = rollRarity(playerEntity)
			local statPool = pickPassiveStatDefs(upgrades, playerEntity, rarity.id)
			local availablePassives = {}
			for _, def in ipairs(statPool) do
				if def.id and not usedPassives[def.id] then
					table.insert(availablePassives, def)
				end
			end
			if #availablePassives == 0 then
				break
			end

			local def = availablePassives[RNG:NextInteger(1, #availablePassives)]
			local rolls, counts, statRarities = rollStatValues({def}, rarity, playerEntity)
			local desc, descParts = buildStatDescription({def}, rolls, counts, statRarities)
			local finalRarityId = getHighestRarityId(statRarities, rarity.id)
			local finalRarity = UpgradeDefs.Rarities[finalRarityId] or rarity
			assignPartColors(descParts, finalRarity)
			local levels = upgrades.passives.levels or {}
			local levelValue = levels[def.id] or 0
			if def.kind == "paired" then
				levelValue = 0
				for _, subId in ipairs(def.subStats or {}) do
					levelValue = math.max(levelValue, levels[subId] or 0)
				end
			end

			local choice = {
				id = HttpService:GenerateGUID(false),
				category = "passive",
				statId = def.id,
				name = def.display,
				desc = desc,
				descParts = descParts,
				color = finalRarity.color,
				rarity = finalRarity.id,
				level = levelValue + 1,
				rolls = rolls,
				counts = counts,
			}

			if markChoice(choice) then
				table.insert(choices, choice)
			end
		end
	end

	return choices
end

local function getAllAttributesForAbility(playerEntity: number, abilityId: string): {{id: string, data: any}}
	local available = {}
	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or not abilityData.abilities or not abilityData.abilities[abilityId] then
		return available
	end

	local success, attributesModule = pcall(function()
		return require(game.ServerScriptService.Abilities[abilityId].Attributes)
	end)
	if not success or not attributesModule then
		return available
	end

	for _, attributeData in pairs(attributesModule) do
		if type(attributeData) == "table" and attributeData.id then
			table.insert(available, {
				id = attributeData.id,
				data = attributeData,
			})
		end
	end

	table.sort(available, function(a, b)
		return tostring(a.data.name or a.id) < tostring(b.data.name or b.id)
	end)
	return available
end

local function rarityAtLeast(rarity: any, minRarityId: string?): any
	if not minRarityId then
		return rarity
	end
	local minRarity = UpgradeDefs.Rarities[minRarityId]
	if not minRarity then
		return rarity
	end
	local currentIndex = RARITY_ORDER[rarity.id] or 1
	local minIndex = RARITY_ORDER[minRarity.id] or 1
	if currentIndex >= minIndex then
		return rarity
	end
	return minRarity
end

local function buildDebugPassiveChoice(playerEntity: number, upgrades: any, statId: string): any?
	local def = passiveStatById[statId]
	if not def or def.hidden then
		return nil
	end

	local forcedRarityId = clampRarityId("Legendary", def.minRarity)
	local rarity = UpgradeDefs.Rarities[forcedRarityId] or rarityAtLeast(rollRarity(playerEntity), def.minRarity)
	local rolls, counts, statRarities = rollStatValues({def}, rarity, playerEntity, forcedRarityId)
	local desc, descParts = buildStatDescription({def}, rolls, counts, statRarities)
	local finalRarityId = getHighestRarityId(statRarities, rarity.id)
	local finalRarity = UpgradeDefs.Rarities[finalRarityId] or rarity
	assignPartColors(descParts, finalRarity)

	local levels = upgrades.passives.levels or {}
	local levelValue = levels[def.id] or 0
	if def.kind == "paired" then
		levelValue = 0
		for _, subId in ipairs(def.subStats or {}) do
			levelValue = math.max(levelValue, levels[subId] or 0)
		end
	end

	return {
		id = HttpService:GenerateGUID(false),
		category = "passive",
		statId = def.id,
		name = def.display,
		desc = desc,
		descParts = descParts,
		color = finalRarity.color,
		rarity = finalRarity.id,
		level = levelValue + 1,
		rolls = rolls,
		counts = counts,
	}
end

function UpgradeSystem.getDebugCatalog(playerEntity: number): {any}
	if not world then
		return {}
	end
	local entries = {}

	local unlockChoices = buildUnlockChoices(playerEntity)
	for _, choice in ipairs(unlockChoices) do
		table.insert(entries, {
			entryId = "unlock:" .. tostring(choice.abilityId),
			category = "unlock",
			name = tostring(choice.name),
			subtitle = "Unlock ability",
			iconKey = "unlock:" .. tostring(choice.abilityId),
		})
	end

	local ownedAbilities = getOwnedAbilities(playerEntity)
	table.sort(ownedAbilities)
	for _, abilityId in ipairs(ownedAbilities) do
		local ability = AbilityRegistry.get(abilityId)
		local abilityName = ability and (ability.balance.Name or abilityId) or abilityId
		table.insert(entries, {
			entryId = "ability:" .. tostring(abilityId),
			category = "ability",
			name = tostring(abilityName),
			subtitle = "Grant ability upgrade",
			iconKey = tostring(abilityId),
		})
	end

	local passiveDefs = {}
	for _, def in pairs(UpgradeDefs.PassiveStats) do
		if def.id and not def.hidden then
			table.insert(passiveDefs, def)
		end
	end
	table.sort(passiveDefs, function(a, b)
		return tostring(a.display or a.id) < tostring(b.display or b.id)
	end)
	for _, def in ipairs(passiveDefs) do
		table.insert(entries, {
			entryId = "passive:" .. tostring(def.id),
			category = "passive",
			name = tostring(def.display or def.id),
			subtitle = "Grant passive upgrade",
			iconKey = tostring(def.id),
		})
	end

	for _, abilityId in ipairs(ownedAbilities) do
		local attrs = getAllAttributesForAbility(playerEntity, abilityId)
		for _, attr in ipairs(attrs) do
			table.insert(entries, {
				entryId = "attribute:" .. tostring(abilityId) .. ":" .. tostring(attr.id),
				category = "attribute",
				name = tostring(attr.data.name or attr.id),
				subtitle = tostring(abilityId),
				iconKey = "attr:" .. tostring(abilityId) .. ":" .. tostring(attr.id),
			})
		end
	end

	local mobilityDefs = {
		{ id = "IceTracer", name = IceTracerConfig.displayName },
		{ id = "Dash", name = DashConfig.displayName },
		{ id = "ShieldBash", name = ShieldBashConfig.displayName },
		{ id = "DoubleJump", name = DoubleJumpConfig.displayName },
		{ id = "Blink", name = BlinkConfig.displayName },
		{ id = "ManaGrapple", name = ManaGrappleConfig.displayName },
	}
	for _, mobility in ipairs(mobilityDefs) do
		table.insert(entries, {
			entryId = "mobility:" .. tostring(mobility.id),
			category = "mobility",
			name = tostring(mobility.name or mobility.id),
			subtitle = "Equip mobility",
			iconKey = "mobility:" .. tostring(mobility.id),
		})
	end

	table.sort(entries, function(a, b)
		local categoryOrder = {
			unlock = 1,
			ability = 2,
			passive = 3,
			attribute = 4,
			mobility = 5,
		}
		local aOrder = categoryOrder[a.category] or 99
		local bOrder = categoryOrder[b.category] or 99
		if aOrder ~= bOrder then
			return aOrder < bOrder
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.entryId < b.entryId
	end)

	return entries
end

function UpgradeSystem.applyDebugEntry(playerEntity: number, entryId: string): boolean
	if not world or type(entryId) ~= "string" or entryId == "" then
		return false
	end

	local upgrades = ensureUpgradeState(playerEntity)
	local prefix, rest = entryId:match("^(%w+)%:(.+)$")
	if not prefix or not rest then
		return false
	end

	if prefix == "unlock" then
		local abilityId = rest
		return UpgradeSystem.applyUpgrade(playerEntity, {
			category = "ability_unlock",
			abilityId = abilityId,
			id = "unlock_" .. abilityId,
		})
	end

	if prefix == "ability" then
		local abilityId = rest
		local choice = buildAbilityUpgradeChoice(playerEntity, abilityId, upgrades, "Legendary", "Legendary")
		if not choice then
			return false
		end
		return UpgradeSystem.applyUpgrade(playerEntity, choice)
	end

	if prefix == "passive" then
		local statId = rest
		local choice = buildDebugPassiveChoice(playerEntity, upgrades, statId)
		if not choice then
			return false
		end
		return UpgradeSystem.applyUpgrade(playerEntity, choice)
	end

	if prefix == "attribute" then
		local abilityId, attributeId = rest:match("^([^:]+)%:(.+)$")
		if not abilityId or not attributeId then
			return false
		end
		return UpgradeSystem.applyUpgrade(playerEntity, {
			category = "attribute",
			id = abilityId .. "_attr_" .. attributeId,
			abilityId = abilityId,
			attributeId = attributeId,
		})
	end

	if prefix == "mobility" then
		local mobilityId = rest
		return UpgradeSystem.applyUpgrade(playerEntity, {
			category = "mobility",
			mobilityId = mobilityId,
			id = "mobility_" .. mobilityId,
		})
	end

	return false
end

local function rebuildAbilityStats(playerEntity: number, abilityId: string, upgrades: any)
	local ability = AbilityRegistry.get(abilityId)
	if not ability then
		return
	end
	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or not abilityData.abilities or not abilityData.abilities[abilityId] then
		return
	end

	local baseBalance = ability.balance
	local abilityRecord = abilityData.abilities[abilityId]
	local abilityState = ensureAbilityUpgradeState(upgrades, abilityId)
	if abilityState.level == 0 and typeof(abilityRecord.level) == "number" then
		abilityState.level = abilityRecord.level
	end

	local stats = {}
	local baseStats = {}
	for key, value in pairs(baseBalance) do
		if type(value) == "number" or type(value) == "string" then
			stats[key] = value
			if type(value) == "number" then
				baseStats[key] = value
			end
		end
	end

	for _, def in pairs(UpgradeDefs.AbilityStats) do
		if def.kind == "count" then
			local baseCount = baseBalance[def.field]
			if typeof(baseCount) == "number" then
				local rawBonus = abilityState.counts[def.id] or 0
				local maxBonus = math.floor(baseCount * (UpgradeDefs.SoftCaps.countMaxMultiplier - 1) + 0.0001)
				local appliedBonus = math.min(maxBonus, rawBonus)
				local rawCount = baseCount + appliedBonus
				stats[def.field .. "Raw"] = math.min(baseCount + maxBonus, rawCount)
				stats[def.field] = math.max(0, math.floor(rawCount + 0.0001))
			end
		else
			local baseValue = baseBalance[def.field]
			if typeof(baseValue) == "number" then
				if def.id == "cooldownReduction" then
					local stack = abilityState.statStacks and abilityState.statStacks[def.id]
					if stack and #stack > 0 then
						stats[def.field] = baseValue * computeStackMultiplier(stack)
					else
						local rawValue = abilityState.stats[def.id] or 0
						local effective = applySoftCap(rawValue, def.softCap, def.curveK)
						stats[def.field] = baseValue * (1 - effective)
					end
				else
					local rawValue = abilityState.stats[def.id] or 0
					local effective = applySoftCap(rawValue, def.softCap, def.curveK)
					if def.effect == "reduce" then
						stats[def.field] = baseValue * (1 - effective)
					else
						stats[def.field] = baseValue * (1 + effective)
					end
				end
			end
		end
	end

	if typeof(stats.pulseInterval) == "number" then
		stats.pulseInterval = math.max(0.02, stats.pulseInterval)
	end
	if typeof(stats.cooldown) == "number" then
		stats.cooldown = math.max(0.05, stats.cooldown)
	end

	local selectedAttribute = abilityRecord.selectedAttribute
	if selectedAttribute then
		local success, attributesModule = pcall(function()
			return require(game.ServerScriptService.Abilities[abilityId].Attributes)
		end)
		if success and attributesModule then
			local attributeData = attributesModule[selectedAttribute]
			if attributeData and attributeData.stats then
				for statName, modifier in pairs(attributeData.stats) do
					local rawKey = statName .. "Raw"
					local currentValue = stats[statName] or baseBalance[statName] or 0
					local currentRaw = stats[rawKey] or currentValue
					local newValue = currentValue
					local newRaw = currentRaw
					local isCountStat = countStatFields[statName] == true

					if type(modifier) == "string" and modifier:match("^%*") then
						local multiplier = tonumber(modifier:match("^%*(%d+%.?%d*)$"))
						if multiplier then
							if stats[rawKey] ~= nil then
								stats[statName .. "Multiplier"] = (stats[statName .. "Multiplier"] or 1) * multiplier
							end
							newValue = currentValue * multiplier
							newRaw = currentRaw * multiplier
						else
							newValue = parseModifier(modifier, currentValue)
							newRaw = parseModifier(modifier, currentRaw)
						end
					else
						newValue = parseModifier(modifier, currentValue)
						newRaw = parseModifier(modifier, currentRaw)
					end

					if stats[rawKey] ~= nil then
						stats[rawKey] = newRaw
						stats[statName] = math.floor(newRaw + 0.0001)
					else
						stats[statName] = newValue
					end

					if isCountStat then
						stats[statName .. "IgnoreCap"] = true
					end
				end
			end
		end
	end

	local updatedRecord = {
		enabled = abilityRecord.enabled,
		Name = abilityRecord.Name or ability.balance.Name,
		name = abilityRecord.name or ability.balance.Name,
		level = abilityState.level,
		selectedAttribute = abilityRecord.selectedAttribute,
		attributeColor = abilityRecord.attributeColor,
		attributeSpecial = abilityRecord.attributeSpecial,
		baseStats = baseStats,
	}

	for statName, value in pairs(stats) do
		updatedRecord[statName] = value
	end

	abilityData.abilities[abilityId] = updatedRecord
	DirtyService.setIfChanged(world, playerEntity, AbilityData, {abilities = abilityData.abilities}, "AbilityData")
end

local function rebuildPassiveEffects(playerEntity: number, upgrades: any)
	local effects = {
		damageMultiplier = PlayerBalance.BaseDamageMultiplier,
		cooldownMultiplier = PlayerBalance.BaseCooldownMultiplier,
		expMultiplier = PlayerBalance.BaseExpMultiplier,
		healthMultiplier = 1.0,
		healthFlatBonus = 0,
		moveSpeedMultiplier = 1.0,
		sizeMultiplier = 1.0,
		durationMultiplier = 1.0,
		pickupRangeMultiplier = 1.0,
		penetrationMultiplier = 1.0,
		penetrationBonus = upgrades.passives.counts.penetration or 0,
		mobilityCooldownMultiplier = 1.0,
		mobilityDistanceMultiplier = 1.0,
		mobilityDistanceBase = 1.0,
		mobilityVerticalMultiplier = 1.0,
		grappleDistanceMultiplier = 1.0,
		regenMultiplier = 1.0,
		regenFlatBonus = 0,
		regenDelayMultiplier = 1.0,
		critChance = 0,
		critDamage = 0,
		armorReduction = 0,
		lifesteal = 0,
		luck = 1.0,
		powerupChance = 0,
		projectileCountBonus = upgrades.passives.counts.projectileCount or 0,
		activeSpeedBuffs = (world:get(playerEntity, PassiveEffects) or {}).activeSpeedBuffs or {},
	}

	for _, def in pairs(UpgradeDefs.PassiveStats) do
		if def.kind == "count" or def.kind == "paired" then
			continue
		end
		local rawValue = upgrades.passives.stats[def.id] or 0
		if def.kind == "flat" then
			if def.field then
				if def.effect == "reduce" then
					effects[def.field] = (effects[def.field] or 0) - rawValue
				else
					effects[def.field] = (effects[def.field] or 0) + rawValue
				end
			end
		if def.id == "regenFlat" and def.delayMin and def.delayMax then
			local minVal = def.min or 0
			local maxVal = def.max or 0
			local denom = math.max(maxVal - minVal, 1e-6)
			local normalized = math.clamp((rawValue - minVal) / denom, 0, 1)
				local delayReduction = def.delayMin + (def.delayMax - def.delayMin) * normalized
				effects.regenDelayMultiplier = effects.regenDelayMultiplier * (1 - delayReduction)
			end
			continue
		end

		if def.id == "cooldownReduction" then
			local stack = upgrades.passives.statStacks and upgrades.passives.statStacks[def.id]
			if stack and #stack > 0 then
				effects.cooldownMultiplier = effects.cooldownMultiplier * computeStackMultiplier(stack)
			else
				local effective = applySoftCap(rawValue, def.softCap, def.curveK)
				effects.cooldownMultiplier = effects.cooldownMultiplier * (1 - effective)
			end
			continue
		end

		if def.id == "mobilityCooldown" then
			local stack = upgrades.passives.statStacks and upgrades.passives.statStacks[def.id]
			if stack and #stack > 0 then
				effects.mobilityCooldownMultiplier = effects.mobilityCooldownMultiplier * computeStackMultiplier(stack)
			else
				local effective = applySoftCap(rawValue, def.softCap, def.curveK)
				effects.mobilityCooldownMultiplier = effects.mobilityCooldownMultiplier * (1 - effective)
			end
			continue
		end

		local effective = applySoftCap(rawValue, def.softCap, def.curveK)

		if def.field == "damageMultiplier"
			or def.field == "cooldownMultiplier"
			or def.field == "healthMultiplier"
			or def.field == "moveSpeedMultiplier"
			or def.field == "sizeMultiplier"
			or def.field == "durationMultiplier"
			or def.field == "pickupRangeMultiplier"
			or def.field == "expMultiplier"
			or def.field == "penetrationMultiplier"
			or def.field == "mobilityCooldownMultiplier"
			or def.field == "mobilityDistanceMultiplier"
			or def.field == "mobilityVerticalMultiplier"
			or def.field == "grappleDistanceMultiplier"
			or def.field == "regenMultiplier" then
			if def.effect == "reduce" then
				effects[def.field] = effects[def.field] * (1 - effective)
			else
				effects[def.field] = effects[def.field] * (1 + effective)
			end
			if def.id == "expGain" then
				effects.pickupRangeMultiplier = effects.pickupRangeMultiplier * (1 + effective * 0.2)
			end
		else
			if def.effect == "reduce" then
				effects[def.field] = (effects[def.field] or 0) - effective
			else
				effects[def.field] = (effects[def.field] or 0) + effective
			end
		end

	end

	effects.mobilityDistanceBase = effects.mobilityDistanceMultiplier

	DirtyService.setIfChanged(world, playerEntity, PassiveEffects, effects, "PassiveEffects")
end

local function rebuildAllPlayerStats(playerEntity: number)
	local upgrades = ensureUpgradeState(playerEntity)
	rebuildPassiveEffects(playerEntity, upgrades)

	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or not abilityData.abilities then
		return
	end
	for abilityId, record in pairs(abilityData.abilities) do
		if record and record.enabled then
			rebuildAbilityStats(playerEntity, abilityId, upgrades)
		end
	end
end

local function applyHeal(playerEntity: number)
	local playerStats = world:get(playerEntity, PlayerStats)
	if not playerStats or not playerStats.player then
		return false
	end

	local player = playerStats.player
	local character = player.Character
	if not character then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end

	local healAmount = humanoid.MaxHealth * 0.3
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + healAmount)

	return true
end

local function applyAttributeUpgrade(playerEntity: number, upgradeId: string): boolean
	local parts = string.split(upgradeId, "_attr_")
	if #parts ~= 2 then
		warn("[UpgradeSystem] Invalid attribute upgrade ID:", upgradeId)
		return false
	end

	local abilityId = parts[1]
	local attributeId = parts[2]

	local ability = AbilityRegistry.get(abilityId)
	if not ability then
		warn("[UpgradeSystem] Unknown ability:", abilityId)
		return false
	end

	local success, attributesModule = pcall(function()
		return require(game.ServerScriptService.Abilities[abilityId].Attributes)
	end)

	if not success or not attributesModule then
		warn("[UpgradeSystem] Failed to load attributes for", abilityId)
		return false
	end

	local attributeData = attributesModule[attributeId]
	if not attributeData then
		warn("[UpgradeSystem] Unknown attribute:", attributeId, "for ability:", abilityId)
		return false
	end

	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or not abilityData.abilities or not abilityData.abilities[abilityId] then
		warn("[UpgradeSystem] Player doesn't have ability:", abilityId)
		return false
	end

	local abilities = abilityData.abilities
	local abilityRecord = abilities[abilityId]

	abilityRecord.selectedAttribute = attributeId
	if attributeData.color then
		abilityRecord.attributeColor = attributeData.color
	end
	if attributeData.special then
		abilityRecord.attributeSpecial = attributeData.special
	end

	DirtyService.setIfChanged(world, playerEntity, AbilityData, {abilities = abilities}, "AbilityData")

	local attributeSelections = world:get(playerEntity, AttributeSelections)
	if not attributeSelections then
		attributeSelections = {}
	end
	attributeSelections[abilityId] = attributeId
	DirtyService.setIfChanged(world, playerEntity, AttributeSelections, attributeSelections, "AttributeSelections")

	if attributeData.special and attributeData.special.replacesPlayer then
		local clonesData = {
			abilityId = abilityId,
			clones = {},
			cloneCount = attributeData.special.cloneCount or 3,
			cloneTransparency = attributeData.special.cloneTransparency or 0.5,
			triangleSideLength = attributeData.special.cloneTriangleSideLength or 30,
		}
		DirtyService.setIfChanged(world, playerEntity, AfterimageClones, clonesData, "AfterimageClones")

		local cooldownData = world:get(playerEntity, Components.AbilityCooldown)
		local cooldowns = cooldownData and cooldownData.cooldowns or {}
		cooldowns[abilityId] = {
			remaining = 0,
			max = abilityRecord.cooldown or ability.balance.cooldown,
		}
		DirtyService.setIfChanged(world, playerEntity, Components.AbilityCooldown, {
			cooldowns = cooldowns,
		}, "AbilityCooldown")
	end

	rebuildAbilityStats(playerEntity, abilityId, ensureUpgradeState(playerEntity))

	return true
end

applyMobilityUpgrade = function(playerEntity: number, mobilityId: string): boolean
	local mobilityConfig = nil
	if mobilityId == "Dash" then
		mobilityConfig = DashConfig
	elseif mobilityId == "IceTracer" then
		mobilityConfig = IceTracerConfig
	elseif mobilityId == "ShieldBash" then
		mobilityConfig = ShieldBashConfig
	elseif mobilityId == "DoubleJump" then
		mobilityConfig = DoubleJumpConfig
	elseif mobilityId == "Blink" then
		mobilityConfig = BlinkConfig
	elseif mobilityId == "ManaGrapple" then
		mobilityConfig = ManaGrappleConfig
	end

	if not mobilityConfig then
		warn("[UpgradeSystem] Unknown mobility ID:", mobilityId)
		return false
	end

	local modelPath = mobilityConfig.platformModelPath or mobilityConfig.shieldModelPath or mobilityConfig.modelPath
	if modelPath and (mobilityId == "DoubleJump" or mobilityId == "ShieldBash") then
		local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
		local serverPath = modelPath:match("ReplicatedStorage%.(.+)")
		if serverPath then
			local success = ModelReplicationService.replicateMobilityModel(serverPath)
			if not success then
				warn("[UpgradeSystem] Could not find mobility model in ServerStorage (expected at: ServerStorage." .. serverPath .. "). Using placeholder instead.")
			end
		end
	end

	if mobilityId == "Blink" then
		local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
		local paths = {
			mobilityConfig.blinkJumpStartModelPath,
			mobilityConfig.blinkJumpEndModelPath,
			mobilityConfig.blinkGroundStartModelPath,
			mobilityConfig.blinkGroundEndModelPath,
			mobilityConfig.blinkGroundBeamModelPath,
		}
		for _, serverPath in ipairs(paths) do
			if type(serverPath) == "string" and serverPath ~= "" then
				local success = ModelReplicationService.replicateMobilityModel(serverPath)
				if not success then
					warn("[UpgradeSystem] Could not find Blink VFX model in ServerStorage (expected at: ServerStorage." .. serverPath .. ").")
				end
			end
		end
	end

	if mobilityId == "ManaGrapple" then
		local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
		local paths = {
			mobilityConfig.grappleStartModelPath,
			mobilityConfig.grappleManaPointModelPath,
			mobilityConfig.grappleEndModelPath,
			mobilityConfig.grappleBeamModelPath,
		}
		for _, serverPath in ipairs(paths) do
			if type(serverPath) == "string" and serverPath ~= "" then
				local success = ModelReplicationService.replicateMobilityModel(serverPath)
				if not success then
					warn("[UpgradeSystem] Could not find Grapple VFX model in ServerStorage (expected at: ServerStorage." .. serverPath .. ").")
				end
			end
		end
	end

	if mobilityId == "IceTracer" then
		local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
		local paths = {
			mobilityConfig.iceTracerPathModelPath,
			mobilityConfig.iceTracerBeam1ModelPath,
			mobilityConfig.iceTracerBeam2ModelPath,
			mobilityConfig.iceTracerAnimationModelPath,
		}
		for _, serverPath in ipairs(paths) do
			if type(serverPath) == "string" and serverPath ~= "" then
				local success = ModelReplicationService.replicateMobilityModel(serverPath)
				if not success then
					warn("[UpgradeSystem] Could not find IceTracer asset in ServerStorage (expected at: ServerStorage." .. serverPath .. ").")
				end
			end
		end
	end

	local mobilityData = {
		equippedMobility = mobilityId,
		distance = mobilityConfig.distance or (mobilityConfig.horizontalDistance and mobilityConfig.horizontalDistance or 25),
		cooldown = mobilityConfig.cooldown,
		duration = mobilityConfig.duration or 0.15,
		verticalHeight = mobilityConfig.verticalHeight,
		platformModelPath = mobilityConfig.platformModelPath,
		shieldModelPath = mobilityConfig.shieldModelPath,
		damage = mobilityConfig.damage,
		knockbackDistance = mobilityConfig.knockbackDistance,
		invincibilityPerHit = mobilityConfig.invincibilityPerHit,
		groundDistance = mobilityConfig.groundDistance,
		airDistance = mobilityConfig.airDistance,
		airAngleDeg = mobilityConfig.airAngleDeg,
		airWindup = mobilityConfig.airWindup,
		groundCooldown = mobilityConfig.groundCooldown,
		airCooldown = mobilityConfig.airCooldown,
		blinkJumpStartPath = mobilityConfig.blinkJumpStartModelPath and ("ReplicatedStorage." .. mobilityConfig.blinkJumpStartModelPath) or nil,
		blinkJumpEndPath = mobilityConfig.blinkJumpEndModelPath and ("ReplicatedStorage." .. mobilityConfig.blinkJumpEndModelPath) or nil,
		blinkGroundStartPath = mobilityConfig.blinkGroundStartModelPath and ("ReplicatedStorage." .. mobilityConfig.blinkGroundStartModelPath) or nil,
		blinkGroundEndPath = mobilityConfig.blinkGroundEndModelPath and ("ReplicatedStorage." .. mobilityConfig.blinkGroundEndModelPath) or nil,
		blinkGroundBeamPath = mobilityConfig.blinkGroundBeamModelPath and ("ReplicatedStorage." .. mobilityConfig.blinkGroundBeamModelPath) or nil,
		grappleHorizontalDistance = mobilityConfig.grappleHorizontalDistance,
		grappleVerticalHeight = mobilityConfig.grappleVerticalHeight,
		grappleCooldown = mobilityConfig.grappleCooldown,
		grappleManaForward = mobilityConfig.grappleManaForward,
		grappleManaUp = mobilityConfig.grappleManaUp,
		grappleDampStartFrac = mobilityConfig.grappleDampStartFrac,
		grappleDampStrength = mobilityConfig.grappleDampStrength,
		grappleStartPath = mobilityConfig.grappleStartModelPath and ("ReplicatedStorage." .. mobilityConfig.grappleStartModelPath) or nil,
		grappleManaPointPath = mobilityConfig.grappleManaPointModelPath and ("ReplicatedStorage." .. mobilityConfig.grappleManaPointModelPath) or nil,
		grappleEndPath = mobilityConfig.grappleEndModelPath and ("ReplicatedStorage." .. mobilityConfig.grappleEndModelPath) or nil,
		grappleBeamPath = mobilityConfig.grappleBeamModelPath and ("ReplicatedStorage." .. mobilityConfig.grappleBeamModelPath) or nil,
		iceTracerPathPath = mobilityConfig.iceTracerPathModelPath and ("ReplicatedStorage." .. mobilityConfig.iceTracerPathModelPath) or nil,
		iceTracerBeam1Path = mobilityConfig.iceTracerBeam1ModelPath and ("ReplicatedStorage." .. mobilityConfig.iceTracerBeam1ModelPath) or nil,
		iceTracerBeam2Path = mobilityConfig.iceTracerBeam2ModelPath and ("ReplicatedStorage." .. mobilityConfig.iceTracerBeam2ModelPath) or nil,
		iceTracerAnimationPath = mobilityConfig.iceTracerAnimationModelPath and ("ReplicatedStorage." .. mobilityConfig.iceTracerAnimationModelPath) or nil,
		iceTracerPathSpacing = mobilityConfig.pathSpacing,
		iceTracerRampFrames = mobilityConfig.rampFrames,
		iceTracerTotalFrames = mobilityConfig.totalFrames,
		iceTracerLookAheadDistance = mobilityConfig.lookAheadDistance,
		iceTracerPartLifetime = mobilityConfig.pathPartLifetime,
	}

	DirtyService.setIfChanged(world, playerEntity, Components.MobilityData, mobilityData, "MobilityData")
	DirtyService.setIfChanged(world, playerEntity, Components.MobilityCooldown, {lastUsedTime = 0}, "MobilityCooldown")
	return true
end

function UpgradeSystem.applyUpgrade(playerEntity: number, upgrade: any): boolean
	if not world then
		warn("[UpgradeSystem] World not initialized")
		return false
	end

	if type(upgrade) == "string" then
		if upgrade:match("_attr_") then
			return applyAttributeUpgrade(playerEntity, upgrade)
		end
		if upgrade:match("^heal_30_") then
			return applyHeal(playerEntity)
		end
		if upgrade:match("^mobility_") then
			local mobilityId = upgrade:match("^mobility_(.+)$")
			return applyMobilityUpgrade(playerEntity, mobilityId)
		end
		warn("[UpgradeSystem] Invalid upgrade payload:", upgrade)
		return false
	end

	if type(upgrade) ~= "table" then
		return false
	end

	local upgrades = ensureUpgradeState(playerEntity)
	local category = upgrade.category
	if category == "attribute" then
		return applyAttributeUpgrade(playerEntity, upgrade.id)
	elseif category == "heal" then
		return applyHeal(playerEntity)
	elseif category == "mobility" then
		return applyMobilityUpgrade(playerEntity, upgrade.mobilityId)
	elseif category == "ability_unlock" then
		local abilityId = upgrade.abilityId
		local ability = AbilityRegistry.get(abilityId)
		if not ability then
			return false
		end
		local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
		AbilityRegistry.grantAbility(world, playerEntity, abilityId, Components, DirtyService, ModelReplicationService)

		local abilityState = ensureAbilityUpgradeState(upgrades, abilityId)
		abilityState.level = math.max(abilityState.level, 1)
		DirtyService.setIfChanged(world, playerEntity, Upgrades, upgrades, "Upgrades")
		rebuildAbilityStats(playerEntity, abilityId, upgrades)
		return true
	elseif category == "ability" then
		local abilityId = upgrade.abilityId
		if not abilityId then
			return false
		end

		local abilityState = ensureAbilityUpgradeState(upgrades, abilityId)
		abilityState.level = (abilityState.level or 0) + 1

		local rolls = upgrade.rolls or {}
		for statId, value in pairs(rolls) do
			abilityState.stats[statId] = (abilityState.stats[statId] or 0) + value
			local def = abilityStatById[statId]
			if def and def.id == "cooldownReduction" then
				local stack = abilityState.statStacks[statId]
				if not stack then
					stack = {}
					abilityState.statStacks[statId] = stack
				end
				if #stack == 0 then
					local existing = abilityState.stats[statId] or 0
					if existing > value then
						local effectiveExisting = applySoftCap(existing - value, def.softCap, def.curveK)
						if effectiveExisting > 0 then
							table.insert(stack, effectiveExisting)
						end
					end
				end
				table.insert(stack, value)
			end
		end
		local counts = upgrade.counts or {}
		for statId, value in pairs(counts) do
			abilityState.counts[statId] = (abilityState.counts[statId] or 0) + value
		end

		DirtyService.setIfChanged(world, playerEntity, Upgrades, upgrades, "Upgrades")
		rebuildAbilityStats(playerEntity, abilityId, upgrades)
		return true
	elseif category == "passive" then
		local rolls = upgrade.rolls or {}
		local counts = upgrade.counts or {}
		local levels = upgrades.passives.levels or {}
		for statKey, value in pairs(rolls) do
			upgrades.passives.stats[statKey] = (upgrades.passives.stats[statKey] or 0) + value
			local def = passiveStatById[statKey]
			if def and (def.id == "cooldownReduction" or def.id == "mobilityCooldown") then
				local stack = upgrades.passives.statStacks[statKey]
				if not stack then
					stack = {}
					upgrades.passives.statStacks[statKey] = stack
				end
				if #stack == 0 then
					local existing = (upgrades.passives.stats[statKey] or 0) - value
					if existing > 0 then
						local effectiveExisting = applySoftCap(existing, def.softCap, def.curveK)
						if effectiveExisting > 0 then
							table.insert(stack, effectiveExisting)
						end
					end
				end
				table.insert(stack, value)
			end
			levels[statKey] = (levels[statKey] or 0) + 1
		end
		for statKey, value in pairs(counts) do
			upgrades.passives.counts[statKey] = (upgrades.passives.counts[statKey] or 0) + value
			levels[statKey] = (levels[statKey] or 0) + 1
		end
		upgrades.passives.levels = levels

		DirtyService.setIfChanged(world, playerEntity, Upgrades, upgrades, "Upgrades")
		rebuildPassiveEffects(playerEntity, upgrades)
		return true
	end

	return false
end

function UpgradeSystem.getAvailableUpgrades(playerEntity: number)
	return {
		choices = UpgradeSystem.selectUpgradeChoices(playerEntity, 1, 6),
	}
end

function UpgradeSystem.step(dt: number)
	if not world then
		return
	end

	rebuildAccumulator += dt
	if rebuildAccumulator < REBUILD_INTERVAL then
		return
	end
	rebuildAccumulator = 0

	for entity, stats in playerQuery do
		if stats and stats.player and stats.player.Parent then
			rebuildAllPlayerStats(entity)
		end
	end
end

function UpgradeSystem.rebuildPlayerStats(playerEntity: number)
	rebuildAllPlayerStats(playerEntity)
end

return UpgradeSystem
