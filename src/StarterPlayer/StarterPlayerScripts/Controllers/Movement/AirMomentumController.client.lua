--!strict
-- AirMomentumController V2
-- Holds an airborne target horizontal velocity state so humanoid air slowdown
-- does not immediately drain carried momentum from jumps/mobility launches.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local MovementBalance = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MovementBalance"))

local ATTR_MOBILITY_VELOCITY_OVERRIDE = "MobilityVelocityOverrideLocal"
local ATTR_DEBUG_TARGET_SPEED = "AirMomentumTargetSpeedLocal"
local ATTR_DEBUG_ACTUAL_SPEED = "AirMomentumActualSpeedLocal"
local ATTR_DEBUG_ACTIVE = "AirMomentumActiveLocal"

local EPSILON = 1e-4

local DEFAULTS = {
	enabled = true,
	mode = "target_state",
	writePhase = "PostSimulation",
	groundResetGraceSeconds = 0.08,
	groundCarryWindowSeconds = 0.25,
	overrideReleaseCarryWindowSeconds = 0.35,
	landingAssistSeconds = 0.16,
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
	oppositeDotThreshold = readNumber(rawConfig.oppositeDotThreshold, DEFAULTS.oppositeDotThreshold),
	oppositeBrakeAccel = readNumber(rawConfig.oppositeBrakeAccel, DEFAULTS.oppositeBrakeAccel),
	turnResponse = readNumber(rawConfig.turnResponse, DEFAULTS.turnResponse),
	turnSpeedLossPerSecond = readNumber(rawConfig.turnSpeedLossPerSecond, DEFAULTS.turnSpeedLossPerSecond),
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
local lastAirborneHorizontalVelocity = Vector3.zero
local groundCarryVelocity = Vector3.zero
local groundCarryRecordedAt = 0
local overrideReleaseVelocity = Vector3.zero
local overrideReleasedAt = 0
local lastOverrideActive = false
local targetHorizontalVelocity = Vector3.zero
local hasTargetHorizontalVelocity = false

local function horizontal(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function setDebugAttributes(active: boolean, targetSpeed: number, actualSpeed: number)
	if not CONFIG.debugAttributes or not character then
		return
	end
	character:SetAttribute(ATTR_DEBUG_ACTIVE, active)
	character:SetAttribute(ATTR_DEBUG_TARGET_SPEED, targetSpeed)
	character:SetAttribute(ATTR_DEBUG_ACTUAL_SPEED, actualSpeed)
end

local function clearDebugAttributes()
	if not CONFIG.debugAttributes or not character then
		return
	end
	character:SetAttribute(ATTR_DEBUG_ACTIVE, false)
	character:SetAttribute(ATTR_DEBUG_TARGET_SPEED, 0)
	character:SetAttribute(ATTR_DEBUG_ACTUAL_SPEED, 0)
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

local function resetAirState()
	wasGrounded = true
	lastGroundedAt = tick()
	lastAirborneHorizontalVelocity = Vector3.zero
	groundCarryVelocity = Vector3.zero
	groundCarryRecordedAt = 0
	overrideReleaseVelocity = Vector3.zero
	overrideReleasedAt = 0
	lastOverrideActive = false
	targetHorizontalVelocity = Vector3.zero
	hasTargetHorizontalVelocity = false
	clearDebugAttributes()
end

local function bindCharacter(newCharacter: Model?)
	character = newCharacter
	humanoid = nil
	rootPart = nil
	resetAirState()

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

	if humanoid then
		wasGrounded = humanoid.FloorMaterial ~= Enum.Material.Air
		lastGroundedAt = tick()
	end
	if rootPart then
		lastAirborneHorizontalVelocity = horizontal(rootPart.AssemblyLinearVelocity)
	end
	lastOverrideActive = newCharacter:GetAttribute(ATTR_MOBILITY_VELOCITY_OVERRIDE) == true
end

local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local gamePaused = remotes:WaitForChild("GamePaused")
local gameUnpaused = remotes:WaitForChild("GameUnpaused")

gamePaused.OnClientEvent:Connect(function()
	isPaused = true
	clearDebugAttributes()
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
		if not wasGrounded then
			lastGroundedAt = now
		end
		local landingAssistWindow = math.max(CONFIG.groundResetGraceSeconds, CONFIG.landingAssistSeconds)
		local withinLandingAssistWindow = (now - lastGroundedAt) <= landingAssistWindow

		if withinLandingAssistWindow then
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
		end

		if (now - groundCarryRecordedAt) > CONFIG.groundCarryWindowSeconds then
			groundCarryVelocity = currentHorizontal
			groundCarryRecordedAt = now
		elseif currentHorizontalSpeed >= groundCarryVelocity.Magnitude then
			groundCarryVelocity = currentHorizontal
			groundCarryRecordedAt = now
		end

		wasGrounded = true
		if CONFIG.groundFrictionEnabled and not overrideActive then
			local inputDirection = getUnitHorizontalInput(currentHumanoid.MoveDirection)
			if inputDirection == nil then
				local coastSource = chooseHigherMagnitude(currentHorizontal, targetHorizontalVelocity)
				local coastSpeed = coastSource.Magnitude
				if coastSpeed > CONFIG.groundFrictionMinSpeed then
					local coastDirection = coastSource.Unit
					local speedDrop = (CONFIG.groundFrictionLinearDecel + coastSpeed * CONFIG.groundFrictionDrag) * stepDt
					local nextSpeed = math.max(0, coastSpeed - speedDrop)
					if nextSpeed > CONFIG.groundFrictionMinSpeed then
						local nextHorizontal = coastDirection * nextSpeed
						currentRootPart.AssemblyLinearVelocity = Vector3.new(nextHorizontal.X, velocity.Y, nextHorizontal.Z)
						currentHorizontal = nextHorizontal
						currentHorizontalSpeed = nextSpeed
						targetHorizontalVelocity = nextHorizontal
						hasTargetHorizontalVelocity = true
					else
						targetHorizontalVelocity = Vector3.zero
						hasTargetHorizontalVelocity = false
					end
				else
					targetHorizontalVelocity = Vector3.zero
					hasTargetHorizontalVelocity = false
				end
			else
				if currentHorizontalSpeed > CONFIG.groundFrictionMinSpeed then
					local currentDirection = if currentHorizontalSpeed > EPSILON then currentHorizontal.Unit else inputDirection
					local dot = currentDirection:Dot(inputDirection)
					if dot <= CONFIG.oppositeDotThreshold then
						local turnAlpha = 1 - math.exp(-CONFIG.turnResponse * stepDt)
						local steered = currentDirection:Lerp(inputDirection, math.clamp(turnAlpha * 0.8, 0, 1))
						if steered.Magnitude > EPSILON then
							currentDirection = steered.Unit
						end
						local nextSpeed = math.max(0, currentHorizontalSpeed - (CONFIG.groundOppositeBrakeAccel * stepDt))
						if nextSpeed > CONFIG.groundFrictionMinSpeed then
							local nextHorizontal = currentDirection * nextSpeed
							currentRootPart.AssemblyLinearVelocity = Vector3.new(nextHorizontal.X, velocity.Y, nextHorizontal.Z)
							currentHorizontal = nextHorizontal
							currentHorizontalSpeed = nextSpeed
							targetHorizontalVelocity = nextHorizontal
							hasTargetHorizontalVelocity = true
						else
							targetHorizontalVelocity = Vector3.zero
							hasTargetHorizontalVelocity = false
						end
					else
						targetHorizontalVelocity = currentHorizontal
						hasTargetHorizontalVelocity = currentHorizontalSpeed > CONFIG.groundFrictionMinSpeed
					end
				else
					targetHorizontalVelocity = Vector3.zero
					hasTargetHorizontalVelocity = false
				end
			end
		end

		if (now - lastGroundedAt) > CONFIG.groundResetGraceSeconds then
			lastAirborneHorizontalVelocity = Vector3.zero
			if not CONFIG.groundFrictionEnabled or currentHorizontalSpeed <= CONFIG.groundFrictionMinSpeed then
				targetHorizontalVelocity = Vector3.zero
				hasTargetHorizontalVelocity = false
			end
		end

		setDebugAttributes(false, targetHorizontalVelocity.Magnitude, currentHorizontalSpeed)
		return
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

	if currentHorizontalSpeed > EPSILON then
		lastAirborneHorizontalVelocity = currentHorizontal
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
		setDebugAttributes(false, targetHorizontalVelocity.Magnitude, currentHorizontalSpeed)
		return
	end

	if not hasTargetHorizontalVelocity then
		if currentHorizontalSpeed <= EPSILON then
			setDebugAttributes(false, 0, currentHorizontalSpeed)
			return
		end
		targetHorizontalVelocity = currentHorizontal
		hasTargetHorizontalVelocity = true
	end

	local speed = targetHorizontalVelocity.Magnitude
	if speed <= CONFIG.minControllableSpeed then
		targetHorizontalVelocity = Vector3.zero
		hasTargetHorizontalVelocity = false
		setDebugAttributes(false, 0, currentHorizontalSpeed)
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
			speed = speed * math.max(0, 1 - (CONFIG.turnSpeedLossPerSecond * stepDt))
			local steered = direction:Lerp(inputDirection, math.clamp(turnAlpha, 0, 1))
			if steered.Magnitude > EPSILON then
				direction = steered.Unit
			end
		end
	else
		speed = speed * math.pow(CONFIG.noInputRetentionPerSecond, stepDt)
	end

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
		setDebugAttributes(false, 0, currentHorizontalSpeed)
		return
	end

	local nextHorizontal = direction * speed
	targetHorizontalVelocity = nextHorizontal
	hasTargetHorizontalVelocity = true
	lastAirborneHorizontalVelocity = nextHorizontal

	if (nextHorizontal - currentHorizontal).Magnitude > EPSILON then
		currentRootPart.AssemblyLinearVelocity = Vector3.new(nextHorizontal.X, velocity.Y, nextHorizontal.Z)
	end

	setDebugAttributes(true, speed, currentHorizontalSpeed)
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
