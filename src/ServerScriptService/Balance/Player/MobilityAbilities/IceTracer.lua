--!strict
-- Ice Tracer Mobility Ability Configuration
-- Starter ice utility slide that generates a local/replicated ice path.

return {
	id = "IceTracer",
	displayName = "Ice Tracer",
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

	-- VFX models (ServerStorage paths; replicated to ReplicatedStorage)
	iceTracerAnimationModelPath = "ContentDrawer.PlayerAbilities.Ice.Utility.IceTracer.IceTracerAnimation",
	iceTracerPathModelPath = "ContentDrawer.PlayerAbilities.Ice.Utility.IceTracer.IcePath",
	iceTracerBeam1ModelPath = "ContentDrawer.PlayerAbilities.Ice.Utility.IceTracer.IceLaser",
	iceTracerBeam2ModelPath = "ContentDrawer.PlayerAbilities.Ice.Utility.IceTracer.IceLaser2",

	-- Unlock
	category = "mobility",
}
