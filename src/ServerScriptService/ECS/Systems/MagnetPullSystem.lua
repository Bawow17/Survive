--!strict
-- MagnetPullSystem - Pulls exp orbs towards player when magnet is active
-- Lerps orb velocity over duration, then removes pull component
-- Also manages active magnet sessions for tagging new exp orbs

local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)

local MagnetPullSystem = {}

local world: any
local Components: any
local DirtyService: any

local MagnetPull: any
local MagnetSession: any
local Position: any
local Velocity: any
local PlayerStats: any

-- Cached queries
local magnetQuery: any
local playerQuery: any
local sessionQuery: any

function MagnetPullSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	MagnetPull = Components.MagnetPull
	MagnetSession = Components.MagnetSession
	Position = Components.Position
	Velocity = Components.Velocity
	PlayerStats = Components.PlayerStats
	
	-- Create cached queries
	magnetQuery = world:query(Components.MagnetPull, Components.Position, Components.Velocity):cached()
	playerQuery = world:query(Components.Position, Components.PlayerStats):cached()
	sessionQuery = world:query(Components.MagnetSession, Components.PlayerStats):cached()
end

-- PUBLIC API: Start a magnet session for a player
function MagnetPullSystem.startMagnetSession(playerEntity: number, duration: number)
	local now = GameTimeSystem.getGameTime()
	DirtyService.setIfChanged(world, playerEntity, MagnetSession, {
		endTime = now + duration,
		startTime = now,
	}, "MagnetSession")
end

-- PUBLIC API: Get all active magnet sessions (for tagging new exp orbs)
function MagnetPullSystem.getActiveSessions(): {number}
	local now = GameTimeSystem.getGameTime()
	local activePlayerEntities = {}
	
	for entity, session, playerStats in sessionQuery do
		if session.endTime > now and playerStats.player and playerStats.player.Parent then
			table.insert(activePlayerEntities, entity)
		end
	end
	
	return activePlayerEntities
end

function MagnetPullSystem.step(dt: number)
	if not world then
		return
	end
	
	local now = GameTimeSystem.getGameTime()
	
	-- Clean up expired magnet sessions
	for entity, session in sessionQuery do
		if now >= session.endTime then
			world:remove(entity, MagnetSession)
		end
	end
	
	-- Build player position cache
	local playerPositions: {[number]: {x: number, y: number, z: number}} = {}
	for entity, position, playerStats in playerQuery do
		if playerStats and playerStats.player and playerStats.player.Parent then
			playerPositions[entity] = position
		end
	end
	
	-- Process all orbs with magnet pull
	for entity, magnetPull, position, velocity in magnetQuery do
		local targetPlayer = magnetPull.targetPlayer
		local startTime = magnetPull.startTime
		local duration = magnetPull.duration
		
		-- Check if pull has completed (remove component, but orb keeps moving until collected)
		if now >= startTime + duration then
			-- Remove magnet pull component so no new velocity updates
			world:remove(entity, MagnetPull)
			continue
		end
		
		-- Get target player position
		local targetPos = playerPositions[targetPlayer]
		if not targetPos then
			-- Player is gone, remove pull
			world:remove(entity, MagnetPull)
			continue
		end
		
		-- Calculate direction to player
		local dx = targetPos.x - position.x
		local dy = targetPos.y - position.y
		local dz = targetPos.z - position.z
		local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
		
		-- Normalize direction
		local dirX = dx / distance
		local dirY = dy / distance
		local dirZ = dz / distance
		
		-- Calculate pull speed (fast exponential acceleration)
		local elapsed = now - startTime
		local progress = math.clamp(elapsed / duration, 0, 1)
		
		-- Much faster pull: 60 -> 200 studs/s with exponential acceleration
		local pullSpeed = 60 + (140 * (progress ^ 2.5))
		
		-- Set velocity towards player (ExpCollectionSystem will handle pickup)
		DirtyService.setIfChanged(world, entity, Velocity, {
			x = dirX * pullSpeed,
			y = dirY * pullSpeed,
			z = dirZ * pullSpeed,
		}, "Velocity")
	end
end

return MagnetPullSystem

