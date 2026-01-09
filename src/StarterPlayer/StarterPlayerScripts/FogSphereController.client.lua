--!strict
-- FogSphereController - Makes inverted sphere fog follow player at 5fps
-- Each player sees their own fog sphere only

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

-- Get the fog sphere template
local fogTemplate = ReplicatedStorage:WaitForChild("ContentDrawer"):WaitForChild("World"):WaitForChild("InvertedSphere")

-- Clone and set up the fog sphere
local fogSphere = fogTemplate:Clone()
fogSphere.CanCollide = false
fogSphere.Anchored = true
fogSphere.CastShadow = false
fogSphere.CanQuery = false
fogSphere.Parent = workspace

-- 5fps = 0.2 seconds per update
local UPDATE_INTERVAL = 0.2
local timeSinceLastUpdate = 0

-- Update fog position
local function updateFogPosition()
	local character = player.Character
	if character and character.PrimaryPart then
		fogSphere.Position = character.PrimaryPart.Position
	end
end

-- Initial position
updateFogPosition()

-- Update at 5fps
RunService.Heartbeat:Connect(function(dt)
	timeSinceLastUpdate = timeSinceLastUpdate + dt
	
	if timeSinceLastUpdate >= UPDATE_INTERVAL then
		timeSinceLastUpdate = 0
		updateFogPosition()
	end
end)

-- Handle character respawn
player.CharacterAdded:Connect(function(character)
	character:WaitForChild("HumanoidRootPart")
	updateFogPosition()
end)

