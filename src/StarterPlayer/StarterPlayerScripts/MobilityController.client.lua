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

-- Shield Bash config values from server
local serverDamage: number? = nil
local serverKnockbackDistance: number? = nil

-- Track if currently dashing (prevent spam)
local isDashing = false
local activeDashConnection: RBXScriptConnection? = nil

-- Pause state
local isPaused = false
local pauseStartTime: number = 0
local totalPausedTime: number = 0

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
		end
		
		-- Update passive effects (for multipliers)
		if updateData.PassiveEffects then
			local data = updateData.PassiveEffects
			if typeof(data) == "table" then
				if typeof(data.mobilityDistanceMultiplier) == "number" then
					mobilityDistanceMultiplier = data.mobilityDistanceMultiplier
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
			currentTime = serverGameTime
		else
			currentTime = serverGameTime + math.max(0, tick() - lastGameTimeUpdate)
		end
	elseif isPaused then
		currentTime = pauseStartTime
	end
	local effectiveCooldown = config.cooldown * cooldownMultiplier
	local timeSinceLastUse = currentTime - lastUsedTime
	return timeSinceLastUse < effectiveCooldown
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
	
	-- Apply distance multiplier from Haste
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
		verticalHeight = serverVerticalHeight or DOUBLE_JUMP_CONFIG.verticalHeight,
		cooldown = serverCooldown or DOUBLE_JUMP_CONFIG.cooldown,
	}
	
	-- Check cooldown
	if isOnCooldown(effectiveConfig) then
		return false
	end
	
	-- Apply distance multiplier from Haste
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
	
	-- Clean up effects on respawn
	if activeDashConnection then
		activeDashConnection:Disconnect()
		activeDashConnection = nil
	end
	
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
		
		-- Adjust cooldown only when using local time (server game time is already pause-aware)
		if not usingServerTime then
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
