--!strict
-- AfterimageCloneSystem - Manages afterimage clones for Afterimages attribute
-- Creates and positions clones in an equilateral triangle around the player
-- Clones inherit player appearance and shoot magic bolts independently

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AfterimageCloneSystem = {}

local world: any
local Components: any
local DirtyService: any
local ECSWorldService: any

-- Component references
local AfterimageClones: any
local AttributeSelections: any
local PlayerStats: any
local Position: any
local EntityType: any
local Visual: any

-- Remote event for clone replication
local AfterimageCloneRemote: RemoteEvent

-- Query for players with Afterimages attribute
local playerQuery: any

-- Initialize the system
function AfterimageCloneSystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService
	
	-- Get component references
	AfterimageClones = Components.AfterimageClones
	AttributeSelections = Components.AttributeSelections
	PlayerStats = Components.PlayerStats
	Position = Components.Position
	EntityType = Components.EntityType
	Visual = Components.Visual
	
	-- Get remote event
	local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
	AfterimageCloneRemote = remotes:FindFirstChild("AfterimageClone")
	if not AfterimageCloneRemote then
		warn("[AfterimageCloneSystem] AfterimageClone remote not found")
	end
	
	-- Create query for players
	playerQuery = world:query(Components.EntityType, Components.PlayerStats, Components.Position):cached()
end

-- Calculate position for a clone in the triangle formation
local function calculateClonePosition(playerPos: Vector3, cloneIndex: number, radius: number): Vector3
	-- Equilateral triangle: clones at 0°, 120°, 240°
	-- Clone 1: North (0°)
	-- Clone 2: Southeast (120°)
	-- Clone 3: Southwest (240°)
	
	local angleRadians = math.rad((cloneIndex - 1) * 120)
	local offsetX = math.sin(angleRadians) * radius
	local offsetZ = math.cos(angleRadians) * radius
	
	return Vector3.new(
		playerPos.X + offsetX,
		playerPos.Y + 5,  -- Float 5 studs above player
		playerPos.Z + offsetZ
	)
end

-- Create a clone entity for a player
local function createCloneEntity(playerEntity: number, player: Player, cloneIndex: number, radius: number, transparency: number): number?
	local playerPos = world:get(playerEntity, Position)
	if not playerPos then
		return nil
	end
	
	-- Calculate clone position
	local clonePos = calculateClonePosition(Vector3.new(playerPos.x, playerPos.y, playerPos.z), cloneIndex, radius)
	
	-- Create clone entity
	local cloneEntity = world:entity()
	
	-- Add EntityType component (mark as AfterimageClone)
	world:set(cloneEntity, EntityType, {
		type = "AfterimageClone",
		player = player,
		ownerEntity = playerEntity,
		cloneIndex = cloneIndex,  -- Store index for client-side orbit calculation
	})
	DirtyService.mark(cloneEntity, "EntityType")
	
	-- Add Position component
	world:set(cloneEntity, Position, {
		x = clonePos.X,
		y = clonePos.Y,
		z = clonePos.Z,
	})
	DirtyService.mark(cloneEntity, "Position")
	
	-- Add Visual component (client will render this as a semi-transparent player character)
	-- NOTE: Send UserId instead of Player instance (Player objects don't serialize well)
	world:set(cloneEntity, Visual, {
		modelType = "PlayerClone",
		scale = 1.0,
		transparency = transparency,
		copyPlayerAppearance = true,  -- Client should copy player's character appearance
		sourcePlayerUserId = player.UserId,  -- Send UserId, client will resolve to Player
	})
	DirtyService.mark(cloneEntity, "Visual")
	
	-- Add FacingDirection component (will be updated when clone shoots)
	world:set(cloneEntity, Components.FacingDirection, {
		x = 0,
		y = 0,
		z = 1,  -- Default: facing forward
	})
	DirtyService.mark(cloneEntity, "FacingDirection")
	
	return cloneEntity
end

-- Ensure clones exist for a player with Afterimages attribute
local function ensureClones(playerEntity: number, player: Player, clonesData: any)
	-- Calculate radius from triangle side length
	-- radius = sideLength / √3
	local sideLength = clonesData.triangleSideLength or 30
	local radius = sideLength / math.sqrt(3)
	
	local cloneCount = clonesData.cloneCount or 3
	local transparency = clonesData.cloneTransparency or 0.5
	
	-- Check if clones already exist
	if clonesData.clones and #clonesData.clones >= cloneCount then
		-- Verify all clones still exist
		local allExist = true
		for _, cloneInfo in ipairs(clonesData.clones) do
			if not world:contains(cloneInfo.entity) then
				allExist = false
				break
			end
		end
		
		if allExist then
			return  -- Clones already exist
		end
	end
	
	-- Clean up any existing clones
	if clonesData.clones then
		for _, cloneInfo in ipairs(clonesData.clones) do
			if world:contains(cloneInfo.entity) then
				world:despawn(cloneInfo.entity)
			end
		end
	end
	
	-- Create new clones
	local newClones = {}
	for i = 1, cloneCount do
		local cloneEntity = createCloneEntity(playerEntity, player, i, radius, transparency)
		if cloneEntity then
			table.insert(newClones, {
				entity = cloneEntity,
				index = i,
				cooldown = 0,  -- Current cooldown remaining
				lastShot = 0,  -- Last shot time
			})
		end
	end
	
	-- Update AfterimageClones component
	clonesData.clones = newClones
	DirtyService.setIfChanged(world, playerEntity, AfterimageClones, clonesData, "AfterimageClones")
end

-- Update clone positions to orbit around player
-- NOTE: Positions are updated server-side for projectile spawning logic
-- But NOT sent to client - client calculates positions independently for smooth visuals
local function updateClonePositions(playerEntity: number, clonesData: any)
	local playerPos = world:get(playerEntity, Position)
	if not playerPos then
		return
	end
	
	local sideLength = clonesData.triangleSideLength or 30
	local radius = sideLength / math.sqrt(3)
	
	for _, cloneInfo in ipairs(clonesData.clones) do
		if world:contains(cloneInfo.entity) then
			local clonePos = calculateClonePosition(
				Vector3.new(playerPos.x, playerPos.y, playerPos.z),
				cloneInfo.index,
				radius
			)
			
			-- Update clone position (server-side only for projectile spawning)
			world:set(cloneInfo.entity, Position, {
				x = clonePos.X,
				y = clonePos.Y,
				z = clonePos.Z,
			})
			-- DON'T mark as dirty - client handles visual positioning independently
			-- DirtyService.mark(cloneInfo.entity, "Position")
		end
	end
end

-- Clean up clones for a player (called when player dies or leaves)
local function cleanupClones(playerEntity: number)
	local clonesData = world:get(playerEntity, AfterimageClones)
	if not clonesData or not clonesData.clones then
		return
	end
	
	-- Despawn all clones
	for _, cloneInfo in ipairs(clonesData.clones) do
		if world:contains(cloneInfo.entity) then
			world:despawn(cloneInfo.entity)
		end
	end
	
	-- Remove component
	world:remove(playerEntity, AfterimageClones)
end

-- Step function (called every frame)
function AfterimageCloneSystem.step(_dt: number)
	if not world then
		return
	end
	
	-- Track players that should have clones
	local playersWithAfterimages = {}
	
	-- Query all players
	for entity, entityType, playerStats, position in playerQuery do
		if entityType.type == "Player" and playerStats.player then
			local player = playerStats.player
			
			-- Check if player has Afterimages attribute for any ability
			local attributeSelections = world:get(entity, AttributeSelections)
			local hasAfterimages = false
			
			if attributeSelections then
				for abilityId, attributeId in pairs(attributeSelections) do
					if attributeId == "Afterimages" then
						hasAfterimages = true
						break
					end
				end
			end
			
			if hasAfterimages then
				playersWithAfterimages[entity] = true
				
				-- Get or create AfterimageClones component
				local clonesData = world:get(entity, AfterimageClones)
				if clonesData then
					-- Ensure clones exist
					ensureClones(entity, player, clonesData)
					
					-- NOTE: Clone positions are now managed CLIENT-SIDE for smooth visuals
					-- Server still tracks positions for projectile spawning logic only
					-- We still update positions server-side for gameplay (projectile spawning)
					updateClonePositions(entity, clonesData)
					-- But we DON'T mark as dirty - client handles visual positioning
				end
			end
		end
	end
	
	-- Clean up clones for players that no longer have Afterimages
	local clonesQuery = world:query(AfterimageClones, PlayerStats)
	for entity, clonesData, playerStats in clonesQuery do
		if not playersWithAfterimages[entity] then
			-- Player no longer has Afterimages attribute (or died/left)
			cleanupClones(entity)
		end
	end
end

-- Export cleanup function for use in player removal
AfterimageCloneSystem.cleanupClones = cleanupClones

return AfterimageCloneSystem

