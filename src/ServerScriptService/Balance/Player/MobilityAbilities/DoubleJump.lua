--!strict
-- Double Jump Mobility Ability Configuration
-- Second jump in mid-air, launching you in your movement direction

return {
	id = "DoubleJump",
	displayName = "Double Jump",
	description = "Second jump in mid-air, launching you in your movement direction, healing you for 12% of your max HP. (Can only be used in the air)",
	
	-- UI color (shown in upgrade selection)
	color = Color3.fromRGB(50, 150, 255), -- Blue
	
	-- Movement
	horizontalDistance = 75,  -- studs (affected by Haste passive)
	verticalHeight = 11,  -- studs
	
	-- Timing
	cooldown = 10.5,  -- seconds (affected by Fast Casting)
	
	-- Healing
	healAmount = 0.12,  -- 15% of max HP (converts to overheal when full)
	
	-- Requirements
	requiresAirborne = true,  -- MUST be in air to activate
	
	-- Visual
	platformDuration = 0.5,  -- how long platform effect lasts
	platformFadeTime = 0.3,  -- fade out duration
	trailDuration = 2.0,  -- trail stays until ground touch or 2s max
	
	-- Physics
	gravityReduction = 0.6,  -- Reduce gravity by 60% while airborne (0.4x normal gravity)
	
	-- Model path (source in ServerStorage, replicated to ReplicatedStorage)
	platformModelPath = "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.DoubleJumpPlatform.DoubleJumpPlatform",
	
	-- Unlock
	minLevel = 15,  
	category = "mobility",
}

