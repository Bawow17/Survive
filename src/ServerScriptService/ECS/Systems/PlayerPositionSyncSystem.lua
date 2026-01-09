--!strict
-- PlayerPositionSyncSystem - keeps ECS player entities aligned with their Roblox characters

local PlayerPositionSyncSystem = {}

local world: any
local Components: any
local DirtyService: any

local Position: any
local PlayerStats: any

-- CRITICAL FIX: Cached query to prevent creating new query every frame!
local playerQuery: any

function PlayerPositionSyncSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService

	Position = Components.Position
	PlayerStats = Components.PlayerStats
	
	-- CRITICAL BUG FIX: Cache the query instead of creating every frame!
	-- This was causing massive performance issues and weird physics behavior
	playerQuery = world:query(Position, PlayerStats):cached()
end

function PlayerPositionSyncSystem.step(dt: number)
	if not world or not playerQuery then
		return
	end

	-- Use cached query (NOT creating new one every frame!)
	for entity, position, playerStats in playerQuery do
		local robloxPlayer = playerStats and playerStats.player
		if robloxPlayer then
			local character = robloxPlayer.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			if rootPart then
				local newPosition = {
					x = rootPart.Position.X,
					y = rootPart.Position.Y,
					z = rootPart.Position.Z,
				}
				DirtyService.setIfChanged(world, entity, Position, newPosition, "Position")
			end
		end
	end
end

return PlayerPositionSyncSystem
