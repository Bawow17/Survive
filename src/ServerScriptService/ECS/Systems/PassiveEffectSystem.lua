--!strict
-- PassiveEffectSystem - Applies passive upgrade effects to player stats
-- Modifies Humanoid properties (Health, WalkSpeed) and stores pickup range

local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)

local PassiveEffectSystem = {}

local world: any
local Components: any
local DirtyService: any
local StatusEffectSystem: any  -- Reference to status effect system

local PassiveEffects: any
local PlayerStats: any
local Health: any

-- Default values (from PlayerBalance)
local DEFAULT_MAX_HEALTH = PlayerBalance.BaseMaxHealth
local DEFAULT_WALK_SPEED = PlayerBalance.BaseWalkSpeed
local DEFAULT_PICKUP_RANGE = PlayerBalance.BasePickupRange
local MOVEMENT_SPEED_TO_MOBILITY_WEIGHT = 0.2

-- Cached query for players
local playerQuery: any

-- 5fps update throttle (prevents excessive updates)
local UPDATE_INTERVAL = 0.2  -- 5fps
local updateAccumulator = 0

function PassiveEffectSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	PassiveEffects = Components.PassiveEffects
	PlayerStats = Components.PlayerStats
	Health = Components.Health
	
	-- Create cached query
	playerQuery = world:query(Components.PlayerStats, Components.PassiveEffects):cached()
end

-- Set StatusEffectSystem reference (called after it's initialized)
function PassiveEffectSystem.setStatusEffectSystem(statusEffectSystem: any)
	StatusEffectSystem = statusEffectSystem
end

-- Calculate total speed multiplier (Haste passive + all active buffs)
local function calculateTotalSpeedMultiplier(effects: any): number
	local baseMult = effects.moveSpeedMultiplier or 1.0  -- Haste passive
	local totalBonus = baseMult - 1.0
	
	-- Speed bonuses stack additively: (1 + a) + (1 + b) => 1 + a + b
	if effects.activeSpeedBuffs then
		for _, buffData in pairs(effects.activeSpeedBuffs) do
			totalBonus += (buffData.multiplier or 1.0) - 1.0
		end
	end
	
	return math.max(0, 1.0 + totalBonus)
end

-- Mobility abilities scale fully with mobility power, plus 20% of movement-speed bonus.
local function calculateMobilityDistanceMultiplier(effects: any, totalSpeedMult: number): number
	local mobilityBase = effects.mobilityDistanceBase or 1.0
	local speedBonus = totalSpeedMult - 1.0
	local speedContribution = 1.0 + (speedBonus * MOVEMENT_SPEED_TO_MOBILITY_WEIGHT)
	return mobilityBase * math.max(0, speedContribution)
end

-- Apply passive effects to a player
local function applyEffectsToPlayer(playerEntity: number, effects: any)
	local playerStats = world:get(playerEntity, PlayerStats)
	if not playerStats or not playerStats.player then
		return
	end
	
	local player = playerStats.player
	local character = player.Character
	if not character then
		return
	end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	
	-- Apply health multiplier
	local healthMult = effects.healthMultiplier or 1.0
	local healthFlat = effects.healthFlatBonus or 0
	local baseMaxHealth = player:GetAttribute("BaseMaxHealth")
	if not baseMaxHealth or baseMaxHealth == 0 then
		-- Use PlayerBalance default, not humanoid's current value
		baseMaxHealth = DEFAULT_MAX_HEALTH
		player:SetAttribute("BaseMaxHealth", baseMaxHealth)
	end
	
	local newMaxHealth = baseMaxHealth * healthMult + healthFlat

	-- Keep ECS Health and Humanoid health in sync.
	-- Damage/regen/death systems use ECS Health as authoritative state.
	local ecsHealth = world:get(playerEntity, Health)
	local targetCurrentHealth = humanoid.Health
	local targetMaxHealth = newMaxHealth

	if ecsHealth then
		local oldMax = math.max(ecsHealth.max or targetMaxHealth, 0.01)
		local oldCurrent = math.clamp(ecsHealth.current or oldMax, 0, oldMax)
		targetCurrentHealth = oldCurrent

		-- Preserve current health percentage when max health changes, without reducing
		-- absolute health on upgrades.
		if math.abs(oldMax - targetMaxHealth) > 0.1 then
			local healthPercent = oldCurrent / oldMax
			targetCurrentHealth = math.max(oldCurrent, targetMaxHealth * healthPercent)
		end

		targetCurrentHealth = math.clamp(targetCurrentHealth, 0, targetMaxHealth)

		if math.abs((ecsHealth.max or 0) - targetMaxHealth) > 0.1
			or math.abs((ecsHealth.current or 0) - targetCurrentHealth) > 0.1 then
			DirtyService.setIfChanged(world, playerEntity, Health, {
				current = targetCurrentHealth,
				max = targetMaxHealth,
			}, "Health")
		end
	else
		-- Defensive path: create ECS health if missing.
		targetCurrentHealth = math.clamp(humanoid.Health, 0, targetMaxHealth)
		DirtyService.setIfChanged(world, playerEntity, Health, {
			current = targetCurrentHealth,
			max = targetMaxHealth,
		}, "Health")
	end

	-- Apply the same target values to Humanoid to avoid visual/gameplay desync.
	if math.abs(humanoid.MaxHealth - targetMaxHealth) > 0.1 then
		humanoid.MaxHealth = targetMaxHealth
	end
	if math.abs(humanoid.Health - targetCurrentHealth) > 0.1 then
		humanoid.Health = math.clamp(targetCurrentHealth, 0.01, targetMaxHealth)
	end
	
	-- Calculate total speed multiplier (Haste + all active buffs stacking additively)
	local totalSpeedMult = calculateTotalSpeedMultiplier(effects)
	
	local baseWalkSpeed = player:GetAttribute("BaseWalkSpeed")
	if not baseWalkSpeed or baseWalkSpeed == 0 then
		-- Use PlayerBalance default, not humanoid's current value
		baseWalkSpeed = DEFAULT_WALK_SPEED
		player:SetAttribute("BaseWalkSpeed", baseWalkSpeed)
	end
	
	-- Apply walkspeed
	local newWalkSpeed = baseWalkSpeed * totalSpeedMult
	if math.abs(humanoid.WalkSpeed - newWalkSpeed) > 0.1 then
		humanoid.WalkSpeed = newWalkSpeed
	end
	
	-- Mobility abilities: full Mobility Power + 20% Movement Speed bonus.
	effects.mobilityDistanceMultiplier = calculateMobilityDistanceMultiplier(effects, totalSpeedMult)
	DirtyService.setIfChanged(world, playerEntity, PassiveEffects, effects, "PassiveEffects")
	
	-- Store pickup range multiplier for ExpCollectionSystem
	local pickupRangeMult = effects.pickupRangeMultiplier or 1.0
	player:SetAttribute("PickupRangeMultiplier", pickupRangeMult)
	player:SetAttribute("BasePickupRange", DEFAULT_PICKUP_RANGE)
	
	-- Store exp multiplier for ExpCollectionSystem
	local expMult = effects.expMultiplier or 1.0
	player:SetAttribute("ExpMultiplier", expMult)
	
	-- Set base animation walkspeed for AnimationSpeedController
	player:SetAttribute("BaseAnimationWalkSpeed", PlayerBalance.BaseAnimationWalkSpeed)
end

-- PUBLIC API: Apply passive effects to a specific player (called after upgrade)
function PassiveEffectSystem.applyToPlayer(playerEntity: number)
	local effects = world:get(playerEntity, PassiveEffects)
	if effects then
		applyEffectsToPlayer(playerEntity, effects)
	end
end

-- System step: Periodically refresh passive effects (5fps throttle)
function PassiveEffectSystem.step(dt: number)
	if not world then
		return
	end
	
	-- Throttle to 5fps for performance and smooth updates
	updateAccumulator = updateAccumulator + dt
	if updateAccumulator < UPDATE_INTERVAL then
		return
	end
	updateAccumulator = 0
	
	local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
	local currentTime = GameTimeSystem.getGameTime()
	
	-- Apply effects to all players (catches respawns, ensures consistency)
	for entity, playerStats, effects in playerQuery do
		-- Clean up expired speed buffs
		if effects.activeSpeedBuffs then
			local needsUpdate = false
			for buffId, buffData in pairs(effects.activeSpeedBuffs) do
				if buffData.endTime and buffData.endTime <= currentTime then
					effects.activeSpeedBuffs[buffId] = nil
					needsUpdate = true
				end
			end
			if needsUpdate then
				DirtyService.mark(entity, "PassiveEffects")
			end
		end
		
		applyEffectsToPlayer(entity, effects)
	end
end

-- PUBLIC API: Get damage multiplier for a player (used by ability systems)
function PassiveEffectSystem.getDamageMultiplier(playerEntity: number): number
	local effects = world:get(playerEntity, PassiveEffects)
	return (effects and effects.damageMultiplier) or 1.0
end

-- PUBLIC API: Get cooldown multiplier for a player (used by ability systems)
function PassiveEffectSystem.getCooldownMultiplier(playerEntity: number): number
	local effects = world:get(playerEntity, PassiveEffects)
	return (effects and effects.cooldownMultiplier) or 1.0
end

-- PUBLIC API: Get size multiplier for a player (used by ability systems)
function PassiveEffectSystem.getSizeMultiplier(playerEntity: number): number
	local effects = world:get(playerEntity, PassiveEffects)
	return (effects and effects.sizeMultiplier) or 1.0
end

-- PUBLIC API: Get duration multiplier for a player (used by ability systems)
function PassiveEffectSystem.getDurationMultiplier(playerEntity: number): number
	local effects = world:get(playerEntity, PassiveEffects)
	return (effects and effects.durationMultiplier) or 1.0
end

-- PUBLIC API: Get pickup range multiplier for a player (used by ExpCollectionSystem)
function PassiveEffectSystem.getPickupRangeMultiplier(playerEntity: number): number
	local effects = world:get(playerEntity, PassiveEffects)
	return (effects and effects.pickupRangeMultiplier) or 1.0
end

-- PUBLIC API: Get exp multiplier for a player (used by ExpCollectionSystem)
function PassiveEffectSystem.getExpMultiplier(playerEntity: number): number
	local effects = world:get(playerEntity, PassiveEffects)
	return (effects and effects.expMultiplier) or 1.0
end

-- PUBLIC API: Refresh player speed (called when buffs change)
function PassiveEffectSystem.refreshPlayerSpeed(playerEntity: number)
	local effects = world:get(playerEntity, PassiveEffects)
	if not effects then
		return
	end
	
	local playerStats = world:get(playerEntity, PlayerStats)
	if not playerStats or not playerStats.player then
		return
	end
	
	local player = playerStats.player
	local character = player.Character
	if not character then
		return
	end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	
	-- Calculate total speed multiplier (Haste + all active buffs stacking additively)
	local totalSpeedMult = calculateTotalSpeedMultiplier(effects)
	local baseWalkSpeed = player:GetAttribute("BaseWalkSpeed") or DEFAULT_WALK_SPEED
	
	-- Apply walkspeed
	humanoid.WalkSpeed = baseWalkSpeed * totalSpeedMult
	
	-- Mobility abilities: full Mobility Power + 20% Movement Speed bonus.
	effects.mobilityDistanceMultiplier = calculateMobilityDistanceMultiplier(effects, totalSpeedMult)
	DirtyService.setIfChanged(world, playerEntity, PassiveEffects, effects, "PassiveEffects")
end

return PassiveEffectSystem
