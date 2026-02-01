--!strict
-- Shared PlayerBalance - Client-accessible subset
-- This is a simplified version for client-side usage

return {
	-- Core Stats
	BaseMaxHealth = 100,
	BaseWalkSpeed = 24,
	BasePickupRange = 20.0,

	-- Combat Scaling Multipliers
	BaseCooldownMultiplier = 1,
	BaseDamageMultiplier = 1.0,

	-- Regeneration & Survival
	HealthRegenRate = 1.0,
	HealthRegenDelay = 5.0,

	-- Experience & Progression
	BaseExpMultiplier = 1.0,

	-- Death & Respawn System
	DeathFadeDelay = 5.0,  -- Seconds before body starts fading
	DeathFadeSpeed = 2.0,  -- Transparency increase per second (0.5 = fully transparent in 2s)
}
