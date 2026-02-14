--!strict
-- SprintController
-- LeftControl sprint with Toggle/Hold mode and W-only gating.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local sprintStateRemote = remotesFolder:WaitForChild("SprintState")
local playerGui = player:WaitForChild("PlayerGui")

local ATTR_TOGGLE_SPRINT_MODE = "Setting_controls_toggleSprintMode"
local SHIFTLOCK_ROOT_NAME = "ShiftLock"
local DEFAULT_CROSSHAIR_FRAME_NAME = "ShiftLockFrame"
local SPRINT_FRAME_NAME = "SprintFrame"

local toggleActive = false
local shiftHeld = false
local wHeld = false
local lastSentIntent = false
local shiftLockFrame: GuiObject? = nil
local sprintFrame: GuiObject? = nil
local transformLockConnections: {RBXScriptConnection} = {}
local shiftLockStateConnection: RBXScriptConnection? = nil
local shiftLockEnabled = false

local function isToggleMode(): boolean
	local value = player:GetAttribute(ATTR_TOGGLE_SPRINT_MODE)
	if typeof(value) == "boolean" then
		return value
	end
	return true
end

local function getSprintIntent(): boolean
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
	resetLocalSprintState()
end)

player.CharacterRemoving:Connect(function()
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
resetLocalSprintState()
