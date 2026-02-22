--!strict
-- Shared MovementBalance - client/server movement tuning values

return {
	AirMomentum = {
		enabled = true,
		mode = "target_state",
		writePhase = "PostSimulation",
		groundResetGraceSeconds = 0.08,
		groundCarryWindowSeconds = 0.1,
		overrideReleaseCarryWindowSeconds = 0.35,
		landingAssistSeconds = 0.08,
		landingAssistSpeedThreshold = 0.01,
		groundFrictionEnabled = true,
		groundFrictionLinearDecel = 8.0,
		groundFrictionDrag = 1.0,
		groundFrictionMinSpeed = 1.0,
		groundOppositeBrakeAccel = 90.0,
		oppositeDotThreshold = -0.2,
		oppositeBrakeAccel = 72,
		turnResponse = 7.5,
		turnSpeedLossPerSecond = 0.01,
		noInputRetentionPerSecond = 0.9998,
		adoptExternalBoost = true,
		externalBoostAdoptThreshold = 1.0,
		softCapMinStart = 110,
		softCapWalkspeedMultiplier = 4.5,
		softCapHardMultiplier = 1.35,
		softCapDrag = 18.0,
		minControllableSpeed = 4.0,
		debugAttributes = false,
	},
}
