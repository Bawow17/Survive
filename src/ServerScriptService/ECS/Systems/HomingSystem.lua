--!strict
-- HomingSystem - Handles homing behavior for projectiles with targetingMode = 3
-- Throttled server-side target acquisition and velocity steering (~10fps per projectile)
-- OPTIMIZATION: Batch updates across 3 frames to reduce O(n) cost
-- Based on JECS patterns: https://ukendio.github.io/jecs/

local SpatialGridSystem = require(game.ServerScriptService.ECS.Systems.SpatialGridSystem)
local AbilitySystemBase = require(game.ServerScriptService.Abilities.AbilitySystemBase)

local HomingSystem = {}

local world: any
local Components: any
local DirtyService: any

-- Component references
local Position: any
local Velocity: any
local Homing: any
local ProjectileData: any
local EntityType: any
local Health: any
local Owner: any
local Piercing: any
local Lifetime: any
local HitTargets: any

-- Cached query for performance
local homingQuery: any

-- Homing update throttling (25fps = 0.04s per update)
local HOMING_UPDATE_INTERVAL = 0.04
local GRID_SIZE = SpatialGridSystem.getGridSize()

-- OPTIMIZATION PHASE 2: Frame-based batch processing
-- Update only 1/3 of homing projectiles per frame, rotating through all
local BATCH_SIZE = 3  -- 3-frame rotation
local currentBatchIndex = 0
local lastBatchTime = 0
local BATCH_ROTATION_INTERVAL = 0.016  -- ~1 frame at 60Hz

-- Track which enemies are currently being targeted (to avoid multiple projectiles targeting same enemy)
local activeTargets: {[number]: boolean} = {}

-- Track player positions for StickToPlayer projectiles
local playerLastPositions: {[number]: Vector3} = {} -- key = projectileEntityId, value = last player position

-- Helper: Convert table to Vector3
local function tableToVector(data: any): Vector3?
	if typeof(data) == "table" then
		local x = data.x or data.X
		local y = data.y or data.Y
		local z = data.z or data.Z
		if x and y and z then
			return Vector3.new(x, y, z)
		end
	end
	return nil
end

-- Helper: Convert Vector3 to table
local function vectorToTable(vec: Vector3): {x: number, y: number, z: number}
	return {x = vec.X, y = vec.Y, z = vec.Z}
end

-- Find nearest enemy within homingDistance (excluding already-hit targets and currently targeted enemies)
local function findNearestTarget(
	projectilePosition: Vector3,
	homingDistance: number,
	ownerEntityId: number?,
	currentTarget: number?,
	hitTargetsTable: {[number]: boolean}?
): number?
	if not world or not Components then
		return nil
	end
	
	-- Use spatial grid for efficient search
	local radiusCells = math.max(1, math.ceil(homingDistance / GRID_SIZE))
	local candidates = SpatialGridSystem.getNeighboringEntities(projectilePosition, radiusCells)
	
	if #candidates == 0 then
		candidates = SpatialGridSystem.getNeighboringEntities(projectilePosition, radiusCells + 1)
	end
	
	local nearestEntity: number? = nil
	local nearestDistSq = homingDistance * homingDistance
	
	for _, enemyEntity in ipairs(candidates) do
		-- Skip owner
		if ownerEntityId and enemyEntity == ownerEntityId then
			continue
		end
		
		-- Skip already-hit targets for homing re-targeting
		if hitTargetsTable and hitTargetsTable[enemyEntity] then
			continue
		end
		
		-- Skip enemies that are already being targeted by other projectiles
		if activeTargets[enemyEntity] then
			continue
		end
		
		-- Check if it's an enemy
		local entityType = world:get(enemyEntity, EntityType)
		if not entityType or entityType.type ~= "Enemy" then
			continue
		end
		
		-- Check if alive
		local health = world:get(enemyEntity, Health)
		if not health or health.current <= 0 then
			continue
		end
		
		-- Get position
		local enemyPos = world:get(enemyEntity, Position)
		if not enemyPos then
			continue
		end
		
		local enemyPosition = Vector3.new(enemyPos.x, enemyPos.y, enemyPos.z)
		
		-- Calculate squared distance manually (Roblox Vector3 doesn't have MagnitudeSquared)
		local diff = enemyPosition - projectilePosition
		local distSq = diff.X * diff.X + diff.Y * diff.Y + diff.Z * diff.Z
		
		-- Within acquisition range
		if distSq <= nearestDistSq then
			nearestDistSq = distSq
			nearestEntity = enemyEntity
		end
	end
	
	return nearestEntity
end

-- Steer velocity towards target with turn rate limiting
local function steerVelocityTowardsTarget(
	currentVelocity: Vector3,
	targetDirection: Vector3,
	homingStrength: number,  -- degrees per second
	homingMaxAngle: number,  -- radians (max angle from current direction)
	dt: number
): (Vector3, boolean)  -- Returns new velocity and whether target is valid
	-- Ensure both vectors are unit
	local currentDir = currentVelocity.Unit
	local targetDir = targetDirection.Unit
	local speed = currentVelocity.Magnitude
	
	-- Calculate angle between current and target direction
	local dotProduct = math.clamp(currentDir:Dot(targetDir), -1, 1)
	local angle = math.acos(dotProduct)
	
	-- Check if target is beyond max turn angle (reject targets that require too sharp a turn)
	if angle > homingMaxAngle then
		return currentVelocity, false  -- Target too far off axis, keep current velocity
	end
	
	-- No turning needed if already facing target
	if angle < 0.001 then
		return targetDir * speed, true
	end
	
	-- Calculate maximum turn this frame based on homingStrength
	local maxTurnThisFrame = math.rad(homingStrength) * dt
	
	-- Actual turn is the minimum of angle to target and max allowed turn per frame
	local actualTurn = math.min(angle, maxTurnThisFrame)
	
	-- Calculate rotation axis (perpendicular to both vectors)
	local axis = currentDir:Cross(targetDir)
	
	-- If vectors are parallel/anti-parallel, pick arbitrary perpendicular axis
	if axis.Magnitude < 0.001 then
		-- Find perpendicular vector
		if math.abs(currentDir.X) < 0.9 then
			axis = Vector3.new(1, 0, 0):Cross(currentDir)
		else
			axis = Vector3.new(0, 1, 0):Cross(currentDir)
		end
	end
	
	axis = axis.Unit
	
	-- Rodrigues' rotation formula to rotate currentDir by actualTurn around axis
	local cosAngle = math.cos(actualTurn)
	local sinAngle = math.sin(actualTurn)
	
	local rotated = currentDir * cosAngle
		+ axis:Cross(currentDir) * sinAngle
		+ axis * (axis:Dot(currentDir)) * (1 - cosAngle)
	
	-- Return velocity with new direction and same speed, and success flag
	return rotated.Unit * speed, true
end

function HomingSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	-- Component references
	Position = Components.Position
	Velocity = Components.Velocity
	Homing = Components.Homing
	ProjectileData = Components.ProjectileData
	EntityType = Components.EntityType
	Health = Components.Health
	Owner = Components.Owner
	Piercing = Components.Piercing
	Lifetime = Components.Lifetime
	HitTargets = Components.HitTargets
	
	-- Create cached query for homing projectiles
	homingQuery = world:query(Components.Projectile, Components.Position, Components.Velocity, Components.ProjectileData, Components.Homing, Components.Piercing, Components.Lifetime):cached()
end

function HomingSystem.step(dt: number)
	if not world then
		return
	end
	
	local currentTime = tick()
	
	-- Rebuild active targets list from all current homing projectiles
	-- This catches targets from previous frames and validates they still exist
	table.clear(activeTargets)
	for entity in world:query(Components.Homing) do
		local homing = world:get(entity, Homing)
		if homing and homing.targetEntity then
			-- Validate target is still alive
			local targetHealth = world:get(homing.targetEntity, Health)
			if targetHealth and targetHealth.current > 0 then
				activeTargets[homing.targetEntity] = true
			end
		end
	end
	
	-- OPTIMIZATION: Rotate batch index to process 1/BATCH_SIZE of homing projectiles per frame
	if currentTime - lastBatchTime >= BATCH_ROTATION_INTERVAL then
		lastBatchTime = currentTime
		currentBatchIndex = (currentBatchIndex + 1) % BATCH_SIZE
	end
	
	-- Query all projectiles with Homing component
	local projectileIndex = 0  -- Counter for batch assignment
	for projectileEntity, _projectile, position, velocity, projectileData, homingData, piercing, lifetime in homingQuery do
		-- Skip if projectile is dead or has no piercing left (prevents falling after hits)
		if not piercing or piercing.remaining <= 0 then
			-- Cleanup player position tracking
			playerLastPositions[projectileEntity] = nil
			continue
		end
		
		if not lifetime or lifetime.remaining <= 0 then
			-- Cleanup player position tracking
			playerLastPositions[projectileEntity] = nil
			continue
		end
		
		-- OPTIMIZATION: Only update projectiles assigned to current batch frame
		if projectileIndex % BATCH_SIZE ~= currentBatchIndex then
			projectileIndex += 1
			continue  -- Skip this projectile, process on its assigned frame
		end
		projectileIndex += 1
		
		local projectilePosition = tableToVector(position)
		if not projectilePosition then
			continue
		end
		
		local currentVelocity = tableToVector(velocity)
		if not currentVelocity or currentVelocity.Magnitude < 0.1 then
			continue
		end
		
		-- Get owner info to avoid targeting owner
		local ownerEntityId: number? = nil
		local ownerComponent = world:get(projectileEntity, Owner)
		if ownerComponent then
			ownerEntityId = ownerComponent.entity
		end
		
		-- Get list of already-hit targets to exclude from re-targeting
		local hitTargetsComp = world:get(projectileEntity, HitTargets)
		local hitTargetsTable = hitTargetsComp and hitTargetsComp.targets or {}
		
		-- Validate or acquire target
		local targetEntity = homingData.targetEntity
		local needsNewTarget = false
		
		if targetEntity then
			-- Check if we've already hit this target (after penetration)
			if hitTargetsTable[targetEntity] then
				-- Already hit this target, need new one
				needsNewTarget = true
				targetEntity = nil
			else
				-- Validate existing target
				local targetHealth = world:get(targetEntity, Health)
				if not targetHealth or targetHealth.current <= 0 then
					-- Target is dead, need new target
					needsNewTarget = true
					targetEntity = nil
				else
					-- Target is still valid (don't enforce range for tracking)
					-- Continue tracking even if it moves out of initial acquisition range
				end
			end
		else
			-- No target, need to acquire one
			needsNewTarget = true
		end
		
		-- Acquire new target if needed
		if needsNewTarget then
			targetEntity = findNearestTarget(
				projectilePosition,
				homingData.homingDistance or 100,
				ownerEntityId,
				targetEntity,
				hitTargetsTable  -- Exclude already-hit targets
			)
			
			-- Immediately mark new target as taken (prevents other projectiles in same frame from taking it)
			if targetEntity then
				activeTargets[targetEntity] = true
			end
		end
		
		-- Check behavior flags (priority: StickToPlayer > AlwaysStayHorizontal > StayHorizontal)
		local stayHorizontal = projectileData.stayHorizontal or false
		local alwaysStayHorizontal = projectileData.alwaysStayHorizontal or false
		local stickToPlayer = projectileData.stickToPlayer or false
		
		-- PRIORITY 1: StickToPlayer - projectile follows player movement
		if stickToPlayer then
			-- Get owner player's current position
			local owner = projectileData.owner
			if owner and owner:IsA("Player") and owner.Character then
				local hrp = owner.Character:FindFirstChild("HumanoidRootPart")
				if hrp and hrp:IsA("BasePart") then
					local currentPlayerPos = (hrp :: BasePart).Position
					
					-- Get last tracked player position for this projectile
					local lastPlayerPos = playerLastPositions[projectileEntity]
					
					if lastPlayerPos then
						-- Calculate player movement delta
						local playerDelta = currentPlayerPos - lastPlayerPos
						
						-- Apply the same delta to projectile position
						local newProjectilePos = projectilePosition + playerDelta
						DirtyService.setIfChanged(world, projectileEntity, Position, {
							x = newProjectilePos.X,
							y = newProjectilePos.Y,
							z = newProjectilePos.Z,
						}, "Position")
					end
					
					-- Update tracked player position for next frame
					playerLastPositions[projectileEntity] = currentPlayerPos
				end
			end
			-- Projectile still homes normally, but position follows player
			
		-- PRIORITY 2: AlwaysStayHorizontal - lock Y at spawn height
		elseif alwaysStayHorizontal then
			-- Get spawn Y from startPosition
			local spawnY = projectileData.startPosition and projectileData.startPosition.y or 0
			
			-- Lock Y position to spawn height
			DirtyService.setIfChanged(world, projectileEntity, Position, {
				x = projectilePosition.X,
				y = spawnY,
				z = projectilePosition.Z,
			}, "Position")
			-- Continue with homing, but flatten to horizontal
		end
		
		-- Steer towards target if we have one
		if targetEntity then
			-- Use getEnemyCenterPosition to target hitbox center (not base position)
			local targetPosition = AbilitySystemBase.getEnemyCenterPosition(targetEntity)
			if targetPosition then
				local targetDirection = (targetPosition - projectilePosition)
				
				-- Flatten direction if AlwaysStayHorizontal or StayHorizontal (not StickToPlayer - it uses full 3D)
				if (alwaysStayHorizontal or stayHorizontal) and not stickToPlayer then
					targetDirection = Vector3.new(targetDirection.X, 0, targetDirection.Z)
					-- Ensure we still have a valid direction after flattening
					if targetDirection.Magnitude < 0.1 then
						targetDirection = Vector3.new(0, 0, 1)  -- Default forward
					end
				end
				
				if targetDirection.Magnitude > 0.1 then
					-- Steer velocity towards target
					local newVelocity, isValidTarget = steerVelocityTowardsTarget(
						currentVelocity,
						targetDirection,
						homingData.homingStrength or 180,
						math.rad(homingData.homingMaxAngle or 90),
						HOMING_UPDATE_INTERVAL  -- Use fixed interval (0.04s) for consistent turning
					)
					
					-- If target was beyond max turn angle, clear it and find a new one
					if not isValidTarget then
						targetEntity = nil  -- Clear invalid target
					else
						-- Flatten velocity if AlwaysStayHorizontal or StayHorizontal (not StickToPlayer)
						if (alwaysStayHorizontal or stayHorizontal) and not stickToPlayer then
							newVelocity = Vector3.new(newVelocity.X, 0, newVelocity.Z).Unit * newVelocity.Magnitude
						end
						
						-- Update velocity
						DirtyService.setIfChanged(world, projectileEntity, Velocity, vectorToTable(newVelocity), "Velocity")
						
						-- Update facing direction for client rendering
						DirtyService.setIfChanged(world, projectileEntity, Components.FacingDirection, {
							x = newVelocity.X,
							y = newVelocity.Y,
							z = newVelocity.Z
						}, "FacingDirection")
					end
				end
			end
		end
		-- If no target, continue straight (velocity unchanged)
		
		-- Update homing data with new target and timestamp
		DirtyService.setIfChanged(world, projectileEntity, Homing, {
			targetEntity = targetEntity,
			homingStrength = homingData.homingStrength,
			homingDistance = homingData.homingDistance,
			homingMaxAngle = homingData.homingMaxAngle,
			lastUpdateTime = currentTime,
		}, "Homing")
	end
end

return HomingSystem

