--!strict
-- ControlsPanelController - Builds and toggles a controls reference panel in MainMenuGui.

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

local playButtonsFrame = mainMenuFrame:WaitForChild("PlayButtonsFrame", 30)
if not playButtonsFrame or not playButtonsFrame:IsA("GuiObject") then
	warn("[ControlsPanel] PlayButtonsFrame not found")
	return
end

local controlsButton = playButtonsFrame:FindFirstChild("ControlsButton")
if not controlsButton or not controlsButton:IsA("GuiButton") then
	warn("[ControlsPanel] ControlsButton not found under MainMenuFrame.PlayButtonsFrame")
	return
end

local controlsFrame = mainMenuGui:WaitForChild("ControlsImageFrame", 30)
if not controlsFrame or not controlsFrame:IsA("GuiObject") then
	warn("[ControlsPanel] ControlsImageFrame not found in MainMenuGui")
	return
end

local controlsList = {
	{ bind = "W / A / S / D", action = "Move", context = "Gameplay" },
	{ bind = "Mouse", action = "Look Around", context = "Gameplay" },
	{ bind = "Space", action = "Jump", context = "Gameplay" },
	{ bind = "Q", action = "Mobility Ability", context = "Gameplay (Dash, Blink, Shield Bash, etc.)" },
	{ bind = "Hold Q", action = "Sustain Mobility", context = "When using Mana Grapple" },
	{ bind = "Release Q", action = "Cancel Grapple Hold", context = "When using Mana Grapple" },
	{ bind = "E", action = "Interact", context = "Objective prompts / world interactions" },
	{ bind = "H", action = "Toggle Stats Panel", context = "Gameplay" },
	{ bind = "P", action = "Toggle Settings Panel", context = "Gameplay + Menu" },
	{ bind = "Q / E", action = "Spectate Previous / Next", context = "While dead" },
	{ bind = "Tap Mobility Button", action = "Use Mobility Ability", context = "Mobile controls" },
}

local generatedRoot = controlsFrame:FindFirstChild("GeneratedControlsPanel")
if generatedRoot then
	generatedRoot:Destroy()
end

local panel = Instance.new("Frame")
panel.Name = "GeneratedControlsPanel"
panel.BackgroundTransparency = 1
panel.Size = UDim2.fromScale(1, 1)
panel.Parent = controlsFrame

local title = Instance.new("TextLabel")
title.Name = "TitleLabel"
title.BackgroundTransparency = 1
title.Position = UDim2.fromScale(0.04, 0.04)
title.Size = UDim2.fromScale(0.72, 0.10)
title.Font = Enum.Font.GothamBold
title.Text = "Controls"
title.TextScaled = true
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(244, 247, 255)
title.Parent = panel

local subtitle = Instance.new("TextLabel")
subtitle.Name = "SubtitleLabel"
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.fromScale(0.04, 0.12)
subtitle.Size = UDim2.fromScale(0.88, 0.06)
subtitle.Font = Enum.Font.Gotham
subtitle.Text = "Quick reference for keyboard and mobile controls"
subtitle.TextScaled = true
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.TextColor3 = Color3.fromRGB(186, 196, 220)
subtitle.Parent = panel

local closeButton = Instance.new("TextButton")
closeButton.Name = "CloseButton"
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Position = UDim2.fromScale(0.96, 0.045)
closeButton.Size = UDim2.fromScale(0.12, 0.08)
closeButton.BackgroundColor3 = Color3.fromRGB(64, 69, 91)
closeButton.BackgroundTransparency = 0.1
closeButton.BorderSizePixel = 0
closeButton.Font = Enum.Font.GothamBold
closeButton.Text = "Close"
closeButton.TextScaled = true
closeButton.TextColor3 = Color3.fromRGB(236, 240, 252)
closeButton.Parent = panel

local scroll = Instance.new("ScrollingFrame")
scroll.Name = "ControlsScrollFrame"
scroll.BackgroundColor3 = Color3.fromRGB(19, 22, 34)
scroll.BackgroundTransparency = 0.18
scroll.BorderSizePixel = 0
scroll.Position = UDim2.fromScale(0.04, 0.20)
scroll.Size = UDim2.fromScale(0.92, 0.74)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.fromOffset(0, 0)
scroll.ScrollBarThickness = 10
scroll.ScrollBarImageColor3 = Color3.fromRGB(95, 105, 136)
scroll.Parent = panel

local scrollPadding = Instance.new("UIPadding")
scrollPadding.Name = "Padding"
scrollPadding.PaddingTop = UDim.new(0.02, 0)
scrollPadding.PaddingBottom = UDim.new(0.02, 0)
scrollPadding.PaddingLeft = UDim.new(0.02, 0)
scrollPadding.PaddingRight = UDim.new(0.02, 0)
scrollPadding.Parent = scroll

local listLayout = Instance.new("UIListLayout")
listLayout.Name = "ListLayout"
listLayout.Padding = UDim.new(0.0125, 0)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = scroll

for index, entry in ipairs(controlsList) do
	local row = Instance.new("Frame")
	row.Name = string.format("ControlRow_%02d", index)
	row.Size = UDim2.fromScale(1, 0.095)
	row.BackgroundColor3 = Color3.fromRGB(31, 35, 52)
	row.BackgroundTransparency = 0.08
	row.BorderSizePixel = 0
	row.Parent = scroll

	local bindLabel = Instance.new("TextLabel")
	bindLabel.Name = "BindLabel"
	bindLabel.BackgroundColor3 = Color3.fromRGB(48, 56, 85)
	bindLabel.BackgroundTransparency = 0.04
	bindLabel.BorderSizePixel = 0
	bindLabel.Position = UDim2.fromScale(0.015, 0.17)
	bindLabel.Size = UDim2.fromScale(0.25, 0.66)
	bindLabel.Font = Enum.Font.GothamBold
	bindLabel.Text = entry.bind
	bindLabel.TextScaled = true
	bindLabel.TextColor3 = Color3.fromRGB(228, 235, 255)
	bindLabel.Parent = row

	local actionLabel = Instance.new("TextLabel")
	actionLabel.Name = "ActionLabel"
	actionLabel.BackgroundTransparency = 1
	actionLabel.Position = UDim2.fromScale(0.285, 0.12)
	actionLabel.Size = UDim2.fromScale(0.70, 0.42)
	actionLabel.Font = Enum.Font.GothamSemibold
	actionLabel.Text = entry.action
	actionLabel.TextScaled = true
	actionLabel.TextXAlignment = Enum.TextXAlignment.Left
	actionLabel.TextColor3 = Color3.fromRGB(240, 243, 255)
	actionLabel.Parent = row

	local contextLabel = Instance.new("TextLabel")
	contextLabel.Name = "ContextLabel"
	contextLabel.BackgroundTransparency = 1
	contextLabel.Position = UDim2.fromScale(0.285, 0.50)
	contextLabel.Size = UDim2.fromScale(0.70, 0.36)
	contextLabel.Font = Enum.Font.Gotham
	contextLabel.Text = entry.context
	contextLabel.TextScaled = true
	contextLabel.TextXAlignment = Enum.TextXAlignment.Left
	contextLabel.TextColor3 = Color3.fromRGB(176, 186, 215)
	contextLabel.Parent = row
end

controlsFrame.Visible = false

local function toggleControlsPanel()
	controlsFrame.Visible = not controlsFrame.Visible
end

controlsButton.Activated:Connect(toggleControlsPanel)
closeButton.Activated:Connect(function()
	controlsFrame.Visible = false
end)

mainMenuFrame:GetPropertyChangedSignal("Visible"):Connect(function()
	if not mainMenuFrame.Visible then
		controlsFrame.Visible = false
	end
end)
