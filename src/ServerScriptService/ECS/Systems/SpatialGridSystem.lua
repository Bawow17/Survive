--!strict
-- SpatialGridSystem - Optimizes collision detection using spatial partitioning
-- Based on Jecs spatial grid example for performance
-- OPTIMIZATION: Consume position changes instead of scanning all entities

local jecs = require(game.ServerStorage.Packages.jecs)
local pair = jecs.pair

local SpatialGridSystem = {}

local world: any
local Components: any
local DirtyService: any

-- Component references
local Position: any
local GridCell: any
local EntityType: any

-- Spatial grid parameters
local GRID_SIZE = 50 -- Size of each grid cell

type GridCellRecord = {
	entity: number,
	entities: {number},
	indexLookup: {[number]: number},
	count: number,
}

local gridMap: {[string]: GridCellRecord} = {} -- Maps grid coordinates to cell records

-- Track entity's last grid cell for incremental updates (PERFORMANCE FIX)
local entityLastGridCell: {[number]: string} = {}
-- Track current occupant list to support O(1) removal
local entityCellIndex: {[number]: {cellKey: string, index: number}} = {}

-- Cached queries
local positionQuery: any
local _gridQuery: any

-- Convert world position to grid coordinates
local function worldToGrid(position: Vector3): Vector3
    return Vector3.new(
        math.floor(position.X / GRID_SIZE),
        math.floor(position.Y / GRID_SIZE),
        math.floor(position.Z / GRID_SIZE)
    )
end

-- Convert grid coordinates to string key
local function gridToKey(gridPos: Vector3): string
    return string.format("%d,%d,%d", gridPos.X, gridPos.Y, gridPos.Z)
end

-- Delete grid cell entity when no occupants remain
local function destroyGridCell(cellKey: string, record: GridCellRecord)
	if record.entity ~= nil and world:contains(record.entity) then
		world:delete(record.entity)
	end
	gridMap[cellKey] = nil
end

-- Get or create grid cell entity
local function getOrCreateGridCell(gridPos: Vector3): GridCellRecord
    local key = gridToKey(gridPos)
    local record = gridMap[key]
    
    if not record then
        local gridEntity = world:entity()
        world:set(gridEntity, Position, {
            x = gridPos.X * GRID_SIZE,
            y = gridPos.Y * GRID_SIZE,
            z = gridPos.Z * GRID_SIZE
        })
        world:add(gridEntity, GridCell)
        world:set(gridEntity, EntityType, { type = "GridCell" })
		record = {
			entity = gridEntity,
			entities = {},
			indexLookup = {},
			count = 0,
		}
        gridMap[key] = record
    end
    
    return record
end

-- Add entity to spatial grid
local function addToGrid(entity: number, position: Vector3)
    local gridPos = worldToGrid(position)
    local record = getOrCreateGridCell(gridPos)
	local key = gridToKey(gridPos)

	-- Use Jecs relationship system (ChildOf) to link entity to grid cell for debug tooling
    world:add(entity, pair(Components.ChildOf, record.entity))

	record.count += 1
	record.entities[record.count] = entity
	record.indexLookup[entity] = record.count
	entityCellIndex[entity] = {
		cellKey = key,
		index = record.count,
	}
end

-- Remove entity from spatial grid
local function removeFromGrid(entity: number)
    -- Remove ChildOf relationship
    local currentGrid = world:target(entity, Components.ChildOf)
    if currentGrid then
        world:remove(entity, pair(Components.ChildOf, currentGrid))
    end

	local mapping = entityCellIndex[entity]
	if not mapping then
		return
	end

	local cellKey = mapping.cellKey
	local index = mapping.index
	local record = gridMap[cellKey]
	entityCellIndex[entity] = nil

	if not record then
		return
	end

	local lastIndex = record.count
	if lastIndex == 0 then
		return
	end

	local lastEntity = record.entities[lastIndex]
	record.entities[lastIndex] = nil
	record.indexLookup[entity] = nil

	if index ~= lastIndex and lastEntity then
		record.entities[index] = lastEntity
		record.indexLookup[lastEntity] = index
		local lastMapping = entityCellIndex[lastEntity]
		if lastMapping then
			lastMapping.index = index
		end
	else
		record.entities[index] = nil
	end

	record.count -= 1
	if record.count <= 0 then
		destroyGridCell(cellKey, record)
	end
end

-- Get entities in same grid cell as given position
local function getEntitiesInGrid(position: Vector3): {number}
    local gridPos = worldToGrid(position)
    local key = gridToKey(gridPos)
    local record = gridMap[key]

    if not record then
        return {}
    end

	local results = table.create(record.count)
	for i = 1, record.count do
		results[i] = record.entities[i]
	end
    
    return results
end

function SpatialGridSystem.init(worldRef: any, components: any, dirtyService: any)
    world = worldRef
    Components = components
    DirtyService = dirtyService
    
    Position = Components.Position
    GridCell = Components.GridCell
    EntityType = Components.EntityType
    
    -- Create cached queries
    positionQuery = world:query(Components.Position, Components.EntityType):cached()
    _gridQuery = world:query(Components.GridCell):cached()
end

-- OPTIMIZATION PHASE 2: Consume position changes instead of O(n) scans
function SpatialGridSystem.step(dt: number)
    if not world or not DirtyService then
        return
    end
    
    -- Get only entities that moved (instead of scanning all)
    local movedEntities = DirtyService.consumePositionChanges()
    
    -- If no position changes recorded, fall back to checking grid cell changes (rare)
    if not movedEntities or next(movedEntities) == nil then
        return
    end
    
    -- Update only moved entities (O(changed) instead of O(n))
    for entity in pairs(movedEntities) do
        if world:contains(entity) then
            local position = world:get(entity, Position)
            local entityType = world:get(entity, EntityType)
            
            if position and entityType and (entityType.type == "Enemy" or entityType.type == "Projectile") then
                local newGridPos = worldToGrid(Vector3.new(position.x, position.y, position.z))
                local newCellKey = gridToKey(newGridPos)
                local lastCellKey = entityLastGridCell[entity]
                
                -- Only update if moved to different grid cell (or first time)
                if newCellKey ~= lastCellKey then
                    if lastCellKey then
                        removeFromGrid(entity)
                    end
                    addToGrid(entity, Vector3.new(position.x, position.y, position.z))
                    entityLastGridCell[entity] = newCellKey
                end
            end
        end
    end
end

-- Public API for collision systems
function SpatialGridSystem.getEntitiesInGrid(position: Vector3): {number}
    return getEntitiesInGrid(position)
end

function SpatialGridSystem.getNeighboringEntities(position: Vector3, radiusCells: number?): {number}
	local accum = {}
	local count = 0
	local radius = radiusCells or 1
	local gridPos = worldToGrid(position)

	for dx = -radius, radius do
		for dz = -radius, radius do
			local neighborKey = gridToKey(Vector3.new(gridPos.X + dx, gridPos.Y, gridPos.Z + dz))
			local record = gridMap[neighborKey]
			if record then
				for i = 1, record.count do
					count += 1
					accum[count] = record.entities[i]
				end
			end
		end
	end

	return accum
end

function SpatialGridSystem.getGridSize(): number
    return GRID_SIZE
end

-- Cleanup when entity is destroyed
function SpatialGridSystem.cleanupEntity(entity: number)
    removeFromGrid(entity)
    entityLastGridCell[entity] = nil  -- Clean up cached grid cell (memory leak prevention)
end

return SpatialGridSystem
