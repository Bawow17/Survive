--!strict
-- ProjectileCollisionSystem - Handles collision detection and damage for projectiles
-- Manages hitbox detection, damage application, and piercing mechanics

local _ReplicatedStorage = game:GetService("ReplicatedStorage")
local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local SpatialGridSystem = require(game.ServerScriptService.ECS.Systems.SpatialGridSystem)
local DamageSystem = require(game.ServerScriptService.ECS.Systems.DamageSystem)
local ModelHitboxHelper = require(game.ServerScriptService.Utilities.ModelHitboxHelper)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)

local ProjectileCollisionSystem = {}
local GRID_SIZE = SpatialGridSystem.getGridSize()
local DEBUG = GameOptions.Debug and GameOptions.Debug.Enabled

local world: any
local Components: any
local DirtyService: any
local ECSWorldService: any

-- Component references
local Position: any
local _Velocity: any
local EntityType: any
local _Projectile: any
local ProjectileData: any
local Damage: any
local Piercing: any
local Collision: any
local Lifetime: any
local Health: any
local Owner: any
local HitTargets: any

-- Cached queries for performance
local projectileQuery: any

-- Collision detection parameters
local COLLISION_CHECK_INTERVAL = 0 -- Run collision every frame to avoid tunneling on fast projectiles
local lastCollisionCheck = 0
local HIT_COOLDOWN = 0.04 -- seconds of per-target immunity against the same projectile
local recentHits: {[number]: {[number]: number}} = {}
local activeExplosions: {{
	position: Vector3,
	radius: number,
	damage: number,
	endTime: number,
	ownerPlayer: Player?,
	ownerEntityId: number?,
	hitEnemies: {[number]: boolean},
	nextTick: number,
	tickInterval: number,
}} = {}

-- Cleanup parameters for recentHits memory leak prevention
local CLEANUP_INTERVAL = 1.0 -- Clean up expired recentHits entries every second
local lastCleanupTime = 0

-- OPTIMIZATION PHASE 1: Neighbor Array Pooling
-- Pre-allocate reusable arrays for neighbor lists to avoid allocation in hot loops
local NEIGHBOR_ARRAY_POOL_SIZE = 10
local neighborArrayPool: {{number}} = {}
local neighborArrayPoolCount = 0

-- Initialize neighbor array pool
for i = 1, NEIGHBOR_ARRAY_POOL_SIZE do
	table.insert(neighborArrayPool, {})
end
neighborArrayPoolCount = NEIGHBOR_ARRAY_POOL_SIZE

-- Acquire a reusable neighbor array from pool
local function acquireNeighborArray(): {number}
	if neighborArrayPoolCount > 0 then
		local array = neighborArrayPool[neighborArrayPoolCount]
		table.clear(array)  -- Clear contents for reuse
		neighborArrayPoolCount -= 1
		return array
	end
	-- Fallback: allocate new array
	if neighborArrayPoolCount == 0 then
		warn("[ProjectileCollisionSystem] Neighbor array pool exhausted; allocating new array")
	end
	return {}
end

-- Release neighbor array back to pool
local function releaseNeighborArray(array: {number})
	if neighborArrayPoolCount < NEIGHBOR_ARRAY_POOL_SIZE then
		table.clear(array)
		neighborArrayPoolCount += 1
		neighborArrayPool[neighborArrayPoolCount] = array
	end
end

-- OPTIMIZATION: Pre-sized set for O(1) deduplication (replaces hash-based approach)
local seenEntitiesSet: {[number]: boolean} = {}
local function clearSeenSet()
	table.clear(seenEntitiesSet)
end

local hitDetectedCount = 0
local damageAppliedCount = 0
local missingHurtboxLogged: {[number]: boolean} = {}

local function logTargetValidationFailure(targetEntity: number, reason: string)
	if not DEBUG then
		return
	end
	print(string.format("[ProjectileCollision] Target validation failed | target=%d | reason=%s", targetEntity, reason))
end

function ProjectileCollisionSystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService
	
	-- Component references
	Position = Components.Position
	_Velocity = Components.Velocity
	EntityType = Components.EntityType
	_Projectile = Components.Projectile
	ProjectileData = Components.ProjectileData
	Damage = Components.Damage
	Piercing = Components.Piercing
	Collision = Components.Collision
	Lifetime = Components.Lifetime
	Health = Components.Health
	Owner = Components.Owner
	HitTargets = Components.HitTargets
	
	-- Create cached queries for performance
	projectileQuery = world:query(Components.Projectile, Components.Position, Components.ProjectileData, Components.Damage, Components.Piercing):cached()
end

-- Use shared helper for hitbox data
local getModelHitboxData = ModelHitboxHelper.getModelHitboxData

-- Trigger FireBall explosion at given position
function ProjectileCollisionSystem.triggerFireBallExplosion(explosionPosition: Vector3, ownerPlayer: Player?, scale: number?, ownerEntityId: number?, explosionDamage: number?)
	if not world or not Components or not DirtyService or not ECSWorldService then
		return
	end
	
	-- Get FireBall balance config for explosion settings
	local AbilityRegistry = require(game.ServerScriptService.Abilities.AbilityRegistry)
	local fireballAbility = AbilityRegistry.get("FireBall")
	if not fireballAbility or not fireballAbility.balance.hasExplosion then
		return
	end
	
	-- Get hitbox size from explosion model
	local hitboxSize, _hitboxOffset = getModelHitboxData(fireballAbility.balance.explosionModelPath)
	local explosionRadius = 10 -- Default fallback
	if hitboxSize then
		-- Use the largest dimension of the hitbox as radius
		local baseRadius = math.max(hitboxSize.X, hitboxSize.Y, hitboxSize.Z) / 2
		-- Apply scale if provided (from size upgrades)
		explosionRadius = baseRadius * (scale or 1.0)
	end
	
		-- Apply explosion damage over time (lingering hitbox for 0.5s to match VFX)
		local explosionDuration = fireballAbility.balance.explosionDuration or 0.5
		local now = tick()
		local tickInterval = fireballAbility.balance.explosionTickInterval or 0
		
		-- Use scaled explosion damage if provided, otherwise fall back to base config
		local finalExplosionDamage = explosionDamage or fireballAbility.balance.explosionDamage or 0

		activeExplosions[#activeExplosions + 1] = {
			position = explosionPosition,
			radius = explosionRadius,
			damage = finalExplosionDamage,
			endTime = now + explosionDuration,
			ownerPlayer = ownerPlayer,
			ownerEntityId = ownerEntityId,  -- Track source entity for damage tracking
			hitEnemies = {},
			nextTick = now,
			tickInterval = tickInterval,
		}
	
	-- Spawn VFX with delay (visual only, no damage)
	task.delay(fireballAbility.balance.explosionDelay or 0.2, function()
		-- Create explosion entity for VFX ONLY (no collision with projectiles)
		local explosionEntity = ECSWorldService.CreateEntity("Projectile", explosionPosition, ownerPlayer)
		if explosionEntity then
			-- Set EntityType with Explosion subtype for client rendering
			DirtyService.setIfChanged(world, explosionEntity, Components.EntityType, {
				type = "Projectile",
				subtype = "FireBallExplosion",
				owner = ownerPlayer,
			}, "EntityType")
			
			-- Mark as explosion for client rendering (NO COLLISION component = won't block projectiles)
			DirtyService.setIfChanged(world, explosionEntity, Components.ProjectileData, {
				type = "FireBallExplosion",
				owner = ownerPlayer,
				damage = 0, -- Already applied damage above
				radius = explosionRadius,
				duration = fireballAbility.balance.explosionDuration,
			}, "ProjectileData")
			
			-- Set visual path for explosion VFX with scale
			DirtyService.setIfChanged(world, explosionEntity, Components.Visual, {
				modelPath = fireballAbility.balance.explosionModelPath,
				visible = true,
				scale = scale or 1.0,  -- Apply scale to explosion VFX
			}, "Visual")
			
			-- Set lifetime (will auto-despawn after duration)
			DirtyService.setIfChanged(world, explosionEntity, Components.Lifetime, {
				remaining = fireballAbility.balance.explosionDuration,
				max = fireballAbility.balance.explosionDuration,
			}, "Lifetime")
			
			-- Mark all components for sync to client
			DirtyService.mark(explosionEntity, "Position")
			DirtyService.mark(explosionEntity, "EntityType")
			DirtyService.mark(explosionEntity, "ProjectileData")
			DirtyService.mark(explosionEntity, "Visual")
			DirtyService.mark(explosionEntity, "Lifetime")
		end
	end)
end

-- Check collision between two entities
local function checkCollision(
    projectilePos: Vector3, 
    projectileRadius: number, 
    targetPos: Vector3, 
    targetRadius: number
): boolean
    local distance = (projectilePos - targetPos).Magnitude
    return distance <= (projectileRadius + targetRadius)
end

-- Apply damage to target entity (optimized to only mark dirty when changed)
-- Route damage through centralized DamageSystem
local function applyDamage(targetEntity: number, damageAmount: number, damageType: string, sourceEntity: number?, abilityId: string?): boolean
    return DamageSystem.applyDamage(targetEntity, damageAmount, damageType, sourceEntity, abilityId)
end

-- Handle projectile collision with target
local function handleProjectileHit(
	projectileEntity: number,
	targetEntity: number,
	targetEntityType: any,
	ownerEntityId: number?,
	ownerPlayer: any
): (boolean, boolean)
	local projectileData = world:get(projectileEntity, ProjectileData)
	local damage = world:get(projectileEntity, Damage)
	local piercing = world:get(projectileEntity, Piercing)
	
	if not projectileData or not damage or not piercing then
		return false, false
	end
	
	-- Don't hit the owner
	if ownerEntityId and targetEntity == ownerEntityId then
		return false, false
	end
	if ownerPlayer and targetEntityType and targetEntityType.type == "Player" then
		local targetPlayer = targetEntityType.player
		if targetPlayer and targetPlayer == ownerPlayer then
			return false, false
		end
	end
	-- Apply damage (track ability damage if owner is a player)
	local sourceEntity = ownerEntityId  -- Player entity ID
	local abilityId = projectileData.type  -- Ability ID (MagicBolt, FireBall, etc.)
    local targetDied, didApplyDamage = applyDamage(targetEntity, damage.amount, damage.type, sourceEntity, abilityId)
	if didApplyDamage then
		damageAppliedCount += 1
	end
    
    -- Track hit targets for homing re-targeting (avoid targeting same enemy)
    local hitTargets = world:get(projectileEntity, HitTargets)
    if not hitTargets then
        hitTargets = {targets = {}}
    end
    if not hitTargets.targets then
        hitTargets.targets = {}
    end
    hitTargets.targets[targetEntity] = true
    DirtyService.setIfChanged(world, projectileEntity, HitTargets, hitTargets, "HitTargets")
    
    -- Check if this projectile has explosion on impact (like FireBall)
    if projectileData.type == "FireBall" then
        -- Trigger explosion at impact location
        local projectilePos = world:get(projectileEntity, Position)
        if projectilePos then
            local explosionPosition = Vector3.new(projectilePos.x, projectilePos.y, projectilePos.z)
            -- Get scale from projectile's Visual component (for size upgrades)
            local visual = world:get(projectileEntity, Components.Visual)
            local scale = (visual and visual.scale) or 1.0
            -- Get custom explosion scale if provided (for "The Big One" attribute)
            -- CRITICAL: explosionScale from projectileData takes priority over visual scale
            local explosionScale = projectileData.explosionScale
            if explosionScale == nil then
                explosionScale = scale
            end
            -- Get scaled explosion damage from projectile data (includes upgrades/passives)
            local explosionDamage = projectileData.explosionDamage
            
            ProjectileCollisionSystem.triggerFireBallExplosion(explosionPosition, ownerPlayer, explosionScale, ownerEntityId, explosionDamage)
        end
    end
    
    -- Update piercing (only mark dirty if changed)
    local newPiercing = piercing.remaining - 1
    if newPiercing <= 0 then
        -- Projectile should be destroyed
        return true, targetDied
    else
        -- Update piercing counter only if it changed
        if newPiercing ~= piercing.remaining then
            DirtyService.setIfChanged(world, projectileEntity, Piercing, {
                remaining = newPiercing,
                max = piercing.max
            }, "Piercing")
        end
        
        -- Clear homing target for re-acquisition after penetration hit
        local homingComponent = world:get(projectileEntity, Components.Homing)
        if homingComponent then
            DirtyService.setIfChanged(world, projectileEntity, Components.Homing, {
                targetEntity = nil,  -- Clear target for re-acquisition
                homingStrength = homingComponent.homingStrength,
                homingDistance = homingComponent.homingDistance,
                homingMaxAngle = homingComponent.homingMaxAngle,
                lastUpdateTime = homingComponent.lastUpdateTime,
            }, "Homing")
        end
    end
    
    -- Mark projectile as having hit something (only if not already marked)
    if not projectileData.hasHit then
        DirtyService.setIfChanged(world, projectileEntity, ProjectileData, {
            type = projectileData.type,
            speed = projectileData.speed,
            owner = projectileData.owner,
            damage = projectileData.damage,
            gravity = projectileData.gravity,
            hasHit = true,
            stayHorizontal = projectileData.stayHorizontal,  -- Preserve stayHorizontal flag
            alwaysStayHorizontal = projectileData.alwaysStayHorizontal,
            stickToPlayer = projectileData.stickToPlayer,
            explosionScale = projectileData.explosionScale,  -- CRITICAL: Preserve for penetration hits
            explosionDamage = projectileData.explosionDamage,  -- CRITICAL: Preserve for penetration hits
            startPosition = projectileData.startPosition,
            targetPosition = projectileData.targetPosition,
            travelTime = projectileData.travelTime,
        }, "ProjectileData")
    end
    
    return false, targetDied -- Don't destroy projectile yet
end

local function processTarget(
	projectileEntity: number,
	projectilePosition: Vector3,
	projectileRadius: number,
	targetEntity: number,
	targetEntityType: any,
	targetPos: any,
	targetHealth: any,
	targetVisual: any,
	ownerEntityId: number?,
	ownerPlayer: any,
	projectileHits: {[number]: number}?,
	currentTime: number,
	maxDistance: number?
): ({[number]: number}?, boolean, boolean, boolean)
	if not targetEntityType or not targetPos or not targetHealth then
		if not targetEntityType then
			logTargetValidationFailure(targetEntity, "missing_entity_type")
		elseif not targetPos then
			logTargetValidationFailure(targetEntity, "missing_position_or_spatial")
		elseif not targetHealth then
			logTargetValidationFailure(targetEntity, "missing_health")
		end
		return projectileHits, false, false, false
	end

	if targetHealth.current and targetHealth.current <= 0 then
		return projectileHits, false, false, false
	end

	if targetEntity == projectileEntity then
		return projectileHits, false, false, false
	end

	if targetEntityType.type ~= "Enemy" and targetEntityType.type ~= "Player" then
		return projectileHits, false, false, false
	end

	if ownerEntityId and targetEntity == ownerEntityId then
		return projectileHits, false, false, false
	end

	if ownerPlayer and targetEntityType.type == "Player" then
		local targetPlayer = targetEntityType.player
		if targetPlayer and targetPlayer == ownerPlayer then
			return projectileHits, false, false, false
		end
	end

	if projectileHits then
		local expiresAt = projectileHits[targetEntity]
		if expiresAt and expiresAt > currentTime then
			return projectileHits, false, false, false
		elseif expiresAt and expiresAt <= currentTime then
			projectileHits[targetEntity] = nil
		end
	end

	-- Phase 4.6: Early distance check before expensive operations (reduces spatial queries)
	local dx = projectilePosition.X - targetPos.x
	local dz = projectilePosition.Z - targetPos.z
	local dist2D = math.sqrt(dx*dx + dz*dz)
	local checkDistance = maxDistance or projectileRadius
	local enemyHitbox = 3  -- Assume average enemy hitbox
	if dist2D > (checkDistance + enemyHitbox + 5) then
		-- Too far away, skip expensive checks
		return projectileHits, false, false, false
	end

	local targetPosition = Vector3.new(targetPos.x, targetPos.y, targetPos.z)
	local targetRadius = 2.0
	local aabbHalfSize: Vector3? = nil
	local aabbCenter: Vector3? = nil

	if maxDistance then
		local distance = (projectilePosition - targetPosition).Magnitude
		if distance > maxDistance + targetRadius then
			return projectileHits, false, false, false
		end
	end

	if targetEntityType.type == "Enemy" then
		local subtype = targetEntityType.subtype or "Zombie"
		local hitbox = ModelReplicationService.getEnemyHitbox(subtype)
		if not hitbox then
			ModelReplicationService.replicateEnemy(subtype)
			hitbox = ModelReplicationService.getEnemyHitbox(subtype)
		end

		if hitbox and hitbox.size then
			aabbHalfSize = hitbox.size / 2
			aabbCenter = targetPosition + hitbox.offset
		elseif targetVisual and targetVisual.modelPath then
			local size, offset = getModelHitboxData(targetVisual.modelPath)
			if size then
				aabbHalfSize = size / 2
				aabbCenter = targetPosition + (offset or Vector3.new(0, 0, 0))
			end
		elseif DEBUG and not missingHurtboxLogged[targetEntity] then
			missingHurtboxLogged[targetEntity] = true
			logTargetValidationFailure(targetEntity, "missing_hurtbox")
		end
	end

	local hit = false
	if aabbHalfSize and aabbCenter then
		local clamped = Vector3.new(
			math.clamp(projectilePosition.X, aabbCenter.X - aabbHalfSize.X, aabbCenter.X + aabbHalfSize.X),
			math.clamp(projectilePosition.Y, aabbCenter.Y - aabbHalfSize.Y, aabbCenter.Y + aabbHalfSize.Y),
			math.clamp(projectilePosition.Z, aabbCenter.Z - aabbHalfSize.Z, aabbCenter.Z + aabbHalfSize.Z)
		)
		local dist = (projectilePosition - clamped).Magnitude
		hit = dist <= projectileRadius
	else
		hit = checkCollision(projectilePosition, projectileRadius, targetPosition, targetRadius)
	end

	if not hit then
		return projectileHits, false, false, false
	end
	hitDetectedCount += 1

	local shouldDestroyProjectile, targetDied = handleProjectileHit(
		projectileEntity,
		targetEntity,
		targetEntityType,
		ownerEntityId,
		ownerPlayer
	)

	if not projectileHits then
		projectileHits = {}
		recentHits[projectileEntity] = projectileHits
	end

	projectileHits[targetEntity] = currentTime + HIT_COOLDOWN

	return projectileHits, true, shouldDestroyProjectile, targetDied and targetEntityType and targetEntityType.type == "Enemy"
end


function ProjectileCollisionSystem.step(dt: number)
	if not world then
		return
	end
    
    local currentTime = tick()
    
    -- Periodic cleanup of expired recentHits entries (memory leak prevention)
    if currentTime - lastCleanupTime >= CLEANUP_INTERVAL then
        lastCleanupTime = currentTime
        for projectileEntity, projectileHits in pairs(recentHits) do
            -- Clean up expired hits for this projectile
            for targetId, expiresAt in pairs(projectileHits) do
                if expiresAt <= currentTime then
                    projectileHits[targetId] = nil
                end
            end
            -- Remove empty projectile entries
            if next(projectileHits) == nil then
                recentHits[projectileEntity] = nil
            end
        end
    end
    
    if currentTime - lastCollisionCheck < COLLISION_CHECK_INTERVAL then
        return
    end
    lastCollisionCheck = currentTime
    
    -- Debug logging (disabled to prevent spam)
    -- print(string.format("[ProjectileCollisionSystem] Running collision check at time %.2f", currentTime))
    
    -- Use cached query for better performance
    local projectileCount = 0
    for projectileEntity, projectile, projectilePos, projectileData, damage, piercing in projectileQuery do
        projectileCount = projectileCount + 1
        -- Skip if projectile has no piercing left
        if piercing.remaining <= 0 then
            continue
        end
        
        local projectilePosition = Vector3.new(projectilePos.x, projectilePos.y, projectilePos.z)
        
        -- Resolve owner data to avoid self-hits
        local ownerEntityId: number? = nil
        local ownerPlayer: any = nil
        local ownerComponent = world:get(projectileEntity, Owner)
        if ownerComponent then
            ownerEntityId = ownerComponent.entity
            ownerPlayer = ownerComponent.player
        end
        local projectileEntityType = world:get(projectileEntity, EntityType)
        if projectileEntityType then
            if ownerEntityId == nil then
                local ownerField = projectileEntityType.owner
                if typeof(ownerField) == "number" then
                    ownerEntityId = ownerField
                elseif typeof(ownerField) == "table" and ownerField.entity then
                    ownerEntityId = ownerField.entity
                end
            end
            if ownerPlayer == nil then
                local ownerField = projectileEntityType.owner
                if typeof(ownerField) == "Instance" then
                    ownerPlayer = ownerField
                elseif typeof(ownerField) == "table" and ownerField.player then
                    ownerPlayer = ownerField.player
                end
            end
        end

        -- Get projectile collision radius
        local collision = world:get(projectileEntity, Collision)
        local projectileRadius = collision and collision.radius or 1.0
        
        -- Get visual component to determine hitbox size and apply scale
        local visual = world:get(projectileEntity, Components.Visual)
        if visual and visual.modelPath then
            local size = select(1, getModelHitboxData(visual.modelPath))
            if size then
                local baseRadius = math.max(size.X, size.Z) / 2 -- horizontal radius only
                -- Apply scale from Visual component (for size upgrades)
                local scale = visual.scale or 1.0
                projectileRadius = baseRadius * scale
            end
        end
        
        -- Prepare per-projectile hit cooldown pruning
        local projectileHits = recentHits[projectileEntity]
        if projectileHits then
            for targetId, expiresAt in pairs(projectileHits) do
                if expiresAt <= currentTime then
                    projectileHits[targetId] = nil
                end
            end
            if next(projectileHits) == nil then
                recentHits[projectileEntity] = nil
                projectileHits = nil
            end
        end

        -- Use spatial grid to get nearby entities for collision optimization
        local nearbyEntities = SpatialGridSystem.getNeighboringEntities(projectilePosition, 0)
		if #nearbyEntities == 0 then
			nearbyEntities = SpatialGridSystem.getNeighboringEntities(projectilePosition, 1)
		end
		if #nearbyEntities == 0 then
			nearbyEntities = SpatialGridSystem.getNeighboringEntities(projectilePosition, 2)
		end
        
        -- Deduplicate nearby entities (spatial grid may return duplicates)
        local uniqueNearbyEntities = acquireNeighborArray()
        for _, targetEntity in ipairs(nearbyEntities) do
			if not seenEntitiesSet[targetEntity] then
				seenEntitiesSet[targetEntity] = true
				table.insert(uniqueNearbyEntities, targetEntity)
			end
		end
        
        -- Check collision with nearby entities only
        for _, targetEntity in ipairs(uniqueNearbyEntities) do
			if targetEntity ~= projectileEntity then
				local targetEntityType = world:get(targetEntity, EntityType)
				local targetPos = world:get(targetEntity, Position)
				local targetHealth = world:get(targetEntity, Health)
				local targetVisual = world:get(targetEntity, Components.Visual)

				local updatedHits, hitOccurred, shouldDestroy, _ = processTarget(
					projectileEntity,
					projectilePosition,
					projectileRadius,
					targetEntity,
					targetEntityType,
					targetPos,
					targetHealth,
					targetVisual,
					ownerEntityId,
					ownerPlayer,
					projectileHits,
					currentTime,
					nil
				)
				projectileHits = updatedHits

				if hitOccurred and shouldDestroy then
					local currentLifetime = world:get(projectileEntity, Lifetime)
					if currentLifetime and currentLifetime.remaining > 0 then
						DirtyService.setIfChanged(world, projectileEntity, Lifetime, {
							remaining = 0,
							max = currentLifetime.max
						}, "Lifetime")
					end
					recentHits[projectileEntity] = nil
					break
				end
			end
        end
        
        -- Release pooled array and clear deduplication set
        releaseNeighborArray(uniqueNearbyEntities)
        clearSeenSet()
    end

	if #activeExplosions > 0 then
		local index = 1
		while index <= #activeExplosions do
			local explosion = activeExplosions[index]
			if currentTime >= explosion.endTime then
				activeExplosions[index] = activeExplosions[#activeExplosions]
				activeExplosions[#activeExplosions] = nil
			elseif currentTime >= explosion.nextTick then
				local radiusCells = math.max(1, math.ceil(explosion.radius / GRID_SIZE))
				local nearby = SpatialGridSystem.getNeighboringEntities(explosion.position, radiusCells)
				if #nearby == 0 then
					nearby = SpatialGridSystem.getNeighboringEntities(explosion.position, radiusCells + 1)
				end

				for _, enemyEntity in ipairs(nearby) do
					if not explosion.hitEnemies[enemyEntity] then
						local entityType = world:get(enemyEntity, EntityType)
						if entityType and entityType.type == "Enemy" then
							local enemyHealth = world:get(enemyEntity, Health)
							if enemyHealth and enemyHealth.current > 0 then
								local enemyPosComponent = world:get(enemyEntity, Position)
								if enemyPosComponent then
									local enemyPos = Vector3.new(enemyPosComponent.x, enemyPosComponent.y, enemyPosComponent.z)
									if (enemyPos - explosion.position).Magnitude <= explosion.radius then
										explosion.hitEnemies[enemyEntity] = true
										-- Track explosion damage for FireBall ability
										DamageSystem.applyDamage(enemyEntity, explosion.damage, "magic", explosion.ownerEntityId, "FireBall")
									end
								end
							end
						end
					end
				end

				if explosion.tickInterval > 0 then
					explosion.nextTick = currentTime + explosion.tickInterval
				else
					explosion.nextTick = currentTime
				end
				index += 1
			else
				index += 1
			end
		end
	end

	-- Don't destroy dead enemies immediately - DeathAnimationSystem will handle cleanup
	-- after death animation completes (flash + fade)
    
    -- Debug logging for projectile count (disabled)
    -- if projectileCount > 0 then
    --	print(string.format("[ProjectileCollisionSystem] Checking %d projectiles for collisions", projectileCount))
    -- end
end

function ProjectileCollisionSystem.getExplosionStats()
	return {
		activeExplosions = #activeExplosions,
	}
end

function ProjectileCollisionSystem.getHitStats()
	return {
		hitsDetected = hitDetectedCount,
		damageApplied = damageAppliedCount,
	}
end

-- Return pool statistics for monitoring
function ProjectileCollisionSystem.getPoolStats()
	return {
		neighborArrayPoolUsage = neighborArrayPoolCount .. "/" .. NEIGHBOR_ARRAY_POOL_SIZE,
		neighborArrayPoolPercent = (neighborArrayPoolCount / NEIGHBOR_ARRAY_POOL_SIZE) * 100,
	}
end

return ProjectileCollisionSystem
