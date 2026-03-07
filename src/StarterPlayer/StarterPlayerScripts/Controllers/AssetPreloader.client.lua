--!strict
-- AssetPreloader.client.lua
-- Preloads all binary content in ReplicatedStorage.ContentDrawer so that
-- models, textures, VFX, and animations are fully downloaded before first use,
-- eliminating "pop-in" and first-use glitches.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local contentDrawer = ReplicatedStorage:WaitForChild("ContentDrawer", 30)
if not contentDrawer then
	warn("[AssetPreloader] ReplicatedStorage.ContentDrawer not found within 30s — skipping preload")
	return
end

-- Preload a batch of instances (yields until done)
local function preloadDescendants(root: Instance)
	local descendants = root:GetDescendants()
	if #descendants == 0 then return end
	ContentProvider:PreloadAsync(descendants)
end

-- Initial full preload
preloadDescendants(contentDrawer)

if game:GetService("RunService"):IsStudio() then
	print("[AssetPreloader] Initial preload complete")
end

-- Preload any new top-level folders added after the initial pass
-- (e.g. dynamically streamed content groups)
contentDrawer.ChildAdded:Connect(function(child: Instance)
	task.defer(function()
		local descendants = child:GetDescendants()
		if #descendants > 0 then
			ContentProvider:PreloadAsync(descendants)
		end
		ContentProvider:PreloadAsync({ child })
	end)
end)
