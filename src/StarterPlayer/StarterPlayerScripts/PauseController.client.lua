--!strict
-- PauseController - Client-side pause UI handler
-- Shows/hides level-up GUI and handles player choices

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

-- Pause state
local isPaused = false

-- Track VFX state for pause/unpause
local pausedVFX: {[Instance]: {enabled: boolean, lifetime: number?}} = {}

-- Track paused animation states
local pausedAnimations: {[AnimationTrack]: {
	timePosition: number,
	speed: number,
	isPlaying: boolean,
	weight: number
}} = {}

-- Track paused humanoid state
local pausedHumanoidState = {
	autoRotate = true,
}

-- Forward declare freezePlayer for use in CharacterAdded
local freezePlayer: () -> ()
local startUnfreezeVerification: () -> ()

-- Handle character respawn
player.CharacterAdded:Connect(function(newCharacter)
	character = newCharacter
	humanoid = character:WaitForChild("Humanoid") :: Humanoid
	pausedAnimations = {}  -- Clear animation state on respawn
	pausedVFX = {}  -- Clear VFX state on respawn
	
	-- If game is paused when player respawns, re-freeze
	if isPaused then
		task.wait(0.1)  -- Small delay to let character fully load
		if freezePlayer then
			freezePlayer()
		end
	end
end)

-- Wait for GUI elements
local gameGui = playerGui:WaitForChild("GameGui")
local levelUpFrame = gameGui:WaitForChild("LevelUpFrame")
local titleLabel = levelUpFrame:WaitForChild("TitleLabel")
local timerLabel = levelUpFrame:WaitForChild("TimerLabel")
local secondsLabel = levelUpFrame:WaitForChild("SecondsLabel")
local outerWindow = levelUpFrame:WaitForChild("Window")
local skipButton = outerWindow:WaitForChild("SkipButton")

-- Get inner window (nested Window.Window structure)
local window = outerWindow:WaitForChild("Window")
local choice1 = window:WaitForChild("Choice1")
local choice2 = window:WaitForChild("Choice2")
local choice3 = window:WaitForChild("Choice3")
local choice4 = window:WaitForChild("Choice4")
local choice5 = window:WaitForChild("Choice5")

-- Table of all choices for easy iteration
local choices = {choice1, choice2, choice3, choice4, choice5}

-- Get remote events
local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local GamePaused = remotes:WaitForChild("GamePaused") :: RemoteEvent
local GameUnpaused = remotes:WaitForChild("GameUnpaused") :: RemoteEvent
local RequestUnpause = remotes:WaitForChild("RequestUnpause") :: RemoteEvent

-- Initially hide the level-up frame
levelUpFrame.Visible = false

-- Timer state (for individual pause mode)
local pauseTimeout = 0
local pauseStartTime = 0
local isTimerActive = false

-- Initially hide timer labels
timerLabel.Visible = false
secondsLabel.Visible = false

-- Freeze player (anchor character and freeze animations)
freezePlayer = function()
	if not character or not humanoid then
		return
	end
	
	isPaused = true
	player:SetAttribute("GamePaused", true)
	
	-- Anchor HumanoidRootPart to freeze movement (don't touch walkspeed)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		rootPart.Anchored = true
	end
	
	-- Store and disable humanoid properties to prevent state changes (stops new animations)
	pausedHumanoidState.autoRotate = humanoid.AutoRotate
	humanoid.AutoRotate = false
	
	-- Pause all animations and store their complete state
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		pausedAnimations = {}  -- Clear previous state
		for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
			-- Store complete state including exact time position
			local currentTime = track.TimePosition
			pausedAnimations[track] = {
				timePosition = currentTime,
				speed = track.Speed,
				isPlaying = track.IsPlaying,
				weight = track.WeightCurrent or 1.0
			}
			-- Freeze at current pose by setting speed to 0
			track:AdjustSpeed(0)
			-- Lock the time position to prevent drift
			track.TimePosition = currentTime
		end
	end
	
	-- Pause only THIS player's character VFX (not workspace-wide)
	-- This ensures projectiles and enemies continue moving/animating
	pausedVFX = {}
	
	if character then
		for _, instance in ipairs(character:GetDescendants()) do
			if instance:IsA("ParticleEmitter") then
				if instance.Enabled then
					pausedVFX[instance] = {enabled = true}
					instance.Enabled = false
				end
			elseif instance:IsA("Trail") then
				if instance.Enabled then
					pausedVFX[instance] = {enabled = true, lifetime = instance.Lifetime}
					instance.Enabled = false
				end
			elseif instance:IsA("Beam") then
				if instance.Enabled then
					pausedVFX[instance] = {enabled = true}
					instance.Enabled = false
				end
			end
		end
	end
end

-- Unfreeze player (unanchor character and resume animations)
local function unfreezePlayer()
	if not character or not humanoid then
		return
	end
	
	isPaused = false
	player:SetAttribute("GamePaused", false)
	
	-- Unanchor HumanoidRootPart to restore movement
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		rootPart.Anchored = false
		
		-- AGGRESSIVE IMMEDIATE VERIFICATION (non-blocking)
		-- Force unanchor multiple times to combat network replication
		task.spawn(function()
			for i = 1, 3 do
				task.wait(0.016)  -- Wait 1 frame
				if rootPart and rootPart.Anchored then
					rootPart.Anchored = false
				end
			end
		end)
	end
	
	-- Restore humanoid properties (CRITICAL: Must restore AutoRotate to unlock turning)
	-- Use task.defer to ensure this happens AFTER all unfreeze logic completes
	task.defer(function()
		if not humanoid or not humanoid.Parent then return end
		
		if pausedHumanoidState.autoRotate ~= nil then
			humanoid.AutoRotate = pausedHumanoidState.autoRotate
		else
			humanoid.AutoRotate = true  -- Fallback to default if state wasn't captured
		end
		
		-- Force a second restoration after a short delay to combat queued level-ups
		task.wait(0.1)
		if humanoid and humanoid.Parent then
			humanoid.AutoRotate = true  -- Always ensure AutoRotate is enabled after unpause
		end
	end)
	
	-- Resume all animations from where they were paused
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for track, state in pairs(pausedAnimations) do
			-- Only resume if the track was playing and is still valid
			if state.isPlaying and track.IsPlaying then
				-- Restore exact time position before resuming
				track.TimePosition = state.timePosition
				-- Resume at original speed
				track:AdjustSpeed(state.speed or 1)
			end
		end
		pausedAnimations = {}  -- Clear stored state
	end
	
	-- Resume all VFX (particles, trails, beams)
	for instance, state in pairs(pausedVFX) do
		if instance and instance.Parent then
			if instance:IsA("ParticleEmitter") then
				instance.Enabled = state.enabled
			elseif instance:IsA("Trail") then
				instance.Enabled = state.enabled
				-- Trails don't need lifetime restoration, they'll continue naturally
			elseif instance:IsA("Beam") then
				instance.Enabled = state.enabled
			end
		end
	end
	pausedVFX = {}
	
	-- Start verification system
	startUnfreezeVerification()
end

-- Verification system for unfreezing
local isVerifyingUnfreeze = false
local unfreezeVerifyStartTime = 0
local UNFREEZE_VERIFY_DURATION = 2.0  -- Verify intensely for 2 seconds
local UNFREEZE_VERIFY_INTERVAL_FAST = 0.016  -- Every frame during intense period
local UNFREEZE_VERIFY_INTERVAL_SLOW = 0.5  -- Every 0.5s as ongoing safety net

local function verifyPlayerUnfrozen()
	if isPaused then
		-- Game is paused, don't verify
		isVerifyingUnfreeze = false
		return
	end
	
	if not character or not humanoid then
		return
	end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end
	
	-- Check if rootPart is still anchored when it shouldn't be
	if rootPart.Anchored then
		rootPart.Anchored = false
		
		-- Also re-apply other unfreeze properties (always force true to fix queued level-up bug)
		humanoid.AutoRotate = true  -- Always true to ensure player can turn
	end
end

-- Start verification loop when unpause happens
startUnfreezeVerification = function()
	isVerifyingUnfreeze = true
	unfreezeVerifyStartTime = tick()
end

-- Populate a choice button with upgrade data
local function populateChoice(choiceFrame: Frame, upgradeData: any, index: number)
	local nameLabel = choiceFrame:FindFirstChild("Name")
	local descLabel = choiceFrame:FindFirstChild("Desc")
	local button = choiceFrame:FindFirstChild("Button")
	
	if not upgradeData then
		-- No upgrade for this slot, hide it
		choiceFrame.Visible = false
		return
	end
	
	-- Show and populate
	choiceFrame.Visible = true
	
	-- Extract name and desc (check if data is nested or direct)
	local displayName = upgradeData.name
	local displayDesc = upgradeData.desc
	
	-- If data is nested (structure: {id, abilityId/passiveId, level, data = {name, desc, ...}})
	if upgradeData.data then
		displayName = upgradeData.data.name
		displayDesc = upgradeData.data.desc
	end
	
	if nameLabel then
		nameLabel.Text = displayName or "Unknown"
		
		-- Apply color to name text
		local textColor = Color3.fromRGB(255, 255, 255) -- Default white
		if upgradeData.color then
			textColor = upgradeData.color
		elseif upgradeData.data and upgradeData.data.color then
			textColor = upgradeData.data.color
		end
		nameLabel.TextColor3 = textColor
	end
	
	if descLabel then
		descLabel.Text = displayDesc or ""
	end
	
	-- Store upgrade ID on button for click handler
	if button then
		button:SetAttribute("UpgradeId", upgradeData.id)
		button:SetAttribute("ChoiceIndex", index)
	end
end

-- Handle game pause
GamePaused.OnClientEvent:Connect(function(data: any)
	local reason = data.reason or "unknown"
	local fromLevel = data.fromLevel or 1
	local toLevel = data.toLevel or 2
	local upgradeChoices = data.upgradeChoices or {}
	local timeout = data.timeout or 0
	local showTimer = data.showTimer or false
	
	if reason == "levelup" then
		-- Update title text
		titleLabel.Text = string.format("Level up: %d > %d!", fromLevel, toLevel)
		
		-- Freeze player movement and animations
		freezePlayer()
		
		-- Populate all 5 choice buttons
		for i = 1, 5 do
			local upgradeData = upgradeChoices[i]
			populateChoice(choices[i], upgradeData, i)
		end
		
		-- Setup timer if individual pause mode
		if showTimer and timeout > 0 then
			isTimerActive = true
			pauseTimeout = timeout
			pauseStartTime = tick()
			timerLabel.Text = "Time left to choose an upgrade:"
			timerLabel.Visible = true
			secondsLabel.Visible = true
		else
			isTimerActive = false
			timerLabel.Visible = false
			secondsLabel.Visible = false
		end
		
		-- Show the GUI
		levelUpFrame.Visible = true
	elseif reason == "freeze_only" then
		-- Another player leveled up - freeze this player but don't show GUI
		freezePlayer()
	elseif reason == "death_freeze" then
		-- This player died - freeze without showing GUI (individual pause mode)
		freezePlayer()
	end
end)

-- Debounce variables for rapid freeze/unfreeze prevention
local lastUnfreezeTime = 0
local UNFREEZE_DEBOUNCE = 0.1  -- 100ms debounce to prevent rapid freeze/unfreeze during queued level-ups

-- Handle game unpause
GameUnpaused.OnClientEvent:Connect(function()
	-- Debounce check: ignore rapid unpause requests
	local now = tick()
	if now - lastUnfreezeTime < UNFREEZE_DEBOUNCE then
		warn("[PauseController] Ignoring rapid unpause request (debounced)")
		return
	end
	lastUnfreezeTime = now
	
	-- Stop timer
	isTimerActive = false
	timerLabel.Visible = false
	secondsLabel.Visible = false
	
	-- Unfreeze player movement and animations
	unfreezePlayer()
	
	-- Hide the GUI
	levelUpFrame.Visible = false
end)

-- Continuously maintain frozen animation poses while paused
-- This prevents animations from advancing their timeline during pause
-- Throttled to 20fps for performance
local lastFreezeUpdate = 0
local FREEZE_UPDATE_INTERVAL = 1 / 20  -- 20fps

RunService.RenderStepped:Connect(function()
	if isPaused and character and humanoid then
		-- Throttle to 20fps
		local now = tick()
		if now - lastFreezeUpdate < FREEZE_UPDATE_INTERVAL then
			return
		end
		lastFreezeUpdate = now
		
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			-- Scan ALL currently playing animations every frame
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				-- FREEZE FIRST (before reading position)
				-- This prevents any advancement between frames
				if track.Speed ~= 0 then
					track:AdjustSpeed(0)
				end
				
				-- If this animation isn't frozen yet, capture its CURRENT position
				if not pausedAnimations[track] then
					pausedAnimations[track] = {
						timePosition = track.TimePosition,
						speed = track.Speed,
						isPlaying = true,
						weight = track.WeightCurrent or 1.0
					}
				end
				
				-- Lock at stored position (prevents any drift)
				track.TimePosition = pausedAnimations[track].timePosition
			end
		end
	end
end)

-- Continuous unfreeze verification
RunService.Heartbeat:Connect(function()
	if not isVerifyingUnfreeze then
		return
	end
	
	local now = tick()
	local elapsed = now - unfreezeVerifyStartTime
	
	if elapsed < UNFREEZE_VERIFY_DURATION then
		-- Intense verification for first 2 seconds (every frame)
		verifyPlayerUnfrozen()
	else
		-- After 2 seconds, stop intense verification but keep slow safety net
		isVerifyingUnfreeze = false
	end
end)

-- Slow safety net - always running
local lastSlowVerify = 0
RunService.Heartbeat:Connect(function()
	local now = tick()
	if now - lastSlowVerify >= UNFREEZE_VERIFY_INTERVAL_SLOW then
		lastSlowVerify = now
		verifyPlayerUnfrozen()
	end
end)

-- Skip button handler
skipButton.MouseButton1Click:Connect(function()
	-- Fire request to server
	RequestUnpause:FireServer({
		action = "skip"
	})
end)

-- Wire up all choice buttons
for i, choiceFrame in ipairs(choices) do
	local button = choiceFrame:FindFirstChild("Button")
	if button then
		button.MouseButton1Click:Connect(function()
			local upgradeId = button:GetAttribute("UpgradeId")
			if upgradeId then
				RequestUnpause:FireServer({
					action = "upgrade",
					upgradeId = upgradeId
				})
			end
		end)
	end
end

-- Update timer countdown (for individual pause mode)
RunService.RenderStepped:Connect(function()
	if not isTimerActive then
		return
	end
	
	local elapsed = tick() - pauseStartTime
	local remaining = math.max(0, pauseTimeout - elapsed)
	
	-- Update timer display
	secondsLabel.Text = string.format("%ds", math.ceil(remaining))
	
	-- Timer expired (server will handle auto-selection)
	if remaining <= 0 then
		isTimerActive = false
	end
end)

