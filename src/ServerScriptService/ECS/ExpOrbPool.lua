--!strict
-- ExpOrbPool - Object pooling for exp orbs
-- Maintains 300 pre-allocated exp orb entities to eliminate creation/destruction overhead

local ExpOrbPool = {}

local MAX_POOL_SIZE = 300
local pool: {number} = {}
local poolCount = 0

local world: any
local Components: any

function ExpOrbPool.init(worldRef: any, components: any)
	world = worldRef
	Components = components
	
	-- Pre-allocate 300 exp orb entities on startup
	print("[ExpOrbPool] Initializing pool with " .. MAX_POOL_SIZE .. " entities...")
	for i = 1, MAX_POOL_SIZE do
		local entity = world:entity()
		table.insert(pool, entity)
	end
	poolCount = MAX_POOL_SIZE
	print("[ExpOrbPool] Pool initialized: " .. poolCount .. "/" .. MAX_POOL_SIZE .. " available")
end

-- Acquire an exp orb entity from pool (resets all components)
function ExpOrbPool.acquire(position: Vector3, owner: any): number
	if poolCount > 0 then
		local entity = pool[poolCount]
		poolCount -= 1
		
		-- Reset all components to safe defaults
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
		
		return entity
	end
	
	-- Pool exhausted - create new entity (fallback)
	warn("[ExpOrbPool] Pool exhausted (" .. poolCount .. "/" .. MAX_POOL_SIZE .. "), allocating new entity")
	return world:entity()
end

-- Return an exp orb entity to pool (clears components for reuse)
function ExpOrbPool.release(entity: number)
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
	}
end

return ExpOrbPool
