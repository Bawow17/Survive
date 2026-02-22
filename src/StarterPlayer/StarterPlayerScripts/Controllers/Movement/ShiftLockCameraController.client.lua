--!strict
-- ShiftLockCameraController
-- Centers shift-lock horizontally and raises camera pivot slightly.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")

local localPlayer = Players.LocalPlayer

-- Keep shift-lock horizontally centered; raise camera pivot slightly.
local SHIFT_LOCK_CAMERA_OFFSET = Vector3.new(0, 3.2, 0)
local ZERO_CAMERA_OFFSET = Vector3.new(0, 0, 0)
local FIRST_PERSON_DISTANCE_THRESHOLD = 1.0
local CAMERA_OFFSET_SMOOTH_SPEED = 14.0
local SHIFT_LOCK_ACTION = "CustomShiftLockToggle"
local SHIFT_LOCK_ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 100
local ATTR_SETTINGS_OPEN = "UI_SettingsOpen"
local ATTR_WEAPON_ACTIVE_LOCAL = "WeaponPrimaryActiveLocal"
local ATTR_LOCAL_UTILITY_FACING_LOCK = "UtilityFacingLockActiveLocal"
local FACING_LOCK_RENDERSTEP = "ShiftLockActiveFacingLock"
local TOGGLE_BUTTON_NAME_HINTS: {[string]: boolean} = {
	ShiftLockButton = true,
	ShiftLockToggle = true,
	Toggle = true,
	Button = true,
}

local currentHumanoid: Humanoid? = nil
local shiftLockEnabled = false
local shiftLockFrame: GuiObject? = nil
local shiftLockFrameButtonConnections: {RBXScriptConnection} = {}
local settingsOpen = false
local restoreShiftLockAfterSettings = false
local mainMenuOpen = false
local restoreShiftLockAfterMainMenu = false
local mainMenuFrame: GuiObject? = nil
local mainMenuFrameConnection: RBXScriptConnection? = nil

local function isMouseLocked(): boolean
	local behavior = UserInputService.MouseBehavior
	return behavior == Enum.MouseBehavior.LockCenter
		or behavior == Enum.MouseBehavior.LockCurrentPosition
end

local function applyNamedStateVisuals(frame: GuiObject, enabled: boolean)
	local function setIfGuiObject(name: string, visible: boolean)
		local obj = frame:FindFirstChild(name, true)
		if obj and obj:IsA("GuiObject") then
			obj.Visible = visible
		end
	end

	local function setByNamePattern(pattern: string, visible: boolean)
		local needle = string.lower(pattern)
		for _, descendant in ipairs(frame:GetDescendants()) do
			if descendant:IsA("GuiObject") then
				local lowerName = string.lower(descendant.Name)
				if string.find(lowerName, needle, 1, true) then
					descendant.Visible = visible
				end
			end
		end
	end

	setIfGuiObject("On", enabled)
	setIfGuiObject("Off", not enabled)
	setIfGuiObject("Enabled", enabled)
	setIfGuiObject("Disabled", not enabled)
	setIfGuiObject("Active", enabled)
	setIfGuiObject("Inactive", not enabled)
	setIfGuiObject("Crosshair", enabled)
	setIfGuiObject("Reticle", enabled)
	setIfGuiObject("CenterDot", enabled)
	setIfGuiObject("Cursor", not enabled)
	setIfGuiObject("Mouse", not enabled)
	setByNamePattern("crosshair", enabled)
	setByNamePattern("reticle", enabled)
	setByNamePattern("cursor", not enabled)
	setByNamePattern("mouse", not enabled)
end

local function clearShiftLockFrameConnections()
	for _, connection in ipairs(shiftLockFrameButtonConnections) do
		connection:Disconnect()
	end
	table.clear(shiftLockFrameButtonConnections)
end

local function setShiftLockIndicatorState(enabled: boolean)
	local frame = shiftLockFrame
	if not frame then
		return
	end
	frame.Visible = enabled
	frame:SetAttribute("ShiftLockEnabled", enabled)
	applyNamedStateVisuals(frame, enabled)
end

local function setShiftLockState(enabled: boolean)
	shiftLockEnabled = enabled
	UserInputService.MouseBehavior = enabled and Enum.MouseBehavior.LockCenter or Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = not enabled
	setShiftLockIndicatorState(enabled)
end

local function toggleShiftLock()
	if settingsOpen or mainMenuOpen then
		return
	end
	setShiftLockState(not shiftLockEnabled)
end

local function syncSettingsLockout()
	if settingsOpen then
		restoreShiftLockAfterSettings = shiftLockEnabled
		-- Force temporary unlocked interaction for menus.
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		setShiftLockIndicatorState(false)
		return
	end

	if restoreShiftLockAfterSettings then
		restoreShiftLockAfterSettings = false
		setShiftLockState(true)
		return
	end

	setShiftLockIndicatorState(shiftLockEnabled)
end

local function syncMainMenuLockout()
	if mainMenuOpen then
		restoreShiftLockAfterMainMenu = restoreShiftLockAfterMainMenu or shiftLockEnabled
		if shiftLockEnabled then
			setShiftLockState(false)
		else
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
			setShiftLockIndicatorState(false)
		end
		return
	end

	if restoreShiftLockAfterMainMenu then
		restoreShiftLockAfterMainMenu = false
		if not settingsOpen then
			setShiftLockState(true)
			return
		end
	end

	if settingsOpen then
		-- Settings lockout decides UI while settings are open.
		return
	end
	setShiftLockIndicatorState(shiftLockEnabled)
end

local function onShiftLockAction(_: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		if settingsOpen or mainMenuOpen then
			return Enum.ContextActionResult.Sink
		end
		if UserInputService:GetFocusedTextBox() then
			return Enum.ContextActionResult.Sink
		end
		toggleShiftLock()
		return Enum.ContextActionResult.Sink
	end
	if inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		-- Sink key-up/cancel too so LeftAlt does not leak into default window/menu behavior.
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Sink
end

local function bindMainMenuFrame(frame: GuiObject)
	if mainMenuFrameConnection then
		mainMenuFrameConnection:Disconnect()
		mainMenuFrameConnection = nil
	end

	mainMenuFrame = frame
	local function refreshMainMenuState()
		local wasOpen = mainMenuOpen
		mainMenuOpen = frame.Visible
		-- Default behavior: entering gameplay from main menu enables shift-lock.
		if wasOpen and not mainMenuOpen then
			restoreShiftLockAfterMainMenu = true
		end
		syncMainMenuLockout()
	end

	mainMenuFrameConnection = frame:GetPropertyChangedSignal("Visible"):Connect(refreshMainMenuState)
	refreshMainMenuState()
end

local function tryBindMainMenuFrame()
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end

	local mainMenuGui = playerGui:FindFirstChild("MainMenuGui")
	local frame: GuiObject? = nil
	if mainMenuGui then
		local found = mainMenuGui:FindFirstChild("MainMenuFrame", true)
		if found and found:IsA("GuiObject") then
			frame = found
		end
	end
	if not frame then
		local found = playerGui:FindFirstChild("MainMenuFrame", true)
		if found and found:IsA("GuiObject") then
			frame = found
		end
	end

	if frame then
		bindMainMenuFrame(frame)
	end
end

local function bindShiftLockFrame(frame: GuiObject)
	clearShiftLockFrameConnections()
	shiftLockFrame = frame
	setShiftLockIndicatorState(shiftLockEnabled)

	local toggleButtons: {GuiButton} = {}
	local function addToggleButton(button: GuiButton)
		for _, existing in ipairs(toggleButtons) do
			if existing == button then
				return
			end
		end
		toggleButtons[#toggleButtons + 1] = button
	end

	if frame:IsA("GuiButton") then
		addToggleButton(frame)
	end

	for _, descendant in ipairs(frame:GetDescendants()) do
		if descendant:IsA("GuiButton") then
			local isExplicitToggle = descendant:GetAttribute("ShiftLockToggle") == true
				or TOGGLE_BUTTON_NAME_HINTS[descendant.Name] == true
			if isExplicitToggle then
				addToggleButton(descendant)
			end
		end
	end

	for _, button in ipairs(toggleButtons) do
		table.insert(shiftLockFrameButtonConnections, button.Activated:Connect(toggleShiftLock))
	end
end

local function tryBindShiftLockFrame()
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end

	local root = playerGui:FindFirstChild("ShiftLock")
	local frame: GuiObject? = nil
	if root then
		local found = root:FindFirstChild("ShiftLockFrame", true)
		if found and found:IsA("GuiObject") then
			frame = found
		end
	end
	if not frame then
		local found = playerGui:FindFirstChild("ShiftLockFrame", true)
		if found and found:IsA("GuiObject") then
			frame = found
		end
	end

	if frame then
		bindShiftLockFrame(frame)
	end
end

local function restoreOffsetIfNeeded()
	local humanoid = currentHumanoid
	if not humanoid or not humanoid.Parent then
		return
	end
	humanoid.CameraOffset = ZERO_CAMERA_OFFSET
end

local function isThirdPersonCamera(): boolean
	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end
	local distance = (camera.CFrame.Position - camera.Focus.Position).Magnitude
	return distance > FIRST_PERSON_DISTANCE_THRESHOLD
end

local function shouldApplyShiftLockOffset(): boolean
	if not shiftLockEnabled then
		return false
	end

	if not currentHumanoid or not currentHumanoid.Parent then
		return false
	end

	local camera = workspace.CurrentCamera
	if not camera or camera.CameraType ~= Enum.CameraType.Custom then
		return false
	end

	if localPlayer.CameraMode == Enum.CameraMode.LockFirstPerson then
		return false
	end

	local mouseBehavior = UserInputService.MouseBehavior
	local isLockedMouse = mouseBehavior == Enum.MouseBehavior.LockCenter
		or mouseBehavior == Enum.MouseBehavior.LockCurrentPosition
	local preserveShiftLockCameraDuringSettings = settingsOpen and restoreShiftLockAfterSettings
	if not isLockedMouse and not preserveShiftLockCameraDuringSettings then
		return false
	end

	if not isThirdPersonCamera() then
		return false
	end

	return true
end

local function getTargetCameraOffset(): Vector3
	if shouldApplyShiftLockOffset() then
		return SHIFT_LOCK_CAMERA_OFFSET
	end
	return ZERO_CAMERA_OFFSET
end

local function updateCameraOffset(dt: number?)
	local humanoid = currentHumanoid
	if not humanoid or not humanoid.Parent then
		return
	end

	local targetOffset = getTargetCameraOffset()
	local currentOffset = humanoid.CameraOffset
	local delta = targetOffset - currentOffset
	if delta.Magnitude <= 1e-4 then
		if currentOffset ~= targetOffset then
			humanoid.CameraOffset = targetOffset
		end
		return
	end

	local stepDt = if typeof(dt) == "number" and dt > 0 then dt else (1 / 60)
	local alpha = 1 - math.exp(-CAMERA_OFFSET_SMOOTH_SPEED * stepDt)
	alpha = math.clamp(alpha, 0, 1)
	humanoid.CameraOffset = currentOffset:Lerp(targetOffset, alpha)
end

local function shouldForceActiveFacing(): boolean
	local humanoid = currentHumanoid
	if not humanoid or not humanoid.Parent or humanoid.Health <= 0 then
		return false
	end
	if not shiftLockEnabled then
		return false
	end
	if not isMouseLocked() then
		return false
	end

	local character = humanoid.Parent
	if not character or not character:IsA("Model") then
		return false
	end
	if character:GetAttribute(ATTR_LOCAL_UTILITY_FACING_LOCK) == true then
		return false
	end

	local weaponActive = character:GetAttribute(ATTR_WEAPON_ACTIVE_LOCAL)
	if typeof(weaponActive) ~= "boolean" or weaponActive == false then
		return false
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return false
	end

	return true
end

local function updateActiveFacing()
	if not shouldForceActiveFacing() then
		return
	end

	local humanoid = currentHumanoid
	if not humanoid or not humanoid.Parent then
		return
	end
	local character = humanoid.Parent
	if not character or not character:IsA("Model") then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local lookFlat = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
	if lookFlat.Magnitude <= 1e-4 then
		return
	end
	lookFlat = lookFlat.Unit

	local rootPosition = rootPart.Position
	rootPart.CFrame = CFrame.lookAt(rootPosition, rootPosition + lookFlat)
end

local function bindCharacter(character: Model)
	restoreOffsetIfNeeded()

	currentHumanoid = character:FindFirstChildOfClass("Humanoid")
	if not currentHumanoid then
		local found = character:WaitForChild("Humanoid", 5)
		if found and found:IsA("Humanoid") then
			currentHumanoid = found
		end
	end

	updateCameraOffset(0)
end

localPlayer.CharacterAdded:Connect(function(character)
	bindCharacter(character)
end)

localPlayer.CharacterRemoving:Connect(function()
	restoreOffsetIfNeeded()
	currentHumanoid = nil
end)

UserInputService:GetPropertyChangedSignal("MouseBehavior"):Connect(updateCameraOffset)
localPlayer:GetPropertyChangedSignal("CameraMode"):Connect(updateCameraOffset)
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(updateCameraOffset)

ContextActionService:BindActionAtPriority(
	SHIFT_LOCK_ACTION,
	onShiftLockAction,
	false,
	SHIFT_LOCK_ACTION_PRIORITY,
	Enum.KeyCode.LeftAlt
)

local playerGui = localPlayer:WaitForChild("PlayerGui")
playerGui.DescendantAdded:Connect(function(descendant: Instance)
	if descendant.Name == "ShiftLockFrame" and descendant:IsA("GuiObject") then
		bindShiftLockFrame(descendant)
	elseif descendant.Name == "MainMenuFrame" and descendant:IsA("GuiObject") then
		bindMainMenuFrame(descendant)
	end
end)
tryBindShiftLockFrame()
tryBindMainMenuFrame()
setShiftLockState(false)
settingsOpen = (localPlayer:GetAttribute(ATTR_SETTINGS_OPEN) == true)
syncSettingsLockout()
syncMainMenuLockout()
localPlayer:GetAttributeChangedSignal(ATTR_SETTINGS_OPEN):Connect(function()
	settingsOpen = (localPlayer:GetAttribute(ATTR_SETTINGS_OPEN) == true)
	syncSettingsLockout()
	syncMainMenuLockout()
end)

RunService:BindToRenderStep("ShiftLockCameraOffset", Enum.RenderPriority.Camera.Value - 1, function(dt: number)
	updateCameraOffset(dt)
end)

RunService:BindToRenderStep(FACING_LOCK_RENDERSTEP, Enum.RenderPriority.Camera.Value + 1, function()
	updateActiveFacing()
end)

if localPlayer.Character then
	bindCharacter(localPlayer.Character)
end
