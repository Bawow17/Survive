--!strict
-- AbilityAnimationController - Manages ability cast animations with priority system
-- Handles looping animations per projectile with frame-based loop points

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer

-- Animation state
local currentAnimation: AnimationTrack? = nil
local currentAnimationPriority: number = 999  -- Lower is higher priority
local currentAbilityId: string? = nil
local currentCastId: number = 0  -- Unique ID for each cast instance
local isAnimating = false
local isPlayingSegment = false  -- True while an animation segment is actively playing

-- Rapid-fire tracking per ability
local lastAnimationEndTime: {[string]: number} = {}  -- Track when animation sequence ended per ability
local lastAnimationType: {[string]: string} = {}  -- Track last animation played (loop/last) for alternation

-- Animation instance cache
local animationCache: {[string]: Animation} = {}
local loadedTracks: {[string]: AnimationTrack} = {}

-- Pause state
local isPaused = false

-- Animation speed cap (prevents animations from looking too fast)
local MAX_ANIMATION_SPEED = 3.8  -- Cap at 3.8x speed for natural look
local MAX_ANIMATION_LOOPS = 7  -- Max number of animations to play per cast

-- Get humanoid and animator
local function getAnimator(): Animator?
	local character = localPlayer.Character
	if not character then
		return nil
	end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	
	local animator = humanoid:FindFirstChildOfClass("Animator")
	return animator
end

-- Load animation instance (cached)
local function loadAnimation(animId: string): AnimationTrack?
	local animator = getAnimator()
	if not animator then
		return nil
	end
	
	-- Check if animId is empty or invalid
	if not animId or animId == "" or animId == "rbxassetid://" then
		return nil
	end
	
	-- Return cached track if it exists
	if loadedTracks[animId] then
		return loadedTracks[animId]
	end
	
	-- Create new animation instance
	local anim: Animation
	if animationCache[animId] then
		anim = animationCache[animId]
	else
		anim = Instance.new("Animation")
		anim.AnimationId = animId
		animationCache[animId] = anim
	end
	
	-- Load and cache track
	local track = animator:LoadAnimation(anim)
	loadedTracks[animId] = track
	return track
end

-- Calculate animation priority based on damage stats
local function calculatePriority(abilityId: string, damageStats: {[string]: number}): number
	if not damageStats or typeof(damageStats) ~= "table" then
		return 2  -- Default low priority
	end
	
	-- Find ability with highest damage
	local maxDamage = 0
	local topAbility: string? = nil
	
	for ability, damage in pairs(damageStats) do
		if damage > maxDamage then
			maxDamage = damage
			topAbility = ability
		end
	end
	
	-- Return priority: 1 (highest) if this ability leads, else 2
	return (topAbility == abilityId) and 1 or 2
end

-- Play a single animation segment
local function playAnimationSegment(
	abilityId: string,
	animType: "first" | "loop" | "last",
	pulseInterval: number,
	isFinal: boolean,
	animationData: any,
	isSingleProjectileFastCooldown: boolean?
): boolean
	if not animationData then
		return false
	end
	
	-- Get animation ID from server-provided data
	local animId = animationData.animationIds and animationData.animationIds[animType]
	if not animId or animId == "" or animId == "rbxassetid://" then
		return false
	end
	
	local track = loadAnimation(animId)
	if not track then
		return false
	end
	
	-- Calculate animation speed based on whether it needs to fit in pulseInterval
	local speedScale = 1.0
	local waitTime = animationData.duration
	
	if isFinal then
		-- Final animation always plays at normal speed with full winddown
		speedScale = 1.0
		waitTime = animationData.duration
	elseif isSingleProjectileFastCooldown and animationData.cooldownDuration then
		-- Single-projectile fast cooldown: speed up to fit within cooldown
		local frameRatio = animationData.loopFrame / animationData.totalFrames
		local naturalLoopTime = animationData.duration * frameRatio
		
		-- Speed up animation to fit in cooldown duration
		local uncappedSpeed = naturalLoopTime / animationData.cooldownDuration
		speedScale = math.min(uncappedSpeed, MAX_ANIMATION_SPEED)
		
		-- Wait for cooldown duration (animation will be sped up to fit)
		waitTime = animationData.cooldownDuration
	else
		-- For non-final animations (first and loop), check if we need to speed up
		-- Natural time to loop frame (where animation would be cut)
		local frameRatio = animationData.loopFrame / animationData.totalFrames
		local naturalLoopTime = animationData.duration * frameRatio
		
		-- Only speed up if pulse interval is shorter than natural loop time
		-- Server already handles anticipation delay, so use pulse interval directly
		if pulseInterval > 0.01 and pulseInterval < naturalLoopTime then
			-- Speed up so animation reaches loop frame exactly at pulseInterval
			local uncappedSpeed = naturalLoopTime / pulseInterval
			speedScale = math.min(uncappedSpeed, MAX_ANIMATION_SPEED)  -- Cap at max speed
			
			-- Recalculate wait time based on CAPPED speed (not pulse interval)
			-- This ensures animation actually has time to play at the capped speed
			waitTime = naturalLoopTime / speedScale
		else
			-- Play at normal speed, stop at loop frame naturally
			speedScale = 1.0
			waitTime = naturalLoopTime
		end
	end
	
	-- Play animation
	track.Priority = animationData.animationPriority
	track:Play()
	track:AdjustSpeed(speedScale)
	
	currentAnimation = track
	isPlayingSegment = true
	
	-- Wait for animation to complete (pause-aware)
	local elapsedTime = 0
	while elapsedTime < waitTime do
		if isPaused then
			-- Don't count time while paused
			task.wait(0.1)
		else
			local dt = task.wait()
			elapsedTime = elapsedTime + dt
		end
	end
	
	isPlayingSegment = false
	
	if currentAnimation == track then
		track:Stop()
	end
	
	return true
end

-- Play ability cast animation sequence
local function playAbilityCast(
	abilityId: string,
	projectileCount: number,
	pulseInterval: number,
	damageStats: {[string]: number},
	animationData: any,
	skipFirstAnimation: boolean?
)
	-- Skip entirely if no animation data or no valid animation IDs
	if not animationData or not animationData.animationIds then
		return
	end
	
	-- Check if at least one animation ID is valid
	local hasValidAnimation = false
	for _, animId in pairs(animationData.animationIds) do
		if animId and animId ~= "" and animId ~= "rbxassetid://" then
			hasValidAnimation = true
			break
		end
	end
	
	if not hasValidAnimation then
		return
	end
	
	-- Calculate priority
	local priority = calculatePriority(abilityId, damageStats)
	
	-- Check if this is a rapid-fire recast
	-- Rapid-fire = casting while same ability's animation is CURRENTLY still playing
	-- Only skip first animation if the same ability is currently mid-animation sequence
	if isAnimating and currentAbilityId == abilityId then
		skipFirstAnimation = true  -- Skip animation 1 for rapid-fire
	end
	
	-- Check if we should interrupt current animation
	if isAnimating then
		if priority > currentAnimationPriority then
			-- Lower priority, don't interrupt
			return
		elseif priority < currentAnimationPriority then
			-- Higher priority, wait for current segment to finish, then interrupt
			while isPlayingSegment do
				task.wait(0.01)
			end
			if currentAnimation then
				currentAnimation:Stop()
				currentAnimation = nil
			end
		elseif abilityId == currentAbilityId then
			-- Same ability recasting, wait for current segment to finish, then interrupt
			while isPlayingSegment do
				task.wait(0.01)
			end
			if currentAnimation then
				currentAnimation:Stop()
				currentAnimation = nil
			end
		else
			-- Same priority but different ability, don't interrupt
			return
		end
	end
	
	-- Set animation state
	isAnimating = true
	currentAnimationPriority = priority
	currentAbilityId = abilityId
	currentCastId = currentCastId + 1  -- Increment for unique cast tracking
	local thisCastId = currentCastId  -- Capture for this coroutine
	
	-- Spawn animation coroutine
	task.spawn(function()
		-- Don't animate if no projectiles
		if projectileCount <= 0 then
			isAnimating = false
			currentAnimation = nil
			return
		end
		
		-- Cap animation loops to prevent spam on high projectile counts
		local cappedCount = math.min(projectileCount, MAX_ANIMATION_LOOPS)
		
		-- Check if this is a single-projectile ability with fast cooldown
		-- If cooldown is shorter than animation, just replay "first" animation
		local isSingleProjectileFastCooldown = false
		if projectileCount == 1 and animationData.cooldownDuration then
			-- Calculate natural animation duration
			local frameRatio = animationData.loopFrame / animationData.totalFrames
			local naturalAnimDuration = animationData.duration * frameRatio
			
			-- If cooldown is shorter than animation, use simple replay
			if animationData.cooldownDuration < naturalAnimDuration then
				isSingleProjectileFastCooldown = true
				-- Clear any previous animation type tracking to ensure "first" always plays
				lastAnimationType[abilityId] = nil
			end
		end
		
		-- Play animation sequence for each projectile
		-- Animation pattern: 1 (first), then alternating 2/3 (loop/last)
		-- When skipping first, offset the pattern but still play same number of animations
		-- EXCEPTION: Single-projectile fast-cooldown abilities always play "first"
		for i = 1, cappedCount do
			-- Check if this cast was interrupted (castId changed means new cast started)
			if currentCastId ~= thisCastId then
				-- This cast was interrupted by a newer cast, stop immediately
				break
			end
			
			-- Wait if paused
			while isPaused do
				task.wait(0.1)
			end
			
			-- Check if this cast was interrupted before determining animation
			if currentCastId ~= thisCastId then
				break  -- Stop immediately if interrupted
			end
			
			-- Determine animation type - simple alternation logic
			local animType: "first" | "loop" | "last"
			
			-- SPECIAL CASE: Single-projectile abilities
			-- Always replay "first" animation for consistency (no loop/last alternation)
			if projectileCount == 1 then
				animType = "first"
			elseif i == 1 and not skipFirstAnimation then
				-- Very first animation: always "first"
				animType = "first"
			else
				-- All other animations: alternate from last played (for multi-projectile)
				local lastType = lastAnimationType[abilityId]
				
				if lastType == "loop" then
					animType = "last"  -- Last was loop → play last
				else
					-- lastType was "last" or "first" (or nil)
					animType = "loop"  -- Play loop
				end
			end
			
			-- During rapid-fire, don't treat as final (keep speed up for smooth flow)
			-- Only play final winddown if this is the last animation AND not in rapid-fire
			-- NEVER treat as final for single-projectile fast cooldown (always same animation)
			local isFinalAnimation = (i == cappedCount) and not skipFirstAnimation and not isSingleProjectileFastCooldown
			
			-- Play animation segment
			local success = playAnimationSegment(abilityId, animType, pulseInterval, isFinalAnimation, animationData, isSingleProjectileFastCooldown)
			if not success then
				break
			end
			
			-- Only update lastAnimationType if this cast is still active (not interrupted)
			-- Don't update for single-projectile abilities (always plays "first")
			if currentCastId == thisCastId and projectileCount > 1 then
				lastAnimationType[abilityId] = animType
			end
		end
		
		-- Track when this ability's animation finished
		lastAnimationEndTime[abilityId] = tick()
		
		-- Clear animation state only if this is still the current cast
		if currentCastId == thisCastId then
			isAnimating = false
			currentAnimation = nil
			currentAbilityId = nil
		end
	end)
end

-- Listen for ability cast events
local abilityCastRemote = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("AbilityCast")

abilityCastRemote.OnClientEvent:Connect(function(abilityId: string, cooldownDuration: number, abilityName: string?, castData: any?)
	-- Validate cast data
	if not castData or typeof(castData) ~= "table" then
		return
	end
	
	local projectileCount = castData.projectileCount or 1
	local pulseInterval = castData.pulseInterval or 0
	local damageStats = castData.damageStats or {}
	local animationData = castData.animationData  -- Server-provided animation config (secure)
	
	-- Only animate if server provided animation data
	if not animationData then
		return
	end
	
	if not animationData.animationIds then
		return
	end
	
	-- Store cooldown duration in animation data for single-projectile logic
	animationData.cooldownDuration = cooldownDuration
	
	-- Play animation (skipFirstAnimation handled internally based on interruption)
	playAbilityCast(abilityId, projectileCount, pulseInterval, damageStats, animationData, false)
end)

-- Handle pause/unpause
local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local gamePaused = remotes:WaitForChild("GamePaused")
local gameUnpaused = remotes:WaitForChild("GameUnpaused")

gamePaused.OnClientEvent:Connect(function()
	isPaused = true
	-- Don't touch animations - PauseController handles all animation freezing
	-- Just set the flag so the animation sequence waits
end)

gameUnpaused.OnClientEvent:Connect(function()
	isPaused = false
	-- Don't touch animations - PauseController handles all animation resuming
end)

-- Handle character respawn
localPlayer.CharacterAdded:Connect(function(character)
	-- Clear animation state
	isAnimating = false
	currentAnimation = nil
	currentAnimationPriority = 999
	currentAbilityId = nil
	
	-- Clear cached tracks (new character = new animator)
	table.clear(loadedTracks)
	
	-- Wait for humanoid and animator
	character:WaitForChild("Humanoid")
end)

