--!strict
-- StatusEffectController - Client-side visual effects for status buffs
-- Uses HighlightManager for priority-based highlight rendering

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HighlightManager = require(script.Parent.HighlightManager)
local player = Players.LocalPlayer

-- Remote for status effect updates
local StatusEffectUpdate: RemoteEvent = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("StatusEffectUpdate")

-- Priority for level-up invincibility highlight
local LEVELUP_PRIORITY = 4

-- Track if invincibility is currently active
local isInvincible = false

-- Apply invincibility visual effects
local function applyInvincibilityVisuals(character: Model, duration: number)
	if not character then
		return
	end
	
	-- Add invincibility effect to HighlightManager
	-- White color, 0.5 character transparency, use actual duration from server
	HighlightManager.addEffect(
		"Invincibility",
		LEVELUP_PRIORITY,
		duration,  -- Use actual duration from server
		Color3.new(1, 1, 1),  -- White
		0.5  -- Character transparency
	)
	
	isInvincible = true
end

-- Remove invincibility visual effects
local function removeInvincibilityVisuals()
	-- Remove effect from HighlightManager
	HighlightManager.removeEffect("Invincibility")
	isInvincible = false
end

-- Handle status effect updates from server
local function onStatusEffectUpdate(effects: {invincible: boolean, invincibleDuration: number?, speedBoost: number})
	local character = player.Character
	if not character then
		return
	end
	
	-- Handle invincibility visuals
	if effects.invincible and not isInvincible then
		-- Start invincibility visuals with actual duration from server
		local duration = effects.invincibleDuration or 2.0  -- Fallback to 2s if not provided
		applyInvincibilityVisuals(character, duration)
	elseif not effects.invincible and isInvincible then
		-- End invincibility visuals
		removeInvincibilityVisuals()
	end
end

-- Listen to status effect updates
StatusEffectUpdate.OnClientEvent:Connect(onStatusEffectUpdate)

-- Handle character respawn/swap
local function onCharacterAdded(character: Model)
	-- Reset invincibility tracking
	isInvincible = false
	
	-- Wait for character to be fully loaded
	character:WaitForChild("HumanoidRootPart")
	
	-- Request current status from server (in case effects were active)
	-- The server will broadcast current state on next update
end

-- Set up character change handler
if player.Character then
	onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(function(character)
	onCharacterAdded(character)
	-- Notify HighlightManager of character change
	HighlightManager.onCharacterAdded(character)
end)

-- Clean up on player removal
Players.PlayerRemoving:Connect(function(removingPlayer)
	if removingPlayer == player then
		removeInvincibilityVisuals()
	end
end)

