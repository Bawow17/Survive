--!strict
-- Glacial Path Mobility Ability Configuration
-- Starter ice utility slide that generates a local/replicated ice path.

return {
	id = "GlacialPath",
	displayName = "Glacial Path",
	description = "Slide on a generated ice path. Instant boost, fast stop, short cooldown.",

	-- UI color (shown in upgrade selection)
	color = Color3.fromRGB(120, 225, 255),

	-- Movement
	distance = 103.125, -- +10% from previous tuning
	duration = 35 / 60, -- 35 frames at 60 FPS

	-- Timing
	cooldown = 3.0,

	-- Ice path generation
	pathSpacing = 3.0, -- 3 studs per generated segment
	rampFrames = 10,
	totalFrames = 35,
	lookAheadDistance = 15.0,
	pathPartLifetime = 2.0,

	-- VFX models (ReplicatedStorage paths)
	glacialPathAnimationModelPath = "ContentDrawer.PlayerAbilities.Ice.Utility.GlacialPath.GlacialPathAnimation",
	glacialPathPathModelPath = "ContentDrawer.PlayerAbilities.Ice.Utility.GlacialPath.IcePath",
	glacialPathBeam1ModelPath = "ContentDrawer.PlayerAbilities.Ice.Utility.GlacialPath.IceLaser",
	glacialPathBeam2ModelPath = "ContentDrawer.PlayerAbilities.Ice.Utility.GlacialPath.IceLaser2",

	-- Unlock
	category = "mobility",
}
