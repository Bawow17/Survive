--!strict
-- ChargerAISystem - AI behavior for Charger enemies with dash attacks
-- States: APPROACH → WINDUP → DASH → ENDLAG → COOLDOWN → repeat
-- Refactored to match ZombieAISystem pattern: separate state component, helper functions

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local ObstacleRaycastCache = require(game.ServerScriptService.ECS.Systems.ObstacleRaycastCache)

local ProfilingConfig = require(ReplicatedStorage.Shared.ProfilingConfig)
local Prof = ProfilingConfig.ENABLED and require(ReplicatedStorage.Shared.ProfilingServer) or require(ReplicatedStorage.Shared.ProfilingStub)

local ChargerAISystem = {}

-- Forward reference to PauseSystem (set via setPauseSystem)
local PauseSystem: any

local world
local Components
local DirtyService
local OctreeSystem
local DamageSystem
local StatusEffectSystem
local GameTimeSystem
local EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)
local EasingUtils = require(game.ServerScriptService.Balance.EasingUtils)
local EnemySlowSystem = require(game.ServerScriptService.ECS.Systems.EnemySlowSystem)

-- Component references
local _Position
local Velocity
local _AI
local ChargerState
local FacingDirection
local _EntityTypeComponent
local _Target
local _PlayerStats

-- State constants
local S_APPROACH = 1
local S_WINDUP = 2
local S_DASH = 3
local S_ENDLAG = 4
local S_COOLDOWN = 5

-- Debug spam reduction
local lastPauseDebugLog = 0
local DEBUG_LOG_INTERVAL = 2.0  -- Only log pause state every 2 seconds

-- Obstacle detection and pathfinding settings
local OBSTACLE_CHECK_INTERVAL = 0.4  -- Check obstacles at ~2.5 FPS
local OBSTACLE_RAYCAST_DISTANCE = 3.5  -- Detect obstacles 3.5 studs ahead
local OBSTACLE_CHECK_MAX_DISTANCE = 140  -- Skip obstacle checks beyond this range
local OBSTACLE_CHECK_MIN_SPEED = 0.1
local OBSTACLE_CHECK_BUDGET_PER_STEP = 120
local STEERING_CHECK_INTERVAL = 0.3  -- Throttle steering raycasts in advanced mode
local WALL_CLIMB_THRESHOLD = 5  -- Player must be 5 studs above to trigger climbing
local STEERING_BLEND_FACTOR = 0.7  -- 70% steering, 30% direct to player
local CLIMB_SPEED_MULTIPLIER = 0.4  -- Climb at 40% of horizontal speed
local CLIMB_HORIZONTAL_REDUCTION = 0.6  -- Horizontal speed reduced to 60% while climbing
local CLIMB_SMOOTHING = 0.15  -- Smooth Y velocity changes (lerp factor)
local GRAVITY_ACCELERATION = -25  -- Gravity when falling (studs/s²)

-- Cached queries for performance (JECS best practice)
local chargerQuery: any
local playerQueryCached: any  -- Player positions (for nearest player lookup)
local entityTypeAIQuery: any  -- EntityType + AI (for pause handling)
local OBSTACLE_CHECK_MAX_DISTANCE_SQ = OBSTACLE_CHECK_MAX_DISTANCE * OBSTACLE_CHECK_MAX_DISTANCE

-- Profiling accumulators (reset per step)
local aiRaycastTime = 0
local obstacleParamsTime = 0
local obstacleParamsRebuilds = 0
local obstacleExclusionSize = 0
local obstacleCheckTime = 0
local steeringTime = 0
local lastObstacleRebuildId = 0

-- Cross-system references
function ChargerAISystem.setOctreeSystem(system)
	OctreeSystem = system
end

function ChargerAISystem.setDamageSystem(system)
	DamageSystem = system
end

-- Per-player enemy pause tracking (for individual pause mode)
local pausedPlayerEnemies: {[number]: {
	enemies: {[number]: number},  -- [enemyEntity] = originalSpeed
	pauseStartTime: number,
	enemyPauseStartTimes: {[number]: number},  -- [enemyEntity] = gameTime when paused
}} = {}

-- Helper function to get attack range from Attackbox part size
local function getAttackRangeFromAttackbox(enemyEntity: number): number
	if not world then
		return 3.5 -- Default attack range (fallback)
	end
	
	local entityType = world:get(enemyEntity, _EntityTypeComponent)
	local enemyType = entityType and entityType.subtype or "Charger"

	local attackboxData = ModelReplicationService.getEnemyAttackbox(enemyType)
	if not attackboxData then
		ModelReplicationService.replicateEnemy(enemyType)
		attackboxData = ModelReplicationService.getEnemyAttackbox(enemyType)
	end

	if not attackboxData or not attackboxData.size then
		return 3.5 -- Default if no attackbox found
	end

	local attackboxSize = attackboxData.size
	local maxDimension = math.max(attackboxSize.X, attackboxSize.Z)
	
	-- Add a small buffer (0.5 studs) to ensure reliable contact detection
	return maxDimension + 0.5
end

-- Helper function to find nearest non-paused player
local function findNearestNonPausedPlayer(enemyEntity: number): number?
	local enemyPos = world:get(enemyEntity, _Position)
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
		
		-- Skip players with spawn protection (not all invincibility)
		if StatusEffectSystem and StatusEffectSystem.hasSpawnProtection(playerEntity) then
			continue  -- Don't target spawn-protected players
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
function ChargerAISystem.onPlayerPaused(playerEntity: number)
	if not world or GameOptions.GlobalPause then
		return  -- Only applies to individual pause mode
	end
	
	local affectedEnemies = {}
	
	-- Chargers don't use Target component - freeze ALL chargers
	-- They use OctreeSystem for targeting, so we can't filter by target
	-- Instead, freeze all chargers (they'll retarget naturally via OctreeSystem)
	-- Use cached query for performance (JECS best practice)
	for entity, entityType, ai in entityTypeAIQuery do
		if entityType.type == "Enemy" and (ai.behaviorType == "Charger") then
			-- Store original speed (use balance base speed if already frozen)
			local originalSpeed = ai.speed
			if originalSpeed == 0 then
				originalSpeed = 27.0  -- Charger base speed from balance
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
function ChargerAISystem.onPlayerUnpaused(playerEntity: number)
	-- Restore speeds for all enemies that were tracking this player
	local data = pausedPlayerEnemies[playerEntity]
	if data then
		local count = 0
		local currentGameTime = GameTimeSystem.getGameTime()
		
		for enemyEntity, originalSpeed in pairs(data.enemies) do
			if world:contains(enemyEntity) then
				local ai = world:get(enemyEntity, _AI)
				if ai then
					ai.speed = originalSpeed
					world:set(enemyEntity, _AI, ai)
					DirtyService.mark(enemyEntity, "AI")
					count = count + 1
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
				
				-- Chargers use OctreeSystem for targeting, not Target component
				-- They'll automatically retarget via getNearestPlayerPosition()
			end
		end
	end
	
	-- Clean up pause tracking
	pausedPlayerEnemies[playerEntity] = nil
end

-- Set PauseSystem reference (called from Bootstrap)
function ChargerAISystem.setPauseSystem(pauseSystem: any)
	PauseSystem = pauseSystem
end

function ChargerAISystem.setStatusEffectSystem(system)
	StatusEffectSystem = system
end

function ChargerAISystem.setGameTimeSystem(system)
	GameTimeSystem = system
end

function ChargerAISystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	_Position = Components.Position
	Velocity = Components.Velocity
	_AI = Components.AI
	ChargerState = Components.ChargerState
	FacingDirection = Components.FacingDirection
	_EntityTypeComponent = Components.EntityType
	_Target = Components.Target
	_PlayerStats = Components.PlayerStats
	
	-- Create cached queries for performance (JECS best practice)
	-- CRITICAL: Exclude dead enemies (with DeathAnimation) from AI processing
	chargerQuery = world:query(Components.Position, Components.Velocity, Components.AI, Components.ChargerState, Components.FacingDirection, Components.EntityType):without(Components.DeathAnimation):cached()
	playerQueryCached = world:query(Components.Position, Components.PlayerStats):cached()
	entityTypeAIQuery = world:query(Components.EntityType, Components.AI):cached()
end

-- Helper functions (same pattern as ZombieAISystem)
local function setVelocity(entity: number, velocity: {x: number, y: number, z: number})
	DirtyService.setIfChanged(world, entity, Velocity, velocity, "Velocity")
end

local function setFacingDirection(entity: number, direction: {x: number, y: number, z: number})
	DirtyService.setIfChanged(world, entity, FacingDirection, direction, "FacingDirection")
end

local function setChargerState(entity: number, stateData: any)
	DirtyService.setIfChanged(world, entity, ChargerState, stateData, "ChargerState")
end

-- Helper: Get current game time (pause-aware)
local function getGameTime(): number
	if GameTimeSystem then
		return GameTimeSystem.getGameTime()
	end
	return 0
end

-- Helper: Check if entity is a player and is invincible
local function isPlayerInvincible(playerEntity): boolean
	if not StatusEffectSystem then return false end
	return StatusEffectSystem.hasInvincibility(playerEntity)
end

local function aiRaycast(origin: Vector3, direction: Vector3, params: RaycastParams): RaycastResult?
	Prof.incCounter("AI.Raycasts", 1)
	local startTime = os.clock()
	local result = Workspace:Raycast(origin, direction, params)
	aiRaycastTime += os.clock() - startTime
	return result
end

-- Detect obstacle in front of charger (including overhangs and steep slopes)
local function detectObstacle(chargerPos: Vector3, direction: Vector3, params: RaycastParams): boolean
	if direction.Magnitude == 0 then
		return false
	end
	
	local normDir = direction.Unit
	
	-- FORWARD OBSTACLE CHECK: Cast forward from 1 stud above ground
	local origin = chargerPos + Vector3.new(0, 1, 0)
	local rayDirection = normDir * OBSTACLE_RAYCAST_DISTANCE
	
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
	local upOrigin = chargerPos + Vector3.new(0, 1, 0)
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
	local aheadOrigin = chargerPos + normDir * 2 + Vector3.new(0, 2, 0)
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
local function calculateSteering(chargerPos: Vector3, currentDir: Vector3, targetDir: Vector3, params: RaycastParams): Vector3
	if currentDir.Magnitude == 0 then
		return targetDir
	end
	
	local normCurrent = currentDir.Unit
	
	local origin = chargerPos + Vector3.new(0, 1, 0)
	
	-- Cast left (rotate 90 degrees counter-clockwise)
	local leftDir = Vector3.new(-normCurrent.Z, 0, normCurrent.X)
	local leftRayDir = leftDir * OBSTACLE_RAYCAST_DISTANCE
	local leftResult = aiRaycast(origin, leftRayDir, params)
	
	-- Cast right (rotate 90 degrees clockwise)
	local rightDir = Vector3.new(normCurrent.Z, 0, -normCurrent.X)
	local rightRayDir = rightDir * OBSTACLE_RAYCAST_DISTANCE
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
	local blended = steerDir * STEERING_BLEND_FACTOR + targetDir * (1 - STEERING_BLEND_FACTOR)
	
	-- Normalize blended direction
	if blended.Magnitude > 0 then
		return blended.Unit
	end
	
	return targetDir.Unit
end

-- Set or update PathfindingState component
local function setPathfindingState(entity: number, stateData: any)
	DirtyService.setIfChanged(world, entity, Components.PathfindingState, stateData, "PathfindingState")
end

function ChargerAISystem.step(dt: number)
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
						local ai = world:get(enemyEntity, _AI)
						if ai and ai.speed ~= 0 then
							ai.speed = 0
							world:set(enemyEntity, _AI, ai)
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
							local ai = world:get(enemyEntity, _AI)
							if ai then
								ai.speed = originalSpeed
								world:set(enemyEntity, _AI, ai)
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
							
							-- Chargers use OctreeSystem for targeting, they'll retarget automatically
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
								-- Found valid target, restore speed
								local ai = world:get(enemyEntity, _AI)
								if ai then
									ai.speed = originalSpeed
									world:set(enemyEntity, _AI, ai)
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
								
								-- Chargers use OctreeSystem, they'll retarget automatically
							end
							-- Don't log "waiting for valid target" - too spammy
						end
					end
					-- DON'T clean up - will clean up when player actually unpauses
				end
			end
		end
	end
	
	-- CRITICAL: Collect all Chargers FIRST, then process
	-- Never modify components during JECS query iteration!
	local chargers = {}
	
	for entity, position, velocity, ai, chargerState, facingDir, entityType in chargerQuery do
		if entityType.type ~= "Enemy" then continue end
		if not ai.behaviorType or ai.behaviorType ~= "Charger" then continue end
		
		table.insert(chargers, {
			entity = entity,
			position = position,
			velocity = velocity,
			ai = ai,
			chargerState = chargerState,
			facingDir = facingDir,
		})
	end
	
	-- Process collected Chargers (safe to modify components now)
	-- (No per-frame logging to avoid spam)
	for _, chargerData in ipairs(chargers) do
		local entity = chargerData.entity
		local position = chargerData.position
		local ai = chargerData.ai
		local chargerState = chargerData.chargerState
		
		-- Get balance data
		local balance = ai.balance
		if not balance then continue end
		
		-- CRITICAL: Check if frozen by pause system
		if ai.speed == 0 then
			setVelocity(entity, { x = 0, y = 0, z = 0 })
			continue  -- Skip all AI processing for frozen chargers
		end
		
		-- Initialize state if needed
		if not chargerState or not chargerState.state or type(chargerState.state) == "string" then
			local base = balance.preferredRange or 35
			local jitter = balance.preferredJitter or 5
			local preferredRange = base + (math.random() * 2 - 1) * jitter
			
			setChargerState(entity, {
				state = S_APPROACH,
				stateEndTime = 0,
				dashDirection = nil,
				hitOnThisDash = false,
				preferredRange = preferredRange,
			})
			continue
		end
		
		-- Convert position to Vector3
		local myPos = Vector3.new(position.x, position.y, position.z)
		
		-- Find nearest player (filters out paused players automatically)
		local playerPos: Vector3? = OctreeSystem.getNearestPlayerPosition(myPos)
		if not playerPos then
			setVelocity(entity, { x = 0, y = 0, z = 0 })
			continue
		end
		
		local now = getGameTime()
		local currentTime = tick()
		local toPlayer = Vector3.new((playerPos :: Vector3).X - myPos.X, 0, (playerPos :: Vector3).Z - myPos.Z)
		local dist = toPlayer.Magnitude
		local distSq = dist * dist
		
		-- Calculate current move speed with scaling
		local baseSpeed = balance.baseSpeed or 27
		local approachSpeed = baseSpeed
		
		-- Apply global and lifetime scaling
		local gameTime = GameTimeSystem.getGameTime()
		local globalSpeedMult = EasingUtils.evaluate(EnemyBalance.GlobalMoveSpeedScaling, gameTime)
		local spawnTime = world:get(entity, Components.SpawnTime)
		local lifetimeSpeedMult = 1.0
		if spawnTime then
			local entityLifetime = gameTime - spawnTime.time
			
			-- Subtract total paused time from lifetime (enemies don't age while paused)
			local pausedTime = world:get(entity, Components.EnemyPausedTime)
			if pausedTime then
				entityLifetime = entityLifetime - pausedTime.totalPausedTime
				entityLifetime = math.max(0, entityLifetime)  -- Never negative
			end
			
			lifetimeSpeedMult = EasingUtils.evaluate(EnemyBalance.LifetimeMoveSpeedScaling, entityLifetime)
		end
		approachSpeed = approachSpeed * globalSpeedMult * lifetimeSpeedMult
		local slowMultiplier = EnemySlowSystem.getSlowMultiplier(entity)
		approachSpeed = approachSpeed * slowMultiplier
		
		-- CRITICAL: Update AI component with scaled speed (for persistence + sync)
		if ai.speed ~= approachSpeed then
			ai.speed = approachSpeed
			world:set(entity, _AI, ai)
			DirtyService.mark(entity, "AI")
		end
		
		-- Apply cooldown speed penalty
		if chargerState.state == S_COOLDOWN then
			approachSpeed = approachSpeed * (balance.cooldownSpeedMult or 0.7)
		end
		
		-- Determine facing direction (ALWAYS face player, except during dash or locked windup)
		local faceDirVec3
		if chargerState.state == S_DASH and chargerState.dashDirection then
			faceDirVec3 = chargerState.dashDirection
		elseif chargerState.state == S_WINDUP and chargerState.directionLocked and chargerState.dashDirection then
			-- NEW: Also freeze facing during windup after direction locks
			faceDirVec3 = chargerState.dashDirection
		elseif dist > 0 then
			faceDirVec3 = toPlayer.Unit
		else
			faceDirVec3 = Vector3.new(0, 0, 1)
		end
		
		-- OBSTACLE DETECTION AND PATHFINDING (only for APPROACH and COOLDOWN states)
		-- Get or initialize PathfindingState
		local pathfindingState = world:get(entity, Components.PathfindingState)
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
		
		-- Only apply pathfinding in APPROACH and COOLDOWN states (not during DASH!)
		if chargerState.state == S_APPROACH or chargerState.state == S_COOLDOWN then
			-- Check if time to update obstacle detection (5 FPS)
			if currentTime - pathfindingState.lastObstacleCheck >= OBSTACLE_CHECK_INTERVAL then
				local shouldCheck = distSq <= OBSTACLE_CHECK_MAX_DISTANCE_SQ and approachSpeed > OBSTACLE_CHECK_MIN_SPEED
				if shouldCheck then
					if obstacleChecksRemaining > 0 then
						obstacleChecksRemaining -= 1
						pathfindingState.lastObstacleCheck = currentTime

						-- Detect obstacle in movement direction
						local params = getObstacleParams()
						local obstacleStart = os.clock()
						local hasObstacle = detectObstacle(myPos, toPlayer.Unit, params)
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
						setPathfindingState(entity, pathfindingState)
					end
				else
					-- Skip checks when too far or not moving; update timestamp to prevent churn.
					pathfindingState.lastObstacleCheck = currentTime
				end
			end
		else
			-- During DASH/WINDUP/ENDLAG: Force Simple Mode (ignore obstacles)
			if pathfindingState.mode ~= "simple" then
				pathfindingState.mode = "simple"
				pathfindingState.obstacleDetected = false
				pathfindingState.steeringDirection = nil
				setPathfindingState(entity, pathfindingState)
			end
		end
		
		-- State machine
		if chargerState.state == S_APPROACH then
			local targetRange = chargerState.preferredRange or (balance.dashTriggerRange or 18)
			local deadband = 1.5
			
			if dist > targetRange + deadband then
				-- Too far: close distance
				local moveDir = faceDirVec3
				
				-- Apply pathfinding if in Advanced Mode
				if pathfindingState.mode == "advanced" and pathfindingState.obstacleDetected then
					-- Check if player is above
					local playerY = (playerPos :: Vector3).Y
					local chargerY = myPos.Y
					local verticalDiff = playerY - chargerY
					
					if verticalDiff > WALL_CLIMB_THRESHOLD then
						-- Player is above - CLIMB
						pathfindingState.targetYVelocity = approachSpeed * CLIMB_SPEED_MULTIPLIER
						local newVel = faceDirVec3 * approachSpeed * CLIMB_HORIZONTAL_REDUCTION
						
						-- Smooth Y velocity
						pathfindingState.currentYVelocity = pathfindingState.currentYVelocity + 
							(pathfindingState.targetYVelocity - pathfindingState.currentYVelocity) * CLIMB_SMOOTHING
						
						setVelocity(entity, { x = newVel.X, y = pathfindingState.currentYVelocity, z = newVel.Z })
					elseif verticalDiff < -WALL_CLIMB_THRESHOLD then
						-- Player is below - DESCEND
						pathfindingState.targetYVelocity = GRAVITY_ACCELERATION * dt
						local newVel = faceDirVec3 * approachSpeed * CLIMB_HORIZONTAL_REDUCTION
						
						-- Smooth Y velocity
						pathfindingState.currentYVelocity = pathfindingState.currentYVelocity + 
							(pathfindingState.targetYVelocity - pathfindingState.currentYVelocity) * CLIMB_SMOOTHING
						
						setVelocity(entity, { x = newVel.X, y = pathfindingState.currentYVelocity, z = newVel.Z })
					else
						-- Player is on same level - STEER AROUND
						pathfindingState.targetYVelocity = 0
						
						-- Smooth Y velocity back to 0
						pathfindingState.currentYVelocity = pathfindingState.currentYVelocity + 
							(pathfindingState.targetYVelocity - pathfindingState.currentYVelocity) * CLIMB_SMOOTHING
						
						local steeringDir = pathfindingState.steeringDirection or faceDirVec3
						if distSq <= OBSTACLE_CHECK_MAX_DISTANCE_SQ and obstacleChecksRemaining > 0 then
							local lastSteer = pathfindingState.lastSteeringCheck or 0
							if currentTime - lastSteer >= STEERING_CHECK_INTERVAL then
								obstacleChecksRemaining -= 1
								pathfindingState.lastSteeringCheck = currentTime
								local params = getObstacleParams()
								local steeringStart = os.clock()
								steeringDir = calculateSteering(myPos, faceDirVec3, faceDirVec3, params)
								steeringTime += os.clock() - steeringStart
								pathfindingState.steeringDirection = steeringDir
							end
						end
						local newVel = steeringDir * approachSpeed
						setVelocity(entity, { x = newVel.X, y = pathfindingState.currentYVelocity, z = newVel.Z })
					end
				else
					-- Simple Mode: Direct movement
					pathfindingState.targetYVelocity = 0
					
					-- Smooth Y velocity back to 0
					pathfindingState.currentYVelocity = pathfindingState.currentYVelocity + 
						(pathfindingState.targetYVelocity - pathfindingState.currentYVelocity) * CLIMB_SMOOTHING
					
					local newVel = moveDir * approachSpeed
					setVelocity(entity, { x = newVel.X, y = pathfindingState.currentYVelocity, z = newVel.Z })
				end
				
				-- Update PathfindingState
				setPathfindingState(entity, pathfindingState)
			elseif dist < targetRange - deadband then
				-- Too close: back off (ignore pathfinding when backing up)
				local newVel = -faceDirVec3 * approachSpeed
				setVelocity(entity, { x = newVel.X, y = 0, z = newVel.Z })
			else
				-- In range: prep dash
				setVelocity(entity, { x = 0, y = 0, z = 0 })
				setChargerState(entity, {
					state = S_WINDUP,
					stateEndTime = now + (balance.windupTime or 0.4),
					windupStartTime = now,  -- NEW: Track when windup started
					dashDirection = nil,  -- NEW: Start unlocked (will be set during windup)
					directionLocked = false,  -- NEW: Track lock state
					hitOnThisDash = false,
					preferredRange = chargerState.preferredRange,
				})
			end
			
		elseif chargerState.state == S_WINDUP then
			-- Hold position during windup
			setVelocity(entity, { x = 0, y = 0, z = 0 })
			
			-- Check if direction should be locked (based on lock delay)
			local lockDelay = balance.directionLockDelay or 0
			local windupElapsed = now - (chargerState.windupStartTime or now)
			
			if not chargerState.directionLocked and windupElapsed >= lockDelay then
				-- TIME TO LOCK: Sample direction and freeze it
				setChargerState(entity, {
					state = S_WINDUP,
					stateEndTime = chargerState.stateEndTime,
					windupStartTime = chargerState.windupStartTime,
					dashDirection = faceDirVec3,  -- LOCK direction at current player position
					directionLocked = true,  -- Mark as locked
					hitOnThisDash = false,
					preferredRange = chargerState.preferredRange,
				})
			end
			
			if now >= chargerState.stateEndTime then
				-- Use the locked direction (was set earlier in windup)
				local lockedDashDir = chargerState.dashDirection or faceDirVec3  -- Fallback if lock failed
				
				-- Calculate dash duration
				local dashSpeed = (balance.dashSpeed or 60) * slowMultiplier
				local dashDist = dist + (balance.dashOvershoot or 30)
				local dashDur = dashSpeed > 0 and (dashDist / dashSpeed) or (balance.dashDuration or 0.75)
				dashDur = math.max(balance.dashDuration or 0.75, dashDur)
				
				-- INSTANT LAUNCH: Set dash velocity immediately on transition
				local dashVel = lockedDashDir * dashSpeed
				setVelocity(entity, { x = dashVel.X, y = 0, z = dashVel.Z })
				
				setChargerState(entity, {
					state = S_DASH,
					stateEndTime = now + dashDur,
					dashDirection = lockedDashDir,
					hitOnThisDash = false,
					preferredRange = chargerState.preferredRange,
				})
			end
			
		elseif chargerState.state == S_DASH then
			-- Fast straight-line dash
			local dashDir = chargerState.dashDirection or faceDirVec3
			local dashSpeed = (balance.dashSpeed or 60) * slowMultiplier
			local newVel = dashDir * dashSpeed
			setVelocity(entity, { x = newVel.X, y = 0, z = newVel.Z })
			
			-- Check for dash collision (deal damage once)
			if not chargerState.hitOnThisDash then
				-- Get attack range from Attackbox part size
				local attackRange = getAttackRangeFromAttackbox(entity)
				local hitRadius = attackRange + 3.0
				local nearbyPlayers = OctreeSystem.getPlayersInRadius(myPos, hitRadius)
				
				for _, playerEntity in ipairs(nearbyPlayers) do
					if not isPlayerInvincible(playerEntity) then
						-- Check vertical distance - player must be close to ground to be hit
						local canHitPlayer = true
						local playerStats = world:get(playerEntity, Components.PlayerStats)
						if playerStats and playerStats.player and playerStats.player.Character then
							local playerRootPart = playerStats.player.Character:FindFirstChild("HumanoidRootPart")
							if playerRootPart then
								local playerY = playerRootPart.Position.Y
								local chargerY = position.y
								local verticalDistance = math.abs(playerY - chargerY)
								
								-- Charger attackbox stays on ground
								local maxVerticalReach = 4  -- Same as zombies
								
								if verticalDistance > maxVerticalReach then
									canHitPlayer = false  -- Player is too high
								end
							end
						end
						
						-- Deal dash damage if within vertical reach
						if canHitPlayer and DamageSystem then
							DamageSystem.applyDamage(playerEntity, balance.baseDamage or 15, "dash", entity)
							
							-- Mark as hit (update state)
							setChargerState(entity, {
								state = chargerState.state,
								stateEndTime = chargerState.stateEndTime,
								dashDirection = chargerState.dashDirection,
								hitOnThisDash = true,
								preferredRange = chargerState.preferredRange,
							})
							break
						end
					end
				end
			end
			
			-- Check if dash is complete
			if now >= chargerState.stateEndTime then
				setVelocity(entity, { x = 0, y = 0, z = 0 })
				setChargerState(entity, {
					state = S_ENDLAG,
					stateEndTime = now + (balance.endlagTime or 0.6),
					dashDirection = chargerState.dashDirection,
					hitOnThisDash = chargerState.hitOnThisDash,
					preferredRange = chargerState.preferredRange,
				})
			end
			
		elseif chargerState.state == S_ENDLAG then
			-- Stuck in place
			setVelocity(entity, { x = 0, y = 0, z = 0 })
			
			if now >= chargerState.stateEndTime then
				setChargerState(entity, {
					state = S_COOLDOWN,
					stateEndTime = now + (balance.dashCooldown or 3.5),
					dashDirection = nil,
					hitOnThisDash = false,
					preferredRange = chargerState.preferredRange,
				})
			end
			
		elseif chargerState.state == S_COOLDOWN then
			-- Slow chase during cooldown
			-- Get attack range from Attackbox part size
			local attackRange = getAttackRangeFromAttackbox(entity)
			if dist > attackRange + 1.5 then
				-- Apply pathfinding if in Advanced Mode
				if pathfindingState.mode == "advanced" and pathfindingState.obstacleDetected then
					-- Check if player is above
					local playerY = (playerPos :: Vector3).Y
					local chargerY = myPos.Y
					local verticalDiff = playerY - chargerY
					
					if verticalDiff > WALL_CLIMB_THRESHOLD then
						-- Player is above - CLIMB
						pathfindingState.targetYVelocity = approachSpeed * CLIMB_SPEED_MULTIPLIER
						local newVel = faceDirVec3 * approachSpeed * CLIMB_HORIZONTAL_REDUCTION
						
						-- Smooth Y velocity
						pathfindingState.currentYVelocity = pathfindingState.currentYVelocity + 
							(pathfindingState.targetYVelocity - pathfindingState.currentYVelocity) * CLIMB_SMOOTHING
						
						setVelocity(entity, { x = newVel.X, y = pathfindingState.currentYVelocity, z = newVel.Z })
					elseif verticalDiff < -WALL_CLIMB_THRESHOLD then
						-- Player is below - DESCEND
						pathfindingState.targetYVelocity = GRAVITY_ACCELERATION * dt
						local newVel = faceDirVec3 * approachSpeed * CLIMB_HORIZONTAL_REDUCTION
						
						-- Smooth Y velocity
						pathfindingState.currentYVelocity = pathfindingState.currentYVelocity + 
							(pathfindingState.targetYVelocity - pathfindingState.currentYVelocity) * CLIMB_SMOOTHING
						
						setVelocity(entity, { x = newVel.X, y = pathfindingState.currentYVelocity, z = newVel.Z })
					else
						-- Player is on same level - STEER AROUND
						pathfindingState.targetYVelocity = 0
						
						-- Smooth Y velocity back to 0
						pathfindingState.currentYVelocity = pathfindingState.currentYVelocity + 
							(pathfindingState.targetYVelocity - pathfindingState.currentYVelocity) * CLIMB_SMOOTHING
						
						local steeringDir = pathfindingState.steeringDirection or faceDirVec3
						if distSq <= OBSTACLE_CHECK_MAX_DISTANCE_SQ and obstacleChecksRemaining > 0 then
							local lastSteer = pathfindingState.lastSteeringCheck or 0
							if currentTime - lastSteer >= STEERING_CHECK_INTERVAL then
								obstacleChecksRemaining -= 1
								pathfindingState.lastSteeringCheck = currentTime
								local params = getObstacleParams()
								local steeringStart = os.clock()
								steeringDir = calculateSteering(myPos, faceDirVec3, faceDirVec3, params)
								steeringTime += os.clock() - steeringStart
								pathfindingState.steeringDirection = steeringDir
							end
						end
						local newVel = steeringDir * approachSpeed
						setVelocity(entity, { x = newVel.X, y = pathfindingState.currentYVelocity, z = newVel.Z })
					end
				else
					-- Simple Mode: Direct movement
					pathfindingState.targetYVelocity = 0
					
					-- Smooth Y velocity back to 0
					pathfindingState.currentYVelocity = pathfindingState.currentYVelocity + 
						(pathfindingState.targetYVelocity - pathfindingState.currentYVelocity) * CLIMB_SMOOTHING
					
					local newVel = faceDirVec3 * approachSpeed
					setVelocity(entity, { x = newVel.X, y = pathfindingState.currentYVelocity, z = newVel.Z })
				end
				
				-- Update PathfindingState
				setPathfindingState(entity, pathfindingState)
			else
				setVelocity(entity, { x = 0, y = 0, z = 0 })
			end
			
			if now >= chargerState.stateEndTime then
				-- Re-roll preferred range
				local base = balance.preferredRange or 26
				local jitter = balance.preferredJitter or 5
				local newPreferredRange = base + (math.random() * 2 - 1) * jitter
				
				setChargerState(entity, {
					state = S_APPROACH,
					stateEndTime = 0,
					dashDirection = nil,
					hitOnThisDash = false,
					preferredRange = newPreferredRange,
				})
			end
		end
		
		-- Update facing direction (always, like ZombieAISystem)
		setFacingDirection(entity, { x = faceDirVec3.X, y = 0, z = faceDirVec3.Z })
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

return ChargerAISystem
