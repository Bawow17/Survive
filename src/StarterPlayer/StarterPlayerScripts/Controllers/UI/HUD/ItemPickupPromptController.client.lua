--!strict
-- ItemPickupPromptController - Drives the existing MainHUD item pickup prompt UI.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
if not playerScripts then
	playerScripts = localPlayer:WaitForChild("PlayerScripts", 10)
end
local scriptsContainer = playerScripts or script:FindFirstAncestor("StarterPlayerScripts")
if not scriptsContainer then
	warn("[ItemPickupPromptController] Could not locate StarterPlayerScripts ancestor")
	return
end

local localSharedFolder = scriptsContainer:WaitForChild("_Shared", 10)
if not localSharedFolder then
	warn("[ItemPickupPromptController] Could not locate _Shared folder")
	return
end

local MainHUDLocator = require(localSharedFolder:WaitForChild("MainHUDLocator"))
local PickupPromptState = require(localSharedFolder:WaitForChild("PickupPromptState"))

local PATRICK_HAND = Font.new("rbxasset://fonts/families/PatrickHand.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal)
local KEY_COLOR_HEX = "#4A86FF"
local FALLBACK_NAME_COLOR_HEX = "#000000"
local ITEM_SLOT_BY_ID = {
	fuse_bomb = "FuseBombImageLabel",
	silver_ninja_star_of_the_brilliant_light = "SilverNinjaStaroftheBrilliantLightImageLabel",
	historic_timmy_gun = "HistoricTimmyGunImageLabel",
	teddy_bloxpin = "TeddyBloxpinImageLabel",
	regeneration_coil = "RegenerationCoilViewportFrame",
	healing_potion = "HealingPotionViewportFrame",
	laser_electrocutor = "LaserElectrocutorViewportFrame",
	builders_club_hard_hat = "BuildersClubHardHatViewportFrame",
	pepperoni_pizza = "PepperoniPizzaViewportFrame",
	delete_tool = "DeleteToolViewportFrame",
	adurite_cape = "AduriteCapeViewportFrame",
	speed_coil = "SpeedCoilViewportFrame",
	bloxy_cola = "BloxyColaViewportFrame",
	cheezburger = "CheezburgerViewportFrame",
	bloxiade = "BloxiadeViewportFrame",
	cake = "CakeViewportFrame",
	energy_sword = "EnergySwordViewportFrame",
	magic_8_ball = "Magic8BallViewportFrame",
	apple = "AppleViewportFrame",
}

type PromptBindings = {
	root: Frame,
	compactRow: Frame,
	actionLabel: TextLabel,
	inspectLabel: TextLabel,
	descriptionPanel: Frame,
	textFrame: Frame,
	previewImage: ImageLabel,
	titleLabel: TextLabel,
	bodyLabel: TextLabel,
}

local function waitForChildOfClass(parent: Instance, childName: string, className: string, searchDescendants: boolean?): Instance?
	local child = if searchDescendants then parent:FindFirstChild(childName, true) else parent:FindFirstChild(childName)
	if not child and not searchDescendants then
		child = parent:WaitForChild(childName, 10)
	end
	if not child then
		warn(string.format("[ItemPickupPromptController] Missing %s.%s", parent:GetFullName(), childName))
		return nil
	end
	if not child:IsA(className) then
		warn(string.format("[ItemPickupPromptController] Expected %s.%s to be a %s", parent:GetFullName(), childName, className))
		return nil
	end
	return child
end

local function styleTextLabel(label: TextLabel, textXAlignment: Enum.TextXAlignment)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.FontFace = PATRICK_HAND
	label.RichText = true
	label.TextScaled = true
	label.TextTransparency = 0
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.TextWrapped = true
	label.TextXAlignment = textXAlignment
	label.TextYAlignment = Enum.TextYAlignment.Center
end

local function escapeRichText(text: string): string
	local escaped = string.gsub(text, "&", "&amp;")
	escaped = string.gsub(escaped, "<", "&lt;")
	escaped = string.gsub(escaped, ">", "&gt;")
	return escaped
end

local function findDirectImageLabel(parent: Instance): ImageLabel?
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("ImageLabel") then
			return child
		end
	end
	return nil
end

local function findDescendantImageLabel(parent: Instance): ImageLabel?
	for _, child in ipairs(parent:GetDescendants()) do
		if child:IsA("ImageLabel") then
			return child
		end
	end
	return nil
end

local function restoreTempRuntimeLayout(descriptionPanel: Frame)
	local textFrame = descriptionPanel:FindFirstChild("TextFrame")
	local imageFrame = descriptionPanel:FindFirstChild("ImageFrame")

	if textFrame and textFrame:IsA("Frame") then
		local nestedTitle = descriptionPanel:FindFirstChild("ItemPickupTitleLabel", true)
		if nestedTitle and nestedTitle:IsA("TextLabel") and nestedTitle.Parent ~= textFrame then
			nestedTitle.Parent = textFrame
		end

		local nestedBody = descriptionPanel:FindFirstChild("ItemPickupDescriptionLabel", true)
		if nestedBody and nestedBody:IsA("TextLabel") and nestedBody.Parent ~= textFrame then
			nestedBody.Parent = textFrame
		end
	end

	local nestedImage = descriptionPanel:FindFirstChild("ImageLabel", true)
	if imageFrame and imageFrame:IsA("Frame") then
		if nestedImage and nestedImage:IsA("ImageLabel") and nestedImage.Parent ~= imageFrame then
			nestedImage.Parent = imageFrame
		end
	end

	local contentRow = descriptionPanel:FindFirstChild("ItemPickupContentRowFrame")
	if contentRow then
		contentRow:Destroy()
	end
end

local function resolveItemSlot(itemsFrame: GuiObject, itemId: string): GuiObject?
	local slotName = ITEM_SLOT_BY_ID[itemId]
	if typeof(slotName) ~= "string" or slotName == "" then
		return nil
	end

	local exact = itemsFrame:FindFirstChild(slotName)
	if exact and exact:IsA("GuiObject") then
		return exact
	end

	if string.sub(slotName, -10) == "ImageLabel" then
		local legacyName = string.sub(slotName, 1, #slotName - 10) .. "ViewportFrame"
		local legacy = itemsFrame:FindFirstChild(legacyName)
		if legacy and legacy:IsA("GuiObject") then
			return legacy
		end
	elseif string.sub(slotName, -13) == "ViewportFrame" then
		local migratedName = string.sub(slotName, 1, #slotName - 13) .. "ImageLabel"
		local migrated = itemsFrame:FindFirstChild(migratedName)
		if migrated and migrated:IsA("GuiObject") then
			return migrated
		end
	end

	return nil
end

local function bindPromptGui(mainHUD: ScreenGui | Frame): PromptBindings?
	local rootInstance = waitForChildOfClass(mainHUD, "ItemPickupPromptFrame", "Frame")
	if not rootInstance then
		return nil
	end
	local root = rootInstance :: Frame

	local descriptionPanelInstance = waitForChildOfClass(root, "ItemPickupDescriptionFrame", "Frame")
	if not descriptionPanelInstance then
		return nil
	end
	local descriptionPanel = descriptionPanelInstance :: Frame
	restoreTempRuntimeLayout(descriptionPanel)

	local textFrameInstance = waitForChildOfClass(descriptionPanel, "TextFrame", "Frame")
	if not textFrameInstance then
		return nil
	end
	local textFrame = textFrameInstance :: Frame

	local imageFrameInstance = waitForChildOfClass(descriptionPanel, "ImageFrame", "Frame")
	if not imageFrameInstance then
		return nil
	end
	local imageFrame = imageFrameInstance :: Frame

	local previewImageInstance = waitForChildOfClass(imageFrame, "ImageLabel", "ImageLabel", true)
	if not previewImageInstance then
		return nil
	end
	local previewImage = previewImageInstance :: ImageLabel

	local compactRowInstance = waitForChildOfClass(root, "ItemPickupPromptRowFrame", "Frame")
	if not compactRowInstance then
		return nil
	end
	local compactRow = compactRowInstance :: Frame

	local actionLabelInstance = waitForChildOfClass(compactRow, "ItemPickupActionLabel", "TextLabel", true)
	if not actionLabelInstance then
		return nil
	end
	local actionLabel = actionLabelInstance :: TextLabel

	local inspectLabelInstance = waitForChildOfClass(compactRow, "ItemPickupInspectLabel", "TextLabel", true)
	if not inspectLabelInstance then
		return nil
	end
	local inspectLabel = inspectLabelInstance :: TextLabel

	local titleLabelInstance = waitForChildOfClass(textFrame, "ItemPickupTitleLabel", "TextLabel", true)
	if not titleLabelInstance then
		return nil
	end
	local titleLabel = titleLabelInstance :: TextLabel

	local bodyLabelInstance = waitForChildOfClass(textFrame, "ItemPickupDescriptionLabel", "TextLabel", true)
	if not bodyLabelInstance then
		return nil
	end
	local bodyLabel = bodyLabelInstance :: TextLabel

	styleTextLabel(actionLabel, Enum.TextXAlignment.Left)
	styleTextLabel(inspectLabel, Enum.TextXAlignment.Right)
	styleTextLabel(titleLabel, Enum.TextXAlignment.Left)
	styleTextLabel(bodyLabel, Enum.TextXAlignment.Left)
	titleLabel.TextYAlignment = Enum.TextYAlignment.Center
	bodyLabel.TextYAlignment = Enum.TextYAlignment.Top

	previewImage.BackgroundTransparency = 1
	previewImage.BorderSizePixel = 0

	local previewCountLabel = previewImage:FindFirstChild("CountLabel")
	if previewCountLabel and previewCountLabel:IsA("GuiObject") then
		previewCountLabel.Visible = false
	end

	return {
		root = root,
		compactRow = compactRow,
		actionLabel = actionLabel,
		inspectLabel = inspectLabel,
		descriptionPanel = descriptionPanel,
		textFrame = textFrame,
		previewImage = previewImage,
		titleLabel = titleLabel,
		bodyLabel = bodyLabel,
	}
end

local function applyDescriptionLayout(ui: PromptBindings)
	return
end

local function syncPreviewImage(destination: ImageLabel?, sourceFrame: GuiObject?)
	if not sourceFrame then
		if destination then
			destination.Visible = false
		end
		return
	end

	local sourceImage: ImageLabel?
	if sourceFrame:IsA("ImageLabel") then
		sourceImage = sourceFrame
	else
		sourceImage = findDirectImageLabel(sourceFrame)
	end
	if not sourceImage then
		if destination then
			destination.Visible = false
		end
		return
	end

	if not destination then
		return
	end

	destination.BackgroundTransparency = 1
	destination.BorderSizePixel = 0
	destination.Image = sourceImage.Image
	destination.ImageColor3 = sourceImage.ImageColor3
	destination.ImageTransparency = sourceImage.ImageTransparency
	destination.ImageRectOffset = sourceImage.ImageRectOffset
	destination.ImageRectSize = sourceImage.ImageRectSize
	destination.ScaleType = sourceImage.ScaleType
	destination.SliceCenter = sourceImage.SliceCenter
	destination.SliceScale = sourceImage.SliceScale
	destination.TileSize = sourceImage.TileSize
	destination.Rotation = sourceImage.Rotation
	destination.Visible = true
end

local mainHUD = MainHUDLocator.waitForMainHUD(playerGui)
local ui = bindPromptGui(mainHUD)
if not ui then
	return
end
local topBarFrame = waitForChildOfClass(mainHUD, "TopBarFrame", "GuiObject")
if not topBarFrame then
	return
end
local itemsFrame = waitForChildOfClass(topBarFrame, "Items", "GuiObject")
if not itemsFrame then
	return
end

local currentPrompt = PickupPromptState.getPrompt()
local tabHeld = false

local function render()
	if currentPrompt == nil then
		ui.root.Visible = false
		ui.descriptionPanel.Visible = false
		if ui.previewImage then
			ui.previewImage.Visible = false
		end
		return
	end

	local displayName = currentPrompt.displayName or currentPrompt.itemId
	local safeDisplayName = escapeRichText(displayName)
	local nameColorHex = currentPrompt.nameColorHex or FALLBACK_NAME_COLOR_HEX
	local sourceFrame = resolveItemSlot(itemsFrame, currentPrompt.itemId)
	syncPreviewImage(ui.previewImage, sourceFrame)
	applyDescriptionLayout(ui)

	ui.root.Visible = true
	ui.actionLabel.Text = string.format(
		[[<font color="%s">E</font>-Get <font color="%s">%s</font>]],
		KEY_COLOR_HEX,
		nameColorHex,
		safeDisplayName
	)
	ui.inspectLabel.Text = string.format([[<font color="%s">Tab</font>-More info]], KEY_COLOR_HEX)
	ui.titleLabel.Text = string.format([[<font color="%s">%s</font>]], nameColorHex, safeDisplayName)
	ui.bodyLabel.Text = currentPrompt.description or "No description available"
	ui.descriptionPanel.Visible = tabHeld
end

PickupPromptState.getChangedEvent():Connect(function(nextPrompt)
	currentPrompt = nextPrompt
	render()
end)

UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessed: boolean)
	if input.KeyCode ~= Enum.KeyCode.Tab then
		return
	end
	if UserInputService:GetFocusedTextBox() then
		return
	end
	tabHeld = true
	render()
end)

UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
	if input.KeyCode ~= Enum.KeyCode.Tab then
		return
	end
	tabHeld = false
	render()
end)

render()
