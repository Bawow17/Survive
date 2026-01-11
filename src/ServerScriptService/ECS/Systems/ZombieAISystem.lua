--!strict
-- ZombieAISystem - drives zombie movement toward players and applies damage on contact

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local OctreeSystem = require(script.Parent.OctreeSystem)
local GameTimeSystem = require(script.Parent.GameTimeSystem)
local EasingUtils = require(game.ServerScriptService.Balance.EasingUtils)
local EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local ObstacleRaycastCache = require(game.ServerScriptService.ECS.Systems.ObstacleRaycastCache)

local ProfilingConfig = require(ReplicatedStorage.Shared.ProfilingConfig)
local Prof = ProfilingConfig.ENABLED and require(ReplicatedStorage.Shared.ProfilingServer) or require(ReplicatedStorage.Shared.ProfilingStub)

local ZombieAISystem = {}

-- Forward reference to PauseSystem (set via setPauseSystem)
local PauseSystem: any

local world: any
local Components: any
local DirtyService: any
local ECSWorldService: any
local StatusEffectSystem: any  -- Reference to status effect system
local QueryPool: any

local Position: any
local Velocity: any
local AI: any
local Target: any
local AttackCooldown: any
local Damage: any
local PlayerStats: any
local Health: any
local EntityTypeComponent: any
local FacingDirection: any

local enemyLogAccumulator = 0

-- Obstacle detection and pathfinding settings
local OBSTACLE_CHECK_INTERVAL = 0.4  -- Check obstacles at ~2.5 FPS
local OBSTACLE_RAYCAST_DISTANCE = 3.5  -- Detect obstacles 3.5 studs ahead
local OBSTACLE_CHECK_MAX_DISTANCE = 120  -- Skip obstacle checks beyond this range
local OBSTACLE_CHECK_MIN_SPEED = 0.1
local OBSTACLE_CHECK_BUDGET_PER_STEP = 120
local STEERING_CHECK_INTERVAL = 0.3  -- Throttle steering raycasts in advanced mode
local WALL_CLIMB_THRESHOLD = 5  -- Player must be 5 studs above to trigger climbing
local STEERING_BLEND_FACTOR = 0.7  -- 70% steering, 30% direct to player
local CLIMB_SPEED_MULTIPLIER = 0.4  -- Climb at 40% of horizontal speed
local CLIMB_HORIZONTAL_REDUCTION = 0.6  -- Horizontal speed reduced to 60% while climbing
local CLIMB_SMOOTHING = 0.15  -- Smooth Y velocity changes (lerp factor)
local GRAVITY_ACCELERATION = -25  -- Gravity when falling (studs/s²)

-- Debug spam reduction
local lastPauseDebugLog = 0
local DEBUG_LOG_INTERVAL = 2.0  -- Only log pause state every 2 seconds

-- Inactive enemy cleanup system (handles ALL enemy types, not just zombies)
local entityLastActivity: {[number]: number} = {} -- Track last time entity moved
local INACTIVE_TIMEOUT = 10 -- 10 seconds - faster cleanup of stuck enemies
local cleanupAccumulator = 0
local CLEANUP_INTERVAL = 45 -- Check for inactive enemies every 45 seconds

-- Cached queries for performance (CRITICAL FIX)
local zombieQuery: any
local playerQueryCached: any
local targetAIQuery: any  -- Cached query for Target + AI (pause handling)
local inactiveCleanupQuery: any
local OBSTACLE_CHECK_MAX_DISTANCE_SQ = OBSTACLE_CHECK_MAX_DISTANCE * OBSTACLE_CHECK_MAX_DISTANCE

-- Profiling accumulators (reset per step)
local aiRaycastTime = 0
local obstacleParamsTime = 0
local obstacleParamsRebuilds = 0
local obstacleExclusionSize = 0
local obstacleCheckTime = 0
local steeringTime = 0
local lastObstacleRebuildId = 0

-- Object pooling with proper limits and safety
local enemyDataPool = {}
local MAX_POOL_SIZE = 50 -- Reasonable pool size limit
local function getEnemyData()
	return table.remove(enemyDataPool) or {}
end
local function returnEnemyData(data)
	table.clear(data)
	-- Only add to pool if it's not full
	if #enemyDataPool < MAX_POOL_SIZE then
		table.insert(enemyDataPool, data)
	end
	-- If pool is full, let the table be garbage collected
end

-- Per-player enemy pause tracking (for individual pause mode)
local pausedPlayerEnemies: {[number]: {
	enemies: {[number]: number},  -- [enemyEntity] = originalSpeed
	pauseStartTime: number,
	enemyPauseStartTimes: {[number]: number},  -- [enemyEntity] = gameTime when paused
}} = {}

-- Get attack range based on enemy attackbox size
local function getAttackRangeFromAttackbox(enemyEntity: number): number
	if not world then
		return 3 -- Default attack range
	end
	
	local entityType = world:get(enemyEntity, Components.EntityType)
	local enemyType = entityType and entityType.subtype or "Zombie"

	local attackboxData = ModelReplicationService.getEnemyAttackbox(enemyType)
	if not attackboxData then
		ModelReplicationService.replicateEnemy(enemyType)
		attackboxData = ModelReplicationService.getEnemyAttackbox(enemyType)
	end

	if not attackboxData or not attackboxData.size then
		return 3 -- Default if no attackbox found
	end

	local attackboxSize = attackboxData.size
	local maxDimension = math.max(attackboxSize.X, attackboxSize.Z)
	
	-- Add a small buffer (0.5 studs) to ensure reliable contact detection
	return maxDimension + 0.5
end


local function findNearestPlayer(enemyPosition: {x: number, y: number, z: number}, players: {[number]: any}): number?
	local nearestId: number? = nil
	local nearestDistSq: number? = nil

	for playerEntity, playerPosition in pairs(players) do
		-- Skip paused players in individual pause mode
		if not GameOptions.GlobalPause and PauseSystem then
			if PauseSystem.isPlayerPaused(playerEntity) then
				continue  -- Don't target paused players
			end
		end
		
		-- Skip players with spawn protection (not all invincibility)
		if StatusEffectSystem and StatusEffectSystem.hasSpawnProtection(playerEntity) then
			continue  -- Don't target spawn-protected players
		end
		
		-- Players are pre-validated in QueryPool.getPlayerPositionsMap() - no world:get needed
		local dx = playerPosition.x - enemyPosition.x
		local dz = playerPosition.z - enemyPosition.z
		local distSq = dx * dx + dz * dz
		if not nearestId or distSq < (nearestDistSq or math.huge) then
			nearestId = playerEntity
			nearestDistSq = distSq
		end
	end

	return nearestId
end

local function setVelocity(entity: number, velocity: {x: number, y: number, z: number})
	DirtyService.setIfChanged(world, entity, Velocity, velocity, "Velocity")
end

local function setAttackCooldown(entity: number, remaining: number, maximum: number)
	DirtyService.setIfChanged(world, entity, AttackCooldown, {
		remaining = remaining,
		max = maximum,
	}, "AttackCooldown")
end

local function setTarget(entity: number, targetId: number?)
	if not Target then
		return
	end

	local newTargetData = { id = targetId }
	DirtyService.setIfChanged(world, entity, Target, newTargetData, "Target")
end

local function setFacingDirection(entity: number, direction: {x: number, y: number, z: number})
	if not FacingDirection then
		return
	end

	DirtyService.setIfChanged(world, entity, FacingDirection, direction, "FacingDirection")
end

-- Player position collection is now handled by QueryPool for better performance

-- DEPRECATED: Use DamageSystem.applyDamage() instead to properly handle overheal
local function applyDamageToPlayer(targetEntity: number, damageAmount: number, sourceEntity: number?)
	if damageAmount <= 0 then
		return
	end
	
	-- Route through centralized DamageSystem (handles overheal, invincibility, etc.)
	local DamageSystem = require(game.ServerScriptService.ECS.Systems.DamageSystem)
	DamageSystem.applyDamage(targetEntity, damageAmount, "physical", sourceEntity)
end

local function aiRaycast(origin: Vector3, direction: Vector3, params: RaycastParams): RaycastResult?
	Prof.incCounter("AI.Raycasts", 1)
	local startTime = os.clock()
	local result = Workspace:Raycast(origin, direction, params)
	aiRaycastTime += os.clock() - startTime
	return result
end

-- Detect obstacle in front of enemy (including overhangs and steep slopes)
local function detectObstacle(enemyPos: {x: number, y: number, z: number}, direction: {x: number, z: number}, params: RaycastParams): boolean
	if not direction or (direction.x == 0 and direction.z == 0) then
		return false
	end
	
	-- Normalize direction
	local mag = math.sqrt(direction.x * direction.x + direction.z * direction.z)
	if mag == 0 then return false end
	
	local normDir = {
		x = direction.x / mag,
		z = direction.z / mag
	}
	
	
	-- FORWARD OBSTACLE CHECK: Cast forward from 1 stud above ground
	local origin = Vector3.new(enemyPos.x, enemyPos.y + 1, enemyPos.z)
	local rayDirection = Vector3.new(normDir.x, 0, normDir.z) * OBSTACLE_RAYCAST_DISTANCE
	
	local result = aiRaycast(origin, rayDirection, params)
	
	-- If we hit something solid, it's an obstacle
	if result and result.Instance then
		local hitPart = result.Instance
		-- Double-check it's actually collidable and not transparent
		if hitPart.CanCollide and hitPart.Transparency < 1 then
			-- Check if it's a steep slope (normal pointing significantly downward or horizontally)
			-- Normal.Y < 0 means overhang/ceiling, Normal.Y < 0.5 means slope > ~60 degrees
			if result.Normal.Y < 0.3 then
				-- Steep slope or overhang - treat as wall
				return true
			end
			return true
		end
	end
	
	-- OVERHANG CHECK: Cast upward to detect overhangs/ceilings above
	local upOrigin = Vector3.new(enemyPos.x, enemyPos.y + 1, enemyPos.z)
	local upDirection = Vector3.new(0, 4, 0)  -- Check 4 studs up
	
	local upResult = aiRaycast(upOrigin, upDirection, params)
	
	if upResult and upResult.Instance then
		local hitPart = upResult.Instance
		if hitPart.CanCollide and hitPart.Transparency < 1 then
			-- Check if it's an overhang (normal pointing downward)
			if upResult.Normal.Y < -0.3 then
				-- Overhang/ceiling detected - treat as obstacle
				return true
			end
		end
	end
	
	-- STEEP GROUND CHECK: Cast down slightly ahead to check for steep slopes
	local aheadOrigin = Vector3.new(
		enemyPos.x + normDir.x * 2,
		enemyPos.y + 2,
		enemyPos.z + normDir.z * 2
	)
	local downDirection = Vector3.new(0, -5, 0)
	
	local downResult = aiRaycast(aheadOrigin, downDirection, params)
	
	if downResult and downResult.Instance then
		local hitPart = downResult.Instance
		if hitPart.CanCollide and hitPart.Transparency < 1 then
			-- Check if ground ahead has steep/inverted slope
			-- Normal.Y < 0 means overhang, Normal.Y < 0.3 means very steep (>~72 degrees)
			if downResult.Normal.Y < 0 then
				-- Inverted slope (overhang) - definitely can't walk on this
				return true
			end
		end
	end
	
	return false
end

-- Calculate steering direction to avoid obstacle
local function calculateSteering(enemyPos: {x: number, y: number, z: number}, currentDir: {x: number, z: number}, targetDir: {x: number, z: number}, params: RaycastParams): {x: number, z: number}
	-- Normalize current direction
	local mag = math.sqrt(currentDir.x * currentDir.x + currentDir.z * currentDir.z)
	if mag == 0 then
		return {x = targetDir.x, z = targetDir.z}
	end
	
	local normCurrent = {
		x = currentDir.x / mag,
		z = currentDir.z / mag
	}
	
	
	local origin = Vector3.new(enemyPos.x, enemyPos.y + 1, enemyPos.z)
	
	-- Cast left (rotate 90 degrees counter-clockwise)
	local leftDir = {x = -normCurrent.z, z = normCurrent.x}
	local leftRayDir = Vector3.new(leftDir.x, 0, leftDir.z) * OBSTACLE_RAYCAST_DISTANCE
	local leftResult = aiRaycast(origin, leftRayDir, params)
	
	-- Cast right (rotate 90 degrees clockwise)
	local rightDir = {x = normCurrent.z, z = -normCurrent.x}
	local rightRayDir = Vector3.new(rightDir.x, 0, rightDir.z) * OBSTACLE_RAYCAST_DISTANCE
	local rightResult = aiRaycast(origin, rightRayDir, params)
	
	-- Choose the clearer direction
	local steerDir
	if not leftResult and not rightResult then
		-- Both sides clear, prefer left
		steerDir = leftDir
	elseif not leftResult then
		-- Left is clear
		steerDir = leftDir
	elseif not rightResult then
		-- Right is clear
		steerDir = rightDir
	else
		-- Both blocked, choose the one with furthest obstacle
		local leftDist = leftResult.Distance
		local rightDist = rightResult.Distance
		if leftDist > rightDist then
			steerDir = leftDir
		else
			steerDir = rightDir
		end
	end
	
	-- Blend steering with target direction
	local blendedX = steerDir.x * STEERING_BLEND_FACTOR + targetDir.x * (1 - STEERING_BLEND_FACTOR)
	local blendedZ = steerDir.z * STEERING_BLEND_FACTOR + targetDir.z * (1 - STEERING_BLEND_FACTOR)
	
	-- Normalize blended direction
	local blendedMag = math.sqrt(blendedX * blendedX + blendedZ * blendedZ)
	if blendedMag > 0 then
		return {
			x = blendedX / blendedMag,
			z = blendedZ / blendedMag
		}
	end
	
	return {x = targetDir.x, z = targetDir.z}
end

-- Set or update PathfindingState component
local function setPathfindingState(entity: number, stateData: any)
	DirtyService.setIfChanged(world, entity, Components.PathfindingState, stateData, "PathfindingState")
end

-- Helper function to find nearest non-paused player
local function findNearestNonPausedPlayer(enemyEntity: number): number?
	local enemyPos = world:get(enemyEntity, Position)
	if not enemyPos then
		return nil
	end
	
	local nearestPlayer = nil
	local nearestDistSq = math.huge
	
	-- Use cached query for performance (JECS best practice)
	for playerEntity, playerPos in playerQueryCached do
		-- Skip paused players
		if PauseSystem and PauseSystem.isPlayerPaused(playerEntity) then
			continue
		end
		
		local dx = playerPos.x - enemyPos.x
		local dz = playerPos.z - enemyPos.z
		local distSq = dx * dx + dz * dz
		
		if distSq < nearestDistSq then
			nearestDistSq = distSq
			nearestPlayer = playerEntity
		end
	end
	
	return nearestPlayer
end

-- Called when a player enters individual pause
function ZombieAISystem.onPlayerPaused(playerEntity: number)
	if not world or GameOptions.GlobalPause then
		return  -- Only applies to individual pause mode
	end
	
	local affectedEnemies = {}
	
	-- Find all enemies targeting this player (use cached query for performance)
	for entity, target, ai in targetAIQuery do
		if target.id == playerEntity then
			-- Store original speed (use balance base speed if already frozen)
			local originalSpeed = ai.speed
			if originalSpeed == 0 then
				-- Enemy already frozen, get base speed from balance
				local entityType = world:get(entity, Components.EntityType)
				if entityType and entityType.subtype == "Zombie" then
					originalSpeed = 8.0  -- Zombie base speed from balance
				elseif entityType and entityType.subtype == "Charger" then
					originalSpeed = 27.0  -- Charger base speed from balance
				else
					originalSpeed = 8.0  -- Fallback
				end
			end
			affectedEnemies[entity] = originalSpeed
		end
	end
	
	if next(affectedEnemies) then
		local count = 0
		for _ in pairs(affectedEnemies) do count = count + 1 end
		
		-- Track pause start time for each enemy (for lifetime scaling)
		local enemyPauseStartTimes = {}
		local currentGameTime = GameTimeSystem.getGameTime()
		for enemyEntity in pairs(affectedEnemies) do
			enemyPauseStartTimes[enemyEntity] = currentGameTime
		end
		
		pausedPlayerEnemies[playerEntity] = {
			enemies = affectedEnemies,
			pauseStartTime = tick(),
			enemyPauseStartTimes = enemyPauseStartTimes,
		}
	end
end

-- Called when a player exits individual pause
function ZombieAISystem.onPlayerUnpaused(playerEntity: number)
	-- Restore speeds for all enemies that were tracking this player
	local data = pausedPlayerEnemies[playerEntity]
	if data then
		local count = 0
		local currentGameTime = GameTimeSystem.getGameTime()
		
		for enemyEntity, originalSpeed in pairs(data.enemies) do
			if world:contains(enemyEntity) then
				local ai = world:get(enemyEntity, AI)
				if ai then
					ai.speed = originalSpeed
					world:set(enemyEntity, AI, ai)
					DirtyService.mark(enemyEntity, "AI")
				end
				
				-- Accumulate paused time for this enemy
				local pauseStartTime = data.enemyPauseStartTimes[enemyEntity]
				if pauseStartTime then
					local pauseDuration = currentGameTime - pauseStartTime
					local pausedTime = world:get(enemyEntity, Components.EnemyPausedTime)
					if pausedTime then
						pausedTime.totalPausedTime = pausedTime.totalPausedTime + pauseDuration
						world:set(enemyEntity, Components.EnemyPausedTime, pausedTime)
					end
				end
				
				-- Retarget back to unpaused player
				local currentTarget = world:get(enemyEntity, Target)
				if currentTarget and currentTarget.id ~= playerEntity then
					setTarget(enemyEntity, playerEntity)
				end
				
				count = count + 1
			end
		end
	end
	
	-- Clean up pause tracking
	pausedPlayerEnemies[playerEntity] = nil
end

-- Set PauseSystem reference (called from Bootstrap)
function ZombieAISystem.setPauseSystem(pauseSystem: any)
	PauseSystem = pauseSystem
end

function ZombieAISystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService

	Position = Components.Position
	Velocity = Components.Velocity
	AI = Components.AI
	Target = Components.Target
	AttackCooldown = Components.AttackCooldown
	Damage = Components.Damage
	PlayerStats = Components.PlayerStats
	Health = Components.Health
	EntityTypeComponent = Components.EntityType
	FacingDirection = Components.FacingDirection
	
	-- Create cached queries for performance (CRITICAL FIX - was creating new queries every frame!)
	-- CRITICAL: Exclude dead enemies (with DeathAnimation) from AI processing
	zombieQuery = world:query(Components.Position, Components.Velocity, Components.AI, Components.AttackCooldown, Components.Damage, Components.EntityType, Components.Target):without(Components.DeathAnimation):cached()
	playerQueryCached = world:query(Components.Position, Components.PlayerStats):cached()
	-- Query for finding enemies by target (used in pause handling)
	targetAIQuery = world:query(Components.Target, Components.AI):cached()
	-- Cleanup query includes ALL enemies (not just zombies with AI component)
	inactiveCleanupQuery = world:query(Components.Position, Components.EntityType):cached()
end

-- Clean up entity tracking when entity is destroyed
function ZombieAISystem.cleanupEntity(entity: number)
	entityLastActivity[entity] = nil
end

-- Check for and clean up inactive enemies (handles ALL enemy types)
local function cleanupInactiveEnemies()
	if not world then
		return 0
	end
	
	local currentTime = tick()
	local inactiveEntities = {}
	
	-- Check all enemies for inactivity using cached query
	for enemyEntity, enemyPosition, entityType in inactiveCleanupQuery do
		-- Only clean up enemies, not players or projectiles
		if entityType.type ~= "Enemy" then
			continue
		end
		
		-- CRITICAL: Skip enemies that are frozen due to player pause
		local target = world:get(enemyEntity, Target)
		local ai = world:get(enemyEntity, AI)
		
		-- Skip if enemy is frozen (speed = 0) and has a target
		-- These are intentionally paused, not stuck
		if ai and ai.speed == 0 and target and target.id then
			-- Check if target is paused
			local targetPauseState = world:get(target.id, Components.PlayerPauseState)
			if targetPauseState then
				-- Enemy is frozen due to paused target, SKIP cleanup
				continue
			end
		end
		
		-- Skip if enemy has no target (will retarget soon)
		if not target or not target.id then
			continue
		end
		
		local lastActivity = entityLastActivity[enemyEntity] or currentTime
		local timeSinceActivity = currentTime - lastActivity
		
		-- Check if enemy has been inactive for too long
		if timeSinceActivity > INACTIVE_TIMEOUT then
			-- Check if enemy is actually stuck (not moving)
			local velocity = world:get(enemyEntity, Velocity)
			if velocity then
				local velocityMagnitude = math.sqrt((velocity.x or 0)^2 + (velocity.z or 0)^2)
				if velocityMagnitude < 0.1 then -- Very low movement threshold
					table.insert(inactiveEntities, enemyEntity)
				else
					-- Enemy is moving, update activity time
					entityLastActivity[enemyEntity] = currentTime
				end
			else
				-- No velocity component, assume stuck
				table.insert(inactiveEntities, enemyEntity)
			end
		end
	end
	
	-- Destroy inactive entities using proper ECS cleanup
	-- This will NOT drop EXP (only damage-based deaths drop EXP)
	for _, entity in ipairs(inactiveEntities) do
		if ECSWorldService then
			print(string.format("[ZombieAI] Cleaning up stuck enemy #%d after %.1fs inactivity", 
				entity, INACTIVE_TIMEOUT))
			
			-- Return pooled enemies to their pools instead of destroying
			local EnemyPool = require(game.ServerScriptService.ECS.EnemyPool)
			local SyncSystem = require(game.ServerScriptService.ECS.Systems.SyncSystem)
			SyncSystem.queueDespawn(entity)  -- Notify clients to remove visual
			EnemyPool.release(entity)
		end
	end
	
	return #inactiveEntities
end

function ZombieAISystem.step(dt: number)
	if not world then
		return
	end

	Prof.beginTimer("AI.Time")
	aiRaycastTime = 0
	obstacleParamsTime = 0
	obstacleParamsRebuilds = 0
	obstacleCheckTime = 0
	steeringTime = 0
	local obstacleChecksRemaining = OBSTACLE_CHECK_BUDGET_PER_STEP
	local obstacleParams: RaycastParams? = nil

	local function getObstacleParams(): RaycastParams
		if obstacleParams then
			return obstacleParams
		end
		local startTime = os.clock()
		obstacleParams = ObstacleRaycastCache.getParams()
		obstacleParamsTime += os.clock() - startTime
		local stats = ObstacleRaycastCache.getStats()
		obstacleExclusionSize = stats.exclusionSize
		if stats.rebuildId ~= lastObstacleRebuildId then
			obstacleParamsRebuilds += 1
			lastObstacleRebuildId = stats.rebuildId
		end
		return obstacleParams
	end
	
	-- Handle paused player enemy transitions (individual pause mode only)
	if not GameOptions.GlobalPause then
		for playerEntity, data in pairs(pausedPlayerEnemies) do
			local elapsed = tick() - data.pauseStartTime
			local freezeDuration = GameOptions.EnemyPauseTransition.FreezeDuration
			
			-- Check if player is still paused
			local stillPaused = PauseSystem and PauseSystem.isPlayerPaused(playerEntity)
			
			if stillPaused and elapsed < freezeDuration then
				-- Freeze enemies (set speed to 0)
				local frozenCount = 0
				for enemyEntity, originalSpeed in pairs(data.enemies) do
					if world:contains(enemyEntity) then
						local ai = world:get(enemyEntity, AI)
						if ai and ai.speed ~= 0 then
							ai.speed = 0
							world:set(enemyEntity, AI, ai)
							DirtyService.mark(enemyEntity, "AI")
							frozenCount = frozenCount + 1
						end
					end
				end
				-- Reduced spam: only log first freeze
				-- (frozenCount tracking for debugging)
			else
				-- After 3s: Attempt to retarget or keep tracking
			if not stillPaused then
				-- Player unpaused after 3s, restore everything and accumulate paused time
					local currentGameTime = GameTimeSystem.getGameTime()
					for enemyEntity, originalSpeed in pairs(data.enemies) do
						if world:contains(enemyEntity) then
							local ai = world:get(enemyEntity, AI)
							if ai then
								ai.speed = originalSpeed
								world:set(enemyEntity, AI, ai)
								DirtyService.mark(enemyEntity, "AI")
							end
							
							-- Accumulate paused time for this enemy
							local pauseStartTime = data.enemyPauseStartTimes[enemyEntity]
							if pauseStartTime then
								local pauseDuration = currentGameTime - pauseStartTime
								local pausedTime = world:get(enemyEntity, Components.EnemyPausedTime)
								if pausedTime then
									pausedTime.totalPausedTime = pausedTime.totalPausedTime + pauseDuration
									world:set(enemyEntity, Components.EnemyPausedTime, pausedTime)
								end
							end
							
							-- Retarget back to unpaused player
							local currentTarget = world:get(enemyEntity, Target)
							if currentTarget and currentTarget.id ~= playerEntity then
								setTarget(enemyEntity, playerEntity)
							end
							end
					end
					-- Clean up tracking
					pausedPlayerEnemies[playerEntity] = nil
				else
					-- Player still paused after 3s, try to retarget but DON'T clean up tracking
					local currentGameTime = GameTimeSystem.getGameTime()
					for enemyEntity, originalSpeed in pairs(data.enemies) do
						if world:contains(enemyEntity) then
							-- Try to find non-paused player
							local nearestPlayer = findNearestNonPausedPlayer(enemyEntity)
							if nearestPlayer then
								-- Found valid target, restore speed and retarget
								local ai = world:get(enemyEntity, AI)
								if ai then
									ai.speed = originalSpeed
									world:set(enemyEntity, AI, ai)
									DirtyService.mark(enemyEntity, "AI")
								end
								
								-- Accumulate paused time for this enemy before retargeting
								local pauseStartTime = data.enemyPauseStartTimes[enemyEntity]
								if pauseStartTime then
									local pauseDuration = currentGameTime - pauseStartTime
									local pausedTime = world:get(enemyEntity, Components.EnemyPausedTime)
									if pausedTime then
										pausedTime.totalPausedTime = pausedTime.totalPausedTime + pauseDuration
										world:set(enemyEntity, Components.EnemyPausedTime, pausedTime)
									end
									-- Clear pause start time since enemy is no longer paused
									data.enemyPauseStartTimes[enemyEntity] = nil
								end
								
								local currentTarget = world:get(enemyEntity, Target)
								if currentTarget and currentTarget.id ~= nearestPlayer then
									setTarget(enemyEntity, nearestPlayer)
								end
							end
							-- Don't log "waiting for valid target" - too spammy
						end
					end
					-- DON'T clean up - will clean up when player actually unpauses
				end
			end
		end
	end

	-- Periodic cleanup of inactive enemies (skip during any pause)
	cleanupAccumulator += dt
	if cleanupAccumulator >= CLEANUP_INTERVAL then
		cleanupAccumulator = 0
		
		-- Check if cleanup should be paused
		-- ALWAYS run cleanup, but cleanup function will skip intentionally frozen enemies
		cleanupInactiveEnemies()
	end

	enemyLogAccumulator += dt
	if enemyLogAccumulator >= 60 then
		-- Optional: periodic health check log could go here
		enemyLogAccumulator = 0
	end

	-- Use cached queries for performance (CRITICAL FIX)
	local enemies = {}
	
	for entity, position, velocity, ai, cooldown, damage, entityType, target in zombieQuery do
		-- Only process Zombies (skip other enemy types like Chargers)
		if entityType and entityType.type == "Enemy" and (not ai.behaviorType or ai.behaviorType == "Zombie") then
			table.insert(enemies, {
				entity = entity,
				position = position,
				velocity = velocity,
				ai = ai,
				cooldown = cooldown,
				damage = damage,
				entityType = entityType,
				target = target
			})
		end
	end
	
	if #enemies == 0 then
		Prof.endTimer("AI.Time")
		return
	end

	-- Get player positions with cached query
	local players = {}
	for entity, position, playerStats in playerQueryCached do
		if playerStats and playerStats.player and playerStats.player.Parent then
			players[entity] = position
		end
	end
	local hasPlayers = next(players) ~= nil

	for _, enemyData in ipairs(enemies) do
		local enemyEntity = enemyData.entity
		local enemyPosition = enemyData.position
		local enemyVelocity = enemyData.velocity
		local ai = enemyData.ai
		local cooldown = enemyData.cooldown or { remaining = 0, max = 1 }
		local damage = enemyData.damage or { amount = 0 }
		local entityType = enemyData.entityType -- Pre-fetched, no world:get needed
		local target = enemyData.target -- Pre-fetched, may be nil

		-- Check for knockback stun - skip normal AI if stunned
		local knockback = world:get(enemyEntity, Components.Knockback)
		if knockback and knockback.stunned then
			-- Enemy is stunned by knockback, skip normal AI movement
			continue
		end

		-- Update activity tracking
		entityLastActivity[enemyEntity] = tick()

		-- EntityType check is no longer needed - pre-filtered in QueryPool.getEnemiesWithCore()

		-- Always update cooldown (lightweight operation)
		do
			local cooldownMax = cooldown.max or 1
			local originalRemaining = cooldown.remaining or 0
			local cooldownRemaining = math.max(originalRemaining - dt, 0)
			if cooldownRemaining ~= originalRemaining then
				setAttackCooldown(enemyEntity, cooldownRemaining, cooldownMax)
			end
		end

		if not hasPlayers then
			if enemyVelocity.x ~= 0 or enemyVelocity.y ~= 0 or enemyVelocity.z ~= 0 then
				setVelocity(enemyEntity, { x = 0, y = 0, z = 0 })
			end
			continue
		end

		-- Always find the nearest player for facing calculations
		local nearestPlayerId = findNearestPlayer(enemyPosition, players)
		
		if not nearestPlayerId then
			setVelocity(enemyEntity, { x = 0, y = 0, z = 0 })
			continue
		end

		local targetPosition = players[nearestPlayerId]
		local dx = targetPosition.x - enemyPosition.x
		local dz = targetPosition.z - enemyPosition.z
		local distSq = dx * dx + dz * dz
		local distance = math.sqrt(distSq)

		-- Update facing direction
		if distSq > 0 and distance > 0 then
			local facingDirection = {
				x = dx / distance,
				y = 0,
				z = dz / distance
			}
			setFacingDirection(enemyEntity, facingDirection)
		end
		
		-- Check if target player is paused (individual pause mode)
		if not GameOptions.GlobalPause and PauseSystem then
			if PauseSystem.isPlayerPaused(nearestPlayerId) then
				-- Target is paused, find new target
				local newTarget = findNearestNonPausedPlayer(enemyEntity)
				if newTarget and newTarget ~= nearestPlayerId then
					nearestPlayerId = newTarget
					targetPosition = players[nearestPlayerId]
					if not targetPosition then
						-- New target doesn't have valid position, stop moving
						setVelocity(enemyEntity, {x = 0, y = 0, z = 0})
						continue
					end
					-- Recalculate distances with new target
					dx = targetPosition.x - enemyPosition.x
					dz = targetPosition.z - enemyPosition.z
					distSq = dx * dx + dz * dz
					distance = math.sqrt(distSq)
				elseif not newTarget then
					-- No valid targets, stop in place
					setVelocity(enemyEntity, {x = 0, y = 0, z = 0})
					continue
				else
					-- Still targeting paused player, stop moving
					setVelocity(enemyEntity, {x = 0, y = 0, z = 0})
					continue
				end
			end
		end
		
		setTarget(enemyEntity, nearestPlayerId)

		-- Calculate movement velocity (will be modified by repulsion system)
		local newVelocity = { x = 0, y = 0, z = 0 }
		if distSq > 0 and distance > 0 then
			-- Get ORIGINAL base speed from AI balance (not from ai.speed to avoid compounding)
			local baseSpeed = (ai and ai.balance and ai.balance.baseSpeed) or 8
			
			-- Apply global overtime speed multiplier (based on game time)
			local gameTime = GameTimeSystem.getGameTime()
			local globalSpeedMult = EasingUtils.evaluate(EnemyBalance.GlobalMoveSpeedScaling, gameTime)
			
			-- Apply per-enemy lifetime speed multiplier (based on individual spawn time)
			local spawnTime = world:get(enemyEntity, Components.SpawnTime)
			local lifetimeSpeedMult = 1.0
			if spawnTime then
				local entityLifetime = gameTime - spawnTime.time
				
				-- Subtract total paused time from lifetime (enemies don't age while paused)
				local pausedTime = world:get(enemyEntity, Components.EnemyPausedTime)
				if pausedTime then
					entityLifetime = entityLifetime - pausedTime.totalPausedTime
					entityLifetime = math.max(0, entityLifetime)  -- Never negative
				end
				
				lifetimeSpeedMult = EasingUtils.evaluate(EnemyBalance.LifetimeMoveSpeedScaling, entityLifetime)
			end
			
			-- Calculate final speed with both multipliers
			local finalSpeed = baseSpeed * globalSpeedMult * lifetimeSpeedMult
			
			-- CRITICAL: Update AI component with scaled speed (for persistence + sync)
			if ai.speed ~= finalSpeed then
				ai.speed = finalSpeed
				world:set(enemyEntity, AI, ai)
				DirtyService.mark(enemyEntity, "AI")
			end
			
			-- Base direction towards player
			local baseDirectionX = dx / distance
			local baseDirectionZ = dz / distance
			
			newVelocity.x = baseDirectionX * finalSpeed
			newVelocity.z = baseDirectionZ * finalSpeed
			
			-- OBSTACLE DETECTION AND PATHFINDING
			-- Get or initialize PathfindingState
			local pathfindingState = world:get(enemyEntity, Components.PathfindingState)
			if not pathfindingState then
				pathfindingState = {
					mode = "simple",
					lastObstacleCheck = tick() + math.random() * OBSTACLE_CHECK_INTERVAL,
					obstacleDetected = false,
					steeringDirection = nil,
					lastSteeringCheck = 0,
					clearCheckCount = 0,
					currentYVelocity = 0,  -- For smooth Y transitions
					targetYVelocity = 0,
				}
			end
			
			-- Initialize Y velocity if not present (for existing entities)
			if not pathfindingState.currentYVelocity then
				pathfindingState.currentYVelocity = 0
			end
			if not pathfindingState.targetYVelocity then
				pathfindingState.targetYVelocity = 0
			end
			
			-- Check if time to update obstacle detection (5 FPS)
			local currentTime = tick()
			if currentTime - pathfindingState.lastObstacleCheck >= OBSTACLE_CHECK_INTERVAL then
				local shouldCheck = distSq <= OBSTACLE_CHECK_MAX_DISTANCE_SQ and finalSpeed > OBSTACLE_CHECK_MIN_SPEED
				if shouldCheck then
					if obstacleChecksRemaining > 0 then
						obstacleChecksRemaining -= 1
						pathfindingState.lastObstacleCheck = currentTime
						
						-- Detect obstacle in movement direction
						local params = getObstacleParams()
						local obstacleStart = os.clock()
						local hasObstacle = detectObstacle(enemyPosition, {x = baseDirectionX, z = baseDirectionZ}, params)
						obstacleCheckTime += os.clock() - obstacleStart
						
						if hasObstacle then
							-- Obstacle detected - switch to Advanced Mode
							pathfindingState.mode = "advanced"
							pathfindingState.obstacleDetected = true
							pathfindingState.clearCheckCount = 0
						else
							-- No obstacle - if in Advanced Mode, count consecutive clear checks
							if pathfindingState.mode == "advanced" then
								pathfindingState.clearCheckCount = (pathfindingState.clearCheckCount or 0) + 1
								-- Switch back to Simple Mode after 2 consecutive clear checks (0.4s)
								if pathfindingState.clearCheckCount >= 2 then
									pathfindingState.mode = "simple"
									pathfindingState.obstacleDetected = false
									pathfindingState.steeringDirection = nil
								end
							end
						end
						
						-- Update PathfindingState component
						setPathfindingState(enemyEntity, pathfindingState)
					end
				else
					-- Skip checks when too far or not moving; update timestamp to prevent churn.
					pathfindingState.lastObstacleCheck = currentTime
				end
			end
			
			-- Apply pathfinding based on mode
			if pathfindingState.mode == "advanced" and pathfindingState.obstacleDetected then
				-- Advanced Mode: Check if player is above
				local playerStats = world:get(nearestPlayerId, Components.PlayerStats)
				local playerY = enemyPosition.y  -- Default to same level
				
				if playerStats and playerStats.player and playerStats.player.Character then
					local playerRootPart = playerStats.player.Character:FindFirstChild("HumanoidRootPart")
					if playerRootPart then
						playerY = playerRootPart.Position.Y
					end
				end
				
				local verticalDiff = playerY - enemyPosition.y
				
				if verticalDiff > WALL_CLIMB_THRESHOLD then
					-- Player is above - CLIMB
					-- Set target Y velocity for smooth climbing
					pathfindingState.targetYVelocity = finalSpeed * CLIMB_SPEED_MULTIPLIER
					
					-- Reduce horizontal speed while climbing for smoother movement
					newVelocity.x = baseDirectionX * finalSpeed * CLIMB_HORIZONTAL_REDUCTION
					newVelocity.z = baseDirectionZ * finalSpeed * CLIMB_HORIZONTAL_REDUCTION
				elseif verticalDiff < -WALL_CLIMB_THRESHOLD then
					-- Player is below - DESCEND (apply gravity)
					pathfindingState.targetYVelocity = GRAVITY_ACCELERATION * dt
					
					-- Reduce horizontal speed while descending
					newVelocity.x = baseDirectionX * finalSpeed * CLIMB_HORIZONTAL_REDUCTION
					newVelocity.z = baseDirectionZ * finalSpeed * CLIMB_HORIZONTAL_REDUCTION
				else
					-- Player is on same level - STEER AROUND
					pathfindingState.targetYVelocity = 0  -- No vertical movement
					
				local steeringDir = {x = baseDirectionX, z = baseDirectionZ}
				if pathfindingState.steeringDirection then
					steeringDir = pathfindingState.steeringDirection
				end
				if distSq <= OBSTACLE_CHECK_MAX_DISTANCE_SQ and obstacleChecksRemaining > 0 then
					local lastSteer = pathfindingState.lastSteeringCheck or 0
					if currentTime - lastSteer >= STEERING_CHECK_INTERVAL then
						obstacleChecksRemaining -= 1
						pathfindingState.lastSteeringCheck = currentTime
						local params = getObstacleParams()
						local steeringStart = os.clock()
						steeringDir = calculateSteering(
							enemyPosition,
							{x = baseDirectionX, z = baseDirectionZ},
							{x = baseDirectionX, z = baseDirectionZ},
							params
						)
						steeringTime += os.clock() - steeringStart
						pathfindingState.steeringDirection = steeringDir
					end
				end
					
					-- Apply steering to velocity
					newVelocity.x = steeringDir.x * finalSpeed
					newVelocity.z = steeringDir.z * finalSpeed
					
					-- Cache steering direction
					pathfindingState.steeringDirection = steeringDir
				end
			else
				-- Simple Mode - no climbing
				pathfindingState.targetYVelocity = 0
			end
			
			-- Smooth Y velocity transitions to prevent teleporting
			pathfindingState.currentYVelocity = pathfindingState.currentYVelocity + 
				(pathfindingState.targetYVelocity - pathfindingState.currentYVelocity) * CLIMB_SMOOTHING
			
			-- Apply the smoothed Y velocity
			newVelocity.y = pathfindingState.currentYVelocity
			
			-- Update PathfindingState with new Y velocities
			setPathfindingState(enemyEntity, pathfindingState)
		end

		-- Attack logic (attack when in range and cooldown is ready)
		local damageAmount = damage.amount or 5
		local attackRange = getAttackRangeFromAttackbox(enemyEntity)

		-- Attack only when within attack range (based on attackbox size)
		if distance <= attackRange and (cooldown.remaining or 0) <= 0 then
				-- Check vertical distance - player must be close to ground to be hit
				local canHitPlayer = true
				local playerStats = world:get(nearestPlayerId, Components.PlayerStats)
				if playerStats and playerStats.player and playerStats.player.Character then
					local playerRootPart = playerStats.player.Character:FindFirstChild("HumanoidRootPart")
					if playerRootPart then
						-- Get player's Y position
						local playerY = playerRootPart.Position.Y
						local enemyY = enemyPosition.y
						local verticalDistance = math.abs(playerY - enemyY)
						
						-- Enemy attackbox stays on ground - can only hit players within vertical range
						-- Typical attackbox height is ~5-6 studs, add buffer for jumping
						local maxVerticalReach = 4  -- Can hit players up to 4 studs above enemy
						
						if verticalDistance > maxVerticalReach then
							canHitPlayer = false  -- Player is too high (jumping/double jumping)
						end
					end
				end
				
				if canHitPlayer then
					applyDamageToPlayer(nearestPlayerId, damageAmount)
					setAttackCooldown(enemyEntity, 0.2, 0.2) -- 0.2 second cooldown between attacks
				end
		end

		setVelocity(enemyEntity, newVelocity)
	end

	if aiRaycastTime > 0 then
		Prof.incCounter("AI.RaycastMs", math.floor(aiRaycastTime * 1000 + 0.5))
	end
	if obstacleParamsTime > 0 then
		Prof.incCounter("AI.ObstacleParamsMs", math.floor(obstacleParamsTime * 1000 + 0.5))
	end
	if obstacleParamsRebuilds > 0 then
		Prof.incCounter("AI.ObstacleParamsRebuilds", obstacleParamsRebuilds)
	end
	if obstacleExclusionSize > 0 then
		Prof.gauge("AI.ObstacleExclusionSize", obstacleExclusionSize)
	end
	if obstacleCheckTime > 0 then
		Prof.incCounter("AI.ObstacleCheckMs", math.floor(obstacleCheckTime * 1000 + 0.5))
	end
	if steeringTime > 0 then
		Prof.incCounter("AI.SteeringMs", math.floor(steeringTime * 1000 + 0.5))
	end

	Prof.endTimer("AI.Time")
end

-- Set StatusEffectSystem reference (called after it's initialized)
function ZombieAISystem.setStatusEffectSystem(statusEffectSystem: any)
	StatusEffectSystem = statusEffectSystem
end

return ZombieAISystem
