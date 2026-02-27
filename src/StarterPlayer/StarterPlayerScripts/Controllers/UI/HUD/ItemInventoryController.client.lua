--!strict
-- ItemInventoryController - Drives TopBar item viewports from replicated item state.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
if not playerScripts then
	playerScripts = localPlayer:WaitForChild("PlayerScripts", 10)
end
local scriptsContainer = playerScripts or script:FindFirstAncestor("StarterPlayerScripts")
if not scriptsContainer then
	warn("[ItemInventoryController] Could not locate StarterPlayerScripts ancestor")
	return
end
local localSharedFolder = scriptsContainer:WaitForChild("_Shared", 10)
if not localSharedFolder then
	warn("[ItemInventoryController] Could not locate _Shared folder")
	return
end

local MainHUDLocator = require(localSharedFolder:WaitForChild("MainHUDLocator"))
local mainHUD = MainHUDLocator.waitForMainHUD(playerGui)

local topBarFrame = mainHUD:WaitForChild("TopBarFrame", 10)
if not topBarFrame or not topBarFrame:IsA("GuiObject") then
	warn("[ItemInventoryController] MainHUD.TopBarFrame not found")
	return
end

local itemsFrame = topBarFrame:WaitForChild("Items", 10)
if not itemsFrame or not itemsFrame:IsA("GuiObject") then
	warn("[ItemInventoryController] MainHUD.TopBarFrame.Items not found")
	return
end

local function collectViewports(): {[string]: ViewportFrame}
	local viewports = {}
	for _, child in ipairs(itemsFrame:GetChildren()) do
		if child:IsA("ViewportFrame") then
			viewports[child.Name] = child
		end
	end
	return viewports
end

local viewportByName = collectViewports()

local function setCountLabel(viewport: ViewportFrame, count: number)
	local label = viewport:FindFirstChild("CountLabel", true)
	if not label or not label:IsA("TextLabel") then
		return
	end
	if count >= 2 then
		label.Visible = true
		label.Text = "x" .. tostring(count)
	else
		label.Visible = false
	end
end

local function hideAll()
	for _, viewport in pairs(viewportByName) do
		viewport.Visible = false
		setCountLabel(viewport, 0)
	end
end

hideAll()

itemsFrame.ChildAdded:Connect(function(child: Instance)
	if child:IsA("ViewportFrame") then
		viewportByName[child.Name] = child
		child.Visible = false
		setCountLabel(child, 0)
	end
end)

itemsFrame.ChildRemoved:Connect(function(child: Instance)
	if child:IsA("ViewportFrame") then
		viewportByName[child.Name] = nil
	end
end)

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local itemsRemotes = remotesFolder:WaitForChild("Items", 10)
if not itemsRemotes or not itemsRemotes:IsA("Folder") then
	warn("[ItemInventoryController] RemoteEvents.Items folder missing")
	return
end
local itemStateRemote = itemsRemotes:WaitForChild("ItemState", 10)
if not itemStateRemote or not itemStateRemote:IsA("RemoteEvent") then
	warn("[ItemInventoryController] RemoteEvents.Items.ItemState missing")
	return
end

local function applyState(payload: any)
	hideAll()
	if typeof(payload) ~= "table" or typeof(payload.items) ~= "table" then
		return
	end

	local items = table.clone(payload.items)
	table.sort(items, function(a: any, b: any)
		local ao = tonumber(a.layoutOrder) or 0
		local bo = tonumber(b.layoutOrder) or 0
		if ao ~= bo then
			return ao < bo
		end
		return tostring(a.itemId or "") < tostring(b.itemId or "")
	end)

	for index, item in ipairs(items) do
		if typeof(item) ~= "table" then
			continue
		end
		local viewportName = item.viewportFrameName
		if typeof(viewportName) ~= "string" or viewportName == "" then
			continue
		end
		local viewport = viewportByName[viewportName]
		if not viewport then
			continue
		end

		local count = if typeof(item.count) == "number" then math.max(0, math.floor(item.count + 0.0001)) else 0
		if count <= 0 then
			continue
		end

		viewport.Visible = true
		viewport.LayoutOrder = index
		setCountLabel(viewport, count)
	end
end

itemStateRemote.OnClientEvent:Connect(applyState)
