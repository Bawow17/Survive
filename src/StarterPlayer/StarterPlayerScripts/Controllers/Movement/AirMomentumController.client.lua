--!strict
-- AirMomentumController V3
-- Air: persistent target-state momentum retention.
-- Ground: high-speed landing carry only (no global walk slide).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local MovementBalance = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MovementBalance"))

local ATTR_MOBILITY_VELOCITY_OVERRIDE = "MobilityVelocityOverrideLocal"
local ATTR_DEBUG_TARGET_SPEED = "AirMomentumTargetSpeedLocal"
local ATTR_DEBUG_ACTUAL_SPEED = "AirMomentumActualSpeedLocal"
local ATTR_DEBUG_ACTIVE = "AirMomentumActiveLocal"
local ATTR_GROUND_CARRY_ACTIVE = "GroundCarryActiveLocal"
local ATTR_GROUND_CARRY_SPEED = "GroundCarrySpeedLocal"

local EPSILON = 1e-4

local DEFAULTS = {
	enabled = true,
	mode = "target_state",
	writePhase = "PostSimulation",
	groundResetGraceSeconds = 0.08,
	groundCarryWindowSeconds = 0.1,
	overrideReleaseCarryWindowSeconds = 0.35,
	landingAssistSeconds = 0.08,
	landingAssistSpeedThreshold = 0.01,

	-- Deprecated global friction path. Kept for config compatibility only.
	groundFrictionEnabled = false,
	groundFrictionLinearDecel = 8.0,
	groundFrictionDrag = 1.0,
	groundFrictionMinSpeed = 1.0,
	groundOppositeBrakeAccel = 90.0,

	landingCarryEnabled = true,
	landingCarryActivationWalkspeedMultiplier = 1.15,
	landingCarryActivationMinSpeed = 22.0,
	landingCarryRecentAirborneWindow = 0.25,
	landingCarryMinDuration = 0.18,
	landingCarryMaxDuration = 0.70,
	landingCarryDurationRefSpeed = 90.0,
	landingCarryLinearDecel = 180.0,
	landingCarryDrag = 0.0,
	landingCarryTurnResponse = 9.0,
	landingCarryOppositeBrakeAccel = 135.0,
	landingCarryExitSpeed = 10.0,
	landingCarryPreserveWithSameInput = true,
	landingCarryDebugAttributes = false,

	oppositeDotThreshold = -0.2,
	oppositeBrakeAccel = 72,
	turnResponse = 7.5,
	turnSpeedLossPerSecond = 0.01,
	bhopLinearDecel = 0.0, -- 0 => derived from landingCarryLinearDecel / 5
	airDirectionalFightAccel = 260.0,
	airControlAccelToWalkSpeed = 42.0,
	airMisalignedBrakeAccel = 18.0,
	airMisalignedLossPerSecond = 1.25,
	noInputRetentionPerSecond = 0.9998,
	adoptExternalBoost = true,
	externalBoostAdoptThreshold = 1.0,
	softCapMinStart = 110,
	softCapWalkspeedMultiplier = 4.5,
	softCapHardMultiplier = 1.35,
	softCapDrag = 18.0,
	minControllableSpeed = 4.0,
	debugAttributes = false,
}

local function readNumber(value: any, fallback: number): number
	return if typeof(value) == "number" then value else fallback
end

local function readString(value: any, fallback: string): string
	return if typeof(value) == "string" then value else fallback
end

local function readBoolean(value: any, fallback: boolean): boolean
	return if typeof(value) == "boolean" then value else fallback
end

local rawConfig = if typeof(MovementBalance) == "table" and typeof(MovementBalance.AirMomentum) == "table"
	then MovementBalance.AirMomentum
	else {}
local CONFIG = {
	enabled = readBoolean(rawConfig.enabled, DEFAULTS.enabled),
	mode = readString(rawConfig.mode, DEFAULTS.mode),
	writePhase = readString(rawConfig.writePhase, DEFAULTS.writePhase),
	groundResetGraceSeconds = readNumber(rawConfig.groundResetGraceSeconds, DEFAULTS.groundResetGraceSeconds),
	groundCarryWindowSeconds = readNumber(rawConfig.groundCarryWindowSeconds, DEFAULTS.groundCarryWindowSeconds),
	overrideReleaseCarryWindowSeconds = readNumber(rawConfig.overrideReleaseCarryWindowSeconds, DEFAULTS.overrideReleaseCarryWindowSeconds),
	landingAssistSeconds = readNumber(rawConfig.landingAssistSeconds, DEFAULTS.landingAssistSeconds),
	landingAssistSpeedThreshold = readNumber(rawConfig.landingAssistSpeedThreshold, DEFAULTS.landingAssistSpeedThreshold),
	groundFrictionEnabled = readBoolean(rawConfig.groundFrictionEnabled, DEFAULTS.groundFrictionEnabled),
	groundFrictionLinearDecel = readNumber(rawConfig.groundFrictionLinearDecel, DEFAULTS.groundFrictionLinearDecel),
	groundFrictionDrag = readNumber(rawConfig.groundFrictionDrag, DEFAULTS.groundFrictionDrag),
	groundFrictionMinSpeed = readNumber(rawConfig.groundFrictionMinSpeed, DEFAULTS.groundFrictionMinSpeed),
	groundOppositeBrakeAccel = readNumber(rawConfig.groundOppositeBrakeAccel, DEFAULTS.groundOppositeBrakeAccel),
	landingCarryEnabled = readBoolean(rawConfig.landingCarryEnabled, DEFAULTS.landingCarryEnabled),
	landingCarryActivationWalkspeedMultiplier = readNumber(rawConfig.landingCarryActivationWalkspeedMultiplier, DEFAULTS.landingCarryActivationWalkspeedMultiplier),
	landingCarryActivationMinSpeed = readNumber(rawConfig.landingCarryActivationMinSpeed, DEFAULTS.landingCarryActivationMinSpeed),
	landingCarryRecentAirborneWindow = readNumber(rawConfig.landingCarryRecentAirborneWindow, DEFAULTS.landingCarryRecentAirborneWindow),
	landingCarryMinDuration = readNumber(rawConfig.landingCarryMinDuration, DEFAULTS.landingCarryMinDuration),
	landingCarryMaxDuration = readNumber(rawConfig.landingCarryMaxDuration, DEFAULTS.landingCarryMaxDuration),
	landingCarryDurationRefSpeed = readNumber(rawConfig.landingCarryDurationRefSpeed, DEFAULTS.landingCarryDurationRefSpeed),
	landingCarryLinearDecel = readNumber(rawConfig.landingCarryLinearDecel, DEFAULTS.landingCarryLinearDecel),
	landingCarryDrag = readNumber(rawConfig.landingCarryDrag, DEFAULTS.landingCarryDrag),
	landingCarryTurnResponse = readNumber(rawConfig.landingCarryTurnResponse, DEFAULTS.landingCarryTurnResponse),
	landingCarryOppositeBrakeAccel = readNumber(rawConfig.landingCarryOppositeBrakeAccel, DEFAULTS.landingCarryOppositeBrakeAccel),
	landingCarryExitSpeed = readNumber(rawConfig.landingCarryExitSpeed, DEFAULTS.landingCarryExitSpeed),
	landingCarryPreserveWithSameInput = readBoolean(rawConfig.landingCarryPreserveWithSameInput, DEFAULTS.landingCarryPreserveWithSameInput),
	landingCarryDebugAttributes = readBoolean(rawConfig.landingCarryDebugAttributes, DEFAULTS.landingCarryDebugAttributes),
	oppositeDotThreshold = readNumber(rawConfig.oppositeDotThreshold, DEFAULTS.oppositeDotThreshold),
	oppositeBrakeAccel = readNumber(rawConfig.oppositeBrakeAccel, DEFAULTS.oppositeBrakeAccel),
	turnResponse = readNumber(rawConfig.turnResponse, DEFAULTS.turnResponse),
	turnSpeedLossPerSecond = readNumber(rawConfig.turnSpeedLossPerSecond, DEFAULTS.turnSpeedLossPerSecond),
	bhopLinearDecel = readNumber(rawConfig.bhopLinearDecel, DEFAULTS.bhopLinearDecel),
	airDirectionalFightAccel = readNumber(rawConfig.airDirectionalFightAccel, DEFAULTS.airDirectionalFightAccel),
	airControlAccelToWalkSpeed = readNumber(rawConfig.airControlAccelToWalkSpeed, DEFAULTS.airControlAccelToWalkSpeed),
	airMisalignedBrakeAccel = readNumber(rawConfig.airMisalignedBrakeAccel, DEFAULTS.airMisalignedBrakeAccel),
	airMisalignedLossPerSecond = readNumber(rawConfig.airMisalignedLossPerSecond, DEFAULTS.airMisalignedLossPerSecond),
	noInputRetentionPerSecond = readNumber(rawConfig.noInputRetentionPerSecond, DEFAULTS.noInputRetentionPerSecond),
	adoptExternalBoost = readBoolean(rawConfig.adoptExternalBoost, DEFAULTS.adoptExternalBoost),
	externalBoostAdoptThreshold = readNumber(rawConfig.externalBoostAdoptThreshold, DEFAULTS.externalBoostAdoptThreshold),
	softCapMinStart = readNumber(rawConfig.softCapMinStart, DEFAULTS.softCapMinStart),
	softCapWalkspeedMultiplier = readNumber(rawConfig.softCapWalkspeedMultiplier, DEFAULTS.softCapWalkspeedMultiplier),
	softCapHardMultiplier = readNumber(rawConfig.softCapHardMultiplier, DEFAULTS.softCapHardMultiplier),
	softCapDrag = readNumber(rawConfig.softCapDrag, DEFAULTS.softCapDrag),
	minControllableSpeed = readNumber(rawConfig.minControllableSpeed, DEFAULTS.minControllableSpeed),
	debugAttributes = readBoolean(rawConfig.debugAttributes, DEFAULTS.debugAttributes),
}

local character: Model? = nil
local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil
local isPaused = false

local wasGrounded = true
local lastGroundedAt = 0
local lastAirborneAt = 0
local lastAirborneHorizontalVelocity = Vector3.zero
local airbornePeakHorizontalVelocity = Vector3.zero
local groundCarryVelocity = Vector3.zero
local groundCarryRecordedAt = 0
local overrideReleaseVelocity = Vector3.zero
local overrideReleasedAt = 0
local lastOverrideActive = false
local targetHorizontalVelocity = Vector3.zero
local hasTargetHorizontalVelocity = false

local landingCarryActive = false
local landingCarryVelocity = Vector3.zero
local landingCarryStartedAt = 0
local landingCarryDuration = 0
local landingCarryAttachment: Attachment? = nil
local landingCarryLinearVelocity: LinearVelocity? = nil
local landingCarryConsumedThisGroundContact = false
local landingAssistConsumedThisGroundContact = false

local function horizontal(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function setAirDebugAttributes(active: boolean, targetSpeed: number, actualSpeed: number)
	if not CONFIG.debugAttributes or not character then
		return
	end
	character:SetAttribute(ATTR_DEBUG_ACTIVE, active)
	character:SetAttribute(ATTR_DEBUG_TARGET_SPEED, targetSpeed)
	character:SetAttribute(ATTR_DEBUG_ACTUAL_SPEED, actualSpeed)
end

local function clearAirDebugAttributes()
	if not CONFIG.debugAttributes or not character then
		return
	end
	character:SetAttribute(ATTR_DEBUG_ACTIVE, false)
	character:SetAttribute(ATTR_DEBUG_TARGET_SPEED, 0)
	character:SetAttribute(ATTR_DEBUG_ACTUAL_SPEED, 0)
end

local function setGroundCarryDebugAttributes(active: boolean, speed: number)
	if not CONFIG.landingCarryDebugAttributes or not character then
		return
	end
	character:SetAttribute(ATTR_GROUND_CARRY_ACTIVE, active)
	character:SetAttribute(ATTR_GROUND_CARRY_SPEED, speed)
end

local function clearGroundCarryDebugAttributes()
	if not CONFIG.landingCarryDebugAttributes or not character then
		return
	end
	character:SetAttribute(ATTR_GROUND_CARRY_ACTIVE, false)
	character:SetAttribute(ATTR_GROUND_CARRY_SPEED, 0)
end

local function getUnitHorizontalInput(moveDirection: Vector3): Vector3?
	local flat = horizontal(moveDirection)
	local magnitude = flat.Magnitude
	if magnitude <= EPSILON then
		return nil
	end
	return flat / magnitude
end

local function chooseHigherMagnitude(current: Vector3, candidate: Vector3): Vector3
	if candidate.Magnitude > current.Magnitude then
		return candidate
	end
	return current
end

local function buildCarryCandidate(baseHorizontal: Vector3, nowTime: number, includeLastAirborne: boolean): Vector3
	local carryCandidate = baseHorizontal
	if includeLastAirborne then
		carryCandidate = chooseHigherMagnitude(carryCandidate, lastAirborneHorizontalVelocity)
	end
	if (nowTime - groundCarryRecordedAt) <= CONFIG.groundCarryWindowSeconds then
		carryCandidate = chooseHigherMagnitude(carryCandidate, groundCarryVelocity)
	end
	if (nowTime - overrideReleasedAt) <= CONFIG.overrideReleaseCarryWindowSeconds then
		carryCandidate = chooseHigherMagnitude(carryCandidate, overrideReleaseVelocity)
	end
	return carryCandidate
end

local function destroyLandingCarryConstraint()
	if landingCarryLinearVelocity and landingCarryLinearVelocity.Parent then
		landingCarryLinearVelocity:Destroy()
	end
	landingCarryLinearVelocity = nil

	if landingCarryAttachment and landingCarryAttachment.Parent then
		landingCarryAttachment:Destroy()
	end
	landingCarryAttachment = nil
end

local function stopLandingCarry()
	landingCarryActive = false
	landingCarryVelocity = Vector3.zero
	landingCarryStartedAt = 0
	landingCarryDuration = 0
	destroyLandingCarryConstraint()
	clearGroundCarryDebugAttributes()
end

local function startLandingCarry(initialHorizontalVelocity: Vector3): boolean
	if not rootPart or not rootPart.Parent then
		return false
	end

	local speed = initialHorizontalVelocity.Magnitude
	if speed <= EPSILON then
		return false
	end

	stopLandingCarry()

	landingCarryAttachment = Instance.new("Attachment")
	landingCarryAttachment.Name = "AirMomentumCarryAttachment"
	landingCarryAttachment.Position = Vector3.zero
	landingCarryAttachment.Parent = rootPart

	landingCarryLinearVelocity = Instance.new("LinearVelocity")
	landingCarryLinearVelocity.Name = "AirMomentumLandingCarry"
	landingCarryLinearVelocity.Attachment0 = landingCarryAttachment
	landingCarryLinearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	landingCarryLinearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	landingCarryLinearVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	landingCarryLinearVelocity.MaxAxesForce = Vector3.new(math.huge, 0, math.huge)
	landingCarryLinearVelocity.VectorVelocity = Vector3.new(initialHorizontalVelocity.X, 0, initialHorizontalVelocity.Z)
	landingCarryLinearVelocity.Parent = rootPart
	rootPart.AssemblyLinearVelocity = Vector3.new(
		initialHorizontalVelocity.X,
		rootPart.AssemblyLinearVelocity.Y,
		initialHorizontalVelocity.Z
	)

	landingCarryActive = true
	landingCarryConsumedThisGroundContact = true
	landingCarryVelocity = initialHorizontalVelocity
	landingCarryStartedAt = tick()
	local activationThreshold = math.max(
		CONFIG.landingCarryActivationMinSpeed,
		(if humanoid then humanoid.WalkSpeed else 0) * CONFIG.landingCarryActivationWalkspeedMultiplier
	)
	local minDuration = math.max(0, CONFIG.landingCarryMinDuration)
	local maxDuration = math.max(minDuration, CONFIG.landingCarryMaxDuration)
	local exitSpeed = math.max(0, CONFIG.landingCarryExitSpeed)
	local rawDuration = math.max(0, speed - exitSpeed) / math.max(1e-3, CONFIG.landingCarryLinearDecel)
	landingCarryDuration = math.clamp(rawDuration, minDuration, maxDuration)
	setGroundCarryDebugAttributes(true, speed)
	return true
end

local function updateLandingCarry(dt: number, currentHumanoid: Humanoid, overrideActive: boolean): boolean
	if not landingCarryActive then
		return false
	end

	if overrideActive then
		stopLandingCarry()
		return false
	end
	if not landingCarryLinearVelocity or not landingCarryLinearVelocity.Parent then
		stopLandingCarry()
		return false
	end

	local speed = landingCarryVelocity.Magnitude
	if speed <= CONFIG.landingCarryExitSpeed then
		stopLandingCarry()
		return false
	end

	local direction = landingCarryVelocity.Unit
	local inputDirection = getUnitHorizontalInput(currentHumanoid.MoveDirection)
	local baseWalkSpeed = math.max(0, currentHumanoid.WalkSpeed)
	if inputDirection then
		local dot = direction:Dot(inputDirection)
		local turnAlpha = 1 - math.exp(-CONFIG.landingCarryTurnResponse * dt)
		if dot <= CONFIG.oppositeDotThreshold then
			speed = math.max(0, speed - (CONFIG.landingCarryOppositeBrakeAccel * dt))
			local steered = direction:Lerp(inputDirection, math.clamp(turnAlpha * 0.8, 0, 1))
			if steered.Magnitude > EPSILON then
				direction = steered.Unit
			end
		else
			if CONFIG.landingCarryPreserveWithSameInput and dot > 0 then
				-- Same-direction input should still decelerate, but only down to base walk speed.
				if speed > (baseWalkSpeed + 0.25) then
					speed = math.max(baseWalkSpeed, speed - (CONFIG.landingCarryLinearDecel * dt))
				else
					stopLandingCarry()
					return false
				end
			else
				local speedDrop = CONFIG.landingCarryLinearDecel * dt
				if dot < 0 then
					-- Slightly opposing input should bleed faster than neutral.
					speedDrop *= 1.2
				end
				speed = math.max(0, speed - speedDrop)
			end
			local steered = direction:Lerp(inputDirection, math.clamp(turnAlpha, 0, 1))
			if steered.Magnitude > EPSILON then
				direction = steered.Unit
			end
		end
	else
		local speedDrop = CONFIG.landingCarryLinearDecel * dt
		speed = math.max(0, speed - speedDrop)
	end

	if speed <= CONFIG.landingCarryExitSpeed then
		stopLandingCarry()
		return false
	end

	landingCarryVelocity = direction * speed
	landingCarryLinearVelocity.VectorVelocity = Vector3.new(landingCarryVelocity.X, 0, landingCarryVelocity.Z)
	if rootPart and rootPart.Parent then
		local currentVelocity = rootPart.AssemblyLinearVelocity
		rootPart.AssemblyLinearVelocity = Vector3.new(landingCarryVelocity.X, currentVelocity.Y, landingCarryVelocity.Z)
	end
	setGroundCarryDebugAttributes(true, speed)
	return true
end

local function resetControllerState()
	wasGrounded = true
	lastGroundedAt = tick()
	lastAirborneAt = tick()
	lastAirborneHorizontalVelocity = Vector3.zero
	airbornePeakHorizontalVelocity = Vector3.zero
	groundCarryVelocity = Vector3.zero
	groundCarryRecordedAt = 0
	overrideReleaseVelocity = Vector3.zero
	overrideReleasedAt = 0
	lastOverrideActive = false
	targetHorizontalVelocity = Vector3.zero
	hasTargetHorizontalVelocity = false
	landingCarryConsumedThisGroundContact = false
	landingAssistConsumedThisGroundContact = false
	stopLandingCarry()
	clearAirDebugAttributes()
	clearGroundCarryDebugAttributes()
end

local function bindCharacter(newCharacter: Model?)
	character = newCharacter
	humanoid = nil
	rootPart = nil
	resetControllerState()

	if not newCharacter then
		return
	end

	humanoid = newCharacter:WaitForChild("Humanoid") :: Humanoid
	rootPart = newCharacter:WaitForChild("HumanoidRootPart") :: BasePart
	newCharacter:SetAttribute(ATTR_MOBILITY_VELOCITY_OVERRIDE, false)

	if CONFIG.debugAttributes then
		newCharacter:SetAttribute(ATTR_DEBUG_ACTIVE, false)
		newCharacter:SetAttribute(ATTR_DEBUG_TARGET_SPEED, 0)
		newCharacter:SetAttribute(ATTR_DEBUG_ACTUAL_SPEED, 0)
	end
	if CONFIG.landingCarryDebugAttributes then
		newCharacter:SetAttribute(ATTR_GROUND_CARRY_ACTIVE, false)
		newCharacter:SetAttribute(ATTR_GROUND_CARRY_SPEED, 0)
	end

	if humanoid then
		wasGrounded = humanoid.FloorMaterial ~= Enum.Material.Air
		lastGroundedAt = tick()
	end
	if rootPart then
		lastAirborneHorizontalVelocity = horizontal(rootPart.AssemblyLinearVelocity)
		airbornePeakHorizontalVelocity = lastAirborneHorizontalVelocity
	end
	lastOverrideActive = newCharacter:GetAttribute(ATTR_MOBILITY_VELOCITY_OVERRIDE) == true
end

local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local gamePaused = remotes:WaitForChild("GamePaused")
local gameUnpaused = remotes:WaitForChild("GameUnpaused")

gamePaused.OnClientEvent:Connect(function()
	isPaused = true
	stopLandingCarry()
	clearAirDebugAttributes()
end)

gameUnpaused.OnClientEvent:Connect(function()
	isPaused = false
end)

localPlayer.CharacterAdded:Connect(bindCharacter)
localPlayer.CharacterRemoving:Connect(function(removingCharacter: Model)
	if removingCharacter == character then
		bindCharacter(nil)
	end
end)

bindCharacter(localPlayer.Character)

local function applyAirMomentumStep(dt: number)
	if not CONFIG.enabled or CONFIG.mode ~= "target_state" or isPaused then
		return
	end

	local currentCharacter = character
	local currentHumanoid = humanoid
	local currentRootPart = rootPart
	if not currentCharacter or not currentCharacter.Parent then
		return
	end
	if not currentHumanoid or currentHumanoid.Health <= 0 then
		return
	end
	if not currentRootPart or not currentRootPart.Parent then
		return
	end

	local stepDt = if dt > 0 then dt else (1 / 60)
	local now = tick()
	local grounded = currentHumanoid.FloorMaterial ~= Enum.Material.Air
	local velocity = currentRootPart.AssemblyLinearVelocity
	local currentHorizontal = horizontal(velocity)
	local currentHorizontalSpeed = currentHorizontal.Magnitude
	local overrideActive = currentCharacter:GetAttribute(ATTR_MOBILITY_VELOCITY_OVERRIDE) == true

	if lastOverrideActive and (not overrideActive) and currentHorizontalSpeed > EPSILON then
		overrideReleaseVelocity = currentHorizontal
		overrideReleasedAt = now
		groundCarryVelocity = currentHorizontal
		groundCarryRecordedAt = now
	end
	lastOverrideActive = overrideActive

	if grounded then
		local justLanded = not wasGrounded
		if justLanded then
			lastGroundedAt = now
			landingCarryConsumedThisGroundContact = false
			landingAssistConsumedThisGroundContact = false
		end

		local landingAssistWindow = math.max(CONFIG.groundResetGraceSeconds, CONFIG.landingAssistSeconds)
		local withinLandingAssistWindow = (now - lastGroundedAt) <= landingAssistWindow
		local recentAirborne = (now - lastAirborneAt) <= CONFIG.landingCarryRecentAirborneWindow
		local jumpQueued = currentHumanoid.Jump

		-- Keep bhop/instant-jump continuity without introducing global ground slide.
		if withinLandingAssistWindow and not landingAssistConsumedThisGroundContact and (justLanded or jumpQueued) then
			local carryCandidate = buildCarryCandidate(currentHorizontal, now, true)
			if carryCandidate.Magnitude > (currentHorizontalSpeed + CONFIG.landingAssistSpeedThreshold) then
				local allowAssist = true
				local inputDirection = getUnitHorizontalInput(currentHumanoid.MoveDirection)
				if inputDirection then
					local candidateDirection = carryCandidate.Unit
					allowAssist = candidateDirection:Dot(inputDirection) > CONFIG.oppositeDotThreshold
				end
				if allowAssist then
					currentRootPart.AssemblyLinearVelocity = Vector3.new(carryCandidate.X, velocity.Y, carryCandidate.Z)
					currentHorizontal = carryCandidate
					currentHorizontalSpeed = carryCandidate.Magnitude
				end
			end
			-- Landing assist is single-fire per ground contact to avoid speed resetting
			-- every frame while jump is held (bhop input).
			landingAssistConsumedThisGroundContact = true
		end

		if (now - groundCarryRecordedAt) > CONFIG.groundCarryWindowSeconds then
			groundCarryVelocity = currentHorizontal
			groundCarryRecordedAt = now
		elseif currentHorizontalSpeed >= groundCarryVelocity.Magnitude then
			groundCarryVelocity = currentHorizontal
			groundCarryRecordedAt = now
		end

		local activationThreshold = math.max(
			CONFIG.landingCarryActivationMinSpeed,
			currentHumanoid.WalkSpeed * CONFIG.landingCarryActivationWalkspeedMultiplier
		)
		local boostedGroundThreshold = math.max(
			CONFIG.landingCarryExitSpeed + 0.5,
			currentHumanoid.WalkSpeed + 0.5
		)
		local recentOverrideRelease = (now - overrideReleasedAt) <= CONFIG.overrideReleaseCarryWindowSeconds
		if landingCarryConsumedThisGroundContact then
			-- Re-arm once player is back near normal movement speed.
			local rearmSpeed = math.max(CONFIG.landingCarryExitSpeed + 0.5, currentHumanoid.WalkSpeed + 0.5)
			if currentHorizontalSpeed <= rearmSpeed then
				landingCarryConsumedThisGroundContact = false
			end
		end

		local highSpeedGrounded = currentHorizontalSpeed >= (activationThreshold + 0.25)
		local canActivateLandingCarry = CONFIG.landingCarryEnabled
			and not overrideActive
			and not landingCarryActive
			and not landingCarryConsumedThisGroundContact
			and ((withinLandingAssistWindow or recentAirborne) or highSpeedGrounded or recentOverrideRelease)
		if canActivateLandingCarry then
			local carryCandidate = buildCarryCandidate(currentHorizontal, now, true)
			local overrideCarryEligible = recentOverrideRelease and carryCandidate.Magnitude >= boostedGroundThreshold
			if carryCandidate.Magnitude >= activationThreshold or overrideCarryEligible then
				startLandingCarry(carryCandidate)
			else
				stopLandingCarry()
			end
		elseif overrideActive then
			stopLandingCarry()
		end

		if landingCarryActive then
			local stillCarrying = updateLandingCarry(stepDt, currentHumanoid, overrideActive)
			if stillCarrying then
				local liveHorizontal = horizontal(currentRootPart.AssemblyLinearVelocity)
				currentHorizontal = liveHorizontal
				currentHorizontalSpeed = liveHorizontal.Magnitude
			end
		end

		wasGrounded = true
		if (now - lastAirborneAt) > CONFIG.groundResetGraceSeconds then
			lastAirborneHorizontalVelocity = Vector3.zero
			airbornePeakHorizontalVelocity = Vector3.zero
			targetHorizontalVelocity = Vector3.zero
			hasTargetHorizontalVelocity = false
		end

		setAirDebugAttributes(false, targetHorizontalVelocity.Magnitude, currentHorizontalSpeed)
		return
	end

	if landingCarryActive then
		stopLandingCarry()
	end

	if wasGrounded then
		local includeLastAirborne = (now - lastGroundedAt) <= CONFIG.groundResetGraceSeconds
		local carryCandidate = buildCarryCandidate(currentHorizontal, now, includeLastAirborne)

		targetHorizontalVelocity = carryCandidate
		hasTargetHorizontalVelocity = carryCandidate.Magnitude > EPSILON

		if carryCandidate.Magnitude > (currentHorizontalSpeed + 0.05) then
			currentRootPart.AssemblyLinearVelocity = Vector3.new(carryCandidate.X, velocity.Y, carryCandidate.Z)
			currentHorizontal = carryCandidate
			currentHorizontalSpeed = carryCandidate.Magnitude
		end
	end
	wasGrounded = false
	lastAirborneAt = now
	landingCarryConsumedThisGroundContact = false
	landingAssistConsumedThisGroundContact = false

	if currentHorizontalSpeed > EPSILON then
		lastAirborneHorizontalVelocity = currentHorizontal
		if currentHorizontalSpeed > airbornePeakHorizontalVelocity.Magnitude then
			airbornePeakHorizontalVelocity = currentHorizontal
		end
	end

	if CONFIG.adoptExternalBoost and currentHorizontalSpeed > (targetHorizontalVelocity.Magnitude + CONFIG.externalBoostAdoptThreshold) then
		targetHorizontalVelocity = currentHorizontal
		hasTargetHorizontalVelocity = true
	end

	if overrideActive then
		if currentHorizontalSpeed > targetHorizontalVelocity.Magnitude then
			targetHorizontalVelocity = currentHorizontal
			hasTargetHorizontalVelocity = true
		end
		setAirDebugAttributes(false, targetHorizontalVelocity.Magnitude, currentHorizontalSpeed)
		return
	end

	if not hasTargetHorizontalVelocity then
		if currentHorizontalSpeed <= EPSILON then
			setAirDebugAttributes(false, 0, currentHorizontalSpeed)
			return
		end
		targetHorizontalVelocity = currentHorizontal
		hasTargetHorizontalVelocity = true
	end

	local speed = targetHorizontalVelocity.Magnitude
	if speed <= CONFIG.minControllableSpeed then
		targetHorizontalVelocity = Vector3.zero
		hasTargetHorizontalVelocity = false
		setAirDebugAttributes(false, 0, currentHorizontalSpeed)
		return
	end

	local direction = targetHorizontalVelocity.Unit
	local inputDirection = getUnitHorizontalInput(currentHumanoid.MoveDirection)
	if inputDirection then
		local dot = direction:Dot(inputDirection)
		local turnAlpha = 1 - math.exp(-CONFIG.turnResponse * stepDt)
		if dot <= CONFIG.oppositeDotThreshold then
			speed = math.max(0, speed - (CONFIG.oppositeBrakeAccel * stepDt))
			local steered = direction:Lerp(inputDirection, math.clamp(turnAlpha * 0.7, 0, 1))
			if steered.Magnitude > EPSILON then
				direction = steered.Unit
			end
		else
			-- Directional-fight steering:
			-- only keep momentum component along current input direction,
			-- and actively bleed the rest so turning cannot fully preserve old speed.
			local momentum = direction * speed
			local forwardCarrySpeed = math.max(0, momentum:Dot(inputDirection))
			local desiredMomentum = inputDirection * forwardCarrySpeed
			local toDesired = desiredMomentum - momentum
			local maxChange = math.max(0, CONFIG.airDirectionalFightAccel) * stepDt
			local toDesiredMag = toDesired.Magnitude
			if toDesiredMag > EPSILON and maxChange > EPSILON then
				if toDesiredMag > maxChange then
					momentum += toDesired.Unit * maxChange
				else
					momentum = desiredMomentum
				end
			else
				momentum = desiredMomentum
			end

			-- Keep a small baseline decay.
			momentum *= math.max(0, 1 - (CONFIG.turnSpeedLossPerSecond * stepDt))

			-- Keep low-speed in-air control responsive without pumping high-speed momentum.
			local walkSpeed = math.max(0, currentHumanoid.WalkSpeed)
			local alongInputSpeed = momentum:Dot(inputDirection)
			if alongInputSpeed < walkSpeed then
				local accelStep = math.min(walkSpeed - alongInputSpeed, CONFIG.airControlAccelToWalkSpeed * stepDt)
				momentum += inputDirection * accelStep
			end

			local steered = direction:Lerp(inputDirection, math.clamp(turnAlpha, 0, 1))
			if steered.Magnitude > EPSILON and momentum.Magnitude > EPSILON then
				-- preserve directional responsiveness while using momentum vector for speed.
				local steeredDir = steered.Unit
				local blended = momentum:Lerp(steeredDir * momentum.Magnitude, math.clamp(turnAlpha * 0.35, 0, 1))
				if blended.Magnitude > EPSILON then
					momentum = blended
				end
			end

			speed = momentum.Magnitude
			if speed > EPSILON then
				direction = momentum.Unit
			end
		end
	else
		speed = speed * math.pow(CONFIG.noInputRetentionPerSecond, stepDt)
	end

	-- Bhop deceleration: never zero, and by default 5x less than ground carry friction.
	local bhopDecel = CONFIG.bhopLinearDecel
	if bhopDecel <= 0 then
		bhopDecel = math.max(0, CONFIG.landingCarryLinearDecel / 5)
	end
	speed = math.max(0, speed - (bhopDecel * stepDt))

	local capStart = math.max(CONFIG.softCapMinStart, currentHumanoid.WalkSpeed * CONFIG.softCapWalkspeedMultiplier)
	local capHard = capStart * CONFIG.softCapHardMultiplier
	if speed > capStart then
		local excess = speed - capStart
		excess = excess * math.exp(-CONFIG.softCapDrag * stepDt)
		speed = capStart + excess
	end
	speed = math.min(speed, capHard)

	if speed <= CONFIG.minControllableSpeed then
		targetHorizontalVelocity = Vector3.zero
		hasTargetHorizontalVelocity = false
		setAirDebugAttributes(false, 0, currentHorizontalSpeed)
		return
	end

	local nextHorizontal = direction * speed
	targetHorizontalVelocity = nextHorizontal
	hasTargetHorizontalVelocity = true
	lastAirborneHorizontalVelocity = nextHorizontal

	if (nextHorizontal - currentHorizontal).Magnitude > EPSILON then
		currentRootPart.AssemblyLinearVelocity = Vector3.new(nextHorizontal.X, velocity.Y, nextHorizontal.Z)
	end

	setAirDebugAttributes(true, speed, currentHorizontalSpeed)
end

local updateSignal = RunService.Heartbeat
if string.lower(CONFIG.writePhase) == "postsimulation" then
	local maybeSignal = (RunService :: any).PostSimulation
	if typeof(maybeSignal) == "RBXScriptSignal" then
		updateSignal = maybeSignal
	end
end

updateSignal:Connect(function(dt: number)
	applyAirMomentumStep(dt)
end)
