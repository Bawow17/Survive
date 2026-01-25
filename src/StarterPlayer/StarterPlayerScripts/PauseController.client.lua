--!strict
-- PauseController - Client-side pause UI handler
-- Shows/hides level-up GUI and handles player choices

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local starterGui = game:GetService("StarterGui")
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
local levelUpToggle = gameGui:FindFirstChild("LevelUpToggle")
if not levelUpToggle then
	local starterGameGui = starterGui:FindFirstChild("GameGui")
	local starterToggle = starterGameGui and starterGameGui:FindFirstChild("LevelUpToggle")
	if starterToggle then
		levelUpToggle = starterToggle:Clone()
		levelUpToggle.Name = "LevelUpToggle"
		levelUpToggle.Parent = gameGui
	end
end
levelUpToggle = levelUpToggle or gameGui:WaitForChild("LevelUpToggle")
local levelUpFrame = gameGui:WaitForChild("LevelUpFrame")
local titleLabel = levelUpFrame:WaitForChild("TitleLabel")
local timerLabel = levelUpFrame:FindFirstChild("TimerLabel")
local secondsLabel = levelUpFrame:FindFirstChild("SecondsLabel")
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

-- Level-up toggle button state (banked hands)
local levelUpToggleTarget = levelUpToggle.Position
local levelUpToggleTween: Tween? = nil
local levelUpToggleVisible = false
local LEVELUP_TOGGLE_DROP_TIME = 0.3

-- Get remote events
local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local GamePaused = remotes:WaitForChild("GamePaused") :: RemoteEvent
local GameUnpaused = remotes:WaitForChild("GameUnpaused") :: RemoteEvent
local RequestUnpause = remotes:WaitForChild("RequestUnpause") :: RemoteEvent
local bankedFolder = remotes:WaitForChild("BankedHands")
local BankedHandsUpdate = bankedFolder:WaitForChild("BankedHandsUpdate") :: RemoteEvent
local BankedHandsShow = bankedFolder:WaitForChild("BankedHandsShow") :: RemoteEvent
local BankedHandsOpen = bankedFolder:WaitForChild("BankedHandsOpen") :: RemoteEvent
local BankedHandsSelect = bankedFolder:WaitForChild("BankedHandsSelect") :: RemoteEvent
local DebugPauseFlag = remotes:FindFirstChild("DebugPause") :: BoolValue
local DebugGrantLevels = remotes:FindFirstChild("DebugGrantLevels") :: RemoteEvent
local debugEnabled = DebugPauseFlag and DebugPauseFlag.Value or false

local currentPauseToken: number? = nil
local debugReproActive = false
local debugReproStartTime = 0
local debugPausedPosition: Vector3? = nil
local debugUnpauseCount = 0
local debugMoveBreaches = 0
local debugLastSpamTime = 0
local debugLastPauseChange = 0
local DEBUG_SPAM_INTERVAL = 0.03

-- Banked hands UI state
local uiMode: string? = nil
local bankedPendingCount = 0
local bankedOpen = false

-- Initially hide the level-up frame
levelUpFrame.Visible = false
levelUpToggle.Visible = false

-- Timer state (for individual pause mode)
local pauseTimeout = 0
local pauseStartTime = 0
local isTimerActive = false

-- Initially hide timer labels
if timerLabel then
	timerLabel.Visible = false
end
if secondsLabel then
	secondsLabel.Visible = false
end

local function setLevelUpToggleVisible(show: boolean, animate: boolean?)
	if show then
		levelUpToggle.Active = true
		levelUpToggle.AutoButtonColor = true
		if levelUpToggleVisible then
			levelUpToggle.Visible = true
			return
		end
		levelUpToggleVisible = true
		levelUpToggle.Visible = true
		
		local dropOffset = levelUpToggle.AbsoluteSize.Y + 12
		local startPos = UDim2.new(
			levelUpToggleTarget.X.Scale,
			levelUpToggleTarget.X.Offset,
			levelUpToggleTarget.Y.Scale,
			levelUpToggleTarget.Y.Offset - dropOffset
		)
		
		if levelUpToggleTween then
			levelUpToggleTween:Cancel()
			levelUpToggleTween = nil
		end
		
		if animate then
			levelUpToggle.Position = startPos
			levelUpToggleTween = TweenService:Create(levelUpToggle, TweenInfo.new(LEVELUP_TOGGLE_DROP_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = levelUpToggleTarget,
			})
			levelUpToggleTween:Play()
		else
			levelUpToggle.Position = levelUpToggleTarget
		end
	else
		levelUpToggle.Active = false
		levelUpToggle.AutoButtonColor = false
		if not levelUpToggleVisible then
			levelUpToggle.Visible = false
			return
		end
		levelUpToggleVisible = false
		if levelUpToggleTween then
			levelUpToggleTween:Cancel()
			levelUpToggleTween = nil
		end
		levelUpToggle.Visible = false
	end
end

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

-- Banked hands updates (no pause)
BankedHandsUpdate.OnClientEvent:Connect(function(data: any)
	local count = data and data.count or 0
	bankedPendingCount = count
	
	if count > 0 then
		setLevelUpToggleVisible(true, not levelUpToggleVisible)
	else
		setLevelUpToggleVisible(false, false)
		if uiMode == "banked" then
			levelUpFrame.Visible = false
			uiMode = nil
		end
		bankedOpen = false
	end
end)

BankedHandsShow.OnClientEvent:Connect(function(data: any)
	if not data then
		return
	end
	
	uiMode = "banked"
	bankedOpen = true
	if typeof(data.pendingCount) == "number" then
		bankedPendingCount = data.pendingCount
	end
	
	local fromLevel = data.fromLevel or 1
	local toLevel = data.toLevel or (fromLevel + 1)
	titleLabel.Text = string.format("Level up: %d > %d!", fromLevel, toLevel)
	
	local choicesData = data.choices or {}
	for i = 1, 5 do
		populateChoice(choices[i], choicesData[i], i)
	end
	
	isTimerActive = false
	if timerLabel then
		timerLabel.Visible = false
	end
	if secondsLabel then
		secondsLabel.Visible = false
	end
	
	levelUpFrame.Visible = true
end)

-- Toggle banked hands menu
levelUpToggle.MouseButton1Click:Connect(function()
	if isPaused then
		return
	end
	if bankedPendingCount <= 0 then
		return
	end
	
	if bankedOpen then
		bankedOpen = false
		if uiMode == "banked" then
			uiMode = nil
			levelUpFrame.Visible = false
		end
		BankedHandsOpen:FireServer({ open = false })
	else
		bankedOpen = true
		BankedHandsOpen:FireServer({ open = true })
	end
end)

-- Handle game pause
GamePaused.OnClientEvent:Connect(function(data: any)
	local reason = data.reason or "unknown"
	local fromLevel = data.fromLevel or 1
	local toLevel = data.toLevel or 2
	local upgradeChoices = data.upgradeChoices or {}
	local timeout = data.timeout or 0
	local showTimer = data.showTimer or false
	currentPauseToken = data.pauseToken
	debugLastPauseChange = tick()
	
	if debugEnabled then
		print(string.format("[PauseController] GamePaused | reason=%s from=%s to=%s token=%s", 
			tostring(reason),
			tostring(fromLevel),
			tostring(toLevel),
			tostring(currentPauseToken)
		))
	end
	
	if reason == "levelup" then
		uiMode = "pause"
		-- Update title text
		titleLabel.Text = string.format("Level up: %d > %d!", fromLevel, toLevel)
		
		-- Freeze player movement and animations
		freezePlayer()
		
		if debugEnabled and character and character.PrimaryPart then
			debugPausedPosition = character.PrimaryPart.Position
		end
		
		-- Populate all 5 choice buttons
		for i = 1, 5 do
			local upgradeData = upgradeChoices[i]
			populateChoice(choices[i], upgradeData, i)
		end
		
		-- Setup timer if individual pause mode
		if showTimer and timeout > 0 and timerLabel and secondsLabel then
			isTimerActive = true
			pauseTimeout = timeout
			pauseStartTime = tick()
			timerLabel.Text = "Time left to choose an upgrade:"
			timerLabel.Visible = true
			secondsLabel.Visible = true
		else
			isTimerActive = false
			if timerLabel then
				timerLabel.Visible = false
			end
			if secondsLabel then
				secondsLabel.Visible = false
			end
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
	debugLastPauseChange = now
	
	if debugEnabled then
		debugUnpauseCount += 1
		print(string.format("[PauseController] GameUnpaused | token=%s count=%d", 
			tostring(currentPauseToken),
			debugUnpauseCount
		))
	end
	currentPauseToken = nil
	debugPausedPosition = nil
	if uiMode == "pause" then
		uiMode = nil
	end
	
	-- Stop timer
	isTimerActive = false
	if timerLabel then
		timerLabel.Visible = false
	end
	if secondsLabel then
		secondsLabel.Visible = false
	end
	
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

-- Debug repro: spam upgrades + verify no movement while paused
RunService.Heartbeat:Connect(function()
	if not debugReproActive then
		return
	end
	
	local now = tick()
	
	if isPaused and currentPauseToken then
		if character and character.PrimaryPart and debugPausedPosition then
			local delta = (character.PrimaryPart.Position - debugPausedPosition).Magnitude
			if delta > 0.5 then
				debugMoveBreaches += 1
				if debugMoveBreaches <= 3 then
					print(string.format("[PauseController] Movement breach during pause | delta=%.2f", delta))
				end
			end
		end
		
		if now - debugLastSpamTime >= DEBUG_SPAM_INTERVAL then
			debugLastSpamTime = now
			
			local selectedUpgradeId: string? = nil
			for _, choiceFrame in ipairs(choices) do
				if choiceFrame.Visible then
					local button = choiceFrame:FindFirstChild("Button")
					if button then
						local upgradeId = button:GetAttribute("UpgradeId")
						if upgradeId then
							selectedUpgradeId = upgradeId
							break
						end
					end
				end
			end
			
			if selectedUpgradeId then
				RequestUnpause:FireServer({
					action = "upgrade",
					upgradeId = selectedUpgradeId,
					pauseToken = currentPauseToken,
				})
			else
				RequestUnpause:FireServer({
					action = "skip",
					pauseToken = currentPauseToken,
				})
			end
		end
	end
	
	if not isPaused and not levelUpFrame.Visible and (now - debugLastPauseChange) > 1.0 then
		stopDebugPauseRepro()
	end
end)

-- Skip button handler
skipButton.MouseButton1Click:Connect(function()
	if uiMode == "banked" then
		BankedHandsSelect:FireServer({
			action = "skip",
		})
		return
	end
	
	-- Fire request to server (pause mode)
	RequestUnpause:FireServer({
		action = "skip",
		pauseToken = currentPauseToken,
	})
	
	if debugEnabled then
		print(string.format("[PauseController] RequestUnpause skip | token=%s", tostring(currentPauseToken)))
	end
end)

-- Wire up all choice buttons
for i, choiceFrame in ipairs(choices) do
	local button = choiceFrame:FindFirstChild("Button")
	if button then
		button.MouseButton1Click:Connect(function()
			local upgradeId = button:GetAttribute("UpgradeId")
			if upgradeId then
				if uiMode == "banked" then
					BankedHandsSelect:FireServer({
						action = "upgrade",
						upgradeId = upgradeId,
					})
					return
				end
				
				RequestUnpause:FireServer({
					action = "upgrade",
					upgradeId = upgradeId,
					pauseToken = currentPauseToken,
				})
				
				if debugEnabled then
					print(string.format("[PauseController] RequestUnpause upgrade | id=%s token=%s", tostring(upgradeId), tostring(currentPauseToken)))
				end
			end
		end)
	end
end

local function startDebugPauseRepro(levels: number)
	if not debugEnabled or not DebugGrantLevels then
		return
	end
	if debugReproActive then
		return
	end
	debugReproActive = true
	debugReproStartTime = tick()
	debugUnpauseCount = 0
	debugMoveBreaches = 0
	debugPausedPosition = nil
	debugLastSpamTime = 0
	debugLastPauseChange = debugReproStartTime
	
	DebugGrantLevels:FireServer({
		levels = levels,
	})
	
	print(string.format("[PauseController] Debug repro started | levels=%d", levels))
end

local function stopDebugPauseRepro()
	if not debugReproActive then
		return
	end
	debugReproActive = false
	
	print(string.format("[PauseController] Debug repro done | duration=%.2fs unpauses=%d movementBreaches=%d",
		tick() - debugReproStartTime,
		debugUnpauseCount,
		debugMoveBreaches
	))
end

if debugEnabled then
	player:GetAttributeChangedSignal("DebugPauseRepro"):Connect(function()
		local value = player:GetAttribute("DebugPauseRepro")
		if value then
			local levels = player:GetAttribute("DebugPauseReproLevels") or 10
			startDebugPauseRepro(levels)
		end
	end)
end

-- Update timer countdown (for individual pause mode)
RunService.RenderStepped:Connect(function()
	if not isTimerActive then
		return
	end
	if not secondsLabel then
		isTimerActive = false
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
