--!strict
-- SprintController
-- LeftControl sprint with Toggle/Hold mode and W-only gating.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local sprintStateRemote = remotesFolder:WaitForChild("SprintState")
local playerGui = player:WaitForChild("PlayerGui")

local ATTR_TOGGLE_SPRINT_MODE = "Setting_controls_toggleSprintMode"
local SHIFTLOCK_ROOT_NAME = "ShiftLock"
local DEFAULT_CROSSHAIR_FRAME_NAME = "ShiftLockFrame"
local SPRINT_FRAME_NAME = "SprintFrame"
local SPRINT_RUN_ANIMATION_ID = "rbxassetid://113934996865672"
local RUN_ANIMATION_BASE_WALKSPEED = 24
local SPRINT_MULTIPLIER = 1.45
local MOVEMENT_SPEED_BONUS_TO_HIT_CAP = 0.75
local RUN_ANIMATION_SPEED_MIN = 0.75
local RUN_ANIMATION_SPEED_MAX = 1.75

local toggleActive = false
local shiftHeld = false
local wHeld = false
local lastSentIntent = false
local shiftLockFrame: GuiObject? = nil
local sprintFrame: GuiObject? = nil
local transformLockConnections: {RBXScriptConnection} = {}
local shiftLockStateConnection: RBXScriptConnection? = nil
local shiftLockEnabled = false
local runAnimation: Animation? = nil
local runTrack: AnimationTrack? = nil
local character: Model? = nil
local humanoid: Humanoid? = nil
local animator: Animator? = nil
local runAnimationConnection: RBXScriptConnection? = nil
local getSprintIntent: () -> boolean = function(): boolean
	return false
end

local function disconnectRunAnimationConnection()
	if runAnimationConnection then
		runAnimationConnection:Disconnect()
		runAnimationConnection = nil
	end
end

local function stopRunTrack()
	if runTrack then
		runTrack:Stop(0.08)
	end
end

local function clearRunTrack()
	stopRunTrack()
	runTrack = nil
end

local function ensureRunTrack()
	if runTrack then
		return runTrack
	end
	if not animator then
		return nil
	end
	if not runAnimation then
		local animation = Instance.new("Animation")
		animation.Name = "SprintOverride"
		animation.AnimationId = SPRINT_RUN_ANIMATION_ID
		runAnimation = animation
	end
	local track = animator:LoadAnimation(runAnimation)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	runTrack = track
	return runTrack
end

local function shouldPlayRunAnimation(): boolean
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	local intent = getSprintIntent()
	if not intent then
		return false
	end
	if humanoid.MoveDirection.Magnitude <= 0.05 then
		return false
	end
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.FallingDown
		or state == Enum.HumanoidStateType.Dead then
		return false
	end
	return true
end

local function getRunAnimationSpeed(): number
	if not humanoid then
		return 1
	end
	local baseWalkSpeed = player:GetAttribute("BaseWalkSpeed")
	if typeof(baseWalkSpeed) ~= "number" or baseWalkSpeed <= 0 then
		baseWalkSpeed = RUN_ANIMATION_BASE_WALKSPEED
	end
	local baseSprintSpeed = baseWalkSpeed * SPRINT_MULTIPLIER
	if baseSprintSpeed <= 0 then
		baseSprintSpeed = RUN_ANIMATION_BASE_WALKSPEED * SPRINT_MULTIPLIER
	end
	local sprintSpeedRatio = humanoid.WalkSpeed / baseSprintSpeed
	if sprintSpeedRatio <= 1 then
		return math.clamp(sprintSpeedRatio, RUN_ANIMATION_SPEED_MIN, RUN_ANIMATION_SPEED_MAX)
	end

	-- Reach max animation speed at +75% movement speed over sprint baseline.
	local bonusRatio = sprintSpeedRatio - 1
	local t = math.clamp(bonusRatio / MOVEMENT_SPEED_BONUS_TO_HIT_CAP, 0, 1)
	local scaledSpeed = 1 + ((RUN_ANIMATION_SPEED_MAX - 1) * t)
	return math.clamp(scaledSpeed, RUN_ANIMATION_SPEED_MIN, RUN_ANIMATION_SPEED_MAX)
end

local function updateRunAnimation()
	local track = ensureRunTrack()
	if not track then
		return
	end

	if shouldPlayRunAnimation() then
		if not track.IsPlaying then
			track:Play(0.08, 1, getRunAnimationSpeed())
		end
		track:AdjustSpeed(getRunAnimationSpeed())
	else
		stopRunTrack()
	end
end

local function bindCharacter(newCharacter: Model?)
	character = newCharacter
	humanoid = nil
	animator = nil
	clearRunTrack()
	disconnectRunAnimationConnection()

	if not newCharacter then
		return
	end

	local foundHumanoid = newCharacter:FindFirstChildOfClass("Humanoid")
	if not foundHumanoid then
		local waitedHumanoid = newCharacter:WaitForChild("Humanoid", 5)
		if waitedHumanoid and waitedHumanoid:IsA("Humanoid") then
			foundHumanoid = waitedHumanoid
		else
			return
		end
	end
	humanoid = foundHumanoid
	animator = foundHumanoid:FindFirstChildOfClass("Animator")
	if not animator then
		local waitedAnimator = foundHumanoid:WaitForChild("Animator", 5)
		if waitedAnimator and waitedAnimator:IsA("Animator") then
			animator = waitedAnimator
		else
			return
		end
	end

	updateRunAnimation()
	runAnimationConnection = RunService.RenderStepped:Connect(function()
		updateRunAnimation()
	end)
end

local function isToggleMode(): boolean
	local value = player:GetAttribute(ATTR_TOGGLE_SPRINT_MODE)
	if typeof(value) == "boolean" then
		return value
	end
	return true
end

getSprintIntent = function(): boolean
	if isToggleMode() then
		return toggleActive and wHeld
	end
	return shiftHeld and wHeld
end

local function clearTransformLocks()
	for _, connection in ipairs(transformLockConnections) do
		connection:Disconnect()
	end
	table.clear(transformLockConnections)
end

local function clearShiftLockStateConnection()
	if shiftLockStateConnection then
		shiftLockStateConnection:Disconnect()
		shiftLockStateConnection = nil
	end
end

local function readShiftLockEnabled(frame: GuiObject?): boolean
	if not frame then
		return false
	end
	local value = frame:GetAttribute("ShiftLockEnabled")
	return typeof(value) == "boolean" and value or false
end

local function lockGuiTransform(frame: GuiObject)
	local lockedPosition = frame.Position
	local lockedSize = frame.Size
	local lockedAnchor = frame.AnchorPoint
	local lockedRotation = frame.Rotation

	table.insert(transformLockConnections, frame:GetPropertyChangedSignal("Position"):Connect(function()
		if frame.Position ~= lockedPosition then
			frame.Position = lockedPosition
		end
	end))

	table.insert(transformLockConnections, frame:GetPropertyChangedSignal("Size"):Connect(function()
		if frame.Size ~= lockedSize then
			frame.Size = lockedSize
		end
	end))

	table.insert(transformLockConnections, frame:GetPropertyChangedSignal("AnchorPoint"):Connect(function()
		if frame.AnchorPoint ~= lockedAnchor then
			frame.AnchorPoint = lockedAnchor
		end
	end))

	table.insert(transformLockConnections, frame:GetPropertyChangedSignal("Rotation"):Connect(function()
		if frame.Rotation ~= lockedRotation then
			frame.Rotation = lockedRotation
		end
	end))
end

local function applySprintUi(intent: boolean)
	if not shiftLockFrame or not sprintFrame then
		return
	end

	local crosshair = shiftLockFrame
	local sprint = sprintFrame
	local showSprint = shiftLockEnabled and intent
	local showCrosshair = shiftLockEnabled and not intent

	crosshair.Visible = showCrosshair
	sprint.Visible = showSprint
end

local function resolveSprintUi()
	local root = playerGui:FindFirstChild(SHIFTLOCK_ROOT_NAME)
	if not root then
		clearTransformLocks()
		clearShiftLockStateConnection()
		shiftLockEnabled = false
		shiftLockFrame = nil
		sprintFrame = nil
		return
	end

	if root:IsA("ScreenGui") then
		pcall(function()
			root.IgnoreGuiInset = true
		end)
		pcall(function()
			root.ScreenInsets = Enum.ScreenInsets.None
		end)
		pcall(function()
			root.SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
		end)
	end

	local foundCrosshair = root:FindFirstChild(DEFAULT_CROSSHAIR_FRAME_NAME, true)
	local newShiftLockFrame = if foundCrosshair and foundCrosshair:IsA("GuiObject") then foundCrosshair else nil

	local foundSprint = root:FindFirstChild(SPRINT_FRAME_NAME, true)
	local newSprintFrame = if foundSprint and foundSprint:IsA("GuiObject") then foundSprint else nil

	local changedFrameRefs = (shiftLockFrame ~= newShiftLockFrame) or (sprintFrame ~= newSprintFrame)
	shiftLockFrame = newShiftLockFrame
	sprintFrame = newSprintFrame

	if changedFrameRefs then
		clearTransformLocks()
		clearShiftLockStateConnection()
		if shiftLockFrame then
			lockGuiTransform(shiftLockFrame)
			shiftLockEnabled = readShiftLockEnabled(shiftLockFrame)
			shiftLockStateConnection = shiftLockFrame:GetAttributeChangedSignal("ShiftLockEnabled"):Connect(function()
				shiftLockEnabled = readShiftLockEnabled(shiftLockFrame)
				applySprintUi(getSprintIntent())
			end)
		else
			shiftLockEnabled = false
		end
		if sprintFrame then
			lockGuiTransform(sprintFrame)
		end
	end
end

local function pushSprintIntent()
	local intent = getSprintIntent()
	if not shiftLockFrame or not sprintFrame then
		resolveSprintUi()
	end
	applySprintUi(intent)
	updateRunAnimation()
	if intent == lastSentIntent then
		return
	end
	lastSentIntent = intent
	if sprintStateRemote and sprintStateRemote:IsA("RemoteEvent") then
		sprintStateRemote:FireServer(intent)
	end
end

local function resetLocalSprintState()
	toggleActive = false
	shiftHeld = false
	wHeld = false
	pushSprintIntent()
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if UserInputService:GetFocusedTextBox() then
		return
	end

	if input.KeyCode == Enum.KeyCode.W then
		wHeld = true
		pushSprintIntent()
		return
	end

	if input.KeyCode == Enum.KeyCode.LeftControl then
		shiftHeld = true
		if isToggleMode() then
			toggleActive = not toggleActive
		end
		pushSprintIntent()
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
	if input.KeyCode == Enum.KeyCode.W then
		wHeld = false
		if isToggleMode() then
			-- Releasing W fully ends toggle sprint; player must toggle again.
			toggleActive = false
		else
			-- Releasing W in hold mode requires re-pressing sprint key.
			shiftHeld = false
		end
		pushSprintIntent()
		return
	end

	if input.KeyCode == Enum.KeyCode.LeftControl then
		shiftHeld = false
		pushSprintIntent()
	end
end)

player:GetAttributeChangedSignal(ATTR_TOGGLE_SPRINT_MODE):Connect(function()
	if not isToggleMode() then
		-- Moving from Toggle -> Hold should not keep old toggle state latched.
		toggleActive = false
	end
	pushSprintIntent()
end)

player.CharacterAdded:Connect(function()
	bindCharacter(player.Character)
	resetLocalSprintState()
end)

player.CharacterRemoving:Connect(function()
	bindCharacter(nil)
	resetLocalSprintState()
end)

playerGui.DescendantAdded:Connect(function(descendant: Instance)
	if not descendant:IsA("GuiObject") then
		return
	end
	if descendant.Name ~= DEFAULT_CROSSHAIR_FRAME_NAME and descendant.Name ~= SPRINT_FRAME_NAME then
		return
	end
	resolveSprintUi()
	applySprintUi(getSprintIntent())
end)

resolveSprintUi()
bindCharacter(player.Character)
resetLocalSprintState()
