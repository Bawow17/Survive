--!strict
-- ControlsPanelController - Toggles a prebuilt controls panel in MainMenuGui.

local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local mainMenuGui = playerGui:WaitForChild("MainMenuGui", 30)
if not mainMenuGui or not mainMenuGui:IsA("ScreenGui") then
	warn("[ControlsPanel] MainMenuGui not found in PlayerGui")
	return
end

local mainMenuFrame = mainMenuGui:WaitForChild("MainMenuFrame", 30)
if not mainMenuFrame or not mainMenuFrame:IsA("GuiObject") then
	warn("[ControlsPanel] MainMenuFrame not found in MainMenuGui")
	return
end

local menuButtonsFrame = mainMenuFrame:WaitForChild("MenuButtonsFrame", 30)
if not menuButtonsFrame or not menuButtonsFrame:IsA("GuiObject") then
	warn("[ControlsPanel] MenuButtonsFrame not found")
	return
end

local controlsButton = menuButtonsFrame:FindFirstChild("ControlsButton")
if not controlsButton or not controlsButton:IsA("GuiButton") then
	warn("[ControlsPanel] ControlsButton not found under MainMenuFrame.MenuButtonsFrame")
	return
end

local controlsFrame = mainMenuGui:WaitForChild("ControlsImageFrame", 30)
if not controlsFrame or not controlsFrame:IsA("GuiObject") then
	warn("[ControlsPanel] ControlsImageFrame not found in MainMenuGui")
	return
end

local settingsFrameInstance = mainMenuGui:FindFirstChild("SettingsImageFrame")
local settingsFrame = if settingsFrameInstance and settingsFrameInstance:IsA("GuiObject")
	then (settingsFrameInstance :: GuiObject)
	else nil

controlsFrame.Visible = false
local closeButtonInstance = controlsFrame:FindFirstChild("CloseButton", true)
local closeButton = if closeButtonInstance and closeButtonInstance:IsA("GuiButton")
	then (closeButtonInstance :: GuiButton)
	else nil

local function toggleControlsPanel()
	local nextVisible = not controlsFrame.Visible
	if nextVisible and settingsFrame and settingsFrame.Visible then
		settingsFrame.Visible = false
	end
	controlsFrame.Visible = nextVisible
end

controlsButton.Activated:Connect(toggleControlsPanel)
if closeButton then
	closeButton.Activated:Connect(function()
		controlsFrame.Visible = false
	end)
else
	warn("[ControlsPanel] CloseButton not found in ControlsImageFrame; controls panel can still be toggled from ControlsButton")
end

mainMenuFrame:GetPropertyChangedSignal("Visible"):Connect(function()
	if not mainMenuFrame.Visible then
		controlsFrame.Visible = false
	end
end)

if settingsFrame then
	settingsFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if settingsFrame.Visible and controlsFrame.Visible then
			controlsFrame.Visible = false
		end
	end)
end
