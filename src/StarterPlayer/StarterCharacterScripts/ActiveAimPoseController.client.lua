--!strict
-- ActiveAimPoseController - R6 composite overlay for pitch aim and cast-facing yaw lock.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local character = script.Parent

if not character:IsA("Model") then
	return
end

local ATTR_LOCAL_WEAPON_ACTIVE = "WeaponPrimaryActiveLocal"
local ATTR_LOCAL_M1_ACTIVE = "WeaponM1ActiveLocal"
local ATTR_LOCAL_M2_CAST_ACTIVE = "WeaponM2CastActiveLocal"
local ATTR_LOCAL_RANGED_AIM_ACTIVE = "AbilityRangedAimActiveLocal"
local ATTR_LOCAL_ABILITY_CAST_ACTIVE = "AbilityCastActiveLocal"
local ATTR_LOCAL_UTILITY_CAST_ACTIVE = "UtilityCastActiveLocal"
local ATTR_LOCAL_UTILITY_FACING_LOCK = "UtilityFacingLockActiveLocal"
local ATTR_LOCAL_MOUSE_AIM_DIRECTION = "WeaponMouseAimDirectionLocal"
local ATTR_LOCAL_MOUSE_AIM_EXPIRES_AT = "WeaponMouseAimExpiresAtLocal"

local ARM_PITCH_LIMIT_RAD = math.rad(55)
local HEAD_PITCH_LIMIT_RAD = math.rad(35)
local PITCH_BLEND_SHARPNESS = 16.0
local YAW_BLEND_SHARPNESS = 18.0
local PITCH_SIGN = 1
local MOTOR_RESOLVE_INTERVAL = 0.35
local AXIS_EPSILON = 1e-4
local WORLD_UP = Vector3.new(0, 1, 0)
local RENDER_STEP_NAME = ("ActiveAimPose_%d_%d"):format(localPlayer.UserId, math.floor(os.clock() * 1000))
local RENDER_STEP_PRIORITY = Enum.RenderPriority.Last.Value

type JointState = {
	motor: Motor6D?,
	currentPitch: number,
	currentYawLock: number,
	previousCompositeOverlayLocal: CFrame,
}

local rightShoulder: JointState = {
	motor = nil,
	currentPitch = 0,
	currentYawLock = 0,
	previousCompositeOverlayLocal = CFrame.identity,
}

local leftShoulder: JointState = {
	motor = nil,
	currentPitch = 0,
	currentYawLock = 0,
	previousCompositeOverlayLocal = CFrame.identity,
}

local neck: JointState = {
	motor = nil,
	currentPitch = 0,
	currentYawLock = 0,
	previousCompositeOverlayLocal = CFrame.identity,
}

local lastMotorResolveAt = 0
local pauseConnection: RBXScriptConnection? = nil
local unpauseConnection: RBXScriptConnection? = nil
local ancestryConnection: RBXScriptConnection? = nil

local function findMotorByName(part: Instance?, motorName: string): Motor6D?
	if not part then
		return nil
	end
	local motor = part:FindFirstChild(motorName)
	if motor and motor:IsA("Motor6D") then
		return motor
	end
	return nil
end

local function findMotorByPart1(part1Name: string): Motor6D?
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("Motor6D") then
			local part1 = descendant.Part1
			if part1 and part1.Name == part1Name then
				return descendant
			end
		end
	end
	return nil
end

local function getHumanoidRootPart(): BasePart?
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function removeCurrentOverlay(state: JointState)
	local motor = state.motor
	if motor and motor.Parent then
		motor.C0 = motor.C0 * state.previousCompositeOverlayLocal:Inverse()
	end
	state.previousCompositeOverlayLocal = CFrame.identity
	state.currentPitch = 0
	state.currentYawLock = 0
end

local function setJointMotor(state: JointState, newMotor: Motor6D?)
	if state.motor == newMotor then
		return
	end
	removeCurrentOverlay(state)
	state.motor = newMotor
end

local function resolveMotors(force: boolean?)
	local now = tick()
	if not force and (now - lastMotorResolveAt) < MOTOR_RESOLVE_INTERVAL then
		return
	end
	lastMotorResolveAt = now

	local torso = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
	local rightMotor = findMotorByName(torso, "Right Shoulder")
		or findMotorByName(torso, "RightShoulder")
		or findMotorByPart1("Right Arm")
	local leftMotor = findMotorByName(torso, "Left Shoulder")
		or findMotorByName(torso, "LeftShoulder")
		or findMotorByPart1("Left Arm")
	local neckMotor = findMotorByName(torso, "Neck") or findMotorByPart1("Head")

	setJointMotor(rightShoulder, rightMotor)
	setJointMotor(leftShoulder, leftMotor)
	setJointMotor(neck, neckMotor)
end

local function getCameraPitch(): number
	local camera = workspace.CurrentCamera
	if not camera then
		return 0
	end
	return math.asin(math.clamp(camera.CFrame.LookVector.Y, -1, 1))
end

local function blend(currentValue: number, targetValue: number, dt: number, sharpness: number): number
	local stepDt = if dt > 0 then dt else (1 / 60)
	local alpha = 1 - math.exp(-sharpness * stepDt)
	alpha = math.clamp(alpha, 0, 1)
	return currentValue + ((targetValue - currentValue) * alpha)
end

local function getFlatUnit(input: Vector3): Vector3?
	local flat = Vector3.new(input.X, 0, input.Z)
	local magnitude = flat.Magnitude
	if magnitude <= AXIS_EPSILON then
		return nil
	end
	return flat / magnitude
end

local function signedAngleAroundAxis(fromDir: Vector3, toDir: Vector3, axis: Vector3): number
	local safeAxis = if axis.Magnitude > AXIS_EPSILON then axis.Unit else WORLD_UP
	local cross = fromDir:Cross(toDir)
	local sinTheta = safeAxis:Dot(cross)
	local cosTheta = math.clamp(fromDir:Dot(toDir), -1, 1)
	return math.atan2(sinTheta, cosTheta)
end

local function resolvePitchTargets(): (number, number, number)
	if character:GetAttribute(ATTR_LOCAL_UTILITY_FACING_LOCK) == true then
		return 0, 0, 0
	end

	local basePitch = getCameraPitch() * PITCH_SIGN
	local armPitch = math.clamp(basePitch, -ARM_PITCH_LIMIT_RAD, ARM_PITCH_LIMIT_RAD)
	local headPitch = math.clamp(basePitch, -HEAD_PITCH_LIMIT_RAD, HEAD_PITCH_LIMIT_RAD)

	if character:GetAttribute(ATTR_LOCAL_RANGED_AIM_ACTIVE) == true then
		return 0, armPitch, headPitch
	end

	local weaponActive = (character:GetAttribute(ATTR_LOCAL_WEAPON_ACTIVE) == true)
		or (character:GetAttribute(ATTR_LOCAL_M1_ACTIVE) == true)
		or (character:GetAttribute(ATTR_LOCAL_M2_CAST_ACTIVE) == true)
	if weaponActive then
		local mouseBehavior = UserInputService.MouseBehavior
		local isMouseLocked = mouseBehavior == Enum.MouseBehavior.LockCenter
			or mouseBehavior == Enum.MouseBehavior.LockCurrentPosition
		if isMouseLocked then
			return armPitch, 0, headPitch
		end

		local expiresAtRaw = character:GetAttribute(ATTR_LOCAL_MOUSE_AIM_EXPIRES_AT)
		local mouseAimDirectionRaw = character:GetAttribute(ATTR_LOCAL_MOUSE_AIM_DIRECTION)
		if typeof(expiresAtRaw) == "number"
			and expiresAtRaw > tick()
			and typeof(mouseAimDirectionRaw) == "Vector3"
			and mouseAimDirectionRaw.Magnitude > AXIS_EPSILON
		then
			local mousePitch = math.asin(math.clamp(mouseAimDirectionRaw.Unit.Y, -1, 1)) * PITCH_SIGN
			local mouseArmPitch = math.clamp(mousePitch, -ARM_PITCH_LIMIT_RAD, ARM_PITCH_LIMIT_RAD)
			local mouseHeadPitch = math.clamp(mousePitch, -HEAD_PITCH_LIMIT_RAD, HEAD_PITCH_LIMIT_RAD)
			return mouseArmPitch, 0, mouseHeadPitch
		end

		-- Un-shiftlocked default: no vertical turning unless a valid mouse-shot aim window is active.
		return 0, 0, 0
	end

	return 0, 0, 0
end

local function resolveLeftYawLockTarget(): number
	if character:GetAttribute(ATTR_LOCAL_UTILITY_FACING_LOCK) == true then
		return 0
	end

	local castActive = (character:GetAttribute(ATTR_LOCAL_ABILITY_CAST_ACTIVE) == true)
		or (character:GetAttribute(ATTR_LOCAL_UTILITY_CAST_ACTIVE) == true)
	if not castActive then
		return 0
	end

	local rootPart = getHumanoidRootPart()
	if not rootPart then
		return 0
	end

	local part0: BasePart? = nil
	if leftShoulder.motor and leftShoulder.motor.Part0 then
		part0 = leftShoulder.motor.Part0
	else
		local torso = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
		if torso and torso:IsA("BasePart") then
			part0 = torso
		end
	end
	if not part0 then
		return 0
	end

	local rootLookFlat = getFlatUnit(rootPart.CFrame.LookVector)
	local torsoLookFlat = getFlatUnit(part0.CFrame.LookVector)
	if not rootLookFlat or not torsoLookFlat then
		return 0
	end

	return signedAngleAroundAxis(torsoLookFlat, rootLookFlat, rootPart.CFrame.UpVector)
end

local function buildOverlay(
	jointWorld: CFrame,
	axisWorld: Vector3,
	angleRadians: number,
	fallbackAxisLocal: Vector3
): CFrame
	if math.abs(angleRadians) <= AXIS_EPSILON then
		return CFrame.identity
	end
	local axisLocal = jointWorld:VectorToObjectSpace(axisWorld)
	if axisLocal.Magnitude <= AXIS_EPSILON then
		axisLocal = fallbackAxisLocal
	else
		axisLocal = axisLocal.Unit
	end
	return CFrame.fromAxisAngle(axisLocal, angleRadians)
end

local function applyCompositeOverlay(state: JointState, includeYaw: boolean)
	local motor = state.motor
	if not motor or not motor.Parent then
		state.previousCompositeOverlayLocal = CFrame.identity
		state.currentPitch = 0
		state.currentYawLock = 0
		return
	end

	local part0 = motor.Part0
	if not part0 then
		state.previousCompositeOverlayLocal = CFrame.identity
		state.currentPitch = 0
		state.currentYawLock = 0
		return
	end

	local animatedBaseC0 = motor.C0 * state.previousCompositeOverlayLocal:Inverse()
	local jointWorld = part0.CFrame * animatedBaseC0
	local rootPart = getHumanoidRootPart()

	local pitchAxisWorld = if rootPart then rootPart.CFrame.RightVector else part0.CFrame.RightVector
	if pitchAxisWorld.Magnitude <= AXIS_EPSILON then
		pitchAxisWorld = Vector3.new(1, 0, 0)
	else
		pitchAxisWorld = pitchAxisWorld.Unit
	end

	local upAxisWorld = if rootPart then rootPart.CFrame.UpVector else WORLD_UP
	if upAxisWorld.Magnitude <= AXIS_EPSILON then
		upAxisWorld = WORLD_UP
	else
		upAxisWorld = upAxisWorld.Unit
	end

	local pitchOverlay = buildOverlay(jointWorld, pitchAxisWorld, state.currentPitch, Vector3.new(1, 0, 0))
	local yawOverlay = if includeYaw
		then buildOverlay(jointWorld, upAxisWorld, state.currentYawLock, Vector3.new(0, 1, 0))
		else CFrame.identity

	local composite = if includeYaw then (pitchOverlay * yawOverlay) else pitchOverlay
	motor.C0 = animatedBaseC0 * composite
	state.previousCompositeOverlayLocal = composite
end

local function resetAllOverlays()
	removeCurrentOverlay(rightShoulder)
	removeCurrentOverlay(leftShoulder)
	removeCurrentOverlay(neck)
end

local function updatePose(dt: number)
	resolveMotors(false)

	local rightTarget, leftTarget, headTarget = resolvePitchTargets()
	local leftYawTarget = resolveLeftYawLockTarget()

	rightShoulder.currentPitch = blend(rightShoulder.currentPitch, rightTarget, dt, PITCH_BLEND_SHARPNESS)
	leftShoulder.currentPitch = blend(leftShoulder.currentPitch, leftTarget, dt, PITCH_BLEND_SHARPNESS)
	neck.currentPitch = blend(neck.currentPitch, headTarget, dt, PITCH_BLEND_SHARPNESS)

	rightShoulder.currentYawLock = blend(rightShoulder.currentYawLock, 0, dt, YAW_BLEND_SHARPNESS)
	leftShoulder.currentYawLock = blend(leftShoulder.currentYawLock, leftYawTarget, dt, YAW_BLEND_SHARPNESS)
	neck.currentYawLock = blend(neck.currentYawLock, 0, dt, YAW_BLEND_SHARPNESS)

	applyCompositeOverlay(rightShoulder, false)
	applyCompositeOverlay(leftShoulder, true)
	applyCompositeOverlay(neck, false)
end

local function cleanup()
	pcall(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)
	if pauseConnection then
		pauseConnection:Disconnect()
		pauseConnection = nil
	end
	if unpauseConnection then
		unpauseConnection:Disconnect()
		unpauseConnection = nil
	end
	if ancestryConnection then
		ancestryConnection:Disconnect()
		ancestryConnection = nil
	end

	resetAllOverlays()
	rightShoulder.motor = nil
	leftShoulder.motor = nil
	neck.motor = nil
	character:SetAttribute(ATTR_LOCAL_RANGED_AIM_ACTIVE, false)
	character:SetAttribute(ATTR_LOCAL_ABILITY_CAST_ACTIVE, false)
	character:SetAttribute(ATTR_LOCAL_UTILITY_CAST_ACTIVE, false)
end

resolveMotors(true)
character:SetAttribute(ATTR_LOCAL_RANGED_AIM_ACTIVE, false)
character:SetAttribute(ATTR_LOCAL_ABILITY_CAST_ACTIVE, false)
character:SetAttribute(ATTR_LOCAL_UTILITY_CAST_ACTIVE, false)

local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local gamePaused = remotes:WaitForChild("GamePaused")
local gameUnpaused = remotes:WaitForChild("GameUnpaused")

pauseConnection = gamePaused.OnClientEvent:Connect(function()
	resetAllOverlays()
end)

unpauseConnection = gameUnpaused.OnClientEvent:Connect(function()
end)

pcall(function()
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
end)
RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_STEP_PRIORITY, function(dt: number)
	updatePose(dt)
end)

ancestryConnection = character.AncestryChanged:Connect(function(_, parent)
	if parent == nil then
		cleanup()
	end
end)
