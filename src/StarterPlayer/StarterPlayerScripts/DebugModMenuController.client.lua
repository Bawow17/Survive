--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local DebugModMenuCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DebugModMenuCatalog"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local modFolder = remotesFolder:WaitForChild("DebugModMenu")

local openStateRemote = modFolder:WaitForChild("OpenState") :: RemoteEvent
local applyEntryRemote = modFolder:WaitForChild("ApplyEntry") :: RemoteEvent
local addSessionTimeRemote = modFolder:WaitForChild("AddSessionTime") :: RemoteEvent
local ackRemote = modFolder:WaitForChild("Ack") :: RemoteEvent

local gui = Instance.new("ScreenGui")
gui.Name = "DebugModMenuGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.Enabled = false
gui.Parent = playerGui

local root = Instance.new("Frame")
root.Name = "Root"
root.AnchorPoint = Vector2.new(0.5, 0.5)
root.Position = UDim2.fromScale(0.5, 0.5)
root.Size = UDim2.fromScale(0.56, 0.70)
root.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
root.BackgroundTransparency = 0.18
root.BorderSizePixel = 0
root.Parent = gui

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(14, 8)
title.Size = UDim2.new(1, -28, 0, 28)
title.Font = Enum.Font.GothamBold
title.TextSize = 20
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(245, 245, 255)
title.Text = "Debug Mod Menu (Owner Only)"
title.Parent = root

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.fromOffset(14, 36)
statusLabel.Size = UDim2.new(1, -28, 0, 20)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 14
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextColor3 = Color3.fromRGB(175, 185, 205)
statusLabel.Text = "Press J to close"
statusLabel.Parent = root

local scroller = Instance.new("ScrollingFrame")
scroller.Name = "List"
scroller.Position = UDim2.fromOffset(12, 62)
scroller.Size = UDim2.new(1, -24, 1, -74)
scroller.CanvasSize = UDim2.fromOffset(0, 0)
scroller.ScrollBarThickness = 8
scroller.BackgroundTransparency = 1
scroller.BorderSizePixel = 0
scroller.Parent = root

local listLayout = Instance.new("UIListLayout")
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Padding = UDim.new(0, 6)
listLayout.Parent = scroller

local entries: {any} = {}
local allowed = false
local pendingToggle = false
local refreshing = false

local function normalizeImageId(iconId: any): string?
	if iconId == nil then
		return nil
	end
	local text = tostring(iconId)
	if text == "" then
		return nil
	end
	if string.match(text, "^%d+$") then
		return "rbxassetid://" .. text
	end
	return text
end

local function makeHeader(text: string, order: number)
	local header = Instance.new("TextLabel")
	header.Name = "Header_" .. text
	header.LayoutOrder = order
	header.Size = UDim2.new(1, 0, 0, 24)
	header.BackgroundColor3 = Color3.fromRGB(35, 38, 50)
	header.BackgroundTransparency = 0.2
	header.BorderSizePixel = 0
	header.Font = Enum.Font.GothamBold
	header.TextSize = 14
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.TextColor3 = Color3.fromRGB(220, 225, 240)
	header.Text = "  " .. text
	header.Parent = scroller
end

local function makeRow(entry: any, order: number)
	local button = Instance.new("TextButton")
	button.Name = "Entry_" .. entry.entryId
	button.LayoutOrder = order
	button.Size = UDim2.new(1, 0, 0, 36)
	button.BackgroundColor3 = Color3.fromRGB(46, 50, 66)
	button.BackgroundTransparency = 0.15
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Text = ""
	button.Parent = scroller

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Position = UDim2.fromOffset(6, 4)
	icon.Size = UDim2.fromOffset(28, 28)
	icon.ImageTransparency = 0
	icon.Parent = button

	local iconId = normalizeImageId(entry.iconId)
	if iconId and iconId ~= "" then
		icon.Image = iconId
		icon.Visible = true
	else
		icon.Visible = false
	end

	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.BackgroundTransparency = 1
	name.Position = UDim2.fromOffset(40, 3)
	name.Size = UDim2.new(1, -46, 0, 18)
	name.Font = Enum.Font.GothamMedium
	name.TextSize = 14
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = Color3.fromRGB(242, 246, 255)
	name.Text = tostring(entry.name or entry.entryId)
	name.Parent = button

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromOffset(40, 18)
	subtitle.Size = UDim2.new(1, -46, 0, 16)
	subtitle.Font = Enum.Font.Gotham
	subtitle.TextSize = 11
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.TextColor3 = Color3.fromRGB(165, 175, 195)
	subtitle.Text = tostring(entry.subtitle or "")
	subtitle.Parent = button

	button.MouseButton1Click:Connect(function()
		if entry.category == "time" and entry.seconds then
			addSessionTimeRemote:FireServer({ seconds = entry.seconds })
		else
			applyEntryRemote:FireServer({ entryId = entry.entryId })
		end
	end)
end

local function rebuildList()
	for _, child in ipairs(scroller:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end

	local index = 1
	local currentCategory: string? = nil
	local sorted = table.clone(entries)
	table.sort(sorted, function(a, b)
		local ao = tonumber(a.categoryOrder) or 99
		local bo = tonumber(b.categoryOrder) or 99
		if ao ~= bo then
			return ao < bo
		end
		if tostring(a.name) ~= tostring(b.name) then
			return tostring(a.name) < tostring(b.name)
		end
		return tostring(a.entryId) < tostring(b.entryId)
	end)

	local all = table.clone(DebugModMenuCatalog.TimeOptions)
	for _, entry in ipairs(sorted) do
		table.insert(all, entry)
	end
	table.sort(all, function(a, b)
		local ao = DebugModMenuCatalog.CategoryOrder[a.category] or a.categoryOrder or 99
		local bo = DebugModMenuCatalog.CategoryOrder[b.category] or b.categoryOrder or 99
		if ao ~= bo then
			return ao < bo
		end
		if tostring(a.name) ~= tostring(b.name) then
			return tostring(a.name) < tostring(b.name)
		end
		return tostring(a.entryId) < tostring(b.entryId)
	end)

	for _, entry in ipairs(all) do
		local category = tostring(entry.category or "unknown")
		if category ~= currentCategory then
			currentCategory = category
			local label = DebugModMenuCatalog.CategoryLabels[category] or tostring(entry.categoryLabel or category)
			makeHeader(label, index)
			index += 1
		end
		makeRow(entry, index)
		index += 1
	end

	task.defer(function()
		local height = listLayout.AbsoluteContentSize.Y + 8
		scroller.CanvasSize = UDim2.fromOffset(0, height)
	end)
end

local function requestState()
	if refreshing then
		return
	end
	refreshing = true
	openStateRemote:FireServer({ request = true })
	task.delay(0.3, function()
		refreshing = false
	end)
end

openStateRemote.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	allowed = payload.allowed == true
	entries = type(payload.catalog) == "table" and payload.catalog or {}
	rebuildList()
	if pendingToggle then
		pendingToggle = false
		gui.Enabled = allowed and not gui.Enabled or false
		if not allowed then
			statusLabel.Text = "Not allowed for this account"
			gui.Enabled = false
		else
			statusLabel.Text = "Press J to close"
		end
	end
end)

ackRemote.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local message = tostring(payload.message or "")
	if message ~= "" then
		statusLabel.Text = message
	end
	requestState()
end)

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.J then
		pendingToggle = true
		requestState()
	end
end)

requestState()
