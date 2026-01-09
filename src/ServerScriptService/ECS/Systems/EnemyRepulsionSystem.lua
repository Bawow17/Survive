--!strict
-- EnemyRepulsionSystem - Minecraft-like enemy separation system to prevent stacking
-- Ensures enemies don't overlap while maintaining player-facing behavior

local OctreeSystem = require(script.Parent.OctreeSystem)

local EnemyRepulsionSystem = {}

local world: any
local Components: any
local DirtyService: any
local EnemyBalance: any

local Position: any
local Velocity: any
local AI: any
local Repulsion: any
local EntityTypeComponent: any

-- Import balance settings
EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)

-- Force smoothing for inner crowd stability
local entityPreviousForces: {[number]: {x: number, z: number}} = {}
local entityForceHistory: {[number]: {{x: number, z: number}}} = {}

-- Spatial partitioning for performance optimization
local GRID_SIZE = 10 -- Grid cell size in studs
local spatialGrid: {[string]: {number}} = {}
local gridCellPool: {[string]: {number}} = {} -- Pool for reusing cell arrays

-- Object pooling for repulsion calculations
local repulsionDataPool = {}
local MAX_POOL_SIZE = 100
local MAX_GRID_POOL_SIZE = 50

-- Cached queries for performance (CRITICAL)
local enemyQuery: any
local playerQuery: any

local function getRepulsionData()
    return table.remove(repulsionDataPool) or {
        totalForceX = 0,
        totalForceZ = 0,
        nearbyCount = 0
    }
end

local function returnRepulsionData(data)
    data.totalForceX = 0
    data.totalForceZ = 0
    data.nearbyCount = 0
    
    if #repulsionDataPool < MAX_POOL_SIZE then
        table.insert(repulsionDataPool, data)
    end
end

-- Pool management for grid cells
local function getGridCell(): {number}
    return table.remove(gridCellPool) or {}
end

local function returnGridCell(cell: {number})
    table.clear(cell)
    if #gridCellPool < MAX_GRID_POOL_SIZE then
        table.insert(gridCellPool, cell)
    end
end

-- Convert world position to grid key for spatial partitioning
local function getGridKey(x: number, z: number): string
    local gridX = math.floor(x / GRID_SIZE)
    local gridZ = math.floor(z / GRID_SIZE)
    return gridX .. "," .. gridZ
end

-- Get neighboring grid cells (including current cell)
local function getNeighboringCells(x: number, z: number): {string}
    local cells = {}
    local gridX = math.floor(x / GRID_SIZE)
    local gridZ = math.floor(z / GRID_SIZE)
    
    -- Check 3x3 grid around current cell
    for dx = -1, 1 do
        for dz = -1, 1 do
            local key = (gridX + dx) .. "," .. (gridZ + dz)
            table.insert(cells, key)
        end
    end
    
    return cells
end

-- Update spatial grid with current enemy positions (CRITICAL: was missing!)
local function updateSpatialGrid(enemies: {{entity: number, position: any}})
    -- Clear existing grid and return cells to pool
    for gridKey, cell in pairs(spatialGrid) do
        returnGridCell(cell)
        spatialGrid[gridKey] = nil
    end
    
    -- Populate grid with current enemy positions
    for _, enemyData in ipairs(enemies) do
        local entity = enemyData.entity
        local position = enemyData.position
        local gridKey = getGridKey(position.x, position.z)
        
        if not spatialGrid[gridKey] then
            spatialGrid[gridKey] = getGridCell()
        end
        
        table.insert(spatialGrid[gridKey], entity)
    end
end

-- Calculate repulsion force between two entities (Minecraft-style)
local function calculateRepulsionForce(pos1: {x: number, z: number}, pos2: {x: number, z: number}, radius: number, strength: number): (number, number)
    local dx = pos1.x - pos2.x
    local dz = pos1.z - pos2.z
    local distance = math.sqrt(dx * dx + dz * dz)
    
    -- No repulsion if outside radius or too close (avoid division by zero)
    if distance >= radius or distance < EnemyBalance.MinSeparationDistance then
        return 0, 0
    end
    
    -- Normalize direction
    local dirX = dx / distance
    local dirZ = dz / distance
    
    -- Minecraft-like repulsion: stronger when closer, using inverse square falloff
    local repulsionMagnitude = strength * ((radius - distance) / radius)^2
    
    -- Cap maximum force to prevent excessive pushing
    repulsionMagnitude = math.min(repulsionMagnitude, EnemyBalance.MaxRepulsionForce)
    
    return dirX * repulsionMagnitude, dirZ * repulsionMagnitude
end

-- PERFORMANCE FIX: Removed duplicate updateSpatialGrid function (lines 208-223)
-- The proper implementation with object pooling is at lines 125-144

function EnemyRepulsionSystem.init(worldRef: any, components: any, dirtyService: any)
    world = worldRef
    Components = components
    DirtyService = dirtyService
    
    Position = Components.Position
    Velocity = Components.Velocity
    AI = Components.AI
    Repulsion = Components.Repulsion
    EntityTypeComponent = Components.EntityType
    
    -- Create cached queries for performance (CRITICAL FIX - was creating new queries every frame!)
    enemyQuery = world:query(Components.Position, Components.Velocity, Components.AI, Components.Repulsion, Components.EntityType):cached()
    playerQuery = world:query(Components.Position, Components.PlayerStats):cached()
end

-- Smooth force application to prevent jittery movement
local function smoothRepulsionForce(entity: number, newForceX: number, newForceZ: number): (number, number)
    local smoothingFactor = EnemyBalance.ForceSmoothing or 0.7
    local previousForce = entityPreviousForces[entity]
    
    if not previousForce then
        -- First time, no smoothing needed
        entityPreviousForces[entity] = {x = newForceX, z = newForceZ}
        return newForceX, newForceZ
    end
    
    -- Blend current force with previous force for stability
    local smoothedX = previousForce.x * smoothingFactor + newForceX * (1 - smoothingFactor)
    local smoothedZ = previousForce.z * smoothingFactor + newForceZ * (1 - smoothingFactor)
    
    -- Update stored force
    entityPreviousForces[entity] = {x = smoothedX, z = smoothedZ}
    
    return smoothedX, smoothedZ
end

-- Cap velocity changes to prevent aggressive jumping
local function capVelocityChange(currentVel: {x: number, y: number, z: number}, newVel: {x: number, y: number, z: number}): {x: number, y: number, z: number}
    local maxChange = EnemyBalance.MaxVelocityChange or 12.0
    
    local deltaX = newVel.x - currentVel.x
    local deltaZ = newVel.z - currentVel.z
    local deltaMagnitude = math.sqrt(deltaX * deltaX + deltaZ * deltaZ)
    
    if deltaMagnitude > maxChange then
        -- Scale down the change to the maximum allowed
        local scaleFactor = maxChange / deltaMagnitude
        return {
            x = currentVel.x + deltaX * scaleFactor,
            y = newVel.y, -- Don't cap Y velocity
            z = currentVel.z + deltaZ * scaleFactor
        }
    end
    
    return newVel
end

-- Clean up repulsion tracking when entity is destroyed
function EnemyRepulsionSystem.cleanupEntity(entity: number)
    entityPreviousForces[entity] = nil
    entityForceHistory[entity] = nil
end

function EnemyRepulsionSystem.step(dt: number)
    if not world or not EnemyBalance.EnableRepulsion then
        return
    end
    
    -- Use cached query for performance (CRITICAL FIX)
    local enemies = {}
    
    for entity, position, velocity, ai, repulsion, entityType in enemyQuery do
        if entityType and entityType.type == "Enemy" then
            table.insert(enemies, {
                entity = entity,
                position = position,
                velocity = velocity,
                ai = ai,
                repulsion = repulsion,
                entityType = entityType
            })
        end
    end
    
    -- Skip if no enemies or only one enemy
    if #enemies <= 1 then
        return
    end
    
    -- REMOVED: updateSpatialGrid(enemies) - now using Octree for neighbor finding
    
    -- Create position lookup table for O(1) access (for repulsion calculations)
    local entityPositions: {[number]: any} = {}
    for _, enemyData in ipairs(enemies) do
        entityPositions[enemyData.entity] = enemyData.position
    end
    
    -- Process repulsion for each enemy
    for _, enemyData in ipairs(enemies) do
        local entity = enemyData.entity
        local position = enemyData.position
        local velocity = enemyData.velocity
        local repulsion = enemyData.repulsion
        
        -- Get repulsion parameters (with defaults)
        local repulsionRadius = repulsion.radius or EnemyBalance.RepulsionRadius
        local repulsionStrength = repulsion.strength or EnemyBalance.RepulsionStrength
        
        -- Calculate total repulsion force from nearby enemies using Octree
        -- OPTIMIZED: 10-40x faster than spatial grid according to DevForum benchmarks
        local repulsionData = getRepulsionData()
        local pos = Vector3.new(position.x, position.y, position.z)
        
        -- Get all enemies within repulsion radius using fast Octree query
        local nearbyEnemies = OctreeSystem.getEnemiesInRadius(pos, repulsionRadius)
        
        for _, otherEntity in ipairs(nearbyEnemies) do
            if entity ~= otherEntity then -- Don't repel from self
                -- Get other entity's position from O(1) lookup table
                local otherPosition = entityPositions[otherEntity]
                
                if otherPosition then
                    local forceX, forceZ = calculateRepulsionForce(
                        {x = position.x, z = position.z},
                        {x = otherPosition.x, z = otherPosition.z},
                        repulsionRadius,
                        repulsionStrength
                    )
                    
                    repulsionData.totalForceX = repulsionData.totalForceX + forceX
                    repulsionData.totalForceZ = repulsionData.totalForceZ + forceZ
                    
                    if forceX ~= 0 or forceZ ~= 0 then
                        repulsionData.nearbyCount = repulsionData.nearbyCount + 1
                    end
                end
            end
        end
        
        -- Apply repulsion force to velocity (additive, doesn't override AI movement)
        if repulsionData.nearbyCount > 0 then
            -- Crowd-density scaling: increase repulsion strength for large groups
            local crowdMultiplier = 1.0
            local crowdThreshold = EnemyBalance.CrowdRepulsionThreshold or 3
            if repulsionData.nearbyCount > crowdThreshold then
                -- Linear scaling for large crowds (configurable threshold and multiplier)
                -- This creates stronger repulsion when there are many enemies
                local extraEnemies = repulsionData.nearbyCount - crowdThreshold
                local multiplierRate = EnemyBalance.CrowdRepulsionMultiplier or 0.3
                crowdMultiplier = 1.0 + extraEnemies * multiplierRate
                -- Cap the multiplier to prevent excessive forces
                local maxMultiplier = EnemyBalance.MaxCrowdMultiplier or 5.0
                crowdMultiplier = math.min(crowdMultiplier, maxMultiplier)
            end
            
            -- Inner crowd dampening: reduce force for heavily crowded enemies
            local innerCrowdThreshold = EnemyBalance.InnerCrowdThreshold or 8
            local dampeningFactor = 1.0
            if repulsionData.nearbyCount >= innerCrowdThreshold then
                dampeningFactor = EnemyBalance.InnerCrowdDampening or 0.6
            end
            
            -- Apply crowd multiplier and dampening to repulsion forces
            local rawRepulsionX = repulsionData.totalForceX * crowdMultiplier * dampeningFactor
            local rawRepulsionZ = repulsionData.totalForceZ * crowdMultiplier * dampeningFactor
            
            -- Smooth the forces to prevent jittery movement
            local smoothedRepulsionX, smoothedRepulsionZ = smoothRepulsionForce(entity, rawRepulsionX, rawRepulsionZ)
            
			-- Add repulsion to current velocity (preserving Y component and AI movement)
			local proposedVelocity = {
				x = velocity.x + smoothedRepulsionX,
				y = velocity.y, -- Preserve Y component
				z = velocity.z + smoothedRepulsionZ
			}
			
			-- Cap velocity changes to prevent aggressive jumping
			local finalVelocity = capVelocityChange(velocity, proposedVelocity)
			
			-- PHYSICS BUG FIX 2.3: Cap total velocity magnitude to prevent launching
			local MAX_TOTAL_VELOCITY = 20.0  -- studs/second
			local velocityMag = math.sqrt(finalVelocity.x^2 + finalVelocity.z^2)
			if velocityMag > MAX_TOTAL_VELOCITY then
				local scale = MAX_TOTAL_VELOCITY / velocityMag
				finalVelocity.x = finalVelocity.x * scale
				finalVelocity.z = finalVelocity.z * scale
			end
			
			-- Update velocity through DirtyService
			DirtyService.setIfChanged(world, entity, Velocity, finalVelocity, "Velocity")
        end
        
        returnRepulsionData(repulsionData)
    end
end

return EnemyRepulsionSystem
