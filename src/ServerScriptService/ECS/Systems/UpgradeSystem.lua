
--!strict
-- UpgradeSystem - New rarity-based upgrade system with roll budgets and soft caps

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local AbilityRegistry = require(game.ServerScriptService.Abilities.AbilityRegistry)
local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local UpgradeDefs = require(game.ServerScriptService.Balance.Upgrades.UpgradeDefs)
local DashConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.Dash)
local ShieldBashConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.ShieldBash)
local DoubleJumpConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.DoubleJump)

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

local playerQuery: any
local REBUILD_INTERVAL = 1.0
local rebuildAccumulator = 0

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

-- Auto-equip basic Dash for new players (called on player spawn)
local function equipStarterDash(playerEntity: number)
	local mobilityData = {
		equippedMobility = "Dash",
		distance = DashConfig.distance,
		cooldown = DashConfig.cooldown,
		duration = DashConfig.duration,
		verticalHeight = nil,
		platformModelPath = nil,
	}

	DirtyService.setIfChanged(world, playerEntity, Components.MobilityData, mobilityData, "MobilityData")

	-- Initialize cooldown
	local cooldownData = { lastUsedTime = 0 }
	DirtyService.setIfChanged(world, playerEntity, Components.MobilityCooldown, cooldownData, "MobilityCooldown")
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
	return abilityState
end

local function applySoftCap(rawValue: number, cap: number?): number
	if not cap or cap <= 0 then
		return rawValue
	end
	if rawValue <= 0 then
		return 0
	end
	local k = UpgradeDefs.SoftCaps.curveK
	return cap * (1 - math.exp(-k * rawValue / cap))
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function formatPercent(value: number): string
	return string.format("%.1f%%", value * 100)
end

local passiveStatById: {[string]: any} = {}
for _, def in pairs(UpgradeDefs.PassiveStats) do
	if def.id then
		passiveStatById[def.id] = def
	end
end

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
		return effects.luck
	end
	return 0
end

local function getRarityWeights(luckValue: number): {[string]: number}
	local commonWeight = UpgradeDefs.Rarities.Common.weight
	local rareWeight = UpgradeDefs.Rarities.Rare.weight
	local epicWeight = UpgradeDefs.Rarities.Epic.weight
	local legendaryWeight = UpgradeDefs.Rarities.Legendary.weight

	local luck = math.max(0, luckValue)
	local epicMult = math.min(1 + luck, UpgradeDefs.Luck.maxEpicMultiplier)
	local legendaryMult = math.min(1 + luck * 1.2, UpgradeDefs.Luck.maxLegendaryMultiplier)

	epicWeight = epicWeight * epicMult
	legendaryWeight = legendaryWeight * legendaryMult

	local remaining = 1 - epicWeight - legendaryWeight
	if remaining < 0 then
		remaining = 0.001
	end

	local baseCommon = UpgradeDefs.Rarities.Common.weight
	local baseRare = UpgradeDefs.Rarities.Rare.weight
	local totalBase = baseCommon + baseRare
	local commonRatio = if totalBase > 0 then baseCommon / totalBase else 0.5
	commonWeight = remaining * commonRatio
	rareWeight = remaining * (1 - commonRatio)

	if commonWeight < UpgradeDefs.Luck.minCommonWeight then
		commonWeight = UpgradeDefs.Luck.minCommonWeight
		rareWeight = math.max(0, 1 - commonWeight - epicWeight - legendaryWeight)
	end

	return {
		Common = commonWeight,
		Rare = rareWeight,
		Epic = epicWeight,
		Legendary = legendaryWeight,
	}
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

local function pickAbilityStatDefs(abilityBalance: any, upgrades: any, abilityId: string): {any}
	local statPool = {}
	local abilityState = ensureAbilityUpgradeState(upgrades, abilityId)
	for _, def in pairs(UpgradeDefs.AbilityStats) do
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

local function pickPassiveStatDefs(upgrades: any, playerEntity: number): {any}
	local statPool = {}
	local mobilityData = world and Components and world:get(playerEntity, Components.MobilityData) or nil
	local equippedMobility = mobilityData and mobilityData.equippedMobility or nil
	for _, def in pairs(UpgradeDefs.PassiveStats) do
		if def.hidden then
			continue
		end
		if def.id == "critDamage" then
			local currentCrit = upgrades.passives.stats.critChance or 0
			if currentCrit <= 0 then
				continue
			end
		end
		if def.id == "doubleJumpPower" and equippedMobility ~= "DoubleJump" then
			continue
		end
		if def.id == "dashDistance" and equippedMobility ~= "Dash" and equippedMobility ~= "ShieldBash" then
			continue
		end
		if def.id == "grappleDistance" and equippedMobility ~= "Grapple" then
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

local function rollStatValues(selectedStats: {any}, rarity: any): ({[string]: number}, {[string]: number})
	local rolls: {[string]: number} = {}
	local counts: {[string]: number} = {}

	local percentStats = {}
	for _, def in ipairs(selectedStats) do
		if def.kind == "count" then
			local increment = def.increment or 1
			if rarity.id == "Legendary" then
				increment = def.legendaryIncrement or (increment * 2)
			end
			counts[def.id] = (counts[def.id] or 0) + increment
		else
			table.insert(percentStats, def)
		end
	end

	if #percentStats == 0 then
		return rolls, counts
	end

	local allocations = {}
	local weightSum = 0
	for i = 1, #percentStats do
		local weight = RNG:NextNumber(0.75, 1.25)
		allocations[i] = weight
		weightSum += weight
	end

	local budget = rarity.budget
	for i, def in ipairs(percentStats) do
		local allocated = budget * (allocations[i] / weightSum)
		if def.kind == "paired" then
			local subStats = def.subStats or {}
			local subWeights = {}
			local subWeightSum = 0
			for idx, _ in ipairs(subStats) do
				local subWeight = RNG:NextNumber(0.75, 1.25)
				subWeights[idx] = subWeight
				subWeightSum += subWeight
			end
			for idx, subId in ipairs(subStats) do
				local subDef = passiveStatById[subId]
				if subDef then
					local subAllocated = allocated * (subWeights[idx] / math.max(subWeightSum, 1e-6))
					local denom = (subDef.max or 0.0001) * (subDef.weight or 1)
					local progress = clamp01(subAllocated / denom)
					local rollValue = lerp(subDef.min or 0, subDef.max or 0, progress)
					rolls[subDef.id] = (rolls[subDef.id] or 0) + rollValue
				end
			end
		else
			local denom = (def.max or 0.0001) * (def.weight or 1)
			local progress = clamp01(allocated / denom)
			local rollValue = lerp(def.min or 0, def.max or 0, progress)
			rolls[def.id] = (rolls[def.id] or 0) + rollValue
		end
	end

	return rolls, counts
end

local function buildStatDescription(statDefs: {any}, rolls: {[string]: number}, counts: {[string]: number}): (string, {any})
	local parts = {}
	local textParts = {}
	local function pushPart(valueText: string, nameText: string, statId: string, score: number?)
		local text = if valueText ~= "" then string.format("%s %s", valueText, nameText) else nameText
		table.insert(parts, {
			text = text,
			valueText = valueText,
			nameText = nameText,
			statId = statId,
			score = score,
		})
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
				pushPart("+" .. displayValue, def.display, def.id, nil)
			end
		elseif def.kind == "paired" then
			local subStats = def.subStats or {}
			for _, subId in ipairs(subStats) do
				local subDef = passiveStatById[subId]
				if subDef then
					local value = rolls[subDef.id]
					if value and value > 0 then
						local score = if subDef.max and subDef.max > 0 then value / subDef.max else nil
						if subDef.effect == "reduce" then
							pushPart("-" .. formatPercent(value), subDef.display, subDef.id, score)
						else
							pushPart("+" .. formatPercent(value), subDef.display, subDef.id, score)
						end
					end
				end
			end
		else
			local value = rolls[def.id]
			if value and value > 0 then
				local score = if def.max and def.max > 0 then value / def.max else nil
				if def.effect == "reduce" then
					pushPart("-" .. formatPercent(value), def.display, def.id, score)
				else
					pushPart("+" .. formatPercent(value), def.display, def.id, score)
				end
				if def.id == "expGain" then
					pushPart("+" .. formatPercent(value), "Pickup Range", "pickupRange", score)
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
			part.color = baseRarity.color
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
		parts[entry.index].color = rarity.color
	end

	return parts
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
	if abilityLevel < 10 then
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
local function buildAbilityUpgradeChoice(playerEntity: number, abilityId: string, upgrades: any): any?
	local ability = AbilityRegistry.get(abilityId)
	if not ability then
		return nil
	end
	local abilityState = ensureAbilityUpgradeState(upgrades, abilityId)
	local rarity = rollRarity(playerEntity)
	local statPool = pickAbilityStatDefs(ability.balance, upgrades, abilityId)
	if #statPool == 0 then
		return nil
	end

	local minStats = math.min(rarity.minStats or 1, #statPool)
	local maxStats = math.min(rarity.maxStats or minStats, #statPool)
	local statCount = RNG:NextInteger(minStats, maxStats)

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

	local rolls, counts = rollStatValues(selected, rarity)
	local desc, descParts = buildStatDescription(selected, rolls, counts)
	assignPartColors(descParts, rarity)
	local abilityName = ability.balance.Name or abilityId

	local choiceId = HttpService:GenerateGUID(false)
	return {
		id = choiceId,
		category = "ability",
		abilityId = abilityId,
		name = string.format("%s %s", rarity.id, abilityName),
		desc = desc,
		descParts = descParts,
		color = rarity.color,
		rarity = rarity.id,
		level = (abilityState.level or 0) + 1,
		rolls = rolls,
		counts = counts,
	}
end

local function buildPassiveUpgradeChoice(playerEntity: number, upgrades: any, biased: boolean?): any?
	local rarity = rollRarity(playerEntity)
	local statPool = pickPassiveStatDefs(upgrades, playerEntity)
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
		return baseWeight * (1 + level * PASSIVE_REPEAT_BIAS)
	end)
	if not selectedDef then
		return nil
	end

	local rolls, counts = rollStatValues({selectedDef}, rarity)
	local desc, descParts = buildStatDescription({selectedDef}, rolls, counts)
	assignPartColors(descParts, rarity)

	local choiceId = HttpService:GenerateGUID(false)
	return {
		id = choiceId,
		category = "passive",
		statId = selectedDef.id,
		name = string.format("%s %s", rarity.id, selectedDef.display),
		desc = desc,
		descParts = descParts,
		color = rarity.color,
		rarity = rarity.id,
		level = ((upgrades.passives.levels and upgrades.passives.levels[selectedDef.id]) or 0) + 1,
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
	local hasMobilityUpgrade = mobilityData and mobilityData.equippedMobility ~= nil and mobilityData.equippedMobility ~= "Dash"
	if hasMobilityUpgrade then
		return choices
	end

	local levelComponent = world:get(playerEntity, Components.Level)
	local playerLevel = levelComponent and levelComponent.current or 1

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

	return choices
end

function UpgradeSystem.selectUpgradeChoices(playerEntity: number, level: number, count: number): {any}
	count = count or 5
	local upgrades = ensureUpgradeState(playerEntity)
	local ownedAbilities = getOwnedAbilities(playerEntity)
	local unlockChoices = buildUnlockChoices(playerEntity)
	local mobilityChoices = buildMobilityChoices(playerEntity)
	local choices = {}

	local usedAbilities: {[string]: boolean} = {}
	local usedPassives: {[string]: boolean} = {}
	local usedUnlock = false

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
	if attributeChoice then
		table.insert(choices, attributeChoice)
	end

	if #mobilityChoices > 0 and #choices < count then
		local mobilityPick = mobilityChoices[RNG:NextInteger(1, #mobilityChoices)]
		table.insert(choices, mobilityPick)
	end

	if #ownedAbilities > 0 and #choices < count then
		local choice = pickAbilityUpgrade(true)
		if choice then
			table.insert(choices, choice)
		end
	end

	local remainingSlots = count - #choices
	local wildSlot = remainingSlots > 0 and RNG:NextInteger(1, remainingSlots) or nil
	local slotIndex = 0
	while #choices < count do
		slotIndex += 1
		local isWild = wildSlot and slotIndex == wildSlot
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
			choice = pickAbilityUpgrade(not isWild)
			if not choice then
				if #unlockChoices > 0 and not usedUnlock and RNG:NextNumber() < 0.35 then
					choice = unlockChoices[RNG:NextInteger(1, #unlockChoices)]
				else
					choice = buildPassiveUpgradeChoice(playerEntity, upgrades, not isWild)
				end
			end
		elseif pickCategory == "unlock" and #unlockChoices > 0 then
			choice = unlockChoices[RNG:NextInteger(1, #unlockChoices)]
		else
			choice = buildPassiveUpgradeChoice(playerEntity, upgrades, not isWild)
			if choice and choice.statId then
				if usedPassives[choice.statId] then
					choice = nil
				else
					usedPassives[choice.statId] = true
				end
			end
		end

		if choice then
			if choice.category == "ability_unlock" then
				usedUnlock = true
			end
			table.insert(choices, choice)
		else
			local fallback = buildPassiveUpgradeChoice(playerEntity, upgrades)
			if not fallback and #unlockChoices > 0 and not usedUnlock then
				fallback = unlockChoices[RNG:NextInteger(1, #unlockChoices)]
			end
			if not fallback and #ownedAbilities > 0 then
				local abilityId = ownedAbilities[RNG:NextInteger(1, #ownedAbilities)]
				fallback = buildAbilityUpgradeChoice(playerEntity, abilityId, upgrades)
			end
			if fallback then
				if fallback.category == "ability_unlock" then
					usedUnlock = true
				end
				table.insert(choices, fallback)
			else
				break
			end
		end
	end

	return choices
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
				stats[def.field] = math.max(0, math.floor(baseCount + appliedBonus + 0.0001))
			end
		else
			local baseValue = baseBalance[def.field]
			if typeof(baseValue) == "number" then
				local rawValue = abilityState.stats[def.id] or 0
				local effective = applySoftCap(rawValue, def.softCap)
				if def.effect == "reduce" then
					stats[def.field] = baseValue * (1 - effective)
				else
					stats[def.field] = baseValue * (1 + effective)
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
					local currentValue = stats[statName] or baseBalance[statName] or 0
					if type(modifier) == "string" and modifier:match("^%*") then
						local multiplier = tonumber(modifier:match("^%*(%d+%.?%d*)$"))
						if multiplier then
							stats[statName] = currentValue * multiplier
						else
							stats[statName] = parseModifier(modifier, currentValue)
						end
					else
						stats[statName] = parseModifier(modifier, currentValue)
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
		moveSpeedMultiplier = 1.0,
		sizeMultiplier = 1.0,
		durationMultiplier = 1.0,
		pickupRangeMultiplier = 1.0,
		penetrationMultiplier = 1.0,
		mobilityCooldownMultiplier = 1.0,
		mobilityDistanceMultiplier = 1.0,
		mobilityDistanceBase = 1.0,
		mobilityVerticalMultiplier = 1.0,
		grappleDistanceMultiplier = 1.0,
		regenMultiplier = 1.0,
		regenDelayMultiplier = 1.0,
		critChance = 0,
		critDamage = 0,
		armorReduction = 0,
		lifesteal = 0,
		luck = 0,
		powerupChance = 0,
		projectileCountBonus = upgrades.passives.counts.projectileCount or 0,
		projectileBounceBonus = upgrades.passives.counts.projectileBounce or 0,
		activeSpeedBuffs = (world:get(playerEntity, PassiveEffects) or {}).activeSpeedBuffs or {},
	}

	for _, def in pairs(UpgradeDefs.PassiveStats) do
		if def.kind == "count" or def.kind == "paired" then
			continue
		end
		local rawValue = upgrades.passives.stats[def.id] or 0
		local effective = applySoftCap(rawValue, def.softCap)

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
				effects.pickupRangeMultiplier = effects.pickupRangeMultiplier * (1 + effective)
			end
		else
			if def.effect == "reduce" then
				effects[def.field] = (effects[def.field] or 0) - effective
			else
				effects[def.field] = (effects[def.field] or 0) + effective
			end
		end

		if def.id == "regen" and def.delayMin and def.delayMax then
			local minVal = def.min or 0
			local maxVal = def.max or 0
			local denom = math.max(maxVal - minVal, 1e-6)
			local normalized = math.clamp((effective - minVal) / denom, 0, 1)
			local delayReduction = def.delayMin + (def.delayMax - def.delayMin) * normalized
			effects.regenDelayMultiplier = effects.regenDelayMultiplier * (1 - delayReduction)
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

local function applyMobilityUpgrade(playerEntity: number, mobilityId: string): boolean
	local mobilityConfig = nil
	if mobilityId == "Dash" then
		mobilityConfig = DashConfig
	elseif mobilityId == "ShieldBash" then
		mobilityConfig = ShieldBashConfig
	elseif mobilityId == "DoubleJump" then
		mobilityConfig = DoubleJumpConfig
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
		choices = UpgradeSystem.selectUpgradeChoices(playerEntity, 1, 5),
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

return UpgradeSystem
