--!strict
-- UpgradeSystem - Handles upgrade selection, application, and stat modifications
-- Supports hybrid absolute/relative value system with smart weighted selection

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local AbilityRegistry = require(game.ServerScriptService.Abilities.AbilityRegistry)
local PassiveUpgrades = require(game.ServerScriptService.Balance.Player.PassiveUpgrades)
local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
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
local Health: any
local AttributeSelections: any
local AfterimageClones: any

-- Random number generator
local RNG = Random.new()

function UpgradeSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	Upgrades = Components.Upgrades
	PassiveEffects = Components.PassiveEffects
	PlayerStats = Components.PlayerStats
	AbilityData = Components.AbilityData
	Health = Components.Health
	AttributeSelections = Components.AttributeSelections
	AfterimageClones = Components.AfterimageClones
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

-- Export for use in Bootstrap
UpgradeSystem.equipStarterDash = equipStarterDash

-- Parse a modifier value and apply to base value
-- Supports: "+50%", "-10%", "75%", or absolute numbers
local function parseModifier(value: any, baseValue: number): number
	if type(value) == "number" then
		return value  -- Absolute value
	end
	
	local str = tostring(value)
	
	-- Match "+X%" pattern (add percentage)
	local addPercent = str:match("^%+(%d+%.?%d*)%%$")
	if addPercent then
		local percent = tonumber(addPercent)
		return baseValue * (1 + percent / 100)
	end
	
	-- Match "-X%" pattern (subtract percentage)
	local subPercent = str:match("^%-(%d+%.?%d*)%%$")
	if subPercent then
		local percent = tonumber(subPercent)
		return baseValue * (1 - percent / 100)
	end
	
	-- Match "X%" pattern (multiply by percentage)
	local setPercent = str:match("^(%d+%.?%d*)%%$")
	if setPercent then
		local percent = tonumber(setPercent)
		return baseValue * (percent / 100)
	end
	
	-- Match "+X" or "-X" absolute additions
	local addNum = str:match("^([%+%-]%d+%.?%d*)$")
	if addNum then
		local num = tonumber(addNum)
		return baseValue + num
	end
	
	-- Fallback: return base value unchanged
	warn("[UpgradeSystem] Could not parse modifier:", value)
	return baseValue
end

-- Get current upgrade level for a specific upgrade type
local function getUpgradeLevel(playerEntity: number, upgradeType: string, category: string): number
	local upgrades = world:get(playerEntity, Upgrades)
	if not upgrades then
		return 0
	end
	
	local categoryData = upgrades[category]  -- "abilities" or "passives"
	if not categoryData or not categoryData[upgradeType] then
		return 0
	end
	
	return categoryData[upgradeType].level or 0
end

-- Set upgrade level for a specific upgrade type
local function setUpgradeLevel(playerEntity: number, upgradeType: string, category: string, level: number, maxLevel: number)
	local upgrades = world:get(playerEntity, Upgrades)
	if not upgrades then
		upgrades = {abilities = {}, passives = {}}
	end
	
	if not upgrades[category] then
		upgrades[category] = {}
	end
	
	upgrades[category][upgradeType] = {
		level = level,
		maxLevel = maxLevel
	}
	
	DirtyService.setIfChanged(world, playerEntity, Upgrades, upgrades, "Upgrades")
end

-- Get all available ability upgrades
local function getAvailableAbilityUpgrades(playerEntity: number): {{id: string, abilityId: string, level: number, data: any}}
	local available = {}
	
	for abilityId, ability in pairs(AbilityRegistry.getAll()) do
		-- Try to load upgrades file
		local success, upgradesModule = pcall(function()
			return require(game.ServerScriptService.Abilities[abilityId].Upgrades)
		end)
		
		if success and upgradesModule then
			local currentLevel = getUpgradeLevel(playerEntity, abilityId, "abilities")
			local nextLevel = currentLevel + 1
			local maxLevel = #upgradesModule
			
			-- Check if next level is available
			if nextLevel <= maxLevel then
				local upgradeData = upgradesModule[nextLevel]
				
				-- Load ability config to get color
				local abilityColor = nil
				local configSuccess, configModule = pcall(function()
					return require(game.ServerScriptService.Abilities[abilityId].Config)
				end)
				if configSuccess and configModule and configModule.color then
					abilityColor = configModule.color
				end
				
				table.insert(available, {
					id = abilityId .. "_" .. nextLevel,
					abilityId = abilityId,
					level = nextLevel,
					maxLevel = maxLevel,
					data = upgradeData,
					category = "ability",
					color = abilityColor,
				})
			end
		end
	end
	
	return available
end

-- Get all available passive upgrades
local function getAvailablePassiveUpgrades(playerEntity: number): {{id: string, passiveId: string, level: number, data: any}}
	local available = {}
	
	for passiveId, passiveLevels in pairs(PassiveUpgrades) do
		local currentLevel = getUpgradeLevel(playerEntity, passiveId, "passives")
		local nextLevel = currentLevel + 1
		local maxLevel = #passiveLevels
		
		-- Check if next level is available
		if nextLevel <= maxLevel then
			local upgradeData = passiveLevels[nextLevel]
			table.insert(available, {
				id = passiveId .. "_" .. nextLevel,
				passiveId = passiveId,
				level = nextLevel,
				maxLevel = maxLevel,
				data = upgradeData,
				category = "passive",
				color = Color3.fromRGB(255, 255, 255), -- White for passives
			})
		end
	end
	
	return available
end

-- Check if player has an ability unlocked
local function hasAbilityUnlocked(playerEntity: number, abilityId: string): boolean
	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or not abilityData.abilities then
		return false
	end
	
	local ability = abilityData.abilities[abilityId]
	return ability ~= nil and ability.enabled == true
end

-- Get all abilities that are at maximum upgrade level
local function getMaxLevelAbilities(playerEntity: number): {{abilityId: string, maxLevel: number}}
	local maxLevelAbilities = {}
	
	local upgrades = world:get(playerEntity, Upgrades)
	if not upgrades or not upgrades.abilities then
		return maxLevelAbilities
	end
	
	-- Check each ability's upgrade level
	for abilityId, upgradeInfo in pairs(upgrades.abilities) do
		local currentLevel = upgradeInfo.level or 0
		local maxLevel = upgradeInfo.maxLevel or 0
		
		-- Only include abilities that are fully upgraded
		if currentLevel > 0 and currentLevel == maxLevel then
			table.insert(maxLevelAbilities, {
				abilityId = abilityId,
				maxLevel = maxLevel,
			})
		end
	end
	
	return maxLevelAbilities
end

-- Get available attributes for a specific ability
local function getAvailableAttributesForAbility(playerEntity: number, abilityId: string): {{id: string, data: any}}
	local available = {}
	
	-- Check if player already has an attribute selected for this ability
	local attributeSelections = world:get(playerEntity, AttributeSelections)
	if attributeSelections and attributeSelections[abilityId] then
		-- Already selected an attribute for this ability
		return available
	end
	local abilityData = world:get(playerEntity, AbilityData)
	if abilityData and abilityData.abilities and abilityData.abilities[abilityId] then
		local abilityRecord = abilityData.abilities[abilityId]
		if abilityRecord and abilityRecord.selectedAttribute then
			return available
		end
	end
	
	-- Try to load Attributes.lua for this ability
	local success, attributesModule = pcall(function()
		return require(game.ServerScriptService.Abilities[abilityId].Attributes)
	end)
	
	if not success or not attributesModule then
		-- No attributes defined for this ability (not an error - most abilities won't have attributes yet)
		return available
	end
	
	-- Add all available attributes
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

-- Select upgrade choices using weighted selection
-- 1 ability (60% owned/40% all), 1 passive (50/50), 3 random
function UpgradeSystem.selectUpgradeChoices(playerEntity: number, level: number, count: number): {any}
	count = count or 5

	local availableAbilities = getAvailableAbilityUpgrades(playerEntity)
	local availablePassives = getAvailablePassiveUpgrades(playerEntity)
	
	-- Check for available attributes (1 slot per 10 levels, starting at level 10)
	-- Only one attribute choice is offered per eligible hand
	local availableAttributes = {}
	local attributeLevelInterval = 10
	local maxAttributeSlots = 5
	local slotsAvailable = math.min(math.floor(level / attributeLevelInterval), maxAttributeSlots)
	local slotsUsed = countSelectedAttributes(playerEntity)
	if slotsAvailable > 0 and slotsUsed < slotsAvailable then
		local maxLevelAbilities = getMaxLevelAbilities(playerEntity)
		local attributeCandidates = {}
		
		for _, abilityInfo in ipairs(maxLevelAbilities) do
			local attributes = getAvailableAttributesForAbility(playerEntity, abilityInfo.abilityId)
			if #attributes > 0 then
				table.insert(attributeCandidates, {
					abilityId = abilityInfo.abilityId,
					attributes = attributes,
				})
			end
		end
		
		if #attributeCandidates > 0 then
			local pickedAbility = attributeCandidates[RNG:NextInteger(1, #attributeCandidates)]
			local randomAttr = pickedAbility.attributes[RNG:NextInteger(1, #pickedAbility.attributes)]
			table.insert(availableAttributes, {
				id = pickedAbility.abilityId .. "_attr_" .. randomAttr.id,
				abilityId = pickedAbility.abilityId,
				attributeId = randomAttr.id,
				name = randomAttr.data.name,
				desc = randomAttr.data.desc,
				category = "attribute",
				data = randomAttr.data,
				color = randomAttr.data.color, -- Attribute color from Attributes.lua
			})
		end
	end
	
	-- Check if all upgrades are maxed
	if #availableAbilities == 0 and #availablePassives == 0 then
		-- Every 5 levels, show heal options
		if level % 5 == 0 then
			local choices = {}
			for i = 1, count do
				table.insert(choices, {
					id = "heal_30_" .. i,
					name = "Heal 30% HP",
					desc = "Restore 30% of your maximum HP",
					isHeal = true,
					category = "heal"
				})
			end
			return choices
		else
			-- Not a heal level, return empty (skip automatically)
			return {}
		end
	end
	
	-- Check if player needs mobility upgrade options (replaces starter dash)
	local levelComponent = world:get(playerEntity, Components.Level)
	local playerLevel = levelComponent and levelComponent.current or 1
	local mobilityData = world:get(playerEntity, Components.MobilityData)
	
	-- Player has upgraded mobility if they have anything OTHER than basic Dash
	local hasMobilityUpgrade = mobilityData and mobilityData.equippedMobility ~= nil and mobilityData.equippedMobility ~= "Dash"
	
	-- Add mobility upgrade options if player meets level requirement and still has basic Dash
	local availableMobility = {}
	
	-- Check each mobility upgrade individually based on its minLevel
	if not hasMobilityUpgrade then
		-- Shield Bash
		if playerLevel >= ShieldBashConfig.minLevel then
			table.insert(availableMobility, {
				id = "mobility_ShieldBash",
				name = ShieldBashConfig.displayName,
				displayName = ShieldBashConfig.displayName,
				desc = ShieldBashConfig.description,
				category = "mobility",
				mobilityId = "ShieldBash",
				color = ShieldBashConfig.color,
			})
		end
		
		-- Double Jump
		if playerLevel >= DoubleJumpConfig.minLevel then
			table.insert(availableMobility, {
				id = "mobility_DoubleJump",
				name = DoubleJumpConfig.displayName,
				displayName = DoubleJumpConfig.displayName,
				desc = DoubleJumpConfig.description,
				category = "mobility",
				mobilityId = "DoubleJump",
				color = DoubleJumpConfig.color,
			})
		end
	end
	
	-- Guarantee at least one mobility option if any are available
	local needsGuaranteedMobility = #availableMobility > 0
	
	local allAvailable = {}
	for _, upgrade in ipairs(availableAbilities) do
		table.insert(allAvailable, upgrade)
	end
	for _, upgrade in ipairs(availablePassives) do
		table.insert(allAvailable, upgrade)
	end
	for _, upgrade in ipairs(availableMobility) do
		table.insert(allAvailable, upgrade)
	end
	-- Add attributes to allAvailable pool (treated like normal upgrades)
	for _, attr in ipairs(availableAttributes) do
		table.insert(allAvailable, attr)
	end
	
	-- Separate owned vs all
	local ownedAbilities = {}
	local ownedPassives = {}
	
	for _, upgrade in ipairs(availableAbilities) do
		if hasAbilityUnlocked(playerEntity, upgrade.abilityId) then
			table.insert(ownedAbilities, upgrade)
		end
	end
	
	for _, upgrade in ipairs(availablePassives) do
		-- Passives are always "owned" once you have 1 level
		local currentLevel = getUpgradeLevel(playerEntity, upgrade.passiveId, "passives")
		if currentLevel > 0 then
			table.insert(ownedPassives, upgrade)
		end
	end
	
	local choices = {}
	local usedIds = {}
	
	-- Slot 1: Ability (60% owned, 40% all)
	if #availableAbilities > 0 then
		local pool = (#ownedAbilities > 0 and RNG:NextNumber() < 0.6) and ownedAbilities or availableAbilities
		if #pool > 0 then
			local selected = pool[RNG:NextInteger(1, #pool)]
			table.insert(choices, selected)
			usedIds[selected.id] = true
		end
	end
	
	-- Slot 2: Passive (50% owned, 50% all)
	if #availablePassives > 0 then
		local pool = (#ownedPassives > 0 and RNG:NextNumber() < 0.5) and ownedPassives or availablePassives
		if #pool > 0 then
			-- Filter out already used
			local filtered = {}
			for _, upgrade in ipairs(pool) do
				if not usedIds[upgrade.id] then
					table.insert(filtered, upgrade)
				end
			end
			
			if #filtered > 0 then
				local selected = filtered[RNG:NextInteger(1, #filtered)]
				table.insert(choices, selected)
				usedIds[selected.id] = true
			end
		end
	end
	
	-- Slot 3: Guarantee attribute if available (whenever requirements are met)
	-- Once player has max-level abilities, attributes will keep appearing until one is selected
	local needsGuaranteedAttribute = #availableAttributes > 0
	if needsGuaranteedAttribute and #choices < count then
		local selected = availableAttributes[RNG:NextInteger(1, #availableAttributes)]
		table.insert(choices, selected)
		usedIds[selected.id] = true
	end
	
	-- Slots 3-5: Random, but guarantee mobility if needed
	-- If player is level 25+ and hasn't picked a mobility, force one mobility option
	if needsGuaranteedMobility and #choices < count and #availableMobility > 0 then
		local selected = availableMobility[RNG:NextInteger(1, #availableMobility)]
		table.insert(choices, selected)
		usedIds[selected.id] = true
	end
	
	-- Fill remaining slots with random upgrades
	while #choices < count and #allAvailable > 0 do
		-- Filter out already used
		local filtered = {}
		for _, upgrade in ipairs(allAvailable) do
			if not usedIds[upgrade.id] then
				table.insert(filtered, upgrade)
			end
		end
		
		if #filtered == 0 then
			break  -- No more unique options
		end
		
		local selected = filtered[RNG:NextInteger(1, #filtered)]
		table.insert(choices, selected)
		usedIds[selected.id] = true
	end
	
	-- If still not enough choices, fill with heal options
	while #choices < count do
		table.insert(choices, {
			id = "heal_30_" .. #choices,
			name = "Heal 30% HP",
			desc = "Restore 30% of your maximum HP",
			isHeal = true,
			category = "heal"
		})
	end
	
	return choices
end

-- Apply an ability upgrade (modifies AbilityData component)
local function applyAbilityUpgrade(playerEntity: number, abilityId: string, level: number)
	-- Get ability balance and upgrades
	local ability = AbilityRegistry.get(abilityId)
	if not ability then
		warn("[UpgradeSystem] Unknown ability:", abilityId)
		return false
	end
	
	local success, upgradesModule = pcall(function()
		return require(game.ServerScriptService.Abilities[abilityId].Upgrades)
	end)
	
	if not success or not upgradesModule or not upgradesModule[level] then
		warn("[UpgradeSystem] Failed to load upgrade level", level, "for", abilityId)
		return false
	end
	
	local upgradeData = upgradesModule[level]
	
	-- Handle unlock special case
	if upgradeData.unlock then
		-- Grant the ability to the player
		local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
		AbilityRegistry.grantAbility(world, playerEntity, abilityId, Components, DirtyService, ModelReplicationService)
		setUpgradeLevel(playerEntity, abilityId, "abilities", level, #upgradesModule)
		return true
	end
	
	-- Get current ability data
	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or not abilityData.abilities or not abilityData.abilities[abilityId] then
		warn("[UpgradeSystem] Player doesn't have ability:", abilityId)
		return false
	end
	
	-- Apply ALL upgrades from level 1 to current level cumulatively
	-- Start from base balance values
	local baseBalance = ability.balance
	local modifiedStats = {}
	
	-- Copy base stats
	for key, value in pairs(baseBalance) do
		if type(value) == "number" or type(value) == "string" then
			modifiedStats[key] = value
		end
	end
	
	-- Apply each upgrade level cumulatively
	for upgradeLevel = 1, level do
		local levelData = upgradesModule[upgradeLevel]
		if levelData then
			for statName, modifier in pairs(levelData) do
				-- Skip metadata fields
				if statName ~= "name" and statName ~= "desc" and statName ~= "unlock" then
					local currentValue = modifiedStats[statName] or baseBalance[statName] or 0
					modifiedStats[statName] = parseModifier(modifier, currentValue)
				end
			end
		end
	end
	
	-- Store modified stats in ability's record (not replacing entire abilities table)
	local abilities = abilityData.abilities
	local abilityRecord = abilities[abilityId]
	
	-- Update ability record with modified stats
	for statName, value in pairs(modifiedStats) do
		abilityRecord[statName] = value
	end
	abilityRecord.level = level
	
	-- Update component
	DirtyService.setIfChanged(world, playerEntity, AbilityData, {abilities = abilities}, "AbilityData")
	
	-- Track upgrade level
	setUpgradeLevel(playerEntity, abilityId, "abilities", level, #upgradesModule)
	
	return true
end

-- Apply a passive upgrade (modifies PassiveEffects component)
local function applyPassiveUpgrade(playerEntity: number, passiveId: string, level: number)
	local passiveLevels = PassiveUpgrades[passiveId]
	if not passiveLevels or not passiveLevels[level] then
		warn("[UpgradeSystem] Unknown passive or level:", passiveId, level)
		return false
	end
	
	-- Apply ALL levels cumulatively to get final multipliers
	local effects = world:get(playerEntity, PassiveEffects)
	if not effects then
		effects = {
			damageMultiplier = PlayerBalance.BaseDamageMultiplier,
			cooldownMultiplier = PlayerBalance.BaseCooldownMultiplier,
			healthMultiplier = 1.0,
			moveSpeedMultiplier = 1.0,
			sizeMultiplier = 1.0,
			durationMultiplier = 1.0,
			pickupRangeMultiplier = 1.0,
			mobilityDistanceMultiplier = 1.0,
			activeSpeedBuffs = {},
		}
	end
	
	-- Recalculate all passive effects from scratch (cumulative)
	-- Reset to PlayerBalance base multipliers (but preserve temporary speed buffs)
	local cumulativeEffects = {
		damageMultiplier = PlayerBalance.BaseDamageMultiplier,
		cooldownMultiplier = PlayerBalance.BaseCooldownMultiplier,
		healthMultiplier = 1.0,
		moveSpeedMultiplier = 1.0,
		sizeMultiplier = 1.0,
		durationMultiplier = 1.0,
		pickupRangeMultiplier = 1.0,
		mobilityDistanceMultiplier = 1.0,
		activeSpeedBuffs = effects.activeSpeedBuffs or {},  -- Preserve all active speed buffs
	}
	
	-- Apply all passive upgrades the player has
	for pId, pLevels in pairs(PassiveUpgrades) do
		local pLevel = getUpgradeLevel(playerEntity, pId, "passives")
		if pId == passiveId then
			pLevel = level  -- Use the new level being applied
		end
		
		-- Apply each level cumulatively
		for i = 1, pLevel do
			local levelData = pLevels[i]
			if levelData then
				for statName, modifier in pairs(levelData) do
					if statName ~= "name" and statName ~= "desc" and statName ~= "healOnLevelUp" then
						if cumulativeEffects[statName] then
							cumulativeEffects[statName] = parseModifier(modifier, cumulativeEffects[statName])
						end
					end
				end
			end
		end
	end
	
	-- Apply moveSpeedMultiplier to mobilityDistanceMultiplier (Haste affects both)
	cumulativeEffects.mobilityDistanceMultiplier = cumulativeEffects.moveSpeedMultiplier
	
	-- Update component
	DirtyService.setIfChanged(world, playerEntity, PassiveEffects, cumulativeEffects, "PassiveEffects")
	
	-- Track upgrade level
	setUpgradeLevel(playerEntity, passiveId, "passives", level, #passiveLevels)
	
	-- Handle heal-on-levelup if present
	local upgradeData = passiveLevels[level]
	if upgradeData.healOnLevelUp then
		local playerStats = world:get(playerEntity, PlayerStats)
		if playerStats and playerStats.player and playerStats.player.Character then
			local humanoid = playerStats.player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				local healAmount = humanoid.MaxHealth * upgradeData.healOnLevelUp
				humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + healAmount)
			end
		end
	end
	
	return true
end

-- Apply heal upgrade (30% HP)
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

-- Apply an attribute upgrade to a player
local function applyAttributeUpgrade(playerEntity: number, upgradeId: string): boolean
	-- Parse: "MagicBolt_attr_ChainCasting" -> abilityId="MagicBolt", attributeId="ChainCasting"
	local parts = string.split(upgradeId, "_attr_")
	if #parts ~= 2 then
		warn("[UpgradeSystem] Invalid attribute upgrade ID:", upgradeId)
		return false
	end
	
	local abilityId = parts[1]
	local attributeId = parts[2]
	
	-- Get ability balance
	local ability = AbilityRegistry.get(abilityId)
	if not ability then
		warn("[UpgradeSystem] Unknown ability:", abilityId)
		return false
	end
	
	-- Load attribute data
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
	
	-- Get current ability data
	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or not abilityData.abilities or not abilityData.abilities[abilityId] then
		warn("[UpgradeSystem] Player doesn't have ability:", abilityId)
		return false
	end
	
	-- Apply attribute stats to ability
	local abilities = abilityData.abilities
	local abilityRecord = abilities[abilityId]
	
	-- Apply stat modifiers
	if attributeData.stats then
		for statName, modifier in pairs(attributeData.stats) do
			local currentValue = abilityRecord[statName] or ability.balance[statName] or 0
			
			-- Handle special multiplier syntax ("*10")
			if type(modifier) == "string" and modifier:match("^%*") then
				local multiplier = tonumber(modifier:match("^%*(%d+%.?%d*)$"))
				if multiplier then
					abilityRecord[statName] = currentValue * multiplier
				else
					abilityRecord[statName] = parseModifier(modifier, currentValue)
				end
			else
				abilityRecord[statName] = parseModifier(modifier, currentValue)
			end
		end
	end
	
	-- Store attribute metadata (color for visual effects)
	if attributeData.color then
		abilityRecord.attributeColor = attributeData.color
	end
	abilityRecord.selectedAttribute = attributeId
	if attributeData.special then
		abilityRecord.attributeSpecial = attributeData.special
	end
	
	-- Update ability data
	DirtyService.setIfChanged(world, playerEntity, AbilityData, {abilities = abilities}, "AbilityData")
	
	-- Track attribute selection
	local attributeSelections = world:get(playerEntity, AttributeSelections)
	if not attributeSelections then
		attributeSelections = {}
	end
	attributeSelections[abilityId] = attributeId
	DirtyService.setIfChanged(world, playerEntity, AttributeSelections, attributeSelections, "AttributeSelections")
	
	-- Handle special attribute logic (e.g., Afterimages clones)
	if attributeData.special and attributeData.special.replacesPlayer then
		-- Initialize AfterimageClones component (will be managed by AfterimageCloneSystem)
		local clonesData = {
			abilityId = abilityId,
			clones = {},  -- Will be populated by AfterimageCloneSystem
			cloneCount = attributeData.special.cloneCount or 3,
			cloneTransparency = attributeData.special.cloneTransparency or 0.5,
			triangleSideLength = attributeData.special.cloneTriangleSideLength or 30,
		}
		DirtyService.setIfChanged(world, playerEntity, AfterimageClones, clonesData, "AfterimageClones")
		
		-- Initialize cooldown in AbilityCooldown component (so UI shows it immediately)
		local cooldownData = world:get(playerEntity, Components.AbilityCooldown)
		local cooldowns = cooldownData and cooldownData.cooldowns or {}
		
		-- Set initial cooldown to 0 (ready to shoot)
		cooldowns[abilityId] = {
			remaining = 0,
			max = abilityRecord.cooldown or ability.balance.cooldown,
		}
		DirtyService.setIfChanged(world, playerEntity, Components.AbilityCooldown, {
			cooldowns = cooldowns
		}, "AbilityCooldown")
	end
	
	return true
end

-- PUBLIC API: Apply an upgrade to a player
function UpgradeSystem.applyUpgrade(playerEntity: number, upgradeId: string): boolean
	if not world then
		warn("[UpgradeSystem] World not initialized")
		return false
	end
	
	-- Handle attribute upgrades (format: "AbilityId_attr_AttributeId")
	if upgradeId:match("_attr_") then
		return applyAttributeUpgrade(playerEntity, upgradeId)
	end
	
	-- Handle heal upgrades
	if upgradeId:match("^heal_30_") then
		return applyHeal(playerEntity)
	end
	
	-- Handle mobility upgrades (format: "mobility_MobilityName")
	if upgradeId:match("^mobility_") then
		local mobilityId = upgradeId:match("^mobility_(.+)$")
		
		-- Get mobility config
		local mobilityConfig = nil
		if mobilityId == "Dash" then
			mobilityConfig = DashConfig
		elseif mobilityId == "ShieldBash" then
			mobilityConfig = ShieldBashConfig
		elseif mobilityId == "DoubleJump" then
			mobilityConfig = DoubleJumpConfig
		end
		
		if mobilityConfig then
			-- Replicate model to ReplicatedStorage if it has a model path
			-- DoubleJump: platform model, ShieldBash: shield model, Dash: no model
			local modelPath = mobilityConfig.platformModelPath or mobilityConfig.shieldModelPath or mobilityConfig.modelPath
			if modelPath and (mobilityId == "DoubleJump" or mobilityId == "ShieldBash") then
				local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
				-- Extract path after "ReplicatedStorage."
				local serverPath = modelPath:match("ReplicatedStorage%.(.+)")
				if serverPath then
					local success = ModelReplicationService.replicateMobilityModel(serverPath)
					if not success then
						warn("[UpgradeSystem] Could not find mobility model in ServerStorage (expected at: ServerStorage." .. serverPath .. "). Using placeholder instead.")
					end
				end
			end
			
			-- Build mobility data (includes all possible fields for different mobility types)
			local mobilityData = {
				equippedMobility = mobilityId,
				-- Send config values to client for proper cooldown checking
				distance = mobilityConfig.distance or (mobilityConfig.horizontalDistance and mobilityConfig.horizontalDistance or 25),
				cooldown = mobilityConfig.cooldown,
				duration = mobilityConfig.duration or 0.15,
				verticalHeight = mobilityConfig.verticalHeight,
				platformModelPath = mobilityConfig.platformModelPath,
				shieldModelPath = mobilityConfig.shieldModelPath,
				
				-- Shield Bash specific (nil for other mobility types)
				damage = mobilityConfig.damage,
				knockbackDistance = mobilityConfig.knockbackDistance,
				invincibilityPerHit = mobilityConfig.invincibilityPerHit,
			}
			
			-- Set equipped mobility with config data (replaces any previous mobility)
			DirtyService.setIfChanged(world, playerEntity, Components.MobilityData, mobilityData, "MobilityData")
			
			-- Initialize cooldown component
			DirtyService.setIfChanged(world, playerEntity, Components.MobilityCooldown, {
				lastUsedTime = 0
			}, "MobilityCooldown")
			
			return true
		else
			warn("[UpgradeSystem] Unknown mobility ID:", mobilityId)
			return false
		end
	end
	
	-- Parse upgrade ID (format: "AbilityName_Level")
	local parts = string.split(upgradeId, "_")
	if #parts < 2 then
		warn("[UpgradeSystem] Invalid upgrade ID:", upgradeId)
		return false
	end
	
	local upgradeType = parts[1]
	local level = tonumber(parts[2])
	
	if not level then
		warn("[UpgradeSystem] Invalid level in upgrade ID:", upgradeId)
		return false
	end
	
	-- Check if it's an ability or passive
	if AbilityRegistry.isRegistered(upgradeType) then
		return applyAbilityUpgrade(playerEntity, upgradeType, level)
	elseif PassiveUpgrades[upgradeType] then
		return applyPassiveUpgrade(playerEntity, upgradeType, level)
	else
		warn("[UpgradeSystem] Unknown upgrade type:", upgradeType)
		return false
	end
end

-- PUBLIC API: Get available upgrades with computed descriptions
function UpgradeSystem.getAvailableUpgrades(playerEntity: number)
	return {
		abilities = getAvailableAbilityUpgrades(playerEntity),
		passives = getAvailablePassiveUpgrades(playerEntity),
	}
end

return UpgradeSystem
