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
local reverseStateByTrack: {[AnimationTrack]: boolean} = {}

local BACKWARD_DOT_THRESHOLD = -0.15
local MOVE_DIRECTION_EPSILON = 0.05

local function isMovingBackward(): boolean
	if not character or not humanoid then
		return false
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return false
	end
	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude <= MOVE_DIRECTION_EPSILON then
		return false
	end
	local forward = rootPart.CFrame.LookVector
	return moveDirection:Dot(forward) < BACKWARD_DOT_THRESHOLD
end

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
	local movingBackward = isMovingBackward()
	
	-- Apply to all playing animation tracks
	for _, track in pairs(animator:GetPlayingAnimationTracks()) do
		-- Only adjust movement animations (walk, run, etc.)
		-- Skip idle, jump, fall, etc. by checking the animation name
		local animName = track.Animation.Name:lower()
		local isWalkTrack = animName:find("walk") ~= nil
		local isRunTrack = animName:find("run") ~= nil
		if isWalkTrack or isRunTrack then
			local targetSpeed = animationSpeed
			if isWalkTrack and movingBackward then
				targetSpeed = -animationSpeed
			end

			local wasReversed = reverseStateByTrack[track] == true
			local nowReversed = targetSpeed < 0
			if nowReversed and not wasReversed then
				if track.Length > 0.02 then
					track.TimePosition = math.max(0, track.Length - 0.01)
				end
			elseif (not nowReversed) and wasReversed then
				if track.Length > 0.02 then
					track.TimePosition = math.min(track.TimePosition, track.Length - 0.01)
				end
			end
			reverseStateByTrack[track] = nowReversed
			track:AdjustSpeed(targetSpeed)
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
	table.clear(reverseStateByTrack)
	-- Re-read attribute on respawn
	BASE_ANIMATION_WALKSPEED = player:GetAttribute("BaseAnimationWalkSpeed") or 17
end)
