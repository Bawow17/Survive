--!strict
-- ProjectilePool - Object pooling for projectiles (including explosions)
-- Maintains 10000 pre-allocated projectile entities to eliminate creation/destruction overhead
-- Supports 10+ players with burst attributes (FireStorm + CannonFire)
-- All components reset to defaults on acquire for safety

local ProjectilePool = {}

local MAX_POOL_SIZE = 10000  -- Increased from 500 to support 10+ players with burst attributes (FireStorm + CannonFire)
local POOL_WARNING_THRESHOLD = 0.9  -- Warn when pool usage exceeds 90%
local pool: {number} = {}
local poolCount = 0
local lastWarningTime = 0
local WARNING_COOLDOWN = 5.0  -- Only warn every 5 seconds

local world: any
local Components: any
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local DEBUG = GameOptions.Debug and GameOptions.Debug.Enabled

function ProjectilePool.init(worldRef: any, components: any)
	world = worldRef
	Components = components
	
	-- Pre-allocate 10000 projectile entities on startup
	if DEBUG then
		print("[ProjectilePool] Initializing pool with " .. MAX_POOL_SIZE .. " entities...")
	end
	for i = 1, MAX_POOL_SIZE do
		local entity = world:entity()
		table.insert(pool, entity)
	end
	poolCount = MAX_POOL_SIZE
	if DEBUG then
		print("[ProjectilePool] Pool initialized: " .. poolCount .. "/" .. MAX_POOL_SIZE .. " available")
		print("[ProjectilePool] Will warn when usage exceeds " .. (POOL_WARNING_THRESHOLD * 100) .. "%")
	end
end

-- Acquire a projectile entity from pool (resets all components)
function ProjectilePool.acquire(position: Vector3, owner: any, projectileType: string?): number
	if poolCount > 0 then
		local entity = pool[poolCount]
		poolCount -= 1
		
		-- Check for high pool usage and warn (throttled to every 5 seconds)
		local usage = (MAX_POOL_SIZE - poolCount) / MAX_POOL_SIZE
		if usage >= POOL_WARNING_THRESHOLD then
			local currentTime = tick()
			if currentTime - lastWarningTime >= WARNING_COOLDOWN then
				lastWarningTime = currentTime
				warn(string.format(
					"[ProjectilePool] High usage warning: %d/%d (%.1f%%) - Consider optimizing projectile spawn rates",
					MAX_POOL_SIZE - poolCount,
					MAX_POOL_SIZE,
					usage * 100
				))
			end
		end
		
		-- Reset all components to safe defaults
		local posData = { x = position.X, y = position.Y, z = position.Z }
		world:set(entity, Components.Position, posData)
		world:set(entity, Components.Velocity, { x = 0, y = 0, z = 0 })
		world:set(entity, Components.EntityType, {
			type = "Projectile",
			subtype = projectileType or "Generic",
			owner = owner,
		})
		world:set(entity, Components.Visual, { modelPath = nil, visible = true })
		
		-- Initialize optional components (will be overwritten by caller)
		-- CRITICAL FIX: Use remaining/max fields for Lifetime (not startTime/duration)
		world:set(entity, Components.Lifetime, { remaining = 10, max = 10 })
		world:set(entity, Components.FacingDirection, { x = 1, y = 0, z = 0 })
		
		return entity
	end
	
	-- Pool exhausted - create new entity (fallback)
	warn("[ProjectilePool] Pool exhausted (" .. poolCount .. "/" .. MAX_POOL_SIZE .. "), allocating new entity")
	return world:entity()
end

-- Return a projectile entity to pool (clears components for reuse)
function ProjectilePool.release(entity: number)
	if poolCount < MAX_POOL_SIZE then
		-- Clear components to free references
		-- CRITICAL: Clear ALL components to prevent state bleeding (wrong projectile model bug)
		if world:has(entity, Components.Position) then
			world:remove(entity, Components.Position)
		end
		if world:has(entity, Components.Velocity) then
			world:remove(entity, Components.Velocity)
		end
		if world:has(entity, Components.EntityType) then
			world:remove(entity, Components.EntityType)
		end
		if world:has(entity, Components.ProjectileData) then
			world:remove(entity, Components.ProjectileData)
		end
		if world:has(entity, Components.Damage) then
			world:remove(entity, Components.Damage)
		end
		if world:has(entity, Components.Piercing) then
			world:remove(entity, Components.Piercing)
		end
		if world:has(entity, Components.Collision) then
			world:remove(entity, Components.Collision)
		end
		if world:has(entity, Components.Lifetime) then
			world:remove(entity, Components.Lifetime)
		end
		if world:has(entity, Components.Visual) then
			world:remove(entity, Components.Visual)
		end
		if world:has(entity, Components.FacingDirection) then
			world:remove(entity, Components.FacingDirection)
		end
		if world:has(entity, Components.Owner) then
			world:remove(entity, Components.Owner)
		end
		if world:has(entity, Components.HitTargets) then
			world:remove(entity, Components.HitTargets)
		end
		if world:has(entity, Components.Homing) then
			world:remove(entity, Components.Homing)
		end
		if world:has(entity, Components.Knockback) then
			world:remove(entity, Components.Knockback)
		end
		-- Additional projectile-specific components
		if world:has(entity, Components.Projectile) then
			world:remove(entity, Components.Projectile)
		end
		if world:has(entity, Components.Explosive) then
			world:remove(entity, Components.Explosive)
		end
		if world:has(entity, Components.StatusEffect) then
			world:remove(entity, Components.StatusEffect)
		end
		if world:has(entity, Components.ProjectileOrbit) then
			world:remove(entity, Components.ProjectileOrbit)
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
function ProjectilePool.getStats()
	return {
		available = poolCount,
		total = MAX_POOL_SIZE,
		inUse = MAX_POOL_SIZE - poolCount,
		utilization = ((MAX_POOL_SIZE - poolCount) / MAX_POOL_SIZE) * 100,
	}
end

return ProjectilePool
