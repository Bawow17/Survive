--!strict
-- ExpOrbPool - Object pooling for exp orbs
-- Maintains 300 pre-allocated exp orb entities to eliminate creation/destruction overhead

local ExpOrbPool = {}

local MAX_POOL_SIZE = 300
local pool: {number} = {}
local poolCount = 0
local lastExhaustWarnTime = 0
local EXHAUST_WARN_COOLDOWN = 5.0

local world: any
local Components: any
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local DEBUG = GameOptions.Debug and GameOptions.Debug.Enabled

local acquireCount = 0
local returnCount = 0
local allocNewCount = 0
local activeCount = 0

local function resetExpOrbEntity(entity: number, position: Vector3, owner: any)
	local posData = { x = position.X, y = position.Y, z = position.Z }
	world:set(entity, Components.Position, posData)
	world:set(entity, Components.Velocity, { x = 0, y = 0, z = 0 })
	world:set(entity, Components.EntityType, {
		type = "ExpOrb",
		owner = owner,
	})
	world:set(entity, Components.Visual, { modelPath = nil, visible = true })
	world:set(entity, Components.ItemData, {
		type = "ExpOrb",
		value = 10,  -- Default; will be overwritten by caller
		rarity = "common",
		ownerId = owner and owner.UserId or nil,
	})
	
	-- Initialize optional components
	world:set(entity, Components.Lifetime, { remaining = 30, max = 30 })
end

local function assertHasComponents(entity: number)
	if not DEBUG then
		return
	end
	assert(world:has(entity, Components.Position), "[ExpOrbPool] Missing Position after acquire")
	assert(world:has(entity, Components.EntityType), "[ExpOrbPool] Missing EntityType after acquire")
	assert(world:has(entity, Components.ItemData), "[ExpOrbPool] Missing ItemData after acquire")
	assert(world:has(entity, Components.Lifetime), "[ExpOrbPool] Missing Lifetime after acquire")
end

function ExpOrbPool.init(worldRef: any, components: any)
	world = worldRef
	Components = components
	
	-- Pre-allocate 300 exp orb entities on startup
	if DEBUG then
		print("[ExpOrbPool] Initializing pool with " .. MAX_POOL_SIZE .. " entities...")
	end
	for i = 1, MAX_POOL_SIZE do
		local entity = world:entity()
		table.insert(pool, entity)
	end
	poolCount = MAX_POOL_SIZE
	if DEBUG then
		print("[ExpOrbPool] Pool initialized: " .. poolCount .. "/" .. MAX_POOL_SIZE .. " available")
	end
end

-- Acquire an exp orb entity from pool (resets all components)
function ExpOrbPool.acquire(position: Vector3, owner: any): number
	acquireCount += 1
	if poolCount > 0 then
		local entity = pool[poolCount]
		poolCount -= 1
		
		-- Reset all components to safe defaults
		resetExpOrbEntity(entity, position, owner)
		activeCount += 1
		assertHasComponents(entity)
		
		return entity
	end
	
	-- Pool exhausted - create new entity (fallback)
	local now = tick()
	if now - lastExhaustWarnTime >= EXHAUST_WARN_COOLDOWN then
		lastExhaustWarnTime = now
		warn("[ExpOrbPool] Pool exhausted (" .. poolCount .. "/" .. MAX_POOL_SIZE .. "), allocating new entity")
	end
	local entity = world:entity()
	allocNewCount += 1
	activeCount += 1
	resetExpOrbEntity(entity, position, owner)
	assertHasComponents(entity)
	return entity
end

-- Return an exp orb entity to pool (clears components for reuse)
function ExpOrbPool.release(entity: number)
	returnCount += 1
	if activeCount > 0 then
		activeCount -= 1
	end
	if poolCount < MAX_POOL_SIZE then
		-- Clear components to free references
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
		if world:has(entity, Components.ItemData) then
			world:remove(entity, Components.ItemData)
		end
		if world:has(entity, Components.Lifetime) then
			world:remove(entity, Components.Lifetime)
		end
		
		-- Return to pool
		poolCount += 1
		pool[poolCount] = entity
	else
		-- Pool full - let entity be garbage collected
		-- (Roblox will handle cleanup)
	end
end

-- Get pool statistics
function ExpOrbPool.getStats()
	return {
		available = poolCount,
		total = MAX_POOL_SIZE,
		inUse = MAX_POOL_SIZE - poolCount,
		utilization = ((MAX_POOL_SIZE - poolCount) / MAX_POOL_SIZE) * 100,
		acquireCount = acquireCount,
		returnCount = returnCount,
		allocNewCount = allocNewCount,
		activeCount = activeCount,
	}
end

return ExpOrbPool
