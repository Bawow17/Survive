--!strict
-- AbilityAnimationController - Manages ability cast animations with priority system
-- Handles looping animations per projectile with frame-based loop points

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local ATTR_LOCAL_RANGED_AIM_ACTIVE = "AbilityRangedAimActiveLocal"
local ATTR_LOCAL_ABILITY_CAST_ACTIVE = "AbilityCastActiveLocal"
local RANGED_VERTICAL_AIM_PROFILE = "ranged_left_head"
local ICE_SHARD_LOCKED_ABILITIES: {[string]: boolean} = {
	IceShard = true,
}

-- Animation state
local currentAnimation: AnimationTrack? = nil
local currentAnimationPriority: number = 999  -- Lower is higher priority
local currentAbilityId: string? = nil
local currentCastId: number = 0  -- Unique ID for each cast instance
local isAnimating = false
local isPlayingSegment = false  -- True while an animation segment is actively playing
local rangedAimActiveCastId: number? = nil
local abilityCastActiveCastId: number? = nil

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
local LAST_SEGMENT_SLOW_FACTOR = 0.4  -- Slow the final segment, speed others up to keep total time
local ICE_SHARD_PLAY_FADE = 0.03
local ICE_SHARD_PLAY_WEIGHT = 5.0
local animationSourceIdCache: {[string]: {[string]: string}} = {}
local warnedMissingAnimationSource: {[string]: boolean} = {}
local warnedInvalidAnimationSource: {[string]: boolean} = {}

local function normalizeAnimationId(rawId: any): string?
	if typeof(rawId) == "number" then
		if rawId <= 0 then
			return nil
		end
		return "rbxassetid://" .. tostring(math.floor(rawId))
	end
	if typeof(rawId) ~= "string" then
		return nil
	end

	local trimmed = string.gsub(rawId, "^%s*(.-)%s*$", "%1")
	if trimmed == "" then
		return nil
	end
	if string.find(trimmed, "rbxassetid://", 1, true) == 1 then
		return trimmed
	end
	if string.match(trimmed, "^%d+$") then
		return "rbxassetid://" .. trimmed
	end
	return nil
end

local function resolveAnimationIdFromInstance(source: Instance?): string?
	if not source then
		return nil
	end
	if source:IsA("Animation") then
		return normalizeAnimationId(source.AnimationId)
	end
	if source:IsA("StringValue") then
		return normalizeAnimationId(source.Value)
	end
	if source:IsA("NumberValue") then
		return normalizeAnimationId(source.Value)
	end
	return nil
end

local function findInstanceByDotPath(path: string): Instance?
	if typeof(path) ~= "string" or path == "" then
		return nil
	end

	local parts = string.split(path, ".")
	local current: Instance? = game
	local startIndex = 1
	if parts[1] == "game" then
		startIndex = 2
	elseif parts[1] == "ReplicatedStorage" then
		current = ReplicatedStorage
		startIndex = 2
	elseif parts[1] == "Workspace" then
		current = game:GetService("Workspace")
		startIndex = 2
	end

	for i = startIndex, #parts do
		if not current then
			return nil
		end
		current = current:FindFirstChild(parts[i])
	end
	return current
end

local function classifyAnimationSlot(name: string): string?
	local lowered = string.lower(name)
	if lowered == "first" or lowered == "start" then
		return "first"
	end
	if lowered == "loop" or lowered == "middle" then
		return "loop"
	end
	if lowered == "last" or lowered == "end" then
		return "last"
	end
	return nil
end

local function resolveAnimationIdsFromSourcePath(sourcePath: string): {[string]: string}?
	local cached = animationSourceIdCache[sourcePath]
	if cached then
		return cached
	end

	local source = findInstanceByDotPath(sourcePath)
	if not source then
		if not warnedMissingAnimationSource[sourcePath] then
			warn(string.format("[AbilityAnimationController] Animation source not found: %s", sourcePath))
			warnedMissingAnimationSource[sourcePath] = true
		end
		return nil
	end

	local firstSource: Instance? = nil
	local loopSource: Instance? = nil
	local lastSource: Instance? = nil
	local allSources: {Instance} = {}

	local function addCandidate(candidate: Instance)
		if not (candidate:IsA("Animation") or candidate:IsA("StringValue") or candidate:IsA("NumberValue")) then
			return
		end
		table.insert(allSources, candidate)

		local slot = classifyAnimationSlot(candidate.Name)
		if slot == "first" then
			firstSource = firstSource or candidate
		elseif slot == "loop" then
			loopSource = loopSource or candidate
		elseif slot == "last" then
			lastSource = lastSource or candidate
		end
	end

	addCandidate(source)
	for _, desc in ipairs(source:GetDescendants()) do
		addCandidate(desc)
	end

	table.sort(allSources, function(a: Instance, b: Instance)
		return a:GetFullName() < b:GetFullName()
	end)

	local firstId = resolveAnimationIdFromInstance(firstSource or allSources[1])
	local loopId = resolveAnimationIdFromInstance(loopSource or allSources[2]) or firstId
	local lastId = resolveAnimationIdFromInstance(lastSource or allSources[3]) or loopId or firstId
	if not firstId and not loopId and not lastId then
		if not warnedInvalidAnimationSource[sourcePath] then
			warn(string.format("[AbilityAnimationController] No valid animation ids in source: %s", sourcePath))
			warnedInvalidAnimationSource[sourcePath] = true
		end
		return nil
	end

	local resolved = {
		first = firstId or loopId or lastId,
		loop = loopId or firstId or lastId,
		last = lastId or loopId or firstId,
	}
	animationSourceIdCache[sourcePath] = resolved
	return resolved
end

local function resolveAnimationData(animationData: any): any?
	if typeof(animationData) ~= "table" then
		return nil
	end

	if typeof(animationData.animationIds) ~= "table" then
		animationData.animationIds = {}
	end
	local animationIds = animationData.animationIds
	animationIds.first = normalizeAnimationId(animationIds.first)
	animationIds.loop = normalizeAnimationId(animationIds.loop)
	animationIds.last = normalizeAnimationId(animationIds.last)

	local sourcePath = if typeof(animationData.sourcePath) == "string" then animationData.sourcePath else nil
	if sourcePath then
		local sourceIds = resolveAnimationIdsFromSourcePath(sourcePath)
		if sourceIds then
			animationIds.first = animationIds.first or sourceIds.first
			animationIds.loop = animationIds.loop or sourceIds.loop
			animationIds.last = animationIds.last or sourceIds.last
		end
	end

	local hasAny = false
	for _, key in ipairs({"first", "loop", "last"}) do
		local value = animationIds[key]
		if value and value ~= "" and value ~= "rbxassetid://" then
			hasAny = true
			break
		end
	end
	if not hasAny then
		return nil
	end

	return animationData
end

local function setRangedAimActive(active: boolean)
	local character = localPlayer.Character
	if not character then
		return
	end
	character:SetAttribute(ATTR_LOCAL_RANGED_AIM_ACTIVE, active)
end

local function setAbilityCastActive(active: boolean)
	local character = localPlayer.Character
	if not character then
		return
	end
	character:SetAttribute(ATTR_LOCAL_ABILITY_CAST_ACTIVE, active)
end

local function isIceShardLockedAbility(abilityId: string?): boolean
	return abilityId ~= nil and ICE_SHARD_LOCKED_ABILITIES[abilityId] == true
end

local function clearRangedAimForCast(castId: number)
	if rangedAimActiveCastId ~= castId then
		return
	end
	rangedAimActiveCastId = nil
	setRangedAimActive(false)
end

local function clearAbilityCastForCast(castId: number)
	if abilityCastActiveCastId ~= castId then
		return
	end
	abilityCastActiveCastId = nil
	setAbilityCastActive(false)
end

local function startRangedAimForCast(castId: number, verticalAimProfile: string?)
	if verticalAimProfile ~= RANGED_VERTICAL_AIM_PROFILE then
		if rangedAimActiveCastId ~= nil then
			rangedAimActiveCastId = nil
			setRangedAimActive(false)
		end
		return
	end

	rangedAimActiveCastId = castId
	setRangedAimActive(true)
end

local function startAbilityCastForCast(castId: number)
	abilityCastActiveCastId = castId
	setAbilityCastActive(true)
end

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
	if abilityId == "TempusGelidum" then
		return 0
	end

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
	isSingleProjectileFastCooldown: boolean?,
	targetDuration: number?
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
	
	-- Calculate animation speed based on whether it needs to fit in pulseInterval / targetDuration
	local speedScale = 1.0
	local waitTime = animationData.duration
	local frameRatio = animationData.loopFrame / animationData.totalFrames
	local naturalLoopTime = animationData.duration * frameRatio
	local naturalTime = isFinal and animationData.duration or naturalLoopTime

	if targetDuration and targetDuration > 0 then
		if targetDuration < naturalTime then
			local uncappedSpeed = naturalTime / targetDuration
			speedScale = math.min(uncappedSpeed, MAX_ANIMATION_SPEED)
			waitTime = naturalTime / speedScale
		else
			speedScale = 1.0
			waitTime = naturalTime
		end
	elseif isFinal then
		-- Final animation plays full duration at normal speed when no target duration is provided
		speedScale = 1.0
		waitTime = animationData.duration
	elseif isSingleProjectileFastCooldown and typeof(animationData.cooldownDuration) == "number" and animationData.cooldownDuration > 0 then
		-- Single-projectile fast cooldown: speed up to fit within cooldown
		local uncappedSpeed = naturalLoopTime / animationData.cooldownDuration
		speedScale = math.min(uncappedSpeed, MAX_ANIMATION_SPEED)
		waitTime = animationData.cooldownDuration
	else
		-- For non-final animations (first and loop), check if we need to speed up
		if pulseInterval > 0.01 and pulseInterval < naturalLoopTime then
			local uncappedSpeed = naturalLoopTime / pulseInterval
			speedScale = math.min(uncappedSpeed, MAX_ANIMATION_SPEED)
			waitTime = naturalLoopTime / speedScale
		else
			speedScale = 1.0
			waitTime = naturalLoopTime
		end
	end
	
	-- Play animation
	if isIceShardLockedAbility(abilityId) then
		-- Force top-priority + heavier blend weight so left-arm keys win over
		-- same-priority action tracks without suppressing whole-body animation.
		track.Priority = Enum.AnimationPriority.Action4
	else
		track.Priority = animationData.animationPriority
	end
	currentAnimation = track
	if isIceShardLockedAbility(abilityId) then
		track:Play(ICE_SHARD_PLAY_FADE, ICE_SHARD_PLAY_WEIGHT, 1)
	else
		track:Play()
	end
	track:AdjustSpeed(speedScale)
	
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
	skipFirstAnimation: boolean?,
	verticalAimProfile: string?
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
		if currentAbilityId == "TempusGelidum" and abilityId ~= "TempusGelidum" then
			-- Ultimate cast owns the animation channel while active.
			return
		end
		if isIceShardLockedAbility(currentAbilityId) and abilityId ~= currentAbilityId then
			-- IceShard cast owns left-arm action channel while active.
			return
		end
		if isIceShardLockedAbility(abilityId) and abilityId ~= currentAbilityId then
			-- IceShard should replace any currently playing action animation.
			while isPlayingSegment do
				task.wait(0.01)
			end
			if currentAnimation then
				currentAnimation:Stop()
				currentAnimation = nil
			end
		end

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
	startAbilityCastForCast(thisCastId)
	startRangedAimForCast(thisCastId, verticalAimProfile)
	
	-- Spawn animation coroutine
	task.spawn(function()
		-- Don't animate if no projectiles
		if projectileCount <= 0 then
			clearAbilityCastForCast(thisCastId)
			clearRangedAimForCast(thisCastId)
			isAnimating = false
			currentAnimation = nil
			return
		end
		
		-- Cap animation loops to prevent spam on high projectile counts
		local cappedCount = math.min(projectileCount, MAX_ANIMATION_LOOPS)
		local anticipation = (animationData and typeof(animationData.anticipation) == "number") and animationData.anticipation or 0
		local basePulseInterval = pulseInterval
		if projectileCount <= 1 then
			basePulseInterval = 0
		end
		local totalSchedule = 0
		local elapsedSchedule = 0
		local segmentIntervals = table.create(cappedCount)

		-- Check if this is a single-projectile ability with fast cooldown
		-- If cooldown is shorter than animation, just replay "first" animation
		local isSingleProjectileFastCooldown = false
		if projectileCount == 1 and typeof(animationData.cooldownDuration) == "number" and animationData.cooldownDuration > 0 then
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
		
		-- Compute intended total schedule length for this cast
		for i = 1, cappedCount do
			local segmentInterval = basePulseInterval
			if i == 1 and not skipFirstAnimation and projectileCount > 1 and anticipation > segmentInterval then
				segmentInterval = anticipation
			end
			segmentIntervals[i] = segmentInterval
			if segmentInterval > 0 then
				totalSchedule += segmentInterval
			end
		end
		
		local totalTarget = (animationData and animationData.cooldownDuration) or 0
		local scheduleScale = 1.0
		if totalTarget > 0 and totalSchedule > 0 and totalTarget < totalSchedule then
			scheduleScale = totalTarget / totalSchedule
		end
		
		-- Scale all segments to fit within cooldown (if needed)
		if scheduleScale ~= 1 then
			for i = 1, cappedCount do
				local interval = segmentIntervals[i] or 0
				if interval > 0 then
					segmentIntervals[i] = interval * scheduleScale
				end
			end
		end
		
		-- Bias: speed up all but the last segment, slow the last slightly (total time unchanged)
		if cappedCount > 1 and LAST_SEGMENT_SLOW_FACTOR > 0 then
			local totalScaled = 0
			for i = 1, cappedCount do
				totalScaled += segmentIntervals[i] or 0
			end
			local lastBase = segmentIntervals[cappedCount] or 0
			local remainingTotal = totalScaled - lastBase
			if totalScaled > 0 and remainingTotal > 0 and lastBase > 0 then
				local desiredLast = lastBase * (1 + LAST_SEGMENT_SLOW_FACTOR)
				if desiredLast >= totalScaled then
					desiredLast = totalScaled * 0.95
				end
				local scaleOthers = (totalScaled - desiredLast) / remainingTotal
				if scaleOthers < 0 then
					scaleOthers = 0
				end
				for i = 1, cappedCount - 1 do
					segmentIntervals[i] = (segmentIntervals[i] or 0) * scaleOthers
				end
				segmentIntervals[cappedCount] = desiredLast
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
			-- Only skip final winddown for single-projectile fast cooldown (always same animation)
			local isFinalAnimation = (i == cappedCount) and not isSingleProjectileFastCooldown
			
			-- Play animation segment
			local segmentInterval = segmentIntervals[i] or basePulseInterval
			local targetDuration: number? = nil
			if segmentInterval > 0 then
				targetDuration = segmentInterval
			end
			local success = playAnimationSegment(abilityId, animType, segmentInterval, isFinalAnimation, animationData, isSingleProjectileFastCooldown, targetDuration)
			if not success then
				break
			end
			
			-- Only update lastAnimationType if this cast is still active (not interrupted)
			-- Don't update for single-projectile abilities (always plays "first")
			if currentCastId == thisCastId and projectileCount > 1 then
				lastAnimationType[abilityId] = animType
			end

			if segmentInterval > 0 then
				elapsedSchedule += segmentInterval
			end
		end
		
		-- Track when this ability's animation finished
		lastAnimationEndTime[abilityId] = tick()
		clearAbilityCastForCast(thisCastId)
		clearRangedAimForCast(thisCastId)
		
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
		if abilityId == "TempusGelidum" then
			warn("[AbilityAnimationController] Tempus cast missing castData")
		end
		return
	end
	
	local projectileCount = castData.projectileCount or 1
	local pulseInterval = castData.pulseInterval or 0
	local damageStats = castData.damageStats or {}
	local animationData = castData.animationData  -- Server-provided animation config (secure)
	local verticalAimProfile = if typeof(castData.verticalAimProfile) == "string" then castData.verticalAimProfile else nil
	
	-- Only animate if server provided animation data
	if not animationData then
		if abilityId == "TempusGelidum" then
			warn("[AbilityAnimationController] Tempus cast missing animationData")
		end
		return
	end

	animationData = resolveAnimationData(animationData)
	if not animationData then
		if abilityId == "TempusGelidum" then
			warn("[AbilityAnimationController] Tempus cast has no playable animation ids (after sourcePath resolution)")
		end
		return
	end
	
	-- Store cooldown duration in animation data for single-projectile logic
	animationData.cooldownDuration = cooldownDuration
	
	-- Play animation (skipFirstAnimation handled internally based on interruption)
	playAbilityCast(abilityId, projectileCount, pulseInterval, damageStats, animationData, false, verticalAimProfile)
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
	abilityCastActiveCastId = nil
	character:SetAttribute(ATTR_LOCAL_ABILITY_CAST_ACTIVE, false)
	rangedAimActiveCastId = nil
	character:SetAttribute(ATTR_LOCAL_RANGED_AIM_ACTIVE, false)
	
	-- Clear cached tracks (new character = new animator)
	table.clear(loadedTracks)
	
	-- Wait for humanoid and animator
	character:WaitForChild("Humanoid")
end)

localPlayer.CharacterRemoving:Connect(function(removingCharacter: Model)
	removingCharacter:SetAttribute(ATTR_LOCAL_ABILITY_CAST_ACTIVE, false)
	abilityCastActiveCastId = nil
	removingCharacter:SetAttribute(ATTR_LOCAL_RANGED_AIM_ACTIVE, false)
	rangedAimActiveCastId = nil
end)

if localPlayer.Character then
	localPlayer.Character:SetAttribute(ATTR_LOCAL_ABILITY_CAST_ACTIVE, false)
	localPlayer.Character:SetAttribute(ATTR_LOCAL_RANGED_AIM_ACTIVE, false)
end
