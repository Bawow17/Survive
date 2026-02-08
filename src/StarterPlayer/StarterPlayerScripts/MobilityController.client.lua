--!strict
-- MobilityController - Client-side mobility ability activation (Dash, Double Jump)
-- Handles Q keybind, client-predicted movement, and server communication

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid") :: Humanoid
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

-- Mobility configs (hardcoded on client for responsiveness)
local DASH_CONFIG = {
	distance = 25,
	duration = 0.15,
	cooldown = 3.5,
	afterimageCount = 6,
	afterimageDuration = 0.3,
	afterimageTransparency = 0.7,
}

local DOUBLE_JUMP_CONFIG = {
	horizontalDistance = 27,
	verticalHeight = 9,
	cooldown = 7,
	platformDuration = 0.5,
	platformFadeTime = 0.3,
	trailDuration = 2.0,
	gravityReduction = 0.6,  -- Reduce gravity by 60%
}

local BLINK_CONFIG = {
	groundDistance = 25,
	airDistance = 110,
	airAngleDeg = 30,
	airWindup = 0.3,
	groundCooldown = 2,
	airCooldown = 5,
}

local MANA_GRAPPLE_CONFIG = {
	grappleHorizontalDistance = 100,
	grappleVerticalHeight = 50,
	grappleCooldown = 10,
	grappleManaForward = 30,
	grappleManaUp = 20,
	grappleDampStartFrac = 0.6,
	grappleDampStrength = 2.0,
}

-- Active trail (for cleanup)
local activeTrail: Trail? = nil
local trailStartTime: number = 0

-- Active gravity effect (for cleanup)
local activeGravityEffect: BodyForce? = nil
local activeGravityConnection: RBXScriptConnection? = nil

-- Remote events for server communication
local MobilityActivateRemote: RemoteEvent
local ShieldBashHitRemote: RemoteEvent
local EntityUpdate: RemoteEvent

-- Player state
local equippedMobility: string? = nil
local lastUsedTime: number = 0
local mobilityDistanceMultiplier: number = 1.0
local cooldownMultiplier: number = 1.0
local mobilityCooldownMultiplier: number = 1.0
local mobilityVerticalMultiplier: number = 1.0

-- Config values from server (overridden when mobility is equipped)
local serverDistance: number? = nil
local serverCooldown: number? = nil
local serverDuration: number? = nil
local serverVerticalHeight: number? = nil
local serverPlatformModelPath: string? = nil
local serverShieldModelPath: string? = nil
local serverGameTime: number? = nil
local lastGameTimeUpdate: number = 0
local usingServerTime = false
local pendingServerLastUsedTime: number? = nil
local pausedServerGameTime: number? = nil
local lastUsedCooldown: number? = nil

-- Shield Bash config values from server
local serverDamage: number? = nil
local serverKnockbackDistance: number? = nil

-- Blink config values from server
local serverGroundDistance: number? = nil
local serverAirDistance: number? = nil
local serverAirWindup: number? = nil
local serverGroundCooldown: number? = nil
local serverAirCooldown: number? = nil
local serverBlinkJumpStartPath: string? = nil
local serverBlinkJumpEndPath: string? = nil
local serverBlinkGroundStartPath: string? = nil
local serverBlinkGroundEndPath: string? = nil
local serverBlinkGroundBeamPath: string? = nil

-- Mana Grapple config values from server
local serverGrappleHorizontalDistance: number? = nil
local serverGrappleVerticalHeight: number? = nil
local serverGrappleCooldown: number? = nil
local serverGrappleManaForward: number? = nil
local serverGrappleManaUp: number? = nil
local serverGrappleDampStartFrac: number? = nil
local serverGrappleDampStrength: number? = nil
local serverGrappleStartPath: string? = nil
local serverGrappleManaPointPath: string? = nil
local serverGrappleEndPath: string? = nil
local serverGrappleBeamPath: string? = nil

-- Track if currently dashing (prevent spam)
local isDashing = false
local activeDashConnection: RBXScriptConnection? = nil

-- Track if currently blinking (prevent spam)
local isBlinking = false
local activeBlinkConnection: RBXScriptConnection? = nil
local blinkOriginalTransparencies: {[BasePart]: number} = {}
local blinkToken = 0
local blinkLocalCooldownEnd = 0

-- Track if currently grappling (prevent spam)
local isGrappling = false
local grappleToken = 0
local activeGrappleConnection: RBXScriptConnection? = nil
local grappleHoldActive = false
local grappleParts: {
	Start: BasePart?,
	End: BasePart?,
	ManaPoint: BasePart?,
	Beam: Beam?,
	StartAttachment: Attachment?,
	EndAttachment: Attachment?,
	StartObject: Instance?,
	EndObject: Instance?,
	ManaPointObject: Instance?,
	BeamObject: Instance?,
} = {
	Start = nil,
	End = nil,
	ManaPoint = nil,
	Beam = nil,
	StartAttachment = nil,
	EndAttachment = nil,
	StartObject = nil,
	EndObject = nil,
	ManaPointObject = nil,
	BeamObject = nil,
}

-- Pause state
local isPaused = false
local pauseStartTime: number = 0
local totalPausedTime: number = 0

-- Raycast params for blink collision checks
local blinkRaycastParams = RaycastParams.new()
blinkRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
blinkRaycastParams.IgnoreWater = true

local BLINK_GROUND_TRAIL_DURATION = 1.0
local BLINK_GROUND_TRAIL_FADE_DURATION = 0.5
local BLINK_JUMP_VFX_DURATION = 1.5

local function getServerTimeForCooldown(): number?
	if not (usingServerTime and serverGameTime) then
		return nil
	end
	if isPaused and pausedServerGameTime then
		return pausedServerGameTime
	end
	return serverGameTime + math.max(0, tick() - lastGameTimeUpdate)
end

-- Visual Effects Functions (defined early so they can be called)

-- Create dash afterimages along path
local function createDashAfterimages(direction: Vector3, distance: number, duration: number)
	if not character or not character.PrimaryPart then
		return
	end
	
	-- Capture character reference to prevent issues if player respawns during dash
	local dashCharacter = character
	local dashRootPart = rootPart
	
	local spacing = distance / DASH_CONFIG.afterimageCount
	
	-- Create afterimages at intervals during dash
	for i = 1, DASH_CONFIG.afterimageCount do
		task.delay((duration / DASH_CONFIG.afterimageCount) * (i - 1), function()
			if not dashCharacter or not dashCharacter.Parent or not dashRootPart or not dashRootPart.Parent then
				return
			end
			
			-- Clone character
			local clone = dashCharacter:Clone()
			if not clone then
				return
			end
			
			-- Remove unwanted elements from clone
			for _, descendant in pairs(clone:GetDescendants()) do
				if descendant:IsA("Script") or descendant:IsA("LocalScript") then
					descendant:Destroy()
				elseif descendant:IsA("Humanoid") then
					descendant:Destroy()
				elseif descendant:IsA("Sound") then
					descendant:Destroy()
				elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Trail") then
					descendant:Destroy()
				end
			end
			
			-- Position clone at current position
			if clone.PrimaryPart and dashRootPart and dashRootPart.Parent then
				clone:PivotTo(dashRootPart:GetPivot())
			else
				-- Can't position, abort
				clone:Destroy()
				return
			end
			
			-- Set all parts to transparent starting value
			for _, part in pairs(clone:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
					part.Massless = true
					part.CastShadow = false
					part.Transparency = DASH_CONFIG.afterimageTransparency
				end
			end
			
			clone.Parent = workspace
			
			-- Tween to fully transparent
			for _, part in pairs(clone:GetDescendants()) do
				if part:IsA("BasePart") then
					local tween = TweenService:Create(
						part,
						TweenInfo.new(DASH_CONFIG.afterimageDuration, Enum.EasingStyle.Linear),
						{Transparency = 1}
					)
					tween:Play()
				end
			end
			
			-- Destroy after animation completes
			Debris:AddItem(clone, DASH_CONFIG.afterimageDuration)
		end)
	end
end

-- Helper to find model by path
local function findModelByPath(path: string): Model?
	local parts = string.split(path, ".")
	local current: any = game
	
	for _, part in ipairs(parts) do
		if part == "game" then
			continue
		end
		
		-- Handle GetService calls
		if part:match("^GetService") then
			local serviceName = part:match('GetService%("(.+)"%)')
			if serviceName then
				current = game:GetService(serviceName)
			end
		else
			current = current:FindFirstChild(part)
			if not current then
				return nil
			end
		end
	end
	
	return if typeof(current) == "Instance" and current:IsA("Model") then current else nil
end

-- Create double jump platform and trail effects
local function createDoubleJumpEffects(spawnPosition: Vector3)
	if not character or not character.PrimaryPart then
		return
	end
	
	-- Try to load model from ReplicatedStorage
	local platform: Model? = nil
	
	if serverPlatformModelPath then
		-- Model should be in ReplicatedStorage after server replication
		local templateModel = findModelByPath(serverPlatformModelPath)
		
		if templateModel then
			platform = templateModel:Clone()
			-- Position at player's feet (offset down from HumanoidRootPart position)
			-- Assuming standard R6 character, offset by -3 studs to reach feet
			local feetPosition = spawnPosition - Vector3.new(0, 3, 0)
			platform:PivotTo(CFrame.new(feetPosition))
			platform.Parent = workspace
		end
	end
	
	-- Fallback to placeholder if no model found
	if not platform then
		local part = Instance.new("Part")
		part.Size = Vector3.new(4, 0.5, 4)
		-- Offset down from HumanoidRootPart to feet level
		part.Position = spawnPosition - Vector3.new(0, 3, 0)
		part.Anchored = true
		part.CanCollide = false
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(100, 200, 255)
		part.Transparency = 0
		part.Parent = workspace
		platform = part :: any
	end
	
	-- Fade out platform (works for both Model and Part) - respects pause
	if platform then
		-- Tween all parts in the model/part
		local partsToFade = {}
		if platform:IsA("Model") then
			for _, desc in pairs(platform:GetDescendants()) do
				if desc:IsA("BasePart") then
					table.insert(partsToFade, desc)
				end
			end
		elseif platform:IsA("BasePart") then
			table.insert(partsToFade, platform)
		end
		
		-- Monitor platform lifetime with pause support
		local platformStartTime = tick()
		local platformTotalPausedTime = 0
		local platformLastPauseCheckTime = tick()
		local platformTweens = {}
		local fadeStarted = false
		
		local platformConnection = RunService.Heartbeat:Connect(function()
			local currentTime = tick()
			
			-- Track paused time
			if isPaused then
				platformTotalPausedTime = platformTotalPausedTime + (currentTime - platformLastPauseCheckTime)
				
				-- Pause any active fade tweens
				for _, tween in ipairs(platformTweens) do
					if tween.PlaybackState == Enum.PlaybackState.Playing then
						tween:Pause()
					end
				end
			else
				-- Resume any paused tweens
				for _, tween in ipairs(platformTweens) do
					if tween.PlaybackState == Enum.PlaybackState.Paused then
						tween:Play()
					end
				end
			end
			
			platformLastPauseCheckTime = currentTime
			
			-- Calculate elapsed time (subtract paused time)
			local elapsedRealTime = currentTime - platformStartTime - platformTotalPausedTime
			
			-- Start fade after display duration (minus fade time)
			if not fadeStarted and elapsedRealTime >= DOUBLE_JUMP_CONFIG.platformDuration - DOUBLE_JUMP_CONFIG.platformFadeTime then
				fadeStarted = true
				for _, part in ipairs(partsToFade) do
					local tween = TweenService:Create(
						part,
						TweenInfo.new(DOUBLE_JUMP_CONFIG.platformFadeTime, Enum.EasingStyle.Linear),
						{Transparency = 1}
					)
					tween:Play()
					table.insert(platformTweens, tween)
				end
			end
			
			-- Destroy platform after full duration
			if elapsedRealTime >= DOUBLE_JUMP_CONFIG.platformDuration then
				if platformConnection then
					platformConnection:Disconnect()
				end
				if platform and platform.Parent then
					platform:Destroy()
				end
			end
		end)
	end
	
	-- Create trail on character
	local function createDoubleJumpTrail()
		-- Clean up existing trail
		if activeTrail and activeTrail.Parent then
			activeTrail:Destroy()
			activeTrail = nil
		end
		
		-- Create new trail
		local trail = Instance.new("Trail")
		trail.Color = ColorSequence.new(Color3.fromRGB(100, 200, 255))
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 1)
		})
		trail.Lifetime = 0.5
		trail.MinLength = 0.1
		trail.WidthScale = NumberSequence.new(1)
		
		-- Create attachments
		local attachment0 = Instance.new("Attachment")
		attachment0.Position = Vector3.new(-1, 0, 0)
		attachment0.Parent = rootPart
		
		local attachment1 = Instance.new("Attachment")
		attachment1.Position = Vector3.new(1, 0, 0)
		attachment1.Parent = rootPart
		
		trail.Attachment0 = attachment0
		trail.Attachment1 = attachment1
		trail.Parent = rootPart
		
		activeTrail = trail
		trailStartTime = tick()
		
	-- Monitor for ground touch or timeout
		local connection: RBXScriptConnection
		connection = RunService.Heartbeat:Connect(function()
			-- Don't process trail updates while paused (trail is disabled during pause)
			if isPaused then
				return
			end
			
			local currentTime = tick()

			-- Check if should disable trail
			local shouldDisable = false

			-- Timeout after TRAIL_DURATION
			if currentTime - trailStartTime >= DOUBLE_JUMP_CONFIG.trailDuration then
				shouldDisable = true
			end

			-- Disable when touching ground
			if humanoid and humanoid.FloorMaterial ~= Enum.Material.Air then
				shouldDisable = true
			end

			-- Character or trail destroyed
			if not character or not character.Parent or not trail or not trail.Parent then
				shouldDisable = true
			end

			if shouldDisable then
				connection:Disconnect()
				if trail and trail.Parent then
					trail.Enabled = false
					-- Clean up attachments and trail after lifetime expires
					Debris:AddItem(attachment0, 1)
					Debris:AddItem(attachment1, 1)
					Debris:AddItem(trail, 1)
				end
				if activeTrail == trail then
					activeTrail = nil
				end
			end
		end)
	end
	
	createDoubleJumpTrail()
end

-- Apply low gravity effect after double jump
local function applyLowGravity()
	-- Clean up existing gravity effect and monitor (prevent duplicates)
	if activeGravityConnection then
		activeGravityConnection:Disconnect()
		activeGravityConnection = nil
	end
	
	if activeGravityEffect and activeGravityEffect.Parent then
		activeGravityEffect:Destroy()
		activeGravityEffect = nil
	end
	
	-- Get character mass for force calculation
	local totalMass = 0
	for _, part in pairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			totalMass = totalMass + part:GetMass()
		end
	end
	
	-- Calculate upward force to reduce gravity
	-- To reduce gravity by X%, apply upward force = mass * (workspace.Gravity * X)
	local gravityForce = totalMass * workspace.Gravity
	local reductionForce = gravityForce * DOUBLE_JUMP_CONFIG.gravityReduction
	
	-- Create BodyForce to counteract gravity
	local bodyForce = Instance.new("BodyForce")
	bodyForce.Force = Vector3.new(0, reductionForce, 0)  -- Upward force
	bodyForce.Parent = rootPart
	
	activeGravityEffect = bodyForce
	
	-- Monitor for ground touch to remove effect (ONLY active during double jump airtime)
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function()
		-- Don't process while paused (gravity effect remains frozen)
		if isPaused then
			return
		end
		
		-- Check if should disable gravity effect
		local shouldDisable = false

		-- Disable when touching ground
		if humanoid and humanoid.FloorMaterial ~= Enum.Material.Air then
			shouldDisable = true
		end

		-- Character destroyed
		if not character or not character.Parent then
			shouldDisable = true
		end

		-- BodyForce destroyed externally
		if not bodyForce or not bodyForce.Parent then
			shouldDisable = true
		end

		if shouldDisable then
			connection:Disconnect()
			if bodyForce and bodyForce.Parent then
				bodyForce:Destroy()
			end
			if activeGravityEffect == bodyForce then
				activeGravityEffect = nil
			end
			if activeGravityConnection == connection then
				activeGravityConnection = nil
			end
		end
	end)
	
	-- Store connection for cleanup
	activeGravityConnection = connection
end

local function applyBlinkTransparency(progress: number)
	local characterModel = player.Character
	if not characterModel then
		return
	end
	local clamped = math.clamp(progress, 0, 1)
	for _, descendant in pairs(characterModel:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			if blinkOriginalTransparencies[descendant] == nil then
				blinkOriginalTransparencies[descendant] = descendant.LocalTransparencyModifier
			end
			local original = blinkOriginalTransparencies[descendant] or 0
			descendant.LocalTransparencyModifier = original + (1 - original) * clamped
		end
	end
end

local function clearBlinkTransparency()
	for part, original in pairs(blinkOriginalTransparencies) do
		if part and part.Parent then
			part.LocalTransparencyModifier = original
		end
	end
	table.clear(blinkOriginalTransparencies)
end

local function getBlinkModelPath(pathOverride: string?, fallback: string): string
	if typeof(pathOverride) == "string" and pathOverride ~= "" then
		return pathOverride
	end
	return fallback
end

local function findInstanceByPath(path: string): Instance?
	local parts = string.split(path, ".")
	local current: any = game
	for _, part in ipairs(parts) do
		if part == "game" then
			continue
		end
		if part:match("^GetService") then
			local serviceName = part:match('GetService%("(.+)"%)')
			if serviceName then
				current = game:GetService(serviceName)
			end
		else
			current = current:FindFirstChild(part)
			if not current then
				return nil
			end
		end
	end
	return if typeof(current) == "Instance" then current else nil
end

local function cloneBlinkObject(path: string, position: Vector3): Instance?
	local template = findInstanceByPath(path) or findModelByPath(path)
	if not template then
		warn("[MobilityController] Mobility VFX model missing at:", path)
		return nil
	end
	local instance = template:Clone()
	if instance:IsA("Model") then
		local primary = instance.PrimaryPart
		if not primary then
			primary = instance:FindFirstChildWhichIsA("BasePart", true)
			if primary then
				instance.PrimaryPart = primary
			end
		end
		if primary then
			instance:PivotTo(CFrame.new(position))
		end
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
			end
		end
	elseif instance:IsA("BasePart") then
		instance.CFrame = CFrame.new(position)
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanQuery = false
		instance.CanTouch = false
	end
	instance.Parent = workspace
	return instance
end

local function emitBlinkParticles(instance: Instance?)
	if not instance then
		return
	end
	if instance:IsA("ParticleEmitter") then
		instance:Emit(2)
		return
	end
	if instance:IsA("Model") then
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("ParticleEmitter") then
				descendant:Emit(2)
			end
		end
	elseif instance:IsA("BasePart") then
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("ParticleEmitter") then
				descendant:Emit(2)
			end
		end
	end
end

local function lerpNumberSequenceToTransparent(sequence: NumberSequence, alpha: number): NumberSequence
	local keypoints = sequence.Keypoints
	local out = table.create(#keypoints)
	for i, kp in ipairs(keypoints) do
		local value = kp.Value + (1 - kp.Value) * alpha
		out[i] = NumberSequenceKeypoint.new(kp.Time, math.clamp(value, 0, 1), kp.Envelope)
	end
	return NumberSequence.new(out)
end

local function scheduleBlinkGroundFade(rootInstance: Instance?)
	if not rootInstance then
		return
	end

	local fadeDelay = math.max(0, BLINK_GROUND_TRAIL_DURATION - BLINK_GROUND_TRAIL_FADE_DURATION)
	local partBaseTransparency: {[BasePart]: number} = {}
	local beamBaseTransparency: {[Beam]: NumberSequence} = {}

	local function capture(inst: Instance)
		if inst:IsA("BasePart") then
			partBaseTransparency[inst] = inst.Transparency
		elseif inst:IsA("Beam") then
			beamBaseTransparency[inst] = inst.Transparency
		end
	end

	capture(rootInstance)
	for _, descendant in ipairs(rootInstance:GetDescendants()) do
		capture(descendant)
	end

	task.delay(fadeDelay, function()
		local fadeStart = tick()
		local fadeConnection: RBXScriptConnection?
		fadeConnection = RunService.Heartbeat:Connect(function()
			local t = math.clamp((tick() - fadeStart) / BLINK_GROUND_TRAIL_FADE_DURATION, 0, 1)

			for part, baseTransparency in pairs(partBaseTransparency) do
				if part and part.Parent then
					part.Transparency = baseTransparency + (1 - baseTransparency) * t
				end
			end

			for beam, baseTransparency in pairs(beamBaseTransparency) do
				if beam and beam.Parent then
					beam.Transparency = lerpNumberSequenceToTransparent(baseTransparency, t)
				end
			end

			if t >= 1 then
				if fadeConnection then
					fadeConnection:Disconnect()
				end
			end
		end)
	end)
end

local function getBasePartFromInstance(instance: Instance?): BasePart?
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function attachmentNameMatches(attachment: Attachment, hints: {string}): boolean
	local lowerName = string.lower(attachment.Name or "")
	for _, hint in ipairs(hints) do
		if string.find(lowerName, string.lower(hint), 1, true) then
			return true
		end
	end
	return false
end

local function findAttachmentInInstance(instance: Instance?, preferredPart: BasePart?, hints: {string}): Attachment?
	if preferredPart then
		for _, child in ipairs(preferredPart:GetChildren()) do
			if child:IsA("Attachment") and attachmentNameMatches(child, hints) then
				return child
			end
		end
		local firstOnPart = preferredPart:FindFirstChildOfClass("Attachment")
		if firstOnPart then
			return firstOnPart
		end
	end

	if not instance then
		return nil
	end

	if instance:IsA("Model") then
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("Attachment") and attachmentNameMatches(descendant, hints) then
				return descendant
			end
		end
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("Attachment") then
				return descendant
			end
		end
	elseif instance:IsA("BasePart") then
		for _, child in ipairs(instance:GetChildren()) do
			if child:IsA("Attachment") and attachmentNameMatches(child, hints) then
				return child
			end
		end
		return instance:FindFirstChildOfClass("Attachment")
	end

	return nil
end

local function ensureBeamBetween(startInstance: Instance?, endInstance: Instance?)
	if not startInstance or not endInstance then
		return
	end
	local startPart = getBasePartFromInstance(startInstance)
	local endPart = getBasePartFromInstance(endInstance)
	if not startPart or not endPart then
		return
	end

	local startAttachment = findAttachmentInInstance(startInstance, startPart, {"start", "a0", "attachment0", "origin"})
	if not startAttachment then
		startAttachment = Instance.new("Attachment")
		startAttachment.Parent = startPart
	end
	local endAttachment = findAttachmentInInstance(endInstance, endPart, {"end", "a1", "attachment1", "target"})
	if not endAttachment then
		endAttachment = Instance.new("Attachment")
		endAttachment.Parent = endPart
	end

	local beam: Beam? = nil
	if startInstance:IsA("Model") then
		beam = startInstance:FindFirstChildWhichIsA("Beam", true)
	elseif startInstance:IsA("BasePart") then
		beam = startInstance:FindFirstChildOfClass("Beam")
	end
	if not beam then
		if endInstance:IsA("Model") then
			beam = endInstance:FindFirstChildWhichIsA("Beam", true)
		elseif endInstance:IsA("BasePart") then
			beam = endInstance:FindFirstChildOfClass("Beam")
		end
	end
	if not beam then
		beam = Instance.new("Beam")
		beam.FaceCamera = true
		beam.Width0 = 0.2
		beam.Width1 = 0.2
		beam.Parent = startPart
	end
	beam.Attachment0 = startAttachment
	beam.Attachment1 = endAttachment
	beam.Enabled = true
end

local function spawnBlinkJumpStartVfx(startPos: Vector3)
	local startPath = getBlinkModelPath(serverBlinkJumpStartPath, "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.Blink.BlinkJump.Start")
	local startInstance = cloneBlinkObject(startPath, startPos)
	emitBlinkParticles(startInstance)
	if startInstance then
		Debris:AddItem(startInstance, BLINK_JUMP_VFX_DURATION)
	end
end

local function spawnBlinkJumpEndVfx(endPos: Vector3)
	local endPath = getBlinkModelPath(serverBlinkJumpEndPath, "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.Blink.BlinkJump.End")
	local endInstance = cloneBlinkObject(endPath, endPos)
	emitBlinkParticles(endInstance)
	if endInstance then
		Debris:AddItem(endInstance, BLINK_JUMP_VFX_DURATION)
	end
end

local function spawnBlinkGroundTrail(startPos: Vector3, endPos: Vector3)
	local beamPath = getBlinkModelPath(serverBlinkGroundBeamPath, "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.Blink.BlinkGround.Beam")
	local beamInstance = cloneBlinkObject(beamPath, startPos)
	if beamInstance then
		-- Case A: beam instance is a model/container that already includes Start/End parts.
		if beamInstance:IsA("Model") or beamInstance:IsA("Folder") then
			local startPart = beamInstance:FindFirstChild("Start", true)
			local endPart = beamInstance:FindFirstChild("End", true)
			local beamObj = beamInstance:FindFirstChildWhichIsA("Beam", true)

			if startPart and startPart:IsA("BasePart") then
				startPart.CFrame = CFrame.new(startPos)
			end
			if endPart and endPart:IsA("BasePart") then
				endPart.CFrame = CFrame.new(endPos)
			end

			if beamObj and startPart and startPart:IsA("BasePart") and endPart and endPart:IsA("BasePart") then
				local a0 = findAttachmentInInstance(beamInstance, startPart, {"start", "a0", "attachment0", "origin"})
				local a1 = findAttachmentInInstance(beamInstance, endPart, {"end", "a1", "attachment1", "target"})
				if not a0 then
					a0 = Instance.new("Attachment")
					a0.Parent = startPart
				end
				if not a1 then
					a1 = Instance.new("Attachment")
					a1.Parent = endPart
				end
				beamObj.Attachment0 = a0
				beamObj.Attachment1 = a1
				beamObj.Enabled = true

				scheduleBlinkGroundFade(beamInstance)
				Debris:AddItem(beamInstance, BLINK_GROUND_TRAIL_DURATION)
				return
			end

			-- If model/folder doesn't expose the needed structure, continue to fallback path below.
			beamInstance:Destroy()
			beamInstance = nil
		elseif beamInstance:IsA("Beam") then
			-- Case B: path points to a Beam template only; wire it to fallback Start/End below.
			-- Keep beamInstance alive and wire after Start/End clones are created.
		else
			-- Unknown type for beam asset; discard and continue fallback.
			beamInstance:Destroy()
			beamInstance = nil
		end
	end

	local startPath = getBlinkModelPath(serverBlinkGroundStartPath, "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.Blink.BlinkGround.Start")
	local endPath = getBlinkModelPath(serverBlinkGroundEndPath, "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.Blink.BlinkGround.End")
	local startInstance = cloneBlinkObject(startPath, startPos)
	local endInstance = cloneBlinkObject(endPath, endPos)

	if beamInstance and beamInstance:IsA("Beam") then
		local startPart = getBasePartFromInstance(startInstance)
		local endPart = getBasePartFromInstance(endInstance)
		if startPart and endPart then
			local a0 = findAttachmentInInstance(startInstance, startPart, {"start", "a0", "attachment0", "origin"})
			local a1 = findAttachmentInInstance(endInstance, endPart, {"end", "a1", "attachment1", "target"})
			if not a0 then
				a0 = Instance.new("Attachment")
				a0.Parent = startPart
			end
			if not a1 then
				a1 = Instance.new("Attachment")
				a1.Parent = endPart
			end
			beamInstance.Attachment0 = a0
			beamInstance.Attachment1 = a1
			beamInstance.Enabled = true
			beamInstance.Parent = startPart
		else
			beamInstance:Destroy()
			beamInstance = nil
		end
	end

	if not beamInstance then
		ensureBeamBetween(startInstance, endInstance)
	end

	if startInstance then
		scheduleBlinkGroundFade(startInstance)
		Debris:AddItem(startInstance, BLINK_GROUND_TRAIL_DURATION)
	end
	if endInstance then
		scheduleBlinkGroundFade(endInstance)
		Debris:AddItem(endInstance, BLINK_GROUND_TRAIL_DURATION)
	end
end

local function getGrappleModelPath(pathOverride: string?, fallback: string): string
	if typeof(pathOverride) == "string" and pathOverride ~= "" then
		return pathOverride
	end
	return fallback
end

local function setInstanceWorldCFrame(instance: Instance?, targetCFrame: CFrame)
	if not instance then
		return
	end
	if instance:IsA("Model") then
		local primary = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			if not instance.PrimaryPart then
				instance.PrimaryPart = primary
			end
			instance:PivotTo(targetCFrame)
		end
	elseif instance:IsA("BasePart") then
		instance.CFrame = targetCFrame
	end
end

local function findBeamInInstance(instance: Instance?): Beam?
	if not instance then
		return nil
	end
	if instance:IsA("Beam") then
		return instance
	end
	if instance:IsA("Model") or instance:IsA("Folder") then
		return instance:FindFirstChildWhichIsA("Beam", true)
	end
	if instance:IsA("BasePart") then
		return instance:FindFirstChildOfClass("Beam")
	end
	return nil
end

local function safeDestroy(instance: Instance?)
	if instance and instance.Parent then
		instance:Destroy()
	end
end

local function getGrappleFolder(): Folder
	local existing = workspace:FindFirstChild("Grapple")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Grapple"
	folder.Parent = workspace
	return folder
end

local function getOrCreateGrapplePart(folder: Folder, name: string): BasePart
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("BasePart") then
		return existing
	end
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Parent = folder
	return part
end

local clearGrappleVfx: () -> ()

local function ensureGrappleVfx(): ()
	clearGrappleVfx()

	local folder = getGrappleFolder()
	local startPath = getGrappleModelPath(serverGrappleStartPath, "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.Grapple.Grapple.Start")
	local endPath = getGrappleModelPath(serverGrappleEndPath, "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.Grapple.Grapple.End")
	local manaPath = getGrappleModelPath(serverGrappleManaPointPath, "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.Grapple.Grapple.ManaPoint")
	local beamPath = getGrappleModelPath(serverGrappleBeamPath, "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.Grapple.Grapple.Beam")

	local startObject = cloneBlinkObject(startPath, rootPart.Position)
	local endObject = cloneBlinkObject(endPath, rootPart.Position)
	local manaObject = cloneBlinkObject(manaPath, rootPart.Position)
	local beamObject = cloneBlinkObject(beamPath, rootPart.Position)

	if startObject then
		startObject.Name = "Start"
		startObject.Parent = folder
	end
	if endObject then
		endObject.Name = "End"
		endObject.Parent = folder
	end
	if manaObject then
		manaObject.Name = "ManaPoint"
		manaObject.Parent = folder
	end
	if beamObject then
		beamObject.Name = "Beam"
		beamObject.Parent = folder
	end

	local startPart = getBasePartFromInstance(startObject) or getOrCreateGrapplePart(folder, "Start")
	local endPart = getBasePartFromInstance(endObject) or getOrCreateGrapplePart(folder, "End")
	local manaPart = getBasePartFromInstance(manaObject) or getOrCreateGrapplePart(folder, "ManaPoint")

	local startAttachment = findAttachmentInInstance(startObject or startPart, startPart, {"start", "a0", "attachment0", "origin"})
	if not startAttachment then
		startAttachment = Instance.new("Attachment")
		startAttachment.Parent = startPart
	end
	local endAttachment = findAttachmentInInstance(endObject or endPart, endPart, {"end", "a1", "attachment1", "target"})
	if not endAttachment then
		endAttachment = Instance.new("Attachment")
		endAttachment.Parent = endPart
	end

	local beam = findBeamInInstance(beamObject)
	if not beam then
		ensureBeamBetween(startObject or startPart, endObject or endPart)
		beam = findBeamInInstance(startObject or startPart) or findBeamInInstance(endObject or endPart)
	end
	if beam then
		beam.Attachment0 = startAttachment
		beam.Attachment1 = endAttachment
		beam.Enabled = false
	end

	grappleParts.Start = startPart
	grappleParts.End = endPart
	grappleParts.ManaPoint = manaPart
	grappleParts.Beam = beam
	grappleParts.StartAttachment = startAttachment
	grappleParts.EndAttachment = endAttachment
	grappleParts.StartObject = startObject
	grappleParts.EndObject = endObject
	grappleParts.ManaPointObject = manaObject
	grappleParts.BeamObject = beamObject
end

clearGrappleVfx = function()
	if grappleParts.Beam then
		grappleParts.Beam.Enabled = false
	end

	local toDestroy: {Instance?} = {
		grappleParts.BeamObject,
		grappleParts.StartObject,
		grappleParts.EndObject,
		grappleParts.ManaPointObject,
	}
	for _, instance in ipairs(toDestroy) do
		safeDestroy(instance)
	end

	if grappleParts.Start and not grappleParts.StartObject then
		safeDestroy(grappleParts.Start)
	end
	if grappleParts.End and not grappleParts.EndObject then
		safeDestroy(grappleParts.End)
	end
	if grappleParts.ManaPoint and not grappleParts.ManaPointObject then
		safeDestroy(grappleParts.ManaPoint)
	end

	grappleParts.Start = nil
	grappleParts.End = nil
	grappleParts.ManaPoint = nil
	grappleParts.Beam = nil
	grappleParts.StartAttachment = nil
	grappleParts.EndAttachment = nil
	grappleParts.StartObject = nil
	grappleParts.EndObject = nil
	grappleParts.ManaPointObject = nil
	grappleParts.BeamObject = nil
end

local function updateGrappleStartCFrame(targetCFrame: CFrame)
	if grappleParts.StartObject then
		setInstanceWorldCFrame(grappleParts.StartObject, targetCFrame)
	elseif grappleParts.Start then
		grappleParts.Start.CFrame = targetCFrame
	end
end

local function updateGrappleTargetCFrame(targetCFrame: CFrame)
	if grappleParts.ManaPointObject then
		setInstanceWorldCFrame(grappleParts.ManaPointObject, targetCFrame)
	elseif grappleParts.ManaPoint then
		grappleParts.ManaPoint.CFrame = targetCFrame
	end

	if grappleParts.EndObject then
		setInstanceWorldCFrame(grappleParts.EndObject, targetCFrame)
	elseif grappleParts.End then
		grappleParts.End.CFrame = targetCFrame
	end
end

-- Initialize remote events
local function initRemotes()
	local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
	MobilityActivateRemote = remotes:WaitForChild("MobilityActivate")
	-- ShieldBashHit is created by server on first use, don't wait for it
	ShieldBashHitRemote = remotes:FindFirstChild("ShieldBashHit")
	
	local ecsRemotes = remotes:WaitForChild("ECS")
	EntityUpdate = ecsRemotes:WaitForChild("EntityUpdate")
	local EntitySync = ecsRemotes:WaitForChild("EntitySync")
	local GameTimeUpdate = remotes:FindFirstChild("GameTimeUpdate")
	if GameTimeUpdate and GameTimeUpdate:IsA("RemoteEvent") then
		GameTimeUpdate.OnClientEvent:Connect(function(gameTime: any)
			if typeof(gameTime) == "number" then
				serverGameTime = gameTime
				lastGameTimeUpdate = tick()
				if isPaused and not pausedServerGameTime then
					pausedServerGameTime = gameTime
				end
				if not usingServerTime then
					usingServerTime = true
					if pendingServerLastUsedTime then
						lastUsedTime = pendingServerLastUsedTime
						pendingServerLastUsedTime = nil
					else
						local offset = serverGameTime - tick()
						lastUsedTime = lastUsedTime + offset
					end
				end
			end
		end)
	end
	
	-- Helper function to process mobility data from server
	local function processMobilityUpdate(updateData)
		if not updateData or typeof(updateData) ~= "table" then
			return
		end
		
		-- Update mobility data
		if updateData.MobilityData then
			local data = updateData.MobilityData
			if typeof(data) == "table" then
				local previousMobility = equippedMobility
				equippedMobility = data.equippedMobility
				
				
				-- Read config values from server
				if typeof(data.distance) == "number" then
					serverDistance = data.distance
				end
				if typeof(data.cooldown) == "number" then
					serverCooldown = data.cooldown
				end
				if typeof(data.duration) == "number" then
					serverDuration = data.duration
				end
				if typeof(data.verticalHeight) == "number" then
					serverVerticalHeight = data.verticalHeight
				end
				if typeof(data.platformModelPath) == "string" then
					serverPlatformModelPath = data.platformModelPath
				end
				if typeof(data.shieldModelPath) == "string" then
					serverShieldModelPath = data.shieldModelPath
				end
				
				-- Blink specific fields
				if typeof(data.groundDistance) == "number" then
					serverGroundDistance = data.groundDistance
				end
				if typeof(data.airDistance) == "number" then
					serverAirDistance = data.airDistance
				end
				if typeof(data.airWindup) == "number" then
					serverAirWindup = data.airWindup
				end
				if typeof(data.groundCooldown) == "number" then
					serverGroundCooldown = data.groundCooldown
				end
				if typeof(data.airCooldown) == "number" then
					serverAirCooldown = data.airCooldown
				end
				if typeof(data.blinkJumpStartPath) == "string" then
					serverBlinkJumpStartPath = data.blinkJumpStartPath
				end
				if typeof(data.blinkJumpEndPath) == "string" then
					serverBlinkJumpEndPath = data.blinkJumpEndPath
				end
				if typeof(data.blinkGroundStartPath) == "string" then
					serverBlinkGroundStartPath = data.blinkGroundStartPath
				end
				if typeof(data.blinkGroundEndPath) == "string" then
					serverBlinkGroundEndPath = data.blinkGroundEndPath
				end
				if typeof(data.blinkGroundBeamPath) == "string" then
					serverBlinkGroundBeamPath = data.blinkGroundBeamPath
				end
				
				-- Mana Grapple specific fields
				if typeof(data.grappleHorizontalDistance) == "number" then
					serverGrappleHorizontalDistance = data.grappleHorizontalDistance
				end
				if typeof(data.grappleVerticalHeight) == "number" then
					serverGrappleVerticalHeight = data.grappleVerticalHeight
				end
				if typeof(data.grappleCooldown) == "number" then
					serverGrappleCooldown = data.grappleCooldown
				end
				if typeof(data.grappleManaForward) == "number" then
					serverGrappleManaForward = data.grappleManaForward
				end
				if typeof(data.grappleManaUp) == "number" then
					serverGrappleManaUp = data.grappleManaUp
				end
				if typeof(data.grappleDampStartFrac) == "number" then
					serverGrappleDampStartFrac = data.grappleDampStartFrac
				end
				if typeof(data.grappleDampStrength) == "number" then
					serverGrappleDampStrength = data.grappleDampStrength
				end
				if typeof(data.grappleStartPath) == "string" then
					serverGrappleStartPath = data.grappleStartPath
				end
				if typeof(data.grappleManaPointPath) == "string" then
					serverGrappleManaPointPath = data.grappleManaPointPath
				end
				if typeof(data.grappleEndPath) == "string" then
					serverGrappleEndPath = data.grappleEndPath
				end
				if typeof(data.grappleBeamPath) == "string" then
					serverGrappleBeamPath = data.grappleBeamPath
				end
				
				-- Shield Bash specific fields
				if typeof(data.damage) == "number" then
					serverDamage = data.damage
				end
				if typeof(data.knockbackDistance) == "number" then
					serverKnockbackDistance = data.knockbackDistance
				end
			end
		end
		
		-- Update cooldown data
		if updateData.MobilityCooldown then
			local data = updateData.MobilityCooldown
			if typeof(data) == "table" and typeof(data.lastUsedTime) == "number" then
				if usingServerTime then
					lastUsedTime = data.lastUsedTime
				else
					pendingServerLastUsedTime = data.lastUsedTime
					lastUsedTime = tick()
				end
			end
			if typeof(data) == "table" and typeof(data.lastUsedCooldown) == "number" then
				lastUsedCooldown = data.lastUsedCooldown
			end
		end
		
		-- Update passive effects (for multipliers)
		if updateData.PassiveEffects then
			local data = updateData.PassiveEffects
			if typeof(data) == "table" then
				if typeof(data.mobilityDistanceMultiplier) == "number" then
					mobilityDistanceMultiplier = data.mobilityDistanceMultiplier
				end
				if typeof(data.mobilityVerticalMultiplier) == "number" then
					mobilityVerticalMultiplier = data.mobilityVerticalMultiplier
				end
				if typeof(data.mobilityCooldownMultiplier) == "number" then
					mobilityCooldownMultiplier = data.mobilityCooldownMultiplier
				elseif typeof(data.cooldownMultiplier) == "number" then
					mobilityCooldownMultiplier = data.cooldownMultiplier
				end
				if typeof(data.cooldownMultiplier) == "number" then
					cooldownMultiplier = data.cooldownMultiplier
				end
			end
		end
	end
	
	-- Listen for initial sync (EntitySync - sent once at start)
	EntitySync.OnClientEvent:Connect(function(snapshot)
		if typeof(snapshot) ~= "table" or not snapshot.entities then
			return
		end
		
		-- Process all entities in the initial snapshot
		for entityId, entityData in pairs(snapshot.entities) do
			processMobilityUpdate(entityData)
		end
	end)
	
	-- Listen for ongoing entity updates (EntityUpdate - ongoing changes)
	EntityUpdate.OnClientEvent:Connect(function(message)
		if typeof(message) ~= "table" then
			return
		end
		
		local entities = message.entities
		if typeof(entities) == "table" then
			for _, entityData in pairs(entities) do
				processMobilityUpdate(entityData)
			end
		end
		
		local updates = message.updates
		if typeof(updates) == "table" then
			-- Process each update in the message
			for _, updateData in ipairs(updates) do
				processMobilityUpdate(updateData)
			end
		end
		
		local resyncs = message.resyncs
		if typeof(resyncs) == "table" then
			for _, updateData in ipairs(resyncs) do
				processMobilityUpdate(updateData)
			end
		end
	end)
end

-- Check if on cooldown
local function isOnCooldown(config: any): boolean
	local currentTime = tick()
	if usingServerTime and serverGameTime then
		if isPaused then
			currentTime = getServerTimeForCooldown() or serverGameTime
		else
			currentTime = getServerTimeForCooldown() or serverGameTime
		end
	elseif isPaused then
		currentTime = pauseStartTime
	end
	local effectiveCooldown = config.cooldown * mobilityCooldownMultiplier
	local timeSinceLastUse = currentTime - lastUsedTime
	return timeSinceLastUse < effectiveCooldown
end

local function isOnCooldownValue(cooldown: number): boolean
	if typeof(lastUsedCooldown) == "number" and lastUsedCooldown > 0 then
		return isOnCooldown({ cooldown = lastUsedCooldown })
	end
	return isOnCooldown({ cooldown = cooldown })
end

-- Execute Dash ability
local function executeDash()
	if isDashing then
		return false
	end
	
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	
	-- Use server config values if available, otherwise fallback to hardcoded
	local effectiveConfig = {
		distance = serverDistance or DASH_CONFIG.distance,
		duration = serverDuration or DASH_CONFIG.duration,
		cooldown = serverCooldown or DASH_CONFIG.cooldown,
	}
	
	-- Check cooldown
	if isOnCooldown(effectiveConfig) then
		return false
	end
	
	-- Apply passive mobility distance scaling from server.
	local effectiveDistance = effectiveConfig.distance * mobilityDistanceMultiplier
	
	-- Get dash direction from player movement input (like double jump)
	local dashDirection = humanoid.MoveDirection
	if dashDirection.Magnitude < 0.1 then
		-- Fallback to look direction if not moving
		dashDirection = rootPart.CFrame.LookVector
	end
	
	-- Keep horizontal (no vertical component)
	dashDirection = Vector3.new(dashDirection.X, 0, dashDirection.Z)
	if dashDirection.Magnitude < 0.1 then
		-- Final fallback to forward
		dashDirection = Vector3.new(0, 0, 1)
	else
		dashDirection = dashDirection.Unit
	end
	
	-- Clean up any existing dash connection
	if activeDashConnection then
		activeDashConnection:Disconnect()
		activeDashConnection = nil
	end
	
	-- Calculate velocity to travel exact distance in duration
	-- Reduce by 15% for smoother feel
	local dashSpeed = (effectiveDistance / effectiveConfig.duration) * 0.85
	-- Dash direction on horizontal plane only
	local targetVelocity = Vector3.new(dashDirection.X * dashSpeed, 0, dashDirection.Z * dashSpeed)
	
	-- Shield Bash: Make player face the dash direction (override shiftlock)
	-- Basic Dash: Keep facing forward (no rotation change)
	local originalAutoRotate = humanoid.AutoRotate
	
	if equippedMobility == "ShieldBash" then
		-- Disable AutoRotate to override shiftlock during Shield Bash
		humanoid.AutoRotate = false
		
		if dashDirection.Magnitude > 0.1 then
			local currentCFrame = rootPart.CFrame
			local targetCFrame = CFrame.lookAt(currentCFrame.Position, currentCFrame.Position + dashDirection)
			rootPart.CFrame = targetCFrame
		end
	end
	
	-- Disable ragdoll states during dash to prevent tripping
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	
	-- Get or create RootAttachment for LinearVelocity constraint
	local rootAttachment = rootPart:FindFirstChild("RootAttachment")
	if not rootAttachment then
		rootAttachment = Instance.new("Attachment")
		rootAttachment.Name = "RootAttachment"
		rootAttachment.Position = Vector3.zero
		rootAttachment.Parent = rootPart
	end
	
	-- Create LinearVelocity constraint with per-axis force limits
	-- Based on: https://devforum.roblox.com/t/making-a-consistent-dash-ability-that-is-affected-by-gravity/3545916
	-- X/Z axes: Full force for dash | Y axis: Zero force (gravity works naturally)
	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "DashLinearVelocity"
	linearVelocity.Attachment0 = rootAttachment
	linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.VectorVelocity = targetVelocity
	-- Per-axis force limits: X and Z have full force, Y has zero (allows gravity)
	linearVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	linearVelocity.MaxAxesForce = Vector3.new(math.huge, 0, math.huge)
	linearVelocity.Parent = rootPart
	
	isDashing = true
	local dashStartTime = tick()
	local dashTotalPausedTime = 0
	local dashLastPauseCheckTime = tick()
	
	-- Shield Bash: Create shield with hitbox for enemy detection
	local shieldModel: Model? = nil
	local shieldBashHitbox: Part? = nil
	local hitEnemyModels: {Model} = {}
	local hitConnection: RBXScriptConnection? = nil
	
	if equippedMobility == "ShieldBash" and serverShieldModelPath then
		-- Load shield model from ReplicatedStorage
		local shieldTemplate = findModelByPath(serverShieldModelPath)
		
		if shieldTemplate then
			shieldModel = shieldTemplate:Clone()
			
			-- Find the Hitbox part in the shield model
			shieldBashHitbox = shieldModel:FindFirstChild("Hitbox", true) :: Part?
			
			if shieldBashHitbox then
				-- Configure hitbox to not interfere with enemy raycast
				shieldBashHitbox.CanCollide = false
				shieldBashHitbox.CanQuery = false  -- Prevents raycast detection
				shieldBashHitbox.CanTouch = true   -- Allows Touched events
				
				-- Make all shield parts massless, non-colliding, and UNANCHORED
				for _, part in pairs(shieldModel:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Anchored = false  -- CRITICAL: Must be unanchored or it will freeze player
						part.CanCollide = false
						part.Massless = true
						if part ~= shieldBashHitbox then
							part.CanQuery = false  -- Only hitbox should be queryable
						end
					end
				end
				
				-- Set PrimaryPart to ensure proper pivoting/welding
				if not shieldModel.PrimaryPart then
					shieldModel.PrimaryPart = shieldBashHitbox
				end
				
				-- Position shield in front of player (dash direction)
				local shieldOffset = 3  -- studs in front of player
				shieldModel:PivotTo(rootPart.CFrame * CFrame.new(0, 0, -shieldOffset))
				shieldModel.Parent = workspace
				
				-- Weld shield to player so it moves with dash
				-- Use Motor6D instead of WeldConstraint to avoid physics conflicts
				local weld = Instance.new("Motor6D")
				weld.Name = "ShieldWeld"
				weld.Part0 = rootPart
				weld.Part1 = shieldModel.PrimaryPart
				weld.C0 = CFrame.new(0, 0, -shieldOffset)  -- Relative offset
				weld.Parent = rootPart
				
				-- Detect enemy hits via the Hitbox part
				hitConnection = shieldBashHitbox.Touched:Connect(function(hit)
					if hit.Parent and hit.Parent:FindFirstChild("Humanoid") and hit.Parent ~= character then
						local enemyModel = hit.Parent
						-- Only count each enemy once
						if not table.find(hitEnemyModels, enemyModel) then
							table.insert(hitEnemyModels, enemyModel)
						end
					end
				end)
			else
				warn("[MobilityController] Shield model missing 'Hitbox' part!")
				-- Clean up model if no hitbox found
				if shieldModel then
					shieldModel:Destroy()
					shieldModel = nil
				end
			end
		else
			warn("[MobilityController] Could not find shield model at:", serverShieldModelPath)
		end
	end
	
	-- Helper function to clean up Shield Bash model and report hits to server
	local function cleanupShieldBash()
		-- Re-enable AutoRotate after Shield Bash (basic Dash doesn't change it)
		if equippedMobility == "ShieldBash" and humanoid then
			humanoid.AutoRotate = originalAutoRotate
		end
		
		-- Disconnect hit detection
		if hitConnection then
			hitConnection:Disconnect()
			hitConnection = nil
		end
		
		-- Fade out shield model over 0.15s, then destroy
		if shieldModel and shieldModel.Parent then
			-- Collect all parts to fade
			local partsToFade = {}
			local activeTweens = {}
			
			for _, part in pairs(shieldModel:GetDescendants()) do
				if part:IsA("BasePart") then
					table.insert(partsToFade, part)
				end
			end
			
			-- Tween all parts to transparent
			for _, part in ipairs(partsToFade) do
				local originalTransparency = part.Transparency
				local tween = TweenService:Create(
					part,
					TweenInfo.new(0.15, Enum.EasingStyle.Linear),
					{Transparency = 1}
				)
				tween:Play()
				table.insert(activeTweens, tween)
			end
			
			-- Monitor pause state for shield fade tweens
			local fadeStartTime = tick()
			local totalPausedTime = 0
			local lastPauseCheckTime = tick()
			
			local pauseConnection = RunService.Heartbeat:Connect(function()
				local currentTime = tick()
				
				if isPaused then
					-- Accumulate paused time
					totalPausedTime = totalPausedTime + (currentTime - lastPauseCheckTime)
					
					-- Pause all tweens
					for _, tween in ipairs(activeTweens) do
						if tween.PlaybackState == Enum.PlaybackState.Playing then
							tween:Pause()
						end
					end
				else
					-- Resume all tweens
					for _, tween in ipairs(activeTweens) do
						if tween.PlaybackState == Enum.PlaybackState.Paused then
							tween:Play()
						end
					end
				end
				
				lastPauseCheckTime = currentTime
				
				-- Check if fade completed (accounting for pause time)
				local elapsedRealTime = currentTime - fadeStartTime - totalPausedTime
				if elapsedRealTime >= 0.15 then
					-- Cleanup
					if pauseConnection then
						pauseConnection:Disconnect()
					end
					if shieldModel and shieldModel.Parent then
						shieldModel:Destroy()
					end
				end
			end)
			
			-- Don't use Debris:AddItem (doesn't account for pause time)
			shieldModel = nil
		end
		shieldBashHitbox = nil
		
		-- Report hits to server for validation and damage application
		if #hitEnemyModels > 0 then
			-- Get remote if it wasn't available at init (created on first Shield Bash use)
			if not ShieldBashHitRemote then
				local remotes = ReplicatedStorage:FindFirstChild("RemoteEvents")
				if remotes then
					ShieldBashHitRemote = remotes:FindFirstChild("ShieldBashHit")
				end
			end
			
			if ShieldBashHitRemote then
				ShieldBashHitRemote:FireServer(hitEnemyModels)
			end
		end
	end
	
	-- Track pause state for dash (to freeze/resume LinearVelocity)
	local pausedVelocity: Vector3? = nil
	
	-- Debug: Monitor state changes during dash
	local stateConnection = humanoid.StateChanged:Connect(function(oldState, newState)
		if newState == Enum.HumanoidStateType.FallingDown or newState == Enum.HumanoidStateType.Ragdoll then
			warn(string.format("[Mobility] Humanoid entered %s during dash!", tostring(newState)))
		end
	end)
	
	-- Monitor dash with gradual deceleration throughout
	local dashConnection: RBXScriptConnection? = nil
	dashConnection = RunService.Heartbeat:Connect(function(dt)
		local currentTime = tick()
		
		-- Handle pause/unpause for LinearVelocity
		if isPaused then
			-- Accumulate paused time for dash duration
			dashTotalPausedTime = dashTotalPausedTime + (currentTime - dashLastPauseCheckTime)
			
			if not pausedVelocity and linearVelocity and linearVelocity.Parent then
				-- Freeze dash by storing current velocity and setting to zero
				pausedVelocity = linearVelocity.VectorVelocity
				linearVelocity.VectorVelocity = Vector3.zero
			end
			
			dashLastPauseCheckTime = currentTime
			return  -- Don't process dash while paused
		elseif not isPaused and pausedVelocity and linearVelocity and linearVelocity.Parent then
			-- Resume dash by restoring velocity
			linearVelocity.VectorVelocity = pausedVelocity
			pausedVelocity = nil
		end
		
		dashLastPauseCheckTime = currentTime
		
		if not rootPart or not rootPart.Parent or not linearVelocity or not linearVelocity.Parent then
			if linearVelocity and linearVelocity.Parent then
				linearVelocity:Destroy()
			end
			if dashConnection then
				dashConnection:Disconnect()
				dashConnection = nil
			end
			if activeDashConnection then
				activeDashConnection = nil
			end
			if stateConnection then
				stateConnection:Disconnect()
			end
			-- Re-enable ragdoll states after dash
			if humanoid then
				humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
			end
			cleanupShieldBash()
			isDashing = false
			return
		end
		
		-- Calculate elapsed time (subtract paused time)
		local elapsed = currentTime - dashStartTime - dashTotalPausedTime
		
		-- Check if dash is complete (with early exit to prevent sticking)
		if elapsed >= effectiveConfig.duration * 0.95 then  -- End at 95% to prevent freeze
			-- Destroy constraint and restore control
			if linearVelocity and linearVelocity.Parent then
				linearVelocity:Destroy()
			end
			
			if dashConnection then
				dashConnection:Disconnect()
				dashConnection = nil
			end
			if activeDashConnection then
				activeDashConnection = nil
			end
			if stateConnection then
				stateConnection:Disconnect()
			end
			-- Re-enable ragdoll states after dash
			if humanoid then
				humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
			end
			cleanupShieldBash()
			isDashing = false
			return
		end
		
		-- Apply smooth deceleration starting at 20% through the dash
		-- Very gradual slowdown to prevent sudden stop feeling
		local progress = elapsed / effectiveConfig.duration  -- 0 to 1
		local decelStartProgress = 0.2  -- Start decelerating at 20% through dash
		
		if progress >= decelStartProgress then
			-- Calculate deceleration progress (0 to 1 from decel start to dash end)
			local decelProgress = (progress - decelStartProgress) / (1 - decelStartProgress)
			
			-- Very smooth curve: quartic ease-out for extremely gradual slowdown
			local easeOut = 1 - math.pow(1 - decelProgress, 4)
			
			-- Reduce velocity to near 0 by end of dash
			local currentSpeed = targetVelocity.Magnitude * (1 - easeOut)
			
			-- Early exit: Destroy constraint when speed is very low to prevent sticking
			if currentSpeed < targetVelocity.Magnitude * 0.08 then  -- Less than 8% of original speed
				if linearVelocity and linearVelocity.Parent then
					linearVelocity:Destroy()
				end
				
				if dashConnection then
					dashConnection:Disconnect()
					dashConnection = nil
				end
				if activeDashConnection then
					activeDashConnection = nil
				end
				if stateConnection then
					stateConnection:Disconnect()
				end
				-- Re-enable ragdoll states after dash
				if humanoid then
					humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
					humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
				end
				cleanupShieldBash()
				isDashing = false
				return
			end
			
			if dashDirection.Magnitude > 0 then
				-- Update vector velocity (horizontal only, Y remains unaffected by constraint)
				linearVelocity.VectorVelocity = Vector3.new(
					dashDirection.X * currentSpeed,
					0,  -- Y velocity is controlled by gravity (MaxAxesForce.Y = 0)
					dashDirection.Z * currentSpeed
				)
			end
		end
	end)
	
	activeDashConnection = dashConnection
	
	-- Update local cooldown
	if usingServerTime and serverGameTime then
		local estimate = serverGameTime + math.max(0, tick() - lastGameTimeUpdate)
		lastUsedTime = estimate
	else
		lastUsedTime = tick()
	end
	
	-- Create afterimages
	createDashAfterimages(dashDirection, effectiveDistance, effectiveConfig.duration)
	
	-- Send to server for validation and effects (Shield Bash: damage/knockback/invincibility)
	-- Send the actual equipped mobility ID (either "Dash" or "ShieldBash")
	local mobilityIdToSend = equippedMobility or "Dash"
	MobilityActivateRemote:FireServer(mobilityIdToSend)
	
	return true
end

-- Execute Double Jump ability
local function executeDoubleJump()
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	
	-- MUST be airborne
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		return false
	end
	
	-- Use server config values if available, otherwise fallback to hardcoded
	local effectiveConfig = {
		horizontalDistance = serverDistance or DOUBLE_JUMP_CONFIG.horizontalDistance,
		verticalHeight = (serverVerticalHeight or DOUBLE_JUMP_CONFIG.verticalHeight) * mobilityVerticalMultiplier,
		cooldown = serverCooldown or DOUBLE_JUMP_CONFIG.cooldown,
	}
	
	-- Check cooldown
	if isOnCooldown(effectiveConfig) then
		return false
	end
	
	-- Apply passive mobility distance scaling from server.
	local effectiveHorizontalDistance = effectiveConfig.horizontalDistance * mobilityDistanceMultiplier
	
	-- Get movement direction from player input
	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude < 0.1 then
		-- Fallback to look direction if not moving
		moveDirection = rootPart.CFrame.LookVector
		moveDirection = Vector3.new(moveDirection.X, 0, moveDirection.Z).Unit
	end
	
	-- Calculate velocity components
	-- Horizontal: based on move direction and distance
	local horizontalVel = moveDirection * (effectiveHorizontalDistance / 0.5)  -- 0.5s arc estimate
	
	-- Vertical: use physics formula to reach desired height
	local verticalVel = math.sqrt(2 * workspace.Gravity * effectiveConfig.verticalHeight)
	
	-- Apply velocity
	local jumpVelocity = Vector3.new(horizontalVel.X, verticalVel, horizontalVel.Z)
	rootPart.AssemblyLinearVelocity = jumpVelocity
	
	-- Apply reduced gravity effect
	applyLowGravity()
	
	-- Update local cooldown
	if usingServerTime and serverGameTime then
		local estimate = serverGameTime + math.max(0, tick() - lastGameTimeUpdate)
		lastUsedTime = estimate
	else
		lastUsedTime = tick()
	end
	
	-- Create visual effects
	createDoubleJumpEffects(rootPart.Position)
	
	-- Send to server for validation
	MobilityActivateRemote:FireServer("DoubleJump")
	
	return true
end

local function getBlinkHorizontalDirection(): Vector3
	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude < 0.1 then
		local look = rootPart.CFrame.LookVector
		moveDirection = Vector3.new(look.X, 0, look.Z)
	end
	if moveDirection.Magnitude < 0.1 then
		moveDirection = Vector3.new(0, 0, 1)
	else
		moveDirection = moveDirection.Unit
	end

	return Vector3.new(moveDirection.X, 0, moveDirection.Z).Unit
end

local function getBlinkTarget(direction: Vector3, distance: number, origin: Vector3?): Vector3
	if not rootPart or not rootPart.Parent then
		return Vector3.zero
	end
	local originPos = origin or rootPart.Position
	if character then
		blinkRaycastParams.FilterDescendantsInstances = {character}
	end
	local result = workspace:Raycast(originPos, direction * distance, blinkRaycastParams)
	if result then
		local padding = 1.0
		return result.Position - direction * padding
	end
	return originPos + direction * distance
end

local function getAirBlinkTarget(horizontalDirection: Vector3, horizontalDistance: number, origin: Vector3?): Vector3
	if not rootPart or not rootPart.Parent then
		return Vector3.zero
	end

	local verticalOffset = horizontalDistance * 0.3
	local travelOffset = (horizontalDirection * horizontalDistance) + Vector3.new(0, verticalOffset, 0)
	local originPos = origin or rootPart.Position
	if travelOffset.Magnitude < 1e-4 then
		return originPos
	end

	if character then
		blinkRaycastParams.FilterDescendantsInstances = {character}
	end

	local result = workspace:Raycast(originPos, travelOffset, blinkRaycastParams)
	if result then
		local padding = 1.0
		return result.Position - travelOffset.Unit * padding
	end

	return originPos + travelOffset
end

local function cleanupBlink()
	if activeBlinkConnection then
		activeBlinkConnection:Disconnect()
		activeBlinkConnection = nil
	end
	clearBlinkTransparency()
	isBlinking = false
end

local function executeBlink()
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	if isBlinking or isDashing then
		return false
	end
	local nowLocal = tick()
	if nowLocal < blinkLocalCooldownEnd then
		return false
	end

	local isAir = humanoid.FloorMaterial == Enum.Material.Air
	local groundDistance = (serverGroundDistance or BLINK_CONFIG.groundDistance) * mobilityDistanceMultiplier
	local airDistance = (serverAirDistance or BLINK_CONFIG.airDistance) * mobilityDistanceMultiplier
	local airWindup = serverAirWindup or BLINK_CONFIG.airWindup
	local groundCooldown = serverGroundCooldown or BLINK_CONFIG.groundCooldown
	local airCooldown = serverAirCooldown or BLINK_CONFIG.airCooldown
	local variant = if isAir then "air" else "ground"
	local effectiveCooldown = if isAir then airCooldown else groundCooldown

	if isOnCooldownValue(effectiveCooldown) then
		return false
	end

	-- Update local cooldown immediately
	if usingServerTime and serverGameTime then
		local estimate = serverGameTime + math.max(0, tick() - lastGameTimeUpdate)
		lastUsedTime = estimate
	else
		lastUsedTime = tick()
	end
	lastUsedCooldown = effectiveCooldown
	blinkLocalCooldownEnd = nowLocal + (effectiveCooldown * mobilityCooldownMultiplier)

	-- Notify server for validation/cooldown UI
	MobilityActivateRemote:FireServer("Blink", variant)

	local horizontalDirection = getBlinkHorizontalDirection()

	if not isAir then
		local startPos = rootPart.Position
		local targetPos = getBlinkTarget(horizontalDirection, groundDistance, startPos)
		if rootPart and rootPart.Parent then
			rootPart.CFrame = CFrame.new(targetPos, targetPos + rootPart.CFrame.LookVector)
		end
		spawnBlinkGroundTrail(startPos, targetPos)
		return true
	end

	isBlinking = true
	blinkToken += 1
	local token = blinkToken
	local windupStart = tick()
	local totalPaused = 0
	local lastPauseCheck = tick()
	local fadeDuration = 0.15
	local fadeStart = math.max(0, airWindup - fadeDuration)

	local startPos = rootPart.Position
	spawnBlinkJumpStartVfx(startPos)

	activeBlinkConnection = RunService.Heartbeat:Connect(function()
		if token ~= blinkToken then
			cleanupBlink()
			return
		end
		if not character or not character.Parent or not humanoid or humanoid.Health <= 0 then
			cleanupBlink()
			return
		end

		local now = tick()
		if isPaused then
			totalPaused += now - lastPauseCheck
			lastPauseCheck = now
			return
		end
		lastPauseCheck = now

		local elapsed = now - windupStart - totalPaused
		if elapsed >= fadeStart then
			local progress = math.clamp((elapsed - fadeStart) / fadeDuration, 0, 1)
			applyBlinkTransparency(progress)
		end

		if elapsed >= airWindup then
			local targetPos = getAirBlinkTarget(horizontalDirection, airDistance)
			if rootPart and rootPart.Parent then
				rootPart.CFrame = CFrame.new(targetPos, targetPos + rootPart.CFrame.LookVector)
				local currentVel = rootPart.AssemblyLinearVelocity
				rootPart.AssemblyLinearVelocity = Vector3.new(currentVel.X, 0, currentVel.Z)
			end
			spawnBlinkJumpEndVfx(targetPos)
			cleanupBlink()
		end
	end)

	return true
end

local function executeManaGrapple()
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	if isGrappling or isDashing or isBlinking then
		return false
	end

	local horizontalDistance = serverGrappleHorizontalDistance or MANA_GRAPPLE_CONFIG.grappleHorizontalDistance
	local horizontalSpeedMultiplier = mobilityDistanceMultiplier
	local horizontalTravelScale = 0.825
	local verticalHeight = serverGrappleVerticalHeight or MANA_GRAPPLE_CONFIG.grappleVerticalHeight
	local verticalArcScale = 0.7
	local cooldown = serverGrappleCooldown or MANA_GRAPPLE_CONFIG.grappleCooldown
	local manaUp = serverGrappleManaUp or MANA_GRAPPLE_CONFIG.grappleManaUp
	local dampStartFrac = serverGrappleDampStartFrac or MANA_GRAPPLE_CONFIG.grappleDampStartFrac
	local dampStrength = serverGrappleDampStrength or MANA_GRAPPLE_CONFIG.grappleDampStrength

	if isOnCooldownValue(cooldown) then
		return false
	end

	local function getCameraMoveDirection(fallback: Vector3): Vector3
		local camera = workspace.CurrentCamera
		if camera then
			local look = camera.CFrame.LookVector
			local horizontalLook = Vector3.new(look.X, 0, look.Z)
			if horizontalLook.Magnitude >= 0.1 then
				return horizontalLook.Unit
			end
		end
		if fallback.Magnitude >= 0.1 then
			return fallback.Unit
		end
		local look = rootPart.CFrame.LookVector
		local horizontalLook = Vector3.new(look.X, 0, look.Z)
		if horizontalLook.Magnitude >= 0.1 then
			return horizontalLook.Unit
		end
		return Vector3.new(0, 0, 1)
	end

	local function getPlayerFacingDirection(fallback: Vector3): Vector3
		local look = rootPart.CFrame.LookVector
		local horizontalLook = Vector3.new(look.X, 0, look.Z)
		if horizontalLook.Magnitude >= 0.1 then
			return horizontalLook.Unit
		end
		if fallback.Magnitude >= 0.1 then
			return fallback.Unit
		end
		return Vector3.new(0, 0, 1)
	end

	local moveDirection = getCameraMoveDirection(Vector3.new(0, 0, 1))

	local gravity = workspace.Gravity
	local ballisticPeakTime = math.max(0.05, math.sqrt((2 * verticalHeight) / gravity))
	-- Keep the swing long enough to provide a longer pre-flick travel window.
	local swingDuration = math.max(1.2, ballisticPeakTime)
	local baseHorizontalSpeed = (horizontalDistance * horizontalTravelScale) / swingDuration
	local instantLiftVelocity = math.max(20, math.sqrt(2 * gravity * math.max(2, verticalHeight * 0.12))) * verticalArcScale
	local launchVelocity = (moveDirection * (baseHorizontalSpeed * 0.7) * horizontalSpeedMultiplier) + Vector3.new(0, instantLiftVelocity, 0)

	rootPart.AssemblyLinearVelocity = launchVelocity

	-- Update local cooldown immediately
	if usingServerTime and serverGameTime then
		local estimate = serverGameTime + math.max(0, tick() - lastGameTimeUpdate)
		lastUsedTime = estimate
	else
		lastUsedTime = tick()
	end
	lastUsedCooldown = cooldown

	MobilityActivateRemote:FireServer("ManaGrapple")

	isGrappling = true
	grappleHoldActive = true
	grappleToken += 1
	local token = grappleToken
	local grappleStartTime = tick()
	local totalPaused = 0
	local lastPauseCheck = tick()

	ensureGrappleVfx()
	if grappleParts.Beam then
		grappleParts.Beam.Enabled = true
	end

	-- Attach Start to hand/arm
	local hand = character:FindFirstChild("RightHand", true)
		or character:FindFirstChild("Right Arm", true)
		or character:FindFirstChild("RightUpperArm", true)
	local handPart = if hand and hand:IsA("BasePart") then hand else nil
	if handPart then
		updateGrappleStartCFrame(handPart.CFrame)
	else
		updateGrappleStartCFrame(rootPart.CFrame)
	end

	-- Place mana point in front-right of player for clearer grapple VFX readability.
	local playerForward = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)
	if playerForward.Magnitude < 0.1 then
		playerForward = moveDirection
	else
		playerForward = playerForward.Unit
	end
	local playerRight = Vector3.new(rootPart.CFrame.RightVector.X, 0, rootPart.CFrame.RightVector.Z)
	if playerRight.Magnitude < 0.1 then
		playerRight = Vector3.new(-playerForward.Z, 0, playerForward.X)
	else
		playerRight = playerRight.Unit
	end
	local manaPointPos = rootPart.Position + playerForward * 60 + playerRight * 40 + Vector3.new(0, 50, 0)
	updateGrappleTargetCFrame(CFrame.new(manaPointPos))

	activeGrappleConnection = RunService.Heartbeat:Connect(function()
		if token ~= grappleToken then
			clearGrappleVfx()
			isGrappling = false
			if activeGrappleConnection then
				activeGrappleConnection:Disconnect()
				activeGrappleConnection = nil
			end
			return
		end
		if not character or not character.Parent or not humanoid or humanoid.Health <= 0 then
			clearGrappleVfx()
			isGrappling = false
			if activeGrappleConnection then
				activeGrappleConnection:Disconnect()
				activeGrappleConnection = nil
			end
			return
		end

		local now = tick()
		if isPaused then
			totalPaused += now - lastPauseCheck
			lastPauseCheck = now
			return
		end
		lastPauseCheck = now

		-- Update start attachment position
		if handPart then
			updateGrappleStartCFrame(handPart.CFrame)
		else
			updateGrappleStartCFrame(rootPart.CFrame)
		end
		local playerDirection = getPlayerFacingDirection(moveDirection)

		local elapsed = now - grappleStartTime - totalPaused
		local progress = math.clamp(elapsed / swingDuration, 0, 1)

		-- Arc profile (reduced horizontal pre-flick window):
		-- 0.00 -> 0.10 : quick upward pop that immediately turns downward
		-- 0.10 -> 0.50 : deeper dip / horizontal travel window
		-- 0.50 -> 1.00 : strong rise to finish
		local phase1End = 0.10
		local phase2End = 0.50

		local targetVerticalSpeed: number
		if progress < phase1End then
			local t = progress / phase1End
			targetVerticalSpeed = instantLiftVelocity * (1 - t) + (-6) * t
		elseif progress < phase2End then
			local t = (progress - phase1End) / (phase2End - phase1End)
			targetVerticalSpeed = (-6) * (1 - t) + (-20) * t
		else
			local t = (progress - phase2End) / (1 - phase2End)
			targetVerticalSpeed = (-20) * (1 - t) + (instantLiftVelocity * 4.10) * t
		end

		-- Ramp horizontal speed harder before the upward flick.
		-- Delay horizontal gain timing by 0.15s.
		local horizontalTimingDelay = 0.15
		local delayedProgress = math.clamp((elapsed - horizontalTimingDelay) / math.max(1e-4, swingDuration), 0, 1)
		local preFlickT = math.clamp(delayedProgress / math.max(phase2End, 1e-4), 0, 1)
		local baseSpeedCurve = 0.80 + (1.10 * preFlickT)
		local speedGainStart = math.clamp(dampStartFrac, 0.1, 0.8)
		local gainT = math.clamp((preFlickT - speedGainStart) / math.max(1e-4, (1 - speedGainStart)), 0, 1)
		local speedGain = 1 + (0.30 + (dampStrength * 0.20)) * gainT
		local preFlickStart = math.max(phase1End, phase2End - 0.24)
		local preFlickBoost = 0
		if delayedProgress >= preFlickStart and delayedProgress < phase2End then
			local t = (delayedProgress - preFlickStart) / math.max(1e-4, (phase2End - preFlickStart))
			preFlickBoost = t * t
		end
		-- Start horizontal loss another 0.15s later than gain timing.
		local horizontalLossDelay = horizontalTimingDelay + 0.15
		local delayedLossProgress = math.clamp((elapsed - horizontalLossDelay) / math.max(1e-4, swingDuration), 0, 1)
		local ascendT = 0
		if delayedLossProgress >= phase2End then
			ascendT = math.clamp((delayedLossProgress - phase2End) / math.max(1e-4, (1 - phase2End)), 0, 1)
		end
		local ascendHorizontalRetention = 1 - (0.85 * ascendT * ascendT)
		local horizontalPeakScale = 0.8
		local targetHorizontalSpeed = baseHorizontalSpeed * horizontalSpeedMultiplier * baseSpeedCurve * speedGain * (1 + preFlickBoost * 1.20) * ascendHorizontalRetention * horizontalPeakScale

		local currentVelocity = rootPart.AssemblyLinearVelocity
		local currentHorizontalVelocity = Vector3.new(currentVelocity.X, 0, currentVelocity.Z)
		local currentHorizontalDirection = if currentHorizontalVelocity.Magnitude >= 0.1 then currentHorizontalVelocity.Unit else moveDirection
		local directionAlpha = math.clamp(0.18 + preFlickBoost * 0.55, 0, 0.9)
		local desiredHorizontalDirection = currentHorizontalDirection:Lerp(playerDirection, directionAlpha)
		if desiredHorizontalDirection.Magnitude < 0.1 then
			desiredHorizontalDirection = playerDirection
		else
			desiredHorizontalDirection = desiredHorizontalDirection.Unit
		end
		local desiredHorizontalVelocity = desiredHorizontalDirection * targetHorizontalSpeed
		local horizontalBlend = math.clamp(0.20 + preFlickBoost * 0.50, 0, 0.85)
		local newHorizontalVelocity = currentHorizontalVelocity:Lerp(desiredHorizontalVelocity, horizontalBlend)
		if ascendT > 0 then
			local ascendBrake = math.clamp(1 - (0.65 * ascendT), 0.20, 1)
			newHorizontalVelocity *= ascendBrake
		end

		rootPart.AssemblyLinearVelocity = Vector3.new(
			newHorizontalVelocity.X,
			targetVerticalSpeed,
			newHorizontalVelocity.Z
		)

		if not grappleHoldActive or progress >= 1 then
			clearGrappleVfx()
			isGrappling = false
			if activeGrappleConnection then
				activeGrappleConnection:Disconnect()
				activeGrappleConnection = nil
			end
		end
	end)

	return true
end

-- Handle Q key press
local function onQKeyPressed()
	-- Don't allow mobility while paused
	if isPaused then
		return
	end
	
	if not equippedMobility then
		return
	end
	
	if equippedMobility == "Dash" then
		executeDash()
	elseif equippedMobility == "ShieldBash" then
		executeDash()  -- Shield Bash uses the same dash function with combat logic
	elseif equippedMobility == "DoubleJump" then
		executeDoubleJump()
	elseif equippedMobility == "Blink" then
		executeBlink()
	elseif equippedMobility == "ManaGrapple" then
		executeManaGrapple()
	end
end

-- Listen for Q key input
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	
	if input.KeyCode == Enum.KeyCode.Q then
		onQKeyPressed()
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Q then
		if isGrappling then
			grappleHoldActive = false
		end
	end
end)

-- Create BindableEvent for mobile button to trigger mobility
local mobilityTrigger = Instance.new("BindableEvent")
mobilityTrigger.Name = "MobilityTrigger"
mobilityTrigger.Parent = ReplicatedStorage
mobilityTrigger.Event:Connect(function()
	onQKeyPressed()
end)

-- Handle character respawn
player.CharacterAdded:Connect(function(newCharacter)
	character = newCharacter
	humanoid = character:WaitForChild("Humanoid") :: Humanoid
	rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
	isDashing = false
	isBlinking = false
	blinkToken += 1
	grappleToken += 1
	isGrappling = false
	grappleHoldActive = false
	
	-- Clean up effects on respawn
	if activeDashConnection then
		activeDashConnection:Disconnect()
		activeDashConnection = nil
	end
	
	if activeBlinkConnection then
		activeBlinkConnection:Disconnect()
		activeBlinkConnection = nil
	end
	clearBlinkTransparency()

	if activeGrappleConnection then
		activeGrappleConnection:Disconnect()
		activeGrappleConnection = nil
	end
	clearGrappleVfx()
	
	if activeGravityConnection then
		activeGravityConnection:Disconnect()
		activeGravityConnection = nil
	end
	
	if activeTrail and activeTrail.Parent then
		activeTrail:Destroy()
		activeTrail = nil
	end
	
	if activeGravityEffect and activeGravityEffect.Parent then
		activeGravityEffect:Destroy()
		activeGravityEffect = nil
	end
end)

-- Pause/Unpause event listeners
local function setupPauseListeners()
	local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
	local GamePaused = remotes:WaitForChild("GamePaused")
	local GameUnpaused = remotes:WaitForChild("GameUnpaused")
	
	GamePaused.OnClientEvent:Connect(function()
		isPaused = true
		pauseStartTime = tick()
		if usingServerTime then
			pausedServerGameTime = serverGameTime
		end
		
		-- Completely freeze player by anchoring
		if rootPart and rootPart.Parent then
			-- Store current velocity and position
			rootPart:SetAttribute("PausedVelocity", rootPart.AssemblyLinearVelocity)
			rootPart:SetAttribute("WasAnchored", rootPart.Anchored)
			
			-- Anchor to prevent ALL movement and jumping
			rootPart.Anchored = true
		end
		
		-- Pause active trail
		if activeTrail and activeTrail.Parent then
			activeTrail.Enabled = false
		end
	end)
	
	GameUnpaused.OnClientEvent:Connect(function()
		isPaused = false
		
		-- Calculate how long we were paused
		local pauseDuration = tick() - pauseStartTime
		totalPausedTime = totalPausedTime + pauseDuration
		
		if usingServerTime and pausedServerGameTime then
			local resumeServerTime = serverGameTime or pausedServerGameTime
			local pauseDurationServer = math.max(0, resumeServerTime - pausedServerGameTime)
			lastUsedTime = lastUsedTime + pauseDurationServer
			pausedServerGameTime = nil
		elseif not usingServerTime then
			lastUsedTime = lastUsedTime + pauseDuration
		end
		
		-- Unfreeze player and restore velocity
		if rootPart and rootPart.Parent then
			-- Restore anchored state
			local wasAnchored = rootPart:GetAttribute("WasAnchored")
			if wasAnchored ~= nil then
				rootPart.Anchored = wasAnchored
				rootPart:SetAttribute("WasAnchored", nil)
			else
				rootPart.Anchored = false  -- Default to unanchored
			end
			
			-- Restore velocity after unanchoring (must be in this order!)
			local pausedVel = rootPart:GetAttribute("PausedVelocity")
			if pausedVel then
				task.wait()  -- Wait one frame for physics to update after unanchoring
				rootPart.AssemblyLinearVelocity = pausedVel
				rootPart:SetAttribute("PausedVelocity", nil)
			end
		end
		
		-- Resume active trail if it exists and should still be active
		if activeTrail and activeTrail.Parent then
			local currentTime = tick()
			-- Only resume if trail hasn't expired
			if currentTime - trailStartTime < DOUBLE_JUMP_CONFIG.trailDuration then
				activeTrail.Enabled = true
			end
		end
	end)
end

-- Initialize
initRemotes()
setupPauseListeners()
