--!strict
-- EnemySpawner - Handles spawning enemies around players
-- Spawns zombies at intervals near players

local Workspace = game:GetService("Workspace")
local EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
local EasingUtils = require(game.ServerScriptService.Balance.EasingUtils)
local EnemyRegistry = require(game.ServerScriptService.Enemies.EnemyRegistry)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local SpatialGridSystem = require(game.ServerScriptService.ECS.Systems.SpatialGridSystem)

local EnemySpawner = {}

-- Spatial grid size for density checking
local GRID_SIZE = SpatialGridSystem.getGridSize()

local world: any
local Components: any
local ECSWorldService: any
local ModelReplicationService: any
local QueryPool: any

local PlayerStats: any
local Position: any

local spawnAccumulator = 0 -- Accumulates enemies to spawn
local initialDelayAccumulator = 0
local hasInitialDelayPassed = false
local zombieSpawnCounter = 0 -- Track total zombie spawns for debug messages
local spawnEnabled = true

-- Nuke powerup state
local nukeActive = false
local nukeEndTime = 0
local nukeRestoreEndTime = 0  -- NEW: When restoration completes
local PowerupBalance = require(game.ServerScriptService.Balance.PowerupBalance)
local NUKE_RESTORE_DURATION = PowerupBalance.PowerupTypes.Nuke.restoreDuration or 15  -- 15 seconds to fully restore spawn rate

-- Spawn check throttle (PERFORMANCE FIX - don't run spawn logic every frame!)
local SPAWN_CHECK_INTERVAL = 0.5  -- Only check/spawn every 0.5 seconds
local spawnCheckAccumulator = 0

-- Cached queries for performance
local enemyCountQuery: any
local playerPositionQuery: any

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

-- RNG for enemy type selection
local enemyTypeRNG = Random.new()

-- Cache for enemy types and weights
local enemyTypes = {}
local cumulativeWeights = {}
local totalWeight = 0

-- Build weighted selection tables
local function rebuildEnemyWeights()
	table.clear(enemyTypes)
	table.clear(cumulativeWeights)
	totalWeight = 0
	
	local weights = EnemyBalance.SpawnWeights or {}
	
	-- Get all available enemy types from registry
	for enemyType, _ in pairs(weights) do
		local config = EnemyRegistry.getEnemyConfig(enemyType)
		if config then
			local weight = weights[enemyType] or 0
			if weight > 0 then
				totalWeight = totalWeight + weight
				table.insert(enemyTypes, enemyType)
				table.insert(cumulativeWeights, totalWeight)
			end
		end
	end
end

-- Select a random enemy type based on weights
local function selectRandomEnemyType(): string
	if #enemyTypes == 0 then
		return "Zombie" -- Fallback
	end
	
	if #enemyTypes == 1 then
		return enemyTypes[1]
	end
	
	local roll = enemyTypeRNG:NextNumber(0, totalWeight)
	
	for i, cumulativeWeight in ipairs(cumulativeWeights) do
		if roll <= cumulativeWeight then
			return enemyTypes[i]
		end
	end
	
	return enemyTypes[#enemyTypes] -- Fallback to last type
end

-- Cache for player parts to avoid recreating tables every frame
local playerPartsCache = {}
local lastPlayerPartsUpdate = 0
local PLAYER_PARTS_CACHE_INTERVAL = 1.0 -- Update cache every 1 second

-- Cache for transparent/non-collidable parts
local TRANSPARENT_PARTS_REBUILD_INTERVAL = 5.0  -- Rebuild every 5 seconds
local lastTransparentPartsRebuild = 0

-- Function to get all player-related parts to exclude from ground detection
local function getPlayerPartsToExclude()
	local currentTime = tick()
	
	-- Check if transparent parts need rebuilding
	local needsTransparentRebuild = (currentTime - lastTransparentPartsRebuild) >= TRANSPARENT_PARTS_REBUILD_INTERVAL
	
	-- Use cached result if it's recent enough and transparent parts are fresh
	if currentTime - lastPlayerPartsUpdate < PLAYER_PARTS_CACHE_INTERVAL and #playerPartsCache > 0 and not needsTransparentRebuild then
		return playerPartsCache
	end
	
	-- Clear and rebuild cache
	table.clear(playerPartsCache)
	local Players = game:GetService("Players")
	
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
	
	-- Exclude exp orbs
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
	
	-- Exclude powerups
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
	
	-- Exclude projectiles
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
	
	-- Exclude transparent and non-collidable parts (rebuild every 5 seconds)
	if needsTransparentRebuild then
		lastTransparentPartsRebuild = currentTime
		
		for _, descendant in pairs(Workspace:GetDescendants()) do
			if descendant:IsA("BasePart") or descendant:IsA("MeshPart") then
				-- Exclude if: (Transparency >= 1 OR CanCollide == false)
				if descendant.Transparency >= 1 or not descendant.CanCollide then
					table.insert(playerPartsCache, descendant)
				end
			end
		end
	end
	
	lastPlayerPartsUpdate = currentTime
	return playerPartsCache
end

-- Update raycast parameters to exclude player parts
local function updateRaycastParams()
	raycastParams.FilterDescendantsInstances = getPlayerPartsToExclude()
end

function EnemySpawner.init(worldRef: any, components: any, ecsWorldService: any, modelReplicationService: any)
	world = worldRef
	Components = components
	ECSWorldService = ecsWorldService
	ModelReplicationService = modelReplicationService

	PlayerStats = Components.PlayerStats
	Position = Components.Position
	
	-- Create cached queries for performance (CRITICAL FIX)
	enemyCountQuery = world:query(Components.EntityType):cached()
	playerPositionQuery = world:query(Components.Position, Components.PlayerStats):cached()
	
	-- Build enemy type weights
	rebuildEnemyWeights()
end

local function getGroundedPosition(position: Vector3, heightOffset: number): Vector3?
	updateRaycastParams() -- Update to exclude player parts
	local origin = position + Vector3.new(0, 25, 0)
	local result = Workspace:Raycast(origin, Vector3.new(0, -200, 0), raycastParams)
	if result then
		local groundY = result.Position.Y
		local yDifference = math.abs(groundY - position.Y)
		
		-- Validate: Ground must be within +/- 20 studs of spawn position
		if yDifference > 20 then
			-- Ground too far above or below - reject this spawn position
			return nil
		end
		
		-- Validate: Don't spawn on canopies far above spawn origin
		-- If ground is more than 25 studs above the spawn origin Y, reject it
		if groundY > position.Y + 25 then
			-- Likely hit a tree canopy or elevated structure, reject
			return nil
		end
		
		return Vector3.new(position.X, groundY + heightOffset, position.Z)
	end
	
	-- No ground found, reject spawn
	return nil
end

local function getRandomSpawnPosition(playerPos: {x: number, y: number, z: number}, sectorAngleMin: number?, sectorAngleMax: number?): Vector3
	-- Safety check for player position
	if not playerPos or not playerPos.x or not playerPos.y or not playerPos.z then
		warn("[EnemySpawner] Invalid player position provided to getRandomSpawnPosition:", playerPos)
		return Vector3.new(0, 0, 0) -- Fallback position
	end
	
	-- Generate random angle (constrained to sector if specified)
	local angle
	if sectorAngleMin and sectorAngleMax then
		angle = sectorAngleMin + math.random() * (sectorAngleMax - sectorAngleMin)
	else
		angle = math.random() * math.pi * 2
	end
	
	local minRadius = EnemyBalance.MinSpawnRadius or 15
	local maxRadius = EnemyBalance.MaxSpawnRadius or 35
	local distance = minRadius + math.random() * (maxRadius - minRadius)

	local offsetX = math.cos(angle) * distance
	local offsetZ = math.sin(angle) * distance

    return Vector3.new(playerPos.x + offsetX, playerPos.y, playerPos.z + offsetZ)
end

-- Count enemies within a sector (angular wedge) of the spawn ring
local function countEnemiesInSector(playerPos: {x: number, y: number, z: number}, sectorAngleMin: number, sectorAngleMax: number): number
	if not world or not Components or not Position then
		return 0
	end
	
	local playerPosVec = Vector3.new(playerPos.x, playerPos.y, playerPos.z)
	local minRadius = EnemyBalance.MinSpawnRadius or 90
	local maxRadius = EnemyBalance.MaxSpawnRadius or 170
	
	-- Use SpatialGridSystem to efficiently find enemies in the spawn ring
	local searchRadius = maxRadius + 10  -- Add buffer
	local radiusCells = math.ceil(searchRadius / GRID_SIZE)
	local nearbyEntities = SpatialGridSystem.getNeighboringEntities(playerPosVec, radiusCells)
	
	local count = 0
	for _, entity in ipairs(nearbyEntities) do
		if world:contains(entity) then
			local entityType = world:get(entity, Components.EntityType)
			if entityType and entityType.type == "Enemy" then
				local enemyPos = world:get(entity, Position)
				if enemyPos then
					local enemyPosVec = Vector3.new(enemyPos.x, enemyPos.y, enemyPos.z)
					local offset = enemyPosVec - playerPosVec
					local dist = Vector3.new(offset.X, 0, offset.Z).Magnitude  -- Ignore Y axis
					
					-- Check if enemy is within spawn ring radius
					if dist >= minRadius and dist <= maxRadius then
						-- Calculate angle from player to enemy
						local angle = math.atan2(offset.Z, offset.X)
						if angle < 0 then
							angle = angle + math.pi * 2  -- Normalize to 0-2π
						end
						
						-- Check if angle is within sector
						if angle >= sectorAngleMin and angle <= sectorAngleMax then
							count = count + 1
						end
					end
				end
			end
		end
	end
	
	return count
end

-- Select the emptiest sector around the player
-- Returns: (sectorAngleMin, sectorAngleMax, enemyCount)
local function selectEmptiestsector(playerPos: {x: number, y: number, z: number}): (number, number, number)
	local config = EnemyBalance.SectorSpawning
	local sectorCount = config.SectorCount or 8
	local sectorSize = (math.pi * 2) / sectorCount  -- Radians per sector
	
	local bestSectorMin = 0
	local bestSectorMax = sectorSize
	local lowestCount = math.huge
	
	-- Check each sector
	for i = 0, sectorCount - 1 do
		local sectorMin = i * sectorSize
		local sectorMax = (i + 1) * sectorSize
		
		local enemyCount = countEnemiesInSector(playerPos, sectorMin, sectorMax)
		
		if enemyCount < lowestCount then
			lowestCount = enemyCount
			bestSectorMin = sectorMin
			bestSectorMax = sectorMax
		end
	end
	
	return bestSectorMin, bestSectorMax, lowestCount
end

-- Count enemies within radius of a position using SpatialGridSystem
local function countEnemiesNearPosition(position: Vector3, radius: number): number
	if not world or not Components then
		return 0
	end
	
	-- Use SpatialGridSystem to efficiently find nearby enemies
	local radiusCells = math.ceil(radius / GRID_SIZE)
	local nearbyEntities = SpatialGridSystem.getNeighboringEntities(position, radiusCells)
	
	local count = 0
	for _, entity in ipairs(nearbyEntities) do
		if world:contains(entity) then
			local entityType = world:get(entity, Components.EntityType)
			if entityType and entityType.type == "Enemy" then
				local enemyPos = world:get(entity, Position)
				if enemyPos then
					local enemyPosVec = Vector3.new(enemyPos.x, enemyPos.y, enemyPos.z)
					local dist = (enemyPosVec - position).Magnitude
					if dist <= radius then
						count = count + 1
					end
				end
			end
		end
	end
	
	return count
end

-- Get spawn position with sector-based distribution and density checking
-- Returns: (position: Vector3?, localDensity: number, sectorInfo: string?)
local function getDensityAwareSpawnPosition(playerPos: {x: number, y: number, z: number}): (Vector3?, number, string?)
	local densityConfig = EnemyBalance.SpawnDensityCheck
	local sectorConfig = EnemyBalance.SectorSpawning
	
	-- Check if sector spawning is enabled
	if not sectorConfig or not sectorConfig.Enabled then
		-- Fallback to old behavior (random position with density check)
		if not densityConfig or not densityConfig.Enabled then
			local pos = getRandomSpawnPosition(playerPos)
			local grounded = getGroundedPosition(pos, 0)
			return grounded, 999, nil
		end
		
		-- Old density-only logic
		local maxAttempts = densityConfig.MaxAttempts or 8
		local maxDensity = densityConfig.MaxEnemiesInRadius or 2
		local checkRadius = densityConfig.CheckRadius or 40
		
		local bestPosition = nil
		local bestDensity = math.huge
		
		for attempt = 1, maxAttempts do
			local candidatePos = getRandomSpawnPosition(playerPos)
			local groundedPos = getGroundedPosition(candidatePos, 0)
			
			if groundedPos then
				local density = countEnemiesNearPosition(groundedPos, checkRadius)
				
				if density < maxDensity then
					return groundedPos, density, nil
				end
				
				if density < bestDensity then
					bestDensity = density
					bestPosition = groundedPos
				end
			end
		end
		
		return bestPosition, bestDensity, nil
	end
	
	-- Sector-based spawning logic
	local sectorMin, sectorMax, sectorEnemyCount = selectEmptiestsector(playerPos)
	local attemptsPerSector = sectorConfig.AttemptsPerSector or 3
	
	local bestPosition = nil
	local bestDensity = math.huge
	
	-- Try multiple positions within the selected sector
	for attempt = 1, attemptsPerSector do
		local candidatePos = getRandomSpawnPosition(playerPos, sectorMin, sectorMax)
		local groundedPos = getGroundedPosition(candidatePos, 0)
		
		if groundedPos then
			-- Check local density if density checking is enabled
			local localDensity = 0
			if densityConfig and densityConfig.Enabled then
				local checkRadius = densityConfig.CheckRadius or 40
				localDensity = countEnemiesNearPosition(groundedPos, checkRadius)
				
				-- Early exit if we find a clean spot
				local maxDensity = densityConfig.MaxEnemiesInRadius or 2
				if localDensity < maxDensity then
					local sectorInfo = string.format("Sector %.0f°-%.0f° (%d enemies)", 
						math.deg(sectorMin), math.deg(sectorMax), sectorEnemyCount)
					return groundedPos, localDensity, sectorInfo
				end
			else
				-- No density check, just use first valid ground position
				local sectorInfo = string.format("Sector %.0f°-%.0f° (%d enemies)", 
					math.deg(sectorMin), math.deg(sectorMax), sectorEnemyCount)
				return groundedPos, localDensity, sectorInfo
			end
			
			-- Track best position as fallback
			if localDensity < bestDensity then
				bestDensity = localDensity
				bestPosition = groundedPos
			end
		end
	end
	
	-- Return best position found in sector (even if above density threshold)
	local sectorInfo = string.format("Sector %.0f°-%.0f° (%d enemies)", 
		math.deg(sectorMin), math.deg(sectorMax), sectorEnemyCount)
	return bestPosition, bestDensity, sectorInfo
end

-- Calculate spawn rate multiplier based on nuke restoration progress
local function getNukeSpawnMultiplier(): number
	if not nukeActive then
		return 1.0  -- Full spawn rate
	end
	
	local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
	local currentTime = GameTimeSystem.getGameTime()
	
	-- Phase 1: Anti-spawn period (0% spawn rate)
	if currentTime < nukeEndTime then
		return 0.0  -- No spawning during nuke
	end
	
	-- Phase 2: Gradual restoration (0% → 100% over 15 seconds)
	if currentTime < nukeRestoreEndTime then
		local elapsed = currentTime - nukeEndTime
		local progress = elapsed / NUKE_RESTORE_DURATION
		return math.clamp(progress, 0, 1)  -- Linear restoration 0 → 1
	end
	
	-- Phase 3: Fully restored
	nukeActive = false  -- Clear nuke state
	return 1.0
end

-- PUBLIC API: Set nuke active state (called by PowerupEffectSystem)
function EnemySpawner.setNukeActive(duration: number)
	local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
	nukeActive = true
	nukeEndTime = GameTimeSystem.getGameTime() + duration
	nukeRestoreEndTime = nukeEndTime + NUKE_RESTORE_DURATION  -- NEW: 15s after nuke ends
end

function EnemySpawner.setEnabled(enabled: boolean)
	spawnEnabled = enabled
end

function EnemySpawner.step(dt: number)
	if not world or not spawnEnabled then
		return
	end
	
	-- Calculate spawn rate multiplier from nuke (0 during nuke, gradually restores)
	local nukeMultiplier = getNukeSpawnMultiplier()

	-- Handle initial delay
	if not hasInitialDelayPassed then
		initialDelayAccumulator += dt
		if initialDelayAccumulator >= EnemyBalance.InitialSpawnDelay then
			hasInitialDelayPassed = true
		else
			return
		end
	end
	
	-- Throttle spawn checks (PERFORMANCE FIX - don't run every frame!)
	spawnCheckAccumulator += dt
	if spawnCheckAccumulator < SPAWN_CHECK_INTERVAL then
		return  -- Early exit, saves 95% of work
	end
	spawnCheckAccumulator -= SPAWN_CHECK_INTERVAL

	-- Accumulate enemies to spawn based on scaled spawn rate (uses game time)
	-- Subtract initial delay so scaling starts from 0 when spawning actually begins
	local gameTime = GameTimeSystem.getGameTime()
	local adjustedTime = math.max(0, gameTime - EnemyBalance.InitialSpawnDelay)
	local baseSpawnRate = EasingUtils.evaluate(EnemyBalance.EnemiesPerSecondScaling, adjustedTime)
	
	-- Multiplayer scaling: scale by number of IN-GAME players only
	local playerCount = 0
	local GameStateManager = require(game.ServerScriptService.ECS.Systems.GameStateManager)
	local Players = game:GetService("Players")
	
	for _ in playerPositionQuery do
		-- Only count players who are actually in the game (not in menu or wipe screen)
		local entity = _
		local playerStats = world:get(entity, PlayerStats)
		if playerStats and playerStats.player then
			if GameStateManager.isPlayerInGame(playerStats.player) then
				playerCount = playerCount + 1
			end
		end
	end
	
	local playerMultiplier = math.max(1, playerCount) * (EnemyBalance.Multiplayer.EnemiesPerPlayer or 1.0)
	local spawnRate = baseSpawnRate * playerMultiplier
	
	local adjustedSpawnRate = spawnRate * nukeMultiplier  -- Apply nuke multiplier
	spawnAccumulator += adjustedSpawnRate * SPAWN_CHECK_INTERVAL

	-- Count current enemies using cached query
	local enemyCount = 0
	for entity, entityType in enemyCountQuery do
		if entityType and entityType.type == "Enemy" then
			enemyCount = enemyCount + 1
		end
	end

	-- Get player positions using cached query
	local playerPositions = {}
	for entity, position, playerStats in playerPositionQuery do
		if playerStats and playerStats.player and playerStats.player.Parent then
			-- Skip players not in the game (in menu or wipe screen)
			if not GameStateManager.isPlayerInGame(playerStats.player) then
				continue
			end
			
			-- Skip paused players in individual pause mode (don't spawn enemies for them)
			if not GameOptions.GlobalPause then
				local cooldownsFrozen = playerStats.player:GetAttribute("CooldownsFrozen")
				if cooldownsFrozen then
					continue  -- Don't spawn enemies for paused players
				end
			end
			
			table.insert(playerPositions, {
				entity = entity,
				position = position,
				stats = playerStats
			})
		end
	end

	if #playerPositions == 0 then
		-- No players, reset accumulator to prevent spawning when players join
		spawnAccumulator = 0
		return
	end
	
	-- Debug: Check if player positions are valid
	for i, playerData in ipairs(playerPositions) do
		if not playerData.position then
			warn("[EnemySpawner] Player", i, "has nil position:", playerData)
		end
	end

	-- Spawn enemies while we have accumulated spawns and haven't reached the cap
	while spawnAccumulator >= 1 and enemyCount < EnemyBalance.MaxEnemies do
		spawnAccumulator = spawnAccumulator - 1

		-- Select enemy type based on weights
		local enemyType = selectRandomEnemyType()
		
		-- Ensure enemy model is replicated before spawning to prevent invisible enemies
		local replicationSuccess = ModelReplicationService.replicateEnemy(enemyType)
		if not replicationSuccess then
			warn(string.format("[EnemySpawner] Failed to replicate %s model, skipping spawn this frame", enemyType))
			-- Don't decrement accumulator; retry next spawn interval
			spawnAccumulator = spawnAccumulator + 1
			break  -- Exit spawn loop, will retry on next interval
		end

		-- Pick a random player to spawn near
		local targetPlayer = playerPositions[math.random(1, #playerPositions)]
		
		-- Safety check for player position
		if not targetPlayer or not targetPlayer.position then
			continue
		end
		
		-- Use density-aware spawn position selection (with sector-based distribution)
		local groundedPos, localDensity, sectorInfo = getDensityAwareSpawnPosition(targetPlayer.position)
		
		-- Skip spawn if no valid ground found within +/- 20 studs
		if not groundedPos then
			continue
		end
		
		-- Debug logging for first 10 spawns
		if zombieSpawnCounter < 10 then
			-- Spawned successfully
		end

		local enemyEntity = ECSWorldService.CreateEnemy(enemyType, groundedPos, nil)

		if enemyEntity then
			enemyCount = enemyCount + 1
			zombieSpawnCounter = zombieSpawnCounter + 1
		end
	end
end

return EnemySpawner
