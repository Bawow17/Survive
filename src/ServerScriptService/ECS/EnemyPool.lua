--!strict
-- EnemyPool - Object pooling for enemies (Zombies and Chargers)
-- Maintains 100 pre-allocated enemy entities to eliminate creation/destruction overhead
-- Supports both Zombie and Charger subtypes

local EnemyPool = {}

local MAX_POOL_SIZE = 100
local REUSE_DELAY_SECONDS = 0.15 -- Allow despawn packets to flush before reusing pooled IDs.
local pool: {number} = {}
local poolCount = 0
local recycleQueue: {{entity: number, readyAt: number}} = {}
local recycleCount = 0
local lastExhaustWarnTime = 0
local EXHAUST_WARN_COOLDOWN = 5.0

local world: any
local Components: any
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local DEBUG = GameOptions.Debug and GameOptions.Debug.Enabled

local function flushRecycleQueue(now: number)
	if recycleCount <= 0 then
		return
	end

	local write = 1
	for i = 1, recycleCount do
		local item = recycleQueue[i]
		if item and item.readyAt <= now and poolCount < MAX_POOL_SIZE then
			poolCount += 1
			pool[poolCount] = item.entity
		else
			recycleQueue[write] = item
			write += 1
		end
	end

	for i = write, recycleCount do
		recycleQueue[i] = nil
	end
	recycleCount = write - 1
end

local function resetEnemyEntity(entity: number, enemyType: string, position: Vector3, owner: any)
	-- Defensive scrub: pooled enemies should never carry player-only/status state.
	if Components.StatusEffects and world:has(entity, Components.StatusEffects) then
		world:remove(entity, Components.StatusEffects)
	end
	if Components.PlayerStats and world:has(entity, Components.PlayerStats) then
		world:remove(entity, Components.PlayerStats)
	end
	if Components.PlayerPauseState and world:has(entity, Components.PlayerPauseState) then
		world:remove(entity, Components.PlayerPauseState)
	end

	local posData = { x = position.X, y = position.Y, z = position.Z }
	world:set(entity, Components.Position, posData)
	world:set(entity, Components.Velocity, { x = 0, y = 0, z = 0 })
	world:set(entity, Components.DesiredVelocity, { x = 0, y = 0, z = 0 })
	world:set(entity, Components.EntityType, {
		type = "Enemy",
		subtype = enemyType,  -- "Zombie" or "Charger"
		owner = owner,
	})
	world:set(entity, Components.Visual, { modelPath = nil, visible = true })
	world:set(entity, Components.FacingDirection, { x = 0, y = 0, z = 1 })
	
	-- Initialize health (will be set by caller based on config)
	world:set(entity, Components.Health, {
		current = 100,
		max = 100,
	})
	
	-- Initialize AI component
	world:set(entity, Components.AI, {
		speed = 8,  -- Will be overwritten by balance config
		state = "idle",
	})
	
	-- Initialize Target
	world:set(entity, Components.Target, {
		id = nil,
		position = { x = 0, y = 0, z = 0 },
	})

	-- Owner/aggro defaults (overwritten by CreateEnemy)
	world:set(entity, Components.EnemyOwner, { id = owner })
	world:set(entity, Components.EnemyAggro, {
		owner = owner,
		target = owner,
		damageByPlayer = {},
		threatByPlayer = {},
		lastThreatTime = 0,
		lastSwitchTime = 0,
		nextSwitchThreshold = 0.30,
	})
	
	-- Initialize optional components
	world:set(entity, Components.Lifetime, { remaining = 300, max = 300 })
end

local function assertHasComponents(entity: number)
	if not DEBUG then
		return
	end
	assert(world:has(entity, Components.Position), "[EnemyPool] Missing Position after acquire")
	assert(world:has(entity, Components.EntityType), "[EnemyPool] Missing EntityType after acquire")
	assert(world:has(entity, Components.Health), "[EnemyPool] Missing Health after acquire")
	assert(world:has(entity, Components.AI), "[EnemyPool] Missing AI after acquire")
end

function EnemyPool.init(worldRef: any, components: any)
	world = worldRef
	Components = components
	
	-- Pre-allocate 100 enemy entities on startup
	if DEBUG then
		print("[EnemyPool] Initializing pool with " .. MAX_POOL_SIZE .. " entities...")
	end
	for i = 1, MAX_POOL_SIZE do
		local entity = world:entity()
		table.insert(pool, entity)
	end
	poolCount = MAX_POOL_SIZE
	if DEBUG then
		print("[EnemyPool] Pool initialized: " .. poolCount .. "/" .. MAX_POOL_SIZE .. " available")
	end
end

-- Acquire an enemy entity from pool (resets all components)
function EnemyPool.acquire(enemyType: string, position: Vector3, owner: any): number
	flushRecycleQueue(tick())

	if poolCount > 0 then
		local entity = pool[poolCount]
		poolCount -= 1
		
		-- Reset all components to safe defaults
		resetEnemyEntity(entity, enemyType, position, owner)
		assertHasComponents(entity)
		
		return entity
	end
	
	-- Pool exhausted - create new entity (fallback)
	local now = tick()
	if now - lastExhaustWarnTime >= EXHAUST_WARN_COOLDOWN then
		lastExhaustWarnTime = now
		warn("[EnemyPool] Pool exhausted (" .. poolCount .. "/" .. MAX_POOL_SIZE .. "), allocating new entity")
	end
	local entity = world:entity()
	resetEnemyEntity(entity, enemyType, position, owner)
	assertHasComponents(entity)
	return entity
end

-- Return an enemy entity to pool (clears components for reuse)
function EnemyPool.release(entity: number)
	flushRecycleQueue(tick())

	if (poolCount + recycleCount) < MAX_POOL_SIZE then
		-- Clear components to free references
		-- CRITICAL: Clear ALL components to prevent state bleeding (invincible mobs bug)
		if world:has(entity, Components.Position) then
			world:remove(entity, Components.Position)
		end
		if world:has(entity, Components.Velocity) then
			world:remove(entity, Components.Velocity)
		end
		if world:has(entity, Components.EntityType) then
			world:remove(entity, Components.EntityType)
		end
		if world:has(entity, Components.Visual) then
			world:remove(entity, Components.Visual)
		end
		if world:has(entity, Components.FacingDirection) then
			world:remove(entity, Components.FacingDirection)
		end
		if world:has(entity, Components.Health) then
			world:remove(entity, Components.Health)
		end
		if world:has(entity, Components.AI) then
			world:remove(entity, Components.AI)
		end
		if world:has(entity, Components.Target) then
			world:remove(entity, Components.Target)
		end
		if world:has(entity, Components.Lifetime) then
			world:remove(entity, Components.Lifetime)
		end
		if world:has(entity, Components.HitFlash) then
			world:remove(entity, Components.HitFlash)
		end
		if world:has(entity, Components.Knockback) then
			world:remove(entity, Components.Knockback)
		end
		if world:has(entity, Components.StatusEffects) then
			world:remove(entity, Components.StatusEffects)
		end
		if world:has(entity, Components.PlayerStats) then
			world:remove(entity, Components.PlayerStats)
		end
		if world:has(entity, Components.PlayerPauseState) then
			world:remove(entity, Components.PlayerPauseState)
		end
		if world:has(entity, Components.DeathAnimation) then
			world:remove(entity, Components.DeathAnimation)
		end
		-- Additional enemy-specific components
		if world:has(entity, Components.Combat) then
			world:remove(entity, Components.Combat)
		end
		if world:has(entity, Components.Movement) then
			world:remove(entity, Components.Movement)
		end
		if world:has(entity, Components.Repulsion) then
			world:remove(entity, Components.Repulsion)
		end
		if world:has(entity, Components.RepulsionVelocity) then
			world:remove(entity, Components.RepulsionVelocity)
		end
		if world:has(entity, Components.DesiredVelocity) then
			world:remove(entity, Components.DesiredVelocity)
		end
		if world:has(entity, Components.ChargerState) then
			world:remove(entity, Components.ChargerState)
		end
		if world:has(entity, Components.PathfindingState) then
			world:remove(entity, Components.PathfindingState)
		end
		if world:has(entity, Components.EnemyPausedTime) then
			world:remove(entity, Components.EnemyPausedTime)
		end
		if world:has(entity, Components.EnemySlow) then
			world:remove(entity, Components.EnemySlow)
		end
		if world:has(entity, Components.EnemyOwner) then
			world:remove(entity, Components.EnemyOwner)
		end
		if world:has(entity, Components.EnemyAggro) then
			world:remove(entity, Components.EnemyAggro)
		end
		if world:has(entity, Components.EnemyTier) then
			world:remove(entity, Components.EnemyTier)
		end
		
		-- Delay reuse slightly so clients process despawn before the same entity ID respawns.
		recycleCount += 1
		recycleQueue[recycleCount] = {
			entity = entity,
			readyAt = tick() + REUSE_DELAY_SECONDS,
		}
	else
		-- Pool full - let entity be garbage collected
		-- (Roblox will handle cleanup)
	end
end

-- Get pool statistics
function EnemyPool.getStats()
	flushRecycleQueue(tick())
	local pooled = poolCount + recycleCount
	local inUse = math.max(MAX_POOL_SIZE - pooled, 0)
	return {
		available = poolCount,
		coolingDown = recycleCount,
		total = MAX_POOL_SIZE,
		inUse = inUse,
		utilization = (inUse / MAX_POOL_SIZE) * 100,
	}
end

return EnemyPool
