-- AnimationSpeedController.client.lua
-- Scales animation speed based on player walkspeed

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

-- Base walkspeed for 1.0x animation speed (read from server attribute)
local BASE_ANIMATION_WALKSPEED = player:GetAttribute("BaseAnimationWalkSpeed") or 17

-- Get the Animator
local animator = humanoid:WaitForChild("Animator") :: Animator

-- Track playing animation tracks
local animationTracks = {}

-- Update animation speed based on current walkspeed
local function updateAnimationSpeed()
	if not humanoid then return end
	
	-- SKIP if game is paused (let PauseController handle it)
	if player:GetAttribute("GamePaused") then
		return
	end
	
	local currentWalkSpeed = humanoid.WalkSpeed
	local animationSpeed = currentWalkSpeed / BASE_ANIMATION_WALKSPEED
	
	-- Clamp to reasonable values (0.5x to 3x)
	animationSpeed = math.clamp(animationSpeed, 0.5, 3.0)
	
	-- Apply to all playing animation tracks
	for _, track in pairs(animator:GetPlayingAnimationTracks()) do
		-- Only adjust movement animations (walk, run, etc.)
		-- Skip idle, jump, fall, etc. by checking the animation name
		local animName = track.Animation.Name:lower()
		if animName:find("walk") or animName:find("run") then
			track:AdjustSpeed(animationSpeed)
		end
	end
end

-- Update animation speed every frame
RunService.RenderStepped:Connect(function()
	updateAnimationSpeed()
end)

-- Handle character respawning
player.CharacterAdded:Connect(function(newCharacter)
	character = newCharacter
	humanoid = character:WaitForChild("Humanoid") :: Humanoid
	animator = humanoid:WaitForChild("Animator") :: Animator
	table.clear(animationTracks)
	-- Re-read attribute on respawn
	BASE_ANIMATION_WALKSPEED = player:GetAttribute("BaseAnimationWalkSpeed") or 17
end)

