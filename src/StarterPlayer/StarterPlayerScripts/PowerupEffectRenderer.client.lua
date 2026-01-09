--!strict
-- PowerupEffectRenderer - Handles client-side visual effects for powerups
-- Uses HighlightManager for priority-based highlight rendering

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HighlightManager = require(script.Parent.HighlightManager)
local player = Players.LocalPlayer

-- Powerup priority mapping (lower = higher priority)
local POWERUP_PRIORITIES = {
	Health = 1,      -- Instant fade, highest priority
	Magnet = 2,      -- 3s duration
	Nuke = 3,        -- 3s duration
	Cloak = 5,       -- 7s duration
	ArcaneRune = 6,  -- 15s duration
}

-- Start powerup effect
local function startPowerupEffect(powerupData: any)
	local powerupType = powerupData.powerupType
	local duration = powerupData.duration or 0
	local highlightColor = powerupData.highlightColor or Color3.fromRGB(255, 255, 255)
	local charTransparency = powerupData.characterTransparency or 0
	
	-- Health powerup has instant fade (very short duration)
	if powerupType == "Health" then
		duration = 0.5  -- Short duration for fade animation
	end
	
	-- Get priority for this powerup type
	local priority = POWERUP_PRIORITIES[powerupType] or 99
	
	-- Add effect to HighlightManager
	HighlightManager.addEffect(powerupType, priority, duration, highlightColor, charTransparency)
end

-- Listen for powerup effect updates from server
local powerupEffectUpdate = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("PowerupEffectUpdate")
powerupEffectUpdate.OnClientEvent:Connect(startPowerupEffect)

-- Handle pause/unpause events
local gamePaused = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("GamePaused")
local gameUnpaused = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("GameUnpaused")

gamePaused.OnClientEvent:Connect(function()
	HighlightManager.onPause()
end)

gameUnpaused.OnClientEvent:Connect(function()
	HighlightManager.onUnpause()
end)

-- Handle character respawn
player.CharacterAdded:Connect(function(character)
	HighlightManager.onCharacterAdded(character)
end)

