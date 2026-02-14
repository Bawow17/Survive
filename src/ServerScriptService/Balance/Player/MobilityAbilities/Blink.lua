--!strict
-- Blink Mobility Ability Configuration
-- Ground: short horizontal teleport
-- Air: windup then angled teleport

return {
	id = "Blink",
	displayName = "Blink",
	description = "Tap into space. Ground: short 25-stud blink. Air: 0.3s windup, then blink 110 studs upward at 30 degrees.",
	
	-- UI color (shown in upgrade selection)
	color = Color3.fromRGB(160, 120, 255),
	
	-- Ground variant
	groundDistance = 25,  -- studs
	groundCooldown = 2.0,  -- seconds

	-- VFX models (ServerStorage paths; replicated to ReplicatedStorage)
	blinkJumpStartModelPath = "ContentDrawer.PlayerAbilities.MobilityAbilities.Blink.BlinkJump.Start",
	blinkJumpEndModelPath = "ContentDrawer.PlayerAbilities.MobilityAbilities.Blink.BlinkJump.End",
	blinkGroundStartModelPath = "ContentDrawer.PlayerAbilities.MobilityAbilities.Blink.BlinkGround.Start",
	blinkGroundEndModelPath = "ContentDrawer.PlayerAbilities.MobilityAbilities.Blink.BlinkGround.End",
	blinkGroundBeamModelPath = "ContentDrawer.PlayerAbilities.MobilityAbilities.Blink.BlinkGround.Beam",
	
	-- Air variant
	airDistance = 110,  -- studs
	airAngleDeg = 30,  -- degrees from horizontal
	airWindup = 0.3,  -- seconds
	airCooldown = 5.0,  -- seconds
	
	-- Unlock
	minLevel = 15,
	category = "mobility",
}
