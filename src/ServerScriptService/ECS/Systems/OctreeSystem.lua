--!strict
-- OctreeSystem - Fast spatial queries for JECS entities
-- Replaces linear O(n) distance checks with O(log n) octree queries
-- Performance: 10-40x faster than looping all entities (DevForum benchmarks)

local Octree = require(game.ServerStorage.Packages.Octree)

local OctreeSystem = {}

local world: any
local Components: any
local StatusEffectSystem: any = nil

-- Octree instance (rebuilt each frame with fresh enemy positions)
local enemyOctree: any = nil
local OCTREE_SIZE = 2000 -- World bounds (±1000 studs from origin)

-- Cached queries (JECS best practice)
local enemyPositionQuery: any
local playerPositionQuery: any

function OctreeSystem.init(worldRef: any, components: any)
	world = worldRef
	Components = components
	
	-- Cache queries for enemy and player positions
	enemyPositionQuery = world:query(Components.Position, Components.EntityType):cached()
	playerPositionQuery = world:query(Components.Position, Components.PlayerStats):cached()
	
	-- Initialize octree
	enemyOctree = Octree.new(Vector3.new(0, 0, 0), OCTREE_SIZE)
end

function OctreeSystem.setStatusEffectSystem(system: any)
	StatusEffectSystem = system
end

-- Update octree with all enemy positions (called once per frame BEFORE AI/Repulsion)
function OctreeSystem.updateEnemyPositions()
	if not enemyOctree then
		return
	end
	
	-- Clear previous frame's data
	enemyOctree:Clear()
	
	-- Populate with current enemy positions from JECS
	local count = 0
	for entity, position, entityType in enemyPositionQuery do
		if entityType.type == "Enemy" then
			-- CRITICAL: Skip enemies with death animation (they're being destroyed)
			if not world:has(entity, Components.DeathAnimation) then
				local pos = Vector3.new(position.x, position.y, position.z)
				enemyOctree:AddObject(entity, pos)
				count += 1
			end
		end
	end
	
	-- Optional: Periodic debug output
	-- if count > 0 and tick() % 5 < 0.1 then
	-- 	print("[OctreeSystem] Updated octree with", count, "enemies")
	-- end
end

-- FAST: Get all enemies within radius (10-40x faster than looping!)
-- Returns: Array of entity IDs
function OctreeSystem.getEnemiesInRadius(center: Vector3, radius: number): {number}
	if not enemyOctree then
		return {}
	end
	
	return enemyOctree:RadiusSearch(center, radius)
end

-- Get all players' positions (helper for systems)
function OctreeSystem.getPlayerPositions(): {{entity: number, position: Vector3}}
	local players = {}
	
	for entity, playerPosition, playerStats in playerPositionQuery do
		if playerStats and playerStats.player and playerStats.player.Parent then
			table.insert(players, {
				entity = entity,
				position = Vector3.new(playerPosition.x, playerPosition.y, playerPosition.z)
			})
		end
	end
	
	return players
end

-- Get nearest player position from a given position
function OctreeSystem.getNearestPlayerPosition(fromPos: Vector3): (Vector3?, number?)
	local nearestPos: Vector3? = nil
	local nearestDist = math.huge
	
	-- Check if we need to filter paused players
	local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
	local shouldFilterPaused = not GameOptions.GlobalPause
	local PauseSystem = shouldFilterPaused and require(game.ServerScriptService.ECS.Systems.PauseSystem) or nil
	
	for entity, playerPosition, playerStats in playerPositionQuery do
		-- Validate player still exists and is connected
		if playerStats and playerStats.player and playerStats.player.Parent then
			-- Skip paused players in individual pause mode
			if shouldFilterPaused and PauseSystem then
				if PauseSystem.isPlayerPaused(entity) then
					continue  -- Don't target paused players
				end
			end
			
			-- Skip players with spawn protection (not all invincibility)
			if StatusEffectSystem and StatusEffectSystem.hasSpawnProtection(entity) then
				continue  -- Don't target spawn-protected players
			end
			
			local playerPos = Vector3.new(playerPosition.x, playerPosition.y, playerPosition.z)
			local dist = (playerPos - fromPos).Magnitude
			
			if dist < nearestDist then
				nearestDist = dist
				nearestPos = playerPos
			end
		end
	end
	
	return nearestPos, if nearestPos then nearestDist else nil
end

-- Get all players within a radius
function OctreeSystem.getPlayersInRadius(center: Vector3, radius: number): {number}
	local playersInRadius = {}
	local radiusSq = radius * radius
	
	-- Check if we need to filter paused players
	local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
	local shouldFilterPaused = not GameOptions.GlobalPause
	local PauseSystem = shouldFilterPaused and require(game.ServerScriptService.ECS.Systems.PauseSystem) or nil
	
	for entity, playerPosition, playerStats in playerPositionQuery do
		if playerStats and playerStats.player and playerStats.player.Parent then
			-- Skip paused players in individual pause mode
			if shouldFilterPaused and PauseSystem then
				if PauseSystem.isPlayerPaused(entity) then
					continue  -- Don't include paused players in results
				end
			end
			
			-- Skip invincible players (spawn protection)
			if StatusEffectSystem and StatusEffectSystem.hasInvincibility(entity) then
				continue  -- Don't include invincible players
			end
			
			local playerPos = Vector3.new(playerPosition.x, playerPosition.y, playerPosition.z)
			local dist = (playerPos - center).Magnitude
			local distSq = dist * dist
			
			if distSq <= radiusSq then
				table.insert(playersInRadius, entity)
			end
		end
	end
	
	return playersInRadius
end

return OctreeSystem

