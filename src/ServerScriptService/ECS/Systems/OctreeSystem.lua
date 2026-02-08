--!strict
-- OctreeSystem - Fast spatial queries for JECS entities
-- Replaces linear O(n) distance checks with O(log n) octree queries
-- Performance: 10-40x faster than looping all entities (DevForum benchmarks)

local Octree = require(game.ServerStorage.Packages.Octree)
local Workspace = game:GetService("Workspace")

local OctreeSystem = {}

local world: any
local Components: any
local StatusEffectSystem: any = nil

-- Octree instance (rebuilt each frame with fresh enemy positions)
local enemyOctree: any = nil
local octreeCenter = Vector3.new(0, 0, 0)
local octreeSize = 4096
local OCTREE_MIN_SIZE = 4096
local OCTREE_MARGIN = 512
local lastBoundsWarning = 0

local function computeOctreeBounds(): (Vector3, number)
	local center = Vector3.new(0, 0, 0)
	local chunkOrigin = Workspace:GetAttribute("ChunkOrigin")
	if typeof(chunkOrigin) == "Vector3" then
		center = chunkOrigin
	end

	local chunkSizeAttr = Workspace:GetAttribute("ChunkSize")
	local chunkLoadRadiusAttr = Workspace:GetAttribute("ChunkLoadRadius")
	local chunkSize = if typeof(chunkSizeAttr) == "number" then chunkSizeAttr else 128
	local loadRadius = if typeof(chunkLoadRadiusAttr) == "number" then chunkLoadRadiusAttr else 5

	-- Radius-based chunk loading keeps play near the loaded chunk cluster; include margin for projectiles.
	local horizontalSpan = (loadRadius + 4) * chunkSize * 2
	local verticalSpan = math.abs(center.Y) * 2 + OCTREE_MARGIN * 2
	local size = math.max(OCTREE_MIN_SIZE, horizontalSpan + OCTREE_MARGIN * 2, verticalSpan)

	return center, size
end

local function isWithinBounds(position: Vector3): boolean
	local halfSize = octreeSize * 0.5
	local min = octreeCenter - Vector3.new(halfSize, halfSize, halfSize)
	local max = octreeCenter + Vector3.new(halfSize, halfSize, halfSize)
	return position.X >= min.X and position.X <= max.X
		and position.Y >= min.Y and position.Y <= max.Y
		and position.Z >= min.Z and position.Z <= max.Z
end

-- Cached queries (JECS best practice)
local enemyPositionQuery: any
local playerPositionQuery: any

function OctreeSystem.init(worldRef: any, components: any)
	world = worldRef
	Components = components

	-- Cache queries for enemy and player positions
	enemyPositionQuery = world:query(Components.Position, Components.EntityType):cached()
	playerPositionQuery = world:query(Components.Position, Components.PlayerStats):cached()

	-- Initialize octree centered on active world origin.
	octreeCenter, octreeSize = computeOctreeBounds()
	enemyOctree = Octree.new(octreeCenter, octreeSize)
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
	local outOfBounds = 0
	for entity, position, entityType in enemyPositionQuery do
		if entityType.type == "Enemy" then
			-- Skip enemies with death animation (they're being destroyed)
			if not world:has(entity, Components.DeathAnimation) then
				local pos = Vector3.new(position.x, position.y, position.z)
				if isWithinBounds(pos) then
					enemyOctree:AddObject(entity, pos)
				else
					outOfBounds += 1
				end
			end
		end
	end

	if outOfBounds > 0 then
		local now = tick()
		if now - lastBoundsWarning >= 2.0 then
			lastBoundsWarning = now
			warn(string.format(
				"[OctreeSystem] %d enemy/enemies outside octree bounds center=(%.1f, %.1f, %.1f) size=%.1f.",
				outOfBounds,
				octreeCenter.X,
				octreeCenter.Y,
				octreeCenter.Z,
				octreeSize
			))
		end
	end
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
					continue -- Don't target paused players
				end
			end

			-- Skip players with spawn protection (not all invincibility)
			if StatusEffectSystem and StatusEffectSystem.hasSpawnProtection(entity) then
				continue -- Don't target spawn-protected players
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
					continue -- Don't include paused players in results
				end
			end

			-- Skip invincible players (spawn protection)
			if StatusEffectSystem and StatusEffectSystem.hasInvincibility(entity) then
				continue -- Don't include invincible players
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
