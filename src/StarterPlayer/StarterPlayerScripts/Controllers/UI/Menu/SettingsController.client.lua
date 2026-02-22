--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local PlayerSettingsSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerSettingsSchema"))
type SettingsV1 = PlayerSettingsSchema.SettingsV1

local ATTR_ENEMY_RENDER_SCALE = "Setting_graphics_enemyRenderScale"
local ATTR_CHUNK_RENDER_SCALE = "Setting_graphics_chunkRenderScale"
local ATTR_RENDER_SCALE_LEGACY = "Setting_graphics_renderScale"
local ATTR_PROJECTILE_OPACITY_SELF = "Setting_graphics_projectileOpacitySelf"
local ATTR_PROJECTILE_OPACITY_OTHERS = "Setting_graphics_projectileOpacityOthers"
local ATTR_OTHER_PLAYER_VFX_OPACITY = "Setting_graphics_otherPlayerVfxOpacity"
local ATTR_REDUCE_FLASH = "Setting_accessibility_reduceFlash"
local ATTR_REDUCE_MOTION = "Setting_accessibility_reduceMotion"
local ATTR_TOGGLE_SPRINT_MODE = "Setting_controls_toggleSprintMode"
local ATTR_SETTINGS_OPEN = "UI_SettingsOpen"
local ATTR_CAMERA_FOV = "Setting_graphics_cameraFov"

local CAMERA_FOV_MIN = 60
local CAMERA_FOV_MAX = 100
local CAMERA_FOV_DEFAULT = 70

local function ensureOpenSignal(): BindableEvent
	local existing = ReplicatedStorage:FindFirstChild("OpenSettingsPanel")
	if existing and existing:IsA("BindableEvent") then
		return existing
	end
	local bindable = Instance.new("BindableEvent")
	bindable.Name = "OpenSettingsPanel"
	bindable.Parent = ReplicatedStorage
	return bindable
end

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local settingsFolder = remotesFolder:WaitForChild("PlayerSettings")
local GetSettingsRemote = settingsFolder:WaitForChild("GetSettings") :: RemoteFunction
local UpdateSettingsRemote = settingsFolder:WaitForChild("UpdateSettings") :: RemoteEvent
local SettingsChangedRemote = settingsFolder:WaitForChild("SettingsChanged") :: RemoteEvent
local openSignal = ensureOpenSignal()

local currentSettings: SettingsV1 = PlayerSettingsSchema.createDefault()
local refreshRows: {() -> ()} = {}
local pendingPushToken = 0
local isOpen = false

player:SetAttribute(ATTR_SETTINGS_OPEN, false)

local mainMenuGuiInstance = playerGui:WaitForChild("MainMenuGui", 30)
if not mainMenuGuiInstance or not mainMenuGuiInstance:IsA("ScreenGui") then
	warn("[SettingsController] MainMenuGui not found in PlayerGui; expected prebuilt StarterGui.MainMenuGui")
	return
end
local mainMenuGui = mainMenuGuiInstance :: ScreenGui

local rootInstance = mainMenuGui:WaitForChild("SettingsImageFrame", 30)
if not rootInstance or not rootInstance:IsA("GuiObject") then
	warn("[SettingsController] MainMenuGui.SettingsImageFrame not found or invalid")
	return
end
local root = rootInstance :: GuiObject
root.Visible = false
local controlsFrameInstance = mainMenuGui:FindFirstChild("ControlsImageFrame")
local controlsFrame = if controlsFrameInstance and controlsFrameInstance:IsA("GuiObject")
	then (controlsFrameInstance :: GuiObject)
	else nil
local mainMenuFrameInstance = mainMenuGui:FindFirstChild("MainMenuFrame")
local mainMenuFrame = if mainMenuFrameInstance and mainMenuFrameInstance:IsA("GuiObject")
	then (mainMenuFrameInstance :: GuiObject)
	else nil

local closeButtonInstance = root:FindFirstChild("CloseButton")
local closeButton = if closeButtonInstance and closeButtonInstance:IsA("TextButton")
	then (closeButtonInstance :: TextButton)
	else nil

local resetButtonInstance = root:FindFirstChild("ResetButton")
local resetButton = if resetButtonInstance and resetButtonInstance:IsA("TextButton")
	then (resetButtonInstance :: TextButton)
	else nil

local contentInstance = root:FindFirstChild("SettingsScrollFrame")
local content = if contentInstance and contentInstance:IsA("ScrollingFrame")
	then (contentInstance :: ScrollingFrame)
	else nil

if not content then
	warn("[SettingsController] Root.SettingsScrollFrame not found; setting row controls will not bind")
else
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	local scrollMetricsQueued = false
	local function applyContentScrollMetricsNow()
		scrollMetricsQueued = false
		local targetThickness = math.clamp(math.floor(root.AbsoluteSize.X * 0.014), 8, 16)
		if content.ScrollBarThickness ~= targetThickness then
			content.ScrollBarThickness = targetThickness
		end
	end
	local function queueContentScrollMetricsUpdate()
		if scrollMetricsQueued then
			return
		end
		scrollMetricsQueued = true
		task.defer(applyContentScrollMetricsNow)
	end
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueContentScrollMetricsUpdate)
	task.defer(queueContentScrollMetricsUpdate)
end

local function setOpen(open: boolean)
	if open and controlsFrame and controlsFrame.Visible then
		controlsFrame.Visible = false
	end
	isOpen = open
	player:SetAttribute(ATTR_SETTINGS_OPEN, open)
	root.Visible = open
end

local function formatNumber(value: number): string
	return string.format("%.2f", value)
end

local function applyCameraFov(value: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	camera.FieldOfView = math.clamp(value, CAMERA_FOV_MIN, CAMERA_FOV_MAX)
end

local function toComponentBaseName(labelText: string): string
	local cleaned = string.gsub(labelText, "[^%w]+", " ")
	local parts = {}
	for part in string.gmatch(cleaned, "%w+") do
		local first = string.sub(part, 1, 1)
		local rest = string.sub(part, 2)
		table.insert(parts, string.upper(first) .. string.lower(rest))
	end
	local joined = table.concat(parts, "")
	if joined == "" then
		return "Setting"
	end
	if string.match(joined, "^[0-9]") then
		return "Setting" .. joined
	end
	return joined
end

local function applyToAttributes(settings: SettingsV1)
	player:SetAttribute(ATTR_ENEMY_RENDER_SCALE, settings.graphics.enemyRenderScale)
	player:SetAttribute(ATTR_CHUNK_RENDER_SCALE, settings.graphics.chunkRenderScale)
	-- Backward compatibility for any still-reading legacy consumers.
	player:SetAttribute(ATTR_RENDER_SCALE_LEGACY, settings.graphics.enemyRenderScale)
	player:SetAttribute(ATTR_PROJECTILE_OPACITY_SELF, settings.graphics.projectileOpacitySelf)
	player:SetAttribute(ATTR_PROJECTILE_OPACITY_OTHERS, settings.graphics.projectileOpacityOthers)
	player:SetAttribute(ATTR_OTHER_PLAYER_VFX_OPACITY, settings.graphics.otherPlayerVfxOpacity)
	player:SetAttribute(ATTR_CAMERA_FOV, settings.graphics.cameraFov)
	player:SetAttribute(ATTR_REDUCE_FLASH, settings.accessibility.reduceFlash)
	player:SetAttribute(ATTR_REDUCE_MOTION, false)
	player:SetAttribute(ATTR_TOGGLE_SPRINT_MODE, settings.controls.toggleSprintMode)
	applyCameraFov(settings.graphics.cameraFov)
end

local function refreshAllRows()
	for _, callback in ipairs(refreshRows) do
		callback()
	end
end

local function setSettingsFromSource(settings: any)
	currentSettings = PlayerSettingsSchema.sanitize(settings)
	currentSettings.accessibility.reduceMotion = false
	currentSettings.controls.settingsHotkeyEnabled = true
	applyToAttributes(currentSettings)
	refreshAllRows()
end

local function pushDebounced()
	pendingPushToken += 1
	local token = pendingPushToken
	task.delay(0.2, function()
		if token ~= pendingPushToken then
			return
		end
		UpdateSettingsRemote:FireServer(currentSettings)
	end)
end

local function findSettingRow(componentBaseName: string, labelText: string?, suppressWarning: boolean?): Frame?
	if not content then
		return nil
	end

	local candidateNames = { componentBaseName .. "Frame" }
	if labelText then
		-- Support authored names that intentionally keep special separators, e.g. "Toggle/HoldSprintFrame".
		local compactLabelName = string.gsub(labelText, "%s+", "") .. "Frame"
		if compactLabelName ~= candidateNames[1] then
			table.insert(candidateNames, compactLabelName)
		end
	end

	for _, candidate in ipairs(candidateNames) do
		local row = content:FindFirstChild(candidate)
		if row and row:IsA("Frame") then
			return row
		end
	end

	if suppressWarning ~= true then
		warn(string.format("[SettingsController] Missing row: %sFrame", componentBaseName))
	end
	return nil
end

local function getNextLayoutOrder(): number
	if not content then
		return 1
	end
	local maxLayoutOrder = 0
	for _, child in ipairs(content:GetChildren()) do
		if child:IsA("GuiObject") then
			maxLayoutOrder = math.max(maxLayoutOrder, child.LayoutOrder)
		end
	end
	return maxLayoutOrder + 1
end

local function cloneTemplateSettingRow(componentBaseName: string): Frame?
	if not content then
		return nil
	end

	for _, child in ipairs(content:GetChildren()) do
		if child:IsA("Frame") and child:FindFirstChild("DescriptionLabel") and child:FindFirstChild("ValueLabel") then
			local cloned = child:Clone()
			cloned.Name = componentBaseName .. "Frame"
			cloned.LayoutOrder = getNextLayoutOrder()
			cloned.Parent = content
			return cloned
		end
	end

	return nil
end

local function addSliderRow(
	labelText: string,
	minimum: number,
	maximum: number,
	step: number,
	getter: () -> number,
	setter: (number) -> ()
)
	local componentBaseName = toComponentBaseName(labelText)
	local row = findSettingRow(componentBaseName, labelText)
	if not row then
		return
	end

	local description = row:FindFirstChild("DescriptionLabel")
	if description and description:IsA("TextLabel") then
		description.Text = labelText
	end

	local minus = row:FindFirstChild("DecreaseButton")
	local plus = row:FindFirstChild("IncreaseButton")
	local valueLabel = row:FindFirstChild("ValueLabel")

	local function refresh()
		if valueLabel and valueLabel:IsA("TextLabel") then
			valueLabel.Text = formatNumber(getter())
		end
	end

	if minus and minus:IsA("TextButton") then
		minus.Activated:Connect(function()
			local nextValue = math.clamp(getter() - step, minimum, maximum)
			setter(nextValue)
			refresh()
			pushDebounced()
		end)
	end

	if plus and plus:IsA("TextButton") then
		plus.Activated:Connect(function()
			local nextValue = math.clamp(getter() + step, minimum, maximum)
			setter(nextValue)
			refresh()
			pushDebounced()
		end)
	end

	table.insert(refreshRows, refresh)
	refresh()
end

local function addNumberInputRow(
	labelText: string,
	minimum: number,
	maximum: number,
	getter: () -> number,
	setter: (number) -> ()
)
	local componentBaseName = toComponentBaseName(labelText)
	local row = findSettingRow(componentBaseName, labelText, true)
	if not row then
		row = cloneTemplateSettingRow(componentBaseName)
	end
	if not row then
		warn(string.format("[SettingsController] Missing or failed to create row: %sFrame", componentBaseName))
		return
	end

	local description = row:FindFirstChild("DescriptionLabel")
	if description and description:IsA("TextLabel") then
		description.Text = string.format("%s (%d-%d)", labelText, minimum, maximum)
	end

	local decreaseButton = row:FindFirstChild("DecreaseButton")
	if decreaseButton and decreaseButton:IsA("GuiObject") then
		decreaseButton.Visible = false
		if decreaseButton:IsA("GuiButton") then
			decreaseButton.Active = false
			decreaseButton.AutoButtonColor = false
		end
	end

	local increaseButton = row:FindFirstChild("IncreaseButton")
	if increaseButton and increaseButton:IsA("GuiObject") then
		increaseButton.Visible = false
		if increaseButton:IsA("GuiButton") then
			increaseButton.Active = false
			increaseButton.AutoButtonColor = false
		end
	end

	local valueLabel = row:FindFirstChild("ValueLabel")
	local input = row:FindFirstChild("ValueInput")
	if input and not input:IsA("TextBox") then
		input:Destroy()
		input = nil
	end

	local valueInput = if input and input:IsA("TextBox") then (input :: TextBox) else nil
	if not valueInput then
		local created = Instance.new("TextBox")
		created.Name = "ValueInput"
		created.ClearTextOnFocus = false
		created.TextEditable = true
		created.PlaceholderText = string.format("%d-%d", minimum, maximum)
		created.TextXAlignment = Enum.TextXAlignment.Center
		created.TextYAlignment = Enum.TextYAlignment.Center

		if valueLabel and valueLabel:IsA("TextLabel") then
			local valueTextLabel = valueLabel :: TextLabel
			created.Size = valueTextLabel.Size
			created.Position = valueTextLabel.Position
			created.AnchorPoint = valueTextLabel.AnchorPoint
			created.BackgroundColor3 = valueTextLabel.BackgroundColor3
			created.BackgroundTransparency = valueTextLabel.BackgroundTransparency
			created.BorderColor3 = valueTextLabel.BorderColor3
			created.BorderSizePixel = valueTextLabel.BorderSizePixel
			created.Font = valueTextLabel.Font
			created.TextSize = valueTextLabel.TextSize
			created.TextColor3 = valueTextLabel.TextColor3
			created.TextStrokeColor3 = valueTextLabel.TextStrokeColor3
			created.TextStrokeTransparency = valueTextLabel.TextStrokeTransparency
			created.TextScaled = valueTextLabel.TextScaled
			valueTextLabel.Visible = false
		else
			created.Size = UDim2.new(0.30, 0, 0.72, 0)
			created.Position = UDim2.new(0.66, 0, 0.14, 0)
			created.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
			created.BackgroundTransparency = 0
			created.BorderSizePixel = 0
			created.Font = Enum.Font.GothamMedium
			created.TextSize = 14
			created.TextColor3 = Color3.fromRGB(235, 235, 235)
		end

		created.Parent = row
		valueInput = created
	end

	local function refresh()
		local clampedValue = math.clamp(math.round(getter()), minimum, maximum)
		valueInput.Text = tostring(clampedValue)
	end

	local function commitInput()
		local previousValue = math.clamp(math.round(getter()), minimum, maximum)
		local parsedValue = tonumber(valueInput.Text)
		if not parsedValue then
			refresh()
			return
		end
		local nextValue = math.clamp(math.round(parsedValue), minimum, maximum)
		if nextValue ~= previousValue then
			setter(nextValue)
			pushDebounced()
		end
		refresh()
	end

	valueInput.FocusLost:Connect(function()
		commitInput()
	end)

	table.insert(refreshRows, refresh)
	refresh()
end

local function addToggleRow(
	labelText: string,
	getter: () -> boolean,
	setter: (boolean) -> (),
	displayLabelText: string?
)
	local componentBaseName = toComponentBaseName(labelText)
	local row = findSettingRow(componentBaseName, labelText)
	if not row then
		return
	end

	local description = row:FindFirstChild("DescriptionLabel")
	if description and description:IsA("TextLabel") then
		description.Text = displayLabelText or labelText
	end

	local toggle = row:FindFirstChild("ToggleButton")
	if not toggle or not toggle:IsA("TextButton") then
		warn(string.format("[SettingsController] Missing ToggleButton in %sFrame", componentBaseName))
		return
	end

	local toggleButton = toggle :: TextButton
	local function refresh()
		local enabled = getter()
		toggleButton.BackgroundColor3 = enabled and Color3.fromRGB(64, 132, 94) or Color3.fromRGB(90, 52, 52)
		toggleButton.TextColor3 = Color3.fromRGB(240, 240, 244)
		toggleButton.Text = if enabled then "ON" else "OFF"
	end

	toggleButton.Activated:Connect(function()
		setter(not getter())
		refresh()
		pushDebounced()
	end)

	table.insert(refreshRows, refresh)
	refresh()
end

addSliderRow("Render Distance Enemies", 0.50, 10.00, 0.50, function()
	return currentSettings.graphics.enemyRenderScale
end, function(value: number)
	currentSettings.graphics.enemyRenderScale = value
	applyToAttributes(currentSettings)
end)

addSliderRow("Render Distance Chunks", 0.50, 10.00, 0.50, function()
	return currentSettings.graphics.chunkRenderScale
end, function(value: number)
	currentSettings.graphics.chunkRenderScale = value
	applyToAttributes(currentSettings)
end)

addSliderRow("My Projectile Opacity", 0.25, 1.00, 0.05, function()
	return currentSettings.graphics.projectileOpacitySelf
end, function(value: number)
	currentSettings.graphics.projectileOpacitySelf = value
	applyToAttributes(currentSettings)
end)

addSliderRow("Other Players Projectile Opacity", 0.05, 1.00, 0.05, function()
	return currentSettings.graphics.projectileOpacityOthers
end, function(value: number)
	currentSettings.graphics.projectileOpacityOthers = value
	applyToAttributes(currentSettings)
end)

addSliderRow("Other Players VFX Opacity", 0.00, 1.00, 0.05, function()
	return currentSettings.graphics.otherPlayerVfxOpacity
end, function(value: number)
	currentSettings.graphics.otherPlayerVfxOpacity = value
	applyToAttributes(currentSettings)
end)

addNumberInputRow("Field Of View", CAMERA_FOV_MIN, CAMERA_FOV_MAX, function()
	return currentSettings.graphics.cameraFov
end, function(value: number)
	currentSettings.graphics.cameraFov = value
	applyToAttributes(currentSettings)
end)

addToggleRow("Reduce Flash Effects", function()
	return currentSettings.accessibility.reduceFlash
end, function(value: boolean)
	currentSettings.accessibility.reduceFlash = value
	applyToAttributes(currentSettings)
end)

addToggleRow("Toggle/Hold Sprint", function()
	return currentSettings.controls.toggleSprintMode
end, function(value: boolean)
	currentSettings.controls.toggleSprintMode = value
	applyToAttributes(currentSettings)
end, "Toggle to sprint")

if closeButton then
	closeButton.Activated:Connect(function()
		setOpen(false)
	end)
else
	warn("[SettingsController] Root.CloseButton not found")
end

if resetButton then
	resetButton.Activated:Connect(function()
		currentSettings = PlayerSettingsSchema.createDefault()
		currentSettings.accessibility.reduceMotion = false
		currentSettings.controls.settingsHotkeyEnabled = true
		applyToAttributes(currentSettings)
		refreshAllRows()
		pushDebounced()
	end)
else
	warn("[SettingsController] Root.ResetButton not found")
end

openSignal.Event:Connect(function(action: any)
	if action == "toggle" then
		setOpen(not isOpen)
	elseif action == false or action == "close" then
		setOpen(false)
	else
		setOpen(true)
	end
end)

SettingsChangedRemote.OnClientEvent:Connect(function(settings: any)
	setSettingsFromSource(settings)
end)

task.spawn(function()
	local ok, settings = pcall(function()
		return GetSettingsRemote:InvokeServer()
	end)
	if ok then
		setSettingsFromSource(settings)
	else
		setSettingsFromSource(PlayerSettingsSchema.createDefault())
	end
end)

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	applyCameraFov(currentSettings.graphics.cameraFov or CAMERA_FOV_DEFAULT)
end)

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode ~= Enum.KeyCode.P then
		return
	end
	if UserInputService:GetFocusedTextBox() then
		return
	end
	setOpen(not isOpen)
end)

if controlsFrame then
	controlsFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if controlsFrame.Visible and isOpen then
			setOpen(false)
		end
	end)
end

if mainMenuFrame then
	mainMenuFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if not mainMenuFrame.Visible and isOpen then
			setOpen(false)
		end
	end)
end
