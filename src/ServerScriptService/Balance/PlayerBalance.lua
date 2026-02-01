--!strict
-- PlayerBalance - Centralized player base stats configuration
-- All player default values should be defined here

return {
	-- Core Stats
	BaseMaxHealth = 100,  -- Starting max health
	BaseWalkSpeed = 24,  -- Base movement speed
	BasePickupRange = 20.0,  -- Collection radius for both exp orbs and powerups
	
	-- Combat Scaling Multipliers (applied before passive upgrades)
	BaseCooldownMultiplier = 1,  -- Global cooldown scaling (lower = faster cooldowns)
	BaseDamageMultiplier = 1.0,  -- Global damage scaling (higher = more damage)
	
	-- Regeneration & Survival
	HealthRegenRate = 1.0,  -- HP per second at 100% regen (0 = no regen by default)
	HealthRegenDelay = 5.0,  -- Total delay before reaching 100% regen (first 1s = 0%, then scales up)
	BaseInvincibilityFrames = 0.5,  -- Seconds of invincibility after taking damage
	
	-- Experience & Progression
	BaseExpMultiplier = 1.0,  -- Experience gain multiplier
	StartingLevel = 1,  -- Level on spawn
	StartingExperience = 0,  -- Starting exp
	
	-- Visual & Respawn	
	RespawnDelay = 300.0,  -- Seconds before respawn after death (DEPRECATED - using DeathRespawnScaling now)
	
	-- Death & Respawn System
	DeathRespawnScaling = {
		-- Linear scaling: respawn time = StartValue + (Slope * level)
		StartValue = 10,   -- 25 seconds at level 1
		Slope = 0.5,        -- +2 seconds per level (level 10 = 43s, level 20 = 63s capped at 60s)
		MaxValue = 60.0,    -- Cap at 60 seconds
	},
	DeathAnimationId = nil,  -- Set to animation ID (e.g., "rbxassetid://123456789") to play death animation
	DeathFadeDelay = 5.0,  -- Seconds before body starts fading
	DeathFadeSpeed = 2.0,  -- Transparency increase per second (0.5 = fully transparent in 2s)
	
	-- Spawn Protection
	SpawnInvincibility = 15.0,  -- Seconds of invincibility on spawn/respawn
	
	-- EXP Catch-Up System (One-Time Boost)
	ExpCatchUp = {
		ActivationThreshold = 0.60,  -- Activate if player < 60% of highest level
		DeactivationPercent = 0.10,  -- Stop after gaining 10% of activation level
		BaseMultiplier = 2.0,  -- Base 2.0x multiplier
		ScalingFactor = 3.0,  -- Multiply gap formula by this (the "x" in formula)
		-- Formula: expBoost = BaseMultiplier + (ScalingFactor * ((highestLevel - playerLevel) / highestLevel))
		-- Example: L10 with L100 highest = 2.0 + (3 * (90/100)) = 2.0 + 2.7 = 4.7x EXP
	},
}
