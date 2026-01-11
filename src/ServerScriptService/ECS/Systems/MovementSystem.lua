--!strict
-- MovementSystem - updates entity positions based on velocity (non-player entities)

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local DEBUG = GameOptions.Debug and GameOptions.Debug.Enabled

local ProfilingConfig = require(ReplicatedStorage.Shared.ProfilingConfig)
local Prof = ProfilingConfig.ENABLED and require(ReplicatedStorage.Shared.ProfilingServer) or require(ReplicatedStorage.Shared.ProfilingStub)

local MovementSystem = {}

local world: any
local Components: any
local DirtyService: any
local Position: any
local _Velocity: any
local _EntityType: any
local _ProjectileData: any
local _Lifetime: any
local _Homing: any
local _AI: any  -- AI component for enemy speed data

-- Cached query for performance
local movingQuery: any

-- Ground height caching (CRITICAL FIX - raycasting every frame is expensive!)
local groundHeightCache: {[string]: {height: number, time: number}} = {}
local GROUND_CACHE_DURATION = 5.0 -- Increased from 2.0 to 5.0 (ground rarely changes)
local GROUND_CHECK_INTERVAL = 0.5 -- Increased from 0.2 to 0.5 (check every 0.5s per entity)
local entityGroundCheckTimers: {[number]: number} = {}
local entityLastPosition: {[number]: {x: number, z: number}} = {}  -- Track horizontal movement

-- Ground height smoothing (prevent teleporting on ragged terrain)
local entityTargetGroundHeight: {[number]: number} = {}  -- Target ground height to lerp towards
local entityCurrentGroundHeight: {[number]: number} = {}  -- Current smoothed ground height
local GROUND_HEIGHT_SMOOTHING = 0.35  -- Lerp factor for ground height transitions (35% per frame - more aggressive)
local GROUND_HEIGHT_DEADZONE = 0.1  -- Don't update if change is less than this (prevents micro-jitter)

-- Profiling accumulators (reset per step)
local groundRaycastTime = 0
local exclusionBuildTime = 0
local exclusionRebuilds = 0
local exclusionCacheSize = 0

-- Cache cleanup to prevent unbounded growth (MEMORY LEAK FIX 1.3)
local CACHE_CLEANUP_INTERVAL = 60.0  -- Clean every 60 seconds
local cacheCleanupAccumulator = 0

-- Track player positions for StickToPlayer projectiles
local playerLastPositions: {[number]: Vector3} = {} -- key = projectileEntityId, value = last player position

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

-- Cache for player parts to avoid recreating tables every frame
local playerPartsCache = {}
local lastPlayerPartsUpdate = 0
local PLAYER_PARTS_CACHE_INTERVAL = 2.0 -- PERFORMANCE FIX: Increased from 1.0 to 2.0 seconds

-- Cache for transparent/non-collidable parts
local TRANSPARENT_PARTS_REBUILD_INTERVAL = 5.0  -- Rebuild every 5 seconds
local lastTransparentPartsRebuild = 0

-- Function to get all parts to exclude from ground detection (players, exp orbs, etc)
local function getPartsToExcludeFromGround()
	local currentTime = tick()
	
	-- Use cached result if it's recent enough (AND transparent parts haven't expired)
	local needsTransparentRebuild = (currentTime - lastTransparentPartsRebuild) >= TRANSPARENT_PARTS_REBUILD_INTERVAL
	if currentTime - lastPlayerPartsUpdate < PLAYER_PARTS_CACHE_INTERVAL and #playerPartsCache > 0 and not needsTransparentRebuild then
		return playerPartsCache
	end
	
	local rebuildStart = os.clock()

	-- Clear and rebuild cache
	table.clear(playerPartsCache)
	local Players = game:GetService("Players")
	local Workspace = game:GetService("Workspace")
	
	-- Exclude player characters
	for _, player in pairs(Players:GetPlayers()) do
		if player.Character then
			-- Exclude character body parts
			for _, part in pairs(player.Character:GetChildren()) do
				if part:IsA("BasePart") then
					table.insert(playerPartsCache, part)
				end
			end
			
			-- Exclude accessories
			for _, accessory in pairs(player.Character:GetChildren()) do
				if accessory:IsA("Accessory") then
					local handle = accessory:FindFirstChild("Handle")
					if handle then
						table.insert(playerPartsCache, handle)
					end
				end
			end
		end
	end
	
	-- CRITICAL FIX: Exclude all exp orbs from ground raycasts
	-- Zombies should pass through orbs, not raycast them
	local expOrbsFolder = Workspace:FindFirstChild("ExpOrbs")
	if expOrbsFolder then
		for _, orbModel in pairs(expOrbsFolder:GetChildren()) do
			if orbModel:IsA("Model") then
				for _, part in pairs(orbModel:GetDescendants()) do
					if part:IsA("BasePart") then
						table.insert(playerPartsCache, part)
					end
				end
			end
		end
	end
	
	-- Exclude powerups from ground raycasts
	local powerupsFolder = Workspace:FindFirstChild("Powerups")
	if powerupsFolder then
		for _, powerupModel in pairs(powerupsFolder:GetChildren()) do
			if powerupModel:IsA("Model") then
				for _, part in pairs(powerupModel:GetDescendants()) do
					if part:IsA("BasePart") then
						table.insert(playerPartsCache, part)
					end
				end
			end
		end
	end
	
	-- Exclude projectiles from ground raycasts
	local projectilesFolder = Workspace:FindFirstChild("Projectiles")
	if projectilesFolder then
		for _, projectileModel in pairs(projectilesFolder:GetChildren()) do
			if projectileModel:IsA("Model") then
				for _, part in pairs(projectileModel:GetDescendants()) do
					if part:IsA("BasePart") then
						table.insert(playerPartsCache, part)
					end
				end
			end
		end
	end
	
	-- PHYSICS BUG FIX 2.1: DO NOT exclude enemies from ground detection
	-- Removing enemy exclusion - enemies should NOT be excluded from raycasts
	-- This was causing zombies to raycast through each other and hit weird geometry
	
	-- Exclude transparent (>= 1) and non-collidable parts from raycasts
	-- Only rebuild this list every 5 seconds for performance
	if needsTransparentRebuild then
		lastTransparentPartsRebuild = currentTime
		
		-- Iterate through workspace to find transparent/non-collidable parts
		for _, descendant in pairs(Workspace:GetDescendants()) do
			if descendant:IsA("BasePart") then
				-- Exclude if: (Transparency >= 1 OR CanCollide == false)
				if descendant.Transparency >= 1 or not descendant.CanCollide then
					table.insert(playerPartsCache, descendant)
				end
			elseif descendant:IsA("MeshPart") then
				-- MeshParts also need to be checked
				if descendant.Transparency >= 1 or not descendant.CanCollide then
					table.insert(playerPartsCache, descendant)
				end
			end
		end
	end
	
	lastPlayerPartsUpdate = currentTime
	exclusionBuildTime += os.clock() - rebuildStart
	exclusionRebuilds += 1
	exclusionCacheSize = #playerPartsCache
	return playerPartsCache
end

-- Update raycast parameters to exclude non-terrain objects
local function updateRaycastParams()
	raycastParams.FilterDescendantsInstances = getPartsToExcludeFromGround()
end

local DEFAULT_HEIGHT_OFFSET = 0

local function vectorToTable(vector: Vector3): {x: number, y: number, z: number}
	return {
		x = vector.X,
		y = vector.Y,
		z = vector.Z,
	}
end

local function tableToVector(data: any): Vector3?
	if typeof(data) ~= "table" then
		return nil
	end

	local x = data.x or data.X
	local y = data.y or data.Y
	local z = data.z or data.Z
	if x == nil or y == nil or z == nil then
		return nil
	end
	return Vector3.new(x, y, z)
end

-- Get ground height grid key for caching
local function getGroundCacheKey(x: number, z: number): string
	-- Round to grid for caching (3 stud grid - finer for ragged terrain)
	local gridX = math.floor(x / 3)
	local gridZ = math.floor(z / 3)
	return string.format("%d,%d", gridX, gridZ)
end

local function getGroundHeight(position: {x: number, y: number, z: number}): number?
	local cacheKey = getGroundCacheKey(position.x, position.z)
	local cached = groundHeightCache[cacheKey]
	local currentTime = tick()
	
	-- Use cached result if recent enough
	if cached and (currentTime - cached.time) < GROUND_CACHE_DURATION and cached.height then
		return cached.height
	end
	
	-- Perform raycast
	updateRaycastParams() -- Update to exclude players, enemies, projectiles
	local origin = Vector3.new(position.x, (position.y or 0) + 25, position.z)
	Prof.incCounter("Movement.Raycasts", 1)
	local raycastStart = os.clock()
	local result = Workspace:Raycast(origin, Vector3.new(0, -250, 0), raycastParams)
	groundRaycastTime += os.clock() - raycastStart
	
	local height = nil
	if result and result.Instance then
		-- Validate result (don't accept unreasonably high ground)
		local resultY = result.Position.Y
		local currentY = position.y or 0
		
		-- CANOPY FIX: If ground is more than 10 studs above current position, reject it
		-- This prevents enemies from teleporting to tree canopies above them
		if resultY > currentY + 10 then
			-- Detected ground above (like tree canopy), keep current Y
			height = currentY
		-- If ground is more than 50 studs above current position, something is wrong
		elseif resultY > currentY + 50 then
			-- Bad raycast data, use current Y
			height = currentY
		else
			height = resultY
		end
	end
	
	-- Cache the result (only if we got valid data)
	if height then
		groundHeightCache[cacheKey] = {
			height = height,
			time = currentTime
		}
	end
	
	return height
end

function MovementSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	Position = Components.Position
	_Velocity = Components.Velocity
	_EntityType = Components.EntityType
	_ProjectileData = Components.ProjectileData
	_Lifetime = Components.Lifetime
	_Homing = Components.Homing
	_AI = Components.AI  -- For enemy speed data
	
	-- Create cached query for performance
	movingQuery = world:query(Components.Position, Components.Velocity, Components.EntityType):cached()
end

function MovementSystem.step(dt: number)
	if not world then
		return
	end

	Prof.beginTimer("Movement.Time")
	groundRaycastTime = 0
	exclusionBuildTime = 0
	exclusionRebuilds = 0

	-- Periodic cache cleanup (MEMORY LEAK FIX 1.3)
	cacheCleanupAccumulator = cacheCleanupAccumulator + dt
	if cacheCleanupAccumulator >= CACHE_CLEANUP_INTERVAL then
		cacheCleanupAccumulator = 0
		-- Clear old cache entries
		local currentTime = tick()
		for key, entry in pairs(groundHeightCache) do
			if currentTime - entry.time > GROUND_CACHE_DURATION * 2 then
				groundHeightCache[key] = nil
			end
		end
		
		-- Clean up tracking tables for non-existent entities
		-- Check if entity still exists in the query
		local activeEntities = {}
		for entity in movingQuery do
			activeEntities[entity] = true
		end
		
		-- Remove tracking data for destroyed entities
		for entity in pairs(entityGroundCheckTimers) do
			if not activeEntities[entity] then
				entityGroundCheckTimers[entity] = nil
				entityLastPosition[entity] = nil
				entityTargetGroundHeight[entity] = nil
				entityCurrentGroundHeight[entity] = nil
				playerLastPositions[entity] = nil  -- NEW: Cleanup StickToPlayer tracking
			end
		end
	end

	-- Use cached query for better performance
	for entity, position, velocity, entityType in movingQuery do
		-- Exclude players from movement system (they have their own character movement)
		if entityType and entityType.type == "Player" then
			continue
		end
		
		-- Exclude ExpOrbs from movement system UNLESS they have a MagnetPull component (being pulled by magnet powerup)
		if entityType and entityType.type == "ExpOrb" then
			local magnetPull = world:get(entity, Components.MagnetPull)
			if not magnetPull then
				continue  -- Orb is not being pulled, keep it stationary
			end
			-- If magnetPull exists, allow the orb to move
		end
		
		-- Skip entities with very low velocity (optimization)
		local velocityMagnitude = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z)
		if velocityMagnitude < 0.01 then
			continue  -- Not moving, no need to update
		end

		local newPosition = {
			x = position.x,
			y = position.y,
			z = position.z,
		}

		local handledByProjectileLerp = false
		if entityType.type == "Projectile" then
			-- Skip lerp movement for homing projectiles (they use velocity-based movement)
			local homingComponent = world:get(entity, _Homing)
			local isHoming = homingComponent ~= nil
			
		if not isHoming then
			-- Only use lerp movement for non-homing projectiles (UNLESS StickToPlayer is active)
			local projectileData = world:get(entity, _ProjectileData)
			local lifetime = world:get(entity, _Lifetime)
			
			-- StickToPlayer projectiles must use velocity-based movement (lerp uses fixed positions)
			local shouldUseLerp = projectileData 
				and not projectileData.stickToPlayer  -- Skip lerp if sticking to player
				and lifetime 
				and projectileData.startPosition 
				and projectileData.targetPosition 
				and projectileData.travelTime 
				and projectileData.travelTime > 0
			
			if shouldUseLerp then
				local startVector = tableToVector(projectileData.startPosition)
				local targetVector = tableToVector(projectileData.targetPosition)
				if startVector and targetVector then
					local elapsed = lifetime.max - lifetime.remaining
					local alpha = math.clamp(elapsed / projectileData.travelTime, 0, 1)
					if alpha < 1 then
						local lerped = startVector:Lerp(targetVector, alpha)
						newPosition = vectorToTable(lerped)
						handledByProjectileLerp = true
					end

					local directionVector = targetVector - startVector
					if directionVector.Magnitude > 0 then
						local speed = projectileData.speed or 0
						local velocityVector: Vector3
						velocityVector = directionVector.Unit * speed
						DirtyService.setIfChanged(world, entity, _Velocity, vectorToTable(velocityVector), "Velocity")
					else
						DirtyService.setIfChanged(world, entity, _Velocity, vectorToTable(Vector3.new(0, 0, 0)), "Velocity")
					end
				end
			end
		end
		end

		if not handledByProjectileLerp then
			newPosition = {
				x = position.x + velocity.x * dt,
				y = position.y + velocity.y * dt,
				z = position.z + velocity.z * dt,
			}
		end
		
		-- Clamp per-frame enemy displacement to prevent teleporting from lag spikes
		-- DYNAMIC CLAMPING: Use enemy's actual speed (accounts for different types + scaling)
		if entityType.type == "Enemy" and not handledByProjectileLerp then
			-- Get enemy's current expected speed from AI component
			local enemySpeed = 150  -- Fallback: generous default for safety
			local ai = world:get(entity, _AI)
			if ai and ai.speed then
				enemySpeed = ai.speed  -- Use scaled speed (baseSpeed * globalMult * lifetimeMult)
			end
			
			-- Allow 2.5x tolerance for burst movement, repulsion, knockback, and frame spikes
			-- This prevents false positives while still catching actual teleports
			local maxDisplacementPerFrame = (enemySpeed * 2.5) * dt
			
			local dx = newPosition.x - position.x
			local dy = newPosition.y - position.y
			local dz = newPosition.z - position.z
			local displacement = math.sqrt(dx*dx + dy*dy + dz*dz)
			
			if displacement > maxDisplacementPerFrame then
				-- Clamp displacement
				local scale = maxDisplacementPerFrame / displacement
				newPosition.x = position.x + dx * scale
				newPosition.y = position.y + dy * scale
				newPosition.z = position.z + dz * scale
				
			-- Only log warning for normal frame times (skip when game is paused/massive lag spike)
			-- Also skip warning for near-stationary enemies with tiny displacements (floating-point noise)
			if DEBUG and dt < 0.1 and not (enemySpeed < 5.0 and displacement < 0.5) then
				warn(string.format("[MovementSystem] Clamped entity %d: %.2f -> %.2f studs (speed: %.1f, dt: %.4f)", 
					entity, displacement, maxDisplacementPerFrame, enemySpeed, dt))
			end
			end
		end
		
		-- PROJECTILE BEHAVIOR FLAGS: StickToPlayer and AlwaysStayHorizontal
		if entityType.type == "Projectile" then
			local projectileData = world:get(entity, _ProjectileData)
			if projectileData then
				-- PRIORITY 1: StickToPlayer - projectile follows player movement delta
				if projectileData.stickToPlayer then
					local owner = projectileData.owner
					if owner and owner:IsA("Player") and owner.Character then
						local hrp = owner.Character:FindFirstChild("HumanoidRootPart")
						if hrp and hrp:IsA("BasePart") then
							local currentPlayerPos = (hrp :: BasePart).Position
							local lastPlayerPos = playerLastPositions[entity]
							
							if lastPlayerPos then
								-- Calculate player movement delta
								local playerDelta = currentPlayerPos - lastPlayerPos
								
								-- Apply delta to projectile position
								newPosition.x = newPosition.x + playerDelta.X
								newPosition.y = newPosition.y + playerDelta.Y
								newPosition.z = newPosition.z + playerDelta.Z
							else
								-- First frame: Initialize tracking (projectile just spawned at player position)
								-- No delta to apply yet, but start tracking for next frame
							end
							
							-- Always update tracked position (even on first frame)
							playerLastPositions[entity] = currentPlayerPos
						end
					end
				end
				
				-- PRIORITY 2: AlwaysStayHorizontal - lock Y at spawn (skip if StickToPlayer handled it)
				if projectileData.alwaysStayHorizontal and not projectileData.stickToPlayer then
					local spawnY = projectileData.startPosition and projectileData.startPosition.y or newPosition.y
					newPosition.y = spawnY
					
					-- Also flatten velocity Y component
					if velocity.y ~= 0 then
						DirtyService.setIfChanged(world, entity, _Velocity, {
							x = velocity.x,
							y = 0,
							z = velocity.z,
						}, "Velocity")
					end
				end
			end
		end
		
		-- Only apply ground snapping to enemies, not projectiles
		-- Throttle ground checks per entity (CRITICAL FIX - raycasting every frame is too expensive!)
		if entityType.type == "Enemy" then
			-- WALL CLIMBING: Skip ground snapping if enemy has significant vertical velocity
			local isClimbing = velocity.y > 0.5  -- Climbing up
			local isFalling = velocity.y < -0.5  -- Falling down fast
			
			local currentTime = tick()
			local lastCheck = entityGroundCheckTimers[entity] or 0
			local lastPos = entityLastPosition[entity]
			
			-- Check if entity moved horizontally (optimization)
			local movedHorizontally = false
			if lastPos then
				local dx = math.abs(newPosition.x - lastPos.x)
				local dz = math.abs(newPosition.z - lastPos.z)
				movedHorizontally = (dx + dz) > 1.0  -- Moved more than 1 stud horizontally
			else
				movedHorizontally = true  -- First check
			end
			
			-- Only check ground at intervals AND if moved significantly AND not climbing/falling
			if not isClimbing and not isFalling and movedHorizontally and currentTime - lastCheck >= GROUND_CHECK_INTERVAL then
				entityGroundCheckTimers[entity] = currentTime
				entityLastPosition[entity] = {x = newPosition.x, z = newPosition.z}
				
				-- Use cached raycast to find target ground level
				local groundHeight = getGroundHeight(newPosition)
				if groundHeight then
					-- PHYSICS BUG FIX 2.2: Prevent unreasonably low ground (map floor is usually > -50)
					if groundHeight < -50 then
						groundHeight = -50  -- Set floor limit
					end
					
					-- Set target ground height for smooth lerping
					entityTargetGroundHeight[entity] = groundHeight
				else
					-- If no ground found, target current Y position
					entityTargetGroundHeight[entity] = position.y
				end
			end
			
			-- Initialize smoothed height if not present
			if not entityCurrentGroundHeight[entity] then
				entityCurrentGroundHeight[entity] = position.y
			end
			
			-- Initialize target height if not present
			if not entityTargetGroundHeight[entity] then
				entityTargetGroundHeight[entity] = position.y
			end
			
			-- Smooth ground height transitions to prevent teleporting on ragged terrain
			local targetHeight = entityTargetGroundHeight[entity]
			local currentHeight = entityCurrentGroundHeight[entity]
			
			-- Lerp current height towards target height
			local heightDiff = targetHeight - currentHeight
			
			-- Deadzone: ignore tiny differences to prevent micro-jitter
			if math.abs(heightDiff) < GROUND_HEIGHT_DEADZONE then
				heightDiff = 0
			else
				local maxChangePerFrame = 12 * dt  -- Max 12 studs/second change (reduced from 15)
				
				-- Clamp the change to prevent too-rapid snapping
				if math.abs(heightDiff) > maxChangePerFrame then
					heightDiff = heightDiff > 0 and maxChangePerFrame or -maxChangePerFrame
				end
				
				-- Apply smoothed change with more aggressive lerping
				currentHeight = currentHeight + heightDiff * GROUND_HEIGHT_SMOOTHING
			end
			
			entityCurrentGroundHeight[entity] = currentHeight
			
			-- Use smoothed height for position
			newPosition.y = currentHeight
			
			-- Apply smooth descent when falling (gravity simulation)
			if isFalling then
				-- Let the falling motion continue naturally, update smoothed height tracking
				newPosition.y = position.y + velocity.y * dt
				entityCurrentGroundHeight[entity] = newPosition.y
				entityTargetGroundHeight[entity] = newPosition.y
			end
			
			-- If climbing, update smoothed height tracking
			if isClimbing then
				entityCurrentGroundHeight[entity] = newPosition.y
				entityTargetGroundHeight[entity] = newPosition.y
			end
		end
		-- Projectiles keep their calculated Y position (no ground snapping)

		-- Only mark dirty if position actually changed
		if newPosition.x ~= position.x or newPosition.y ~= position.y or newPosition.z ~= position.z then
			DirtyService.setIfChanged(world, entity, Position, newPosition, "Position")
		end
	end

	if groundRaycastTime > 0 then
		Prof.incCounter("Movement.RaycastMs", math.floor(groundRaycastTime * 1000 + 0.5))
	end
	if exclusionBuildTime > 0 then
		Prof.incCounter("Movement.ExclusionBuildMs", math.floor(exclusionBuildTime * 1000 + 0.5))
	end
	if exclusionRebuilds > 0 then
		Prof.incCounter("Movement.ExclusionRebuilds", exclusionRebuilds)
	end
	if exclusionCacheSize > 0 then
		Prof.gauge("Movement.ExclusionCacheSize", exclusionCacheSize)
	end

	Prof.endTimer("Movement.Time")
end

return MovementSystem
