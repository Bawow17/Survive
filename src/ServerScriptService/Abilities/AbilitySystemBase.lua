--!strict
-- AbilitySystemBase.lua - Shared utilities for all ability systems
-- Contains common targeting, spawning, and helper functions

local _ReplicatedStorage = game:GetService("ReplicatedStorage")
local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local SpatialGridSystem = require(game.ServerScriptService.ECS.Systems.SpatialGridSystem)
local ModelHitboxHelper = require(game.ServerScriptService.Utilities.ModelHitboxHelper)

-- Targeting prediction tuning
local PREDICTION_FACTOR = 0.6  -- 60% of predicted position (conservative)
local MOVING_SPEED_THRESHOLD = 5  -- studs/sec - below this, aim at center
local MAX_PREDICTION_OFFSET = 10  -- studs - cap prediction lead distance

local AbilitySystemBase = {}

-- Shared references (initialized by each system)
local world: any = nil
local Components: any = nil
local DirtyService: any = nil
local ECSWorldService: any = nil

-- Projectile spawn queue system (backpressure handling when pool is exhausted)
local MAX_QUEUE_SIZE_PER_PLAYER = 100  -- Max pending projectiles per player
local QUEUE_PROCESS_RATE = 10  -- Process 10 projectiles per frame when pool has capacity
local projectileSpawnQueue: {[Player]: {{
	abilityId: string,
	balance: any,
	spawnPosition: Vector3,
	direction: Vector3,
	targetPosition: Vector3,
	timestamp: number
}}} = {}
local queueProcessAccumulator = 0

-- Virtual damage tracking for smart multi-targeting
-- Structure: {playerEntity: {enemyEntity: predictedDamageTaken}}
local activeCastPredictions: {[number]: {[number]: number}} = {}

-- Current target tracking for target stickiness
-- Structure: {playerEntity: enemyEntity}
local currentCastTargets: {[number]: number} = {}

-- Prediction start times for timeout cleanup (memory leak prevention)
-- Structure: {playerEntity: startTime}
local predictionStartTimes: {[number]: number} = {}

-- Cleanup parameters
local PREDICTION_TIMEOUT = 5.0 -- Clear predictions after 5 seconds (safety net)
local CLEANUP_INTERVAL = 10.0 -- Check for stale predictions every 10 seconds
local lastCleanupTime = 0

local GRID_SIZE = SpatialGridSystem.getGridSize()
local enemyFallbackQuery: any = nil

local function ensureEnemyQuery()
	if world and Components and not enemyFallbackQuery then
		enemyFallbackQuery = world:query(Components.EntityType, Components.Position, Components.Health):cached()
	end
end

local function gatherEnemyCandidates(center: Vector3, maxRange: number): {number}
	if not world or not Components then
		return {}
	end

	local radiusCells = math.max(1, math.ceil(maxRange / GRID_SIZE))
	local candidates = SpatialGridSystem.getNeighboringEntities(center, radiusCells)
	if #candidates == 0 then
		candidates = SpatialGridSystem.getNeighboringEntities(center, radiusCells + 1)
	end

	if #candidates == 0 then
		ensureEnemyQuery()
		if enemyFallbackQuery then
			local fallback = {}
			for enemyEntity, entityType in enemyFallbackQuery do
				if entityType.type == "Enemy" then
					fallback[#fallback + 1] = enemyEntity
				end
			end
			return fallback
		end
	end

	return candidates
end

-- Initialize base with ECS references
function AbilitySystemBase.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService
	ensureEnemyQuery()
end

-- Get ability stats for a player (merges base balance with upgrades and passive effects)
function AbilitySystemBase.getAbilityStats(playerEntity: number, abilityId: string, baseBalance: any): any
	if not world or not Components then
		return baseBalance
	end
	
	-- Start with base balance
	local stats = {}
	for key, value in pairs(baseBalance) do
		stats[key] = value
	end
	
	-- Get upgraded stats from AbilityData
	local abilityData = world:get(playerEntity, Components.AbilityData)
	if abilityData and abilityData.abilities and abilityData.abilities[abilityId] then
		local abilityRecord = abilityData.abilities[abilityId]
		-- Override with upgraded values
		for key, value in pairs(abilityRecord) do
			if key ~= "enabled" and key ~= "Name" and key ~= "name" and key ~= "level" then
				stats[key] = value
			end
		end
	end
	
	-- Apply passive effect multipliers
	local passiveEffects = world:get(playerEntity, Components.PassiveEffects)
	if passiveEffects then
		-- Apply damage multiplier
		if stats.damage and passiveEffects.damageMultiplier then
			stats.damage = stats.damage * passiveEffects.damageMultiplier
		end
		
		-- Apply damage multiplier to explosion damage (for FireBall)
		if stats.explosionDamage and passiveEffects.damageMultiplier then
			stats.explosionDamage = stats.explosionDamage * passiveEffects.damageMultiplier
		end
		
		-- Apply cooldown multiplier
		if stats.cooldown and passiveEffects.cooldownMultiplier then
			stats.cooldown = stats.cooldown * passiveEffects.cooldownMultiplier
		end
		
		-- Apply size/scale multiplier
		-- Ensure stats.scale exists (default to 1 if not present)
		if not stats.scale then
			stats.scale = 1.0
		end
		if passiveEffects.sizeMultiplier then
			stats.scale = stats.scale * passiveEffects.sizeMultiplier
		end
		
		-- Apply duration multiplier
		if stats.duration and passiveEffects.durationMultiplier then
			stats.duration = stats.duration * passiveEffects.durationMultiplier
		end
	end
	
	-- Apply buff multipliers (stacks with passives)
	local BuffSystem = require(game.ServerScriptService.ECS.Systems.BuffSystem)
	if BuffSystem then
		-- Apply damage buff multiplier
		if stats.damage then
			local buffDamageMult = BuffSystem.getDamageMultiplier(playerEntity)
			stats.damage = stats.damage * buffDamageMult
		end
		
		-- Apply damage buff multiplier to explosion damage (for FireBall)
		if stats.explosionDamage then
			local buffDamageMult = BuffSystem.getDamageMultiplier(playerEntity)
			stats.explosionDamage = stats.explosionDamage * buffDamageMult
		end
		
		-- Apply cooldown buff multiplier
		if stats.cooldown then
			local buffCooldownMult = BuffSystem.getCooldownMultiplier(playerEntity)
			stats.cooldown = stats.cooldown * buffCooldownMult
		end
		
		-- Check if ArcaneRune buff is active for additional multipliers
		local buffState = world:get(playerEntity, Components.BuffState)
		if buffState and buffState.buffs and buffState.buffs["ArcaneRune"] then
			local arcaneRuneBuff = buffState.buffs["ArcaneRune"]
			
			-- Apply homing multiplier from buff config
			local homingMult = arcaneRuneBuff.homingMultiplier or 1.0
			if stats.homingStrength then
				stats.homingStrength = stats.homingStrength * homingMult
			end
			if stats.homingDistance then
				stats.homingDistance = stats.homingDistance * homingMult
			end
			if stats.homingMaxAngle then
				stats.homingMaxAngle = stats.homingMaxAngle * homingMult
			end
			
			-- Apply penetration multiplier from buff config
			local penetrationMult = arcaneRuneBuff.penetrationMultiplier or 1.0
			if stats.penetration then
				stats.penetration = stats.penetration * penetrationMult
			end
			
			-- Apply duration multiplier from buff config (stacks with passive duration multiplier)
			local durationMult = arcaneRuneBuff.durationMultiplier or 1.0
			if stats.duration then
				stats.duration = stats.duration * durationMult
			end
			
			-- Apply projectile speed multiplier from buff config
			local projectileSpeedMult = arcaneRuneBuff.projectileSpeedMultiplier or 1.0
			if stats.projectileSpeed then
				stats.projectileSpeed = stats.projectileSpeed * projectileSpeedMult
			end
		end
	end
	
	return stats
end

-- Start tracking predictions for a new cast
function AbilitySystemBase.startCastPrediction(playerEntity: number)
	activeCastPredictions[playerEntity] = {}
	currentCastTargets[playerEntity] = nil
	predictionStartTimes[playerEntity] = tick()  -- Track start time for timeout cleanup
end

-- Clear predictions after cast completes
function AbilitySystemBase.endCastPrediction(playerEntity: number)
	activeCastPredictions[playerEntity] = nil
	currentCastTargets[playerEntity] = nil
	predictionStartTimes[playerEntity] = nil  -- Clear start time
end

-- Periodic cleanup of stale predictions (memory leak prevention)
-- Should be called periodically (e.g., in main game loop)
function AbilitySystemBase.cleanupStalePredictions()
	local currentTime = tick()
	
	if currentTime - lastCleanupTime < CLEANUP_INTERVAL then
		return
	end
	lastCleanupTime = currentTime
	
	-- Remove predictions that have been active for too long
	for playerEntity, startTime in pairs(predictionStartTimes) do
		if currentTime - startTime > PREDICTION_TIMEOUT then
			activeCastPredictions[playerEntity] = nil
			currentCastTargets[playerEntity] = nil
			predictionStartTimes[playerEntity] = nil
		end
	end
end

-- Record predicted damage to an enemy (accumulates for multi-shot)
function AbilitySystemBase.recordPredictedDamage(playerEntity: number, enemyEntity: number, damage: number)
	local predictions = activeCastPredictions[playerEntity]
	if predictions then
		predictions[enemyEntity] = (predictions[enemyEntity] or 0) + damage
	end
end

-- Get total predicted damage for an enemy
function AbilitySystemBase.getPredictedDamage(playerEntity: number, enemyEntity: number): number
	local predictions = activeCastPredictions[playerEntity]
	return predictions and predictions[enemyEntity] or 0
end

	-- Helper function to get the first enemy within range
	function AbilitySystemBase.findNearestEnemy(playerPosition: Vector3, maxRange: number): number?
		if not world or not Components then
			warn("[AbilitySystemBase] Not initialized")
			return nil
		end
		
		local nearestEntity: number? = nil
		local nearestDistance = math.huge
		local candidates = gatherEnemyCandidates(playerPosition, maxRange)

		for _, entity in ipairs(candidates) do
			local entityType = world:get(entity, Components.EntityType)
			if entityType and entityType.type == "Enemy" then
				local position = world:get(entity, Components.Position)
				if position then
					local ecsPosition = Vector3.new(position.x, position.y, position.z)
					local distance = (ecsPosition - playerPosition).Magnitude
					if distance <= maxRange and distance < nearestDistance then
						nearestEntity = entity
						nearestDistance = distance
					end
				end
			end
		end
	
		return nearestEntity
	end
	
	-- Smart target finding with kill prediction (for multi-target optimization)
	function AbilitySystemBase.findBestTarget(
		playerEntity: number,
		playerPosition: Vector3,
		maxRange: number,
		damageAmount: number
): number?
	if not world or not Components then
		warn("[AbilitySystemBase] Not initialized")
		return nil
	end
	
	-- Check if we have a current target that's still valid (target stickiness)
	local currentTarget = currentCastTargets[playerEntity]
	if currentTarget then
		local health = world:get(currentTarget, Components.Health)
		local predictedDamage = AbilitySystemBase.getPredictedDamage(playerEntity, currentTarget)
		
		-- Keep current target if it's still alive and won't die from this shot
		if health and (health.current - predictedDamage) > damageAmount then
			local position = world:get(currentTarget, Components.Position)
			if position then
				local ecsPosition = Vector3.new(position.x, position.y, position.z)
				local distance = (ecsPosition - playerPosition).Magnitude
				-- Keep target if still in range
				if distance <= maxRange then
					return currentTarget
				end
			end
		end
	end
	
	-- NEW: When switching targets, prioritize reliability
	-- Reset prediction for new target to ensure center-mass aiming initially
	local previousTarget = currentCastTargets[playerEntity]
	
	-- Need to find new target
	local nearestValidTarget: number? = nil
	local nearestDistance = math.huge
	local candidates = gatherEnemyCandidates(playerPosition, maxRange)

	for _, entity in ipairs(candidates) do
		local entityType = world:get(entity, Components.EntityType)
		if entityType and entityType.type == "Enemy" then
			local health = world:get(entity, Components.Health)
			local position = world:get(entity, Components.Position)
			if health and position then
				-- Get predicted damage for this enemy from current cast
				local predictedDamage = AbilitySystemBase.getPredictedDamage(playerEntity, entity)
				
				-- Skip if enemy is predicted to die from already-fired projectiles
				if health.current > predictedDamage then
					local ecsPosition = Vector3.new(position.x, position.y, position.z)
					local distance = (ecsPosition - playerPosition).Magnitude
					
					if distance <= maxRange and distance < nearestDistance then
						nearestValidTarget = entity
						nearestDistance = distance
					end
				end
			end
		end
	end
	
	-- If all enemies are predicted to die, fall back to nearest enemy anyway
	if not nearestValidTarget then
		nearestValidTarget = AbilitySystemBase.findNearestEnemy(playerPosition, maxRange)
	end
	
	-- Store the new target for stickiness
	if nearestValidTarget then
		currentCastTargets[playerEntity] = nearestValidTarget
		-- NEW: If this is a target switch, reset its prediction to start fresh
		if previousTarget and previousTarget ~= nearestValidTarget then
			local predictions = activeCastPredictions[playerEntity]
			if predictions then
				-- Clear any stale predictions for new target (ensures center-mass aim first)
				predictions[nearestValidTarget] = 0
			end
		end
	end
	
	return nearestValidTarget
end

-- Helper function to find model by path string
local function findModelByPath(modelPath: string): Model?
	if modelPath == nil then
		return nil
	end

	local current: Instance? = game
	for _, partName in ipairs(string.split(modelPath, ".")) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(partName)
	end

	if current and current:IsA("Model") then
		return current
	end

	return nil
end

-- Get the center position of an enemy for targeting
function AbilitySystemBase.getEnemyCenterPosition(enemyEntity: number): Vector3?
	if not world or not Components then
		warn("[AbilitySystemBase] Not initialized")
		return nil
	end
	
	local position = world:get(enemyEntity, Components.Position)
	if not position then
		return nil
	end

	local basePosition = Vector3.new(position.x, position.y, position.z)
	local entityType = world:get(enemyEntity, Components.EntityType)
	if not entityType or entityType.type ~= "Enemy" then
		return basePosition
	end

	local subtype = entityType.subtype or "Enemy"

	-- Prefer cached hitbox data from the replication service
	local hitboxData = ModelReplicationService.getEnemyHitbox(subtype)
	if hitboxData then
		return basePosition + hitboxData.offset
	end

	-- Attempt to replicate the enemy model to populate hitbox cache
	ModelReplicationService.replicateEnemy(subtype)
	hitboxData = ModelReplicationService.getEnemyHitbox(subtype)
	if hitboxData then
		return basePosition + hitboxData.offset
	end

	-- Fallback to inspecting the model directly if we have a visual path
	local visual = world:get(enemyEntity, Components.Visual)
	if visual and visual.modelPath then
		local model = findModelByPath(visual.modelPath)
		if model then
			local pivotPosition = model:GetPivot().Position
			if model.PrimaryPart then
				return basePosition + (model.PrimaryPart.Position - pivotPosition)
			end

			local hitboxPart = model:FindFirstChild("Hitbox")
			if hitboxPart and hitboxPart:IsA("BasePart") then
				return basePosition + (hitboxPart.Position - pivotPosition)
			end
		end
	end

	-- Final fallback: raise aim slightly above ground
	return basePosition + Vector3.new(0, 2, 0)
end

-- Helper function to check if player is grounded
local function isPlayerGrounded(player: Player?): boolean
	if not player then
		return false
	end
	
	local character = player.Character
	if not character then
		return false
	end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end
	
	-- Check if player is NOT in freefall state (freefall = airborne)
	local state = humanoid:GetState()
	return state ~= Enum.HumanoidStateType.Freefall and state ~= Enum.HumanoidStateType.Flying
end

-- Helper function to flatten direction vector to horizontal plane
local function flattenDirection(direction: Vector3, playerY: number): Vector3
	-- Keep only X and Z components, set Y to 0 relative to player position
	local flatDirection = Vector3.new(direction.X, 0, direction.Z)
	
	-- If direction was purely vertical, default to forward
	if flatDirection.Magnitude < 0.01 then
		return Vector3.new(0, 0, 1)
	end
	
	return flatDirection.Unit
end

-- Calculate targeting direction based on mode
function AbilitySystemBase.calculateTargetingDirection(
	playerPosition: Vector3,
	targetingMode: number,
	targetPosition: Vector3?,
	targetingStats: any?,
	stayHorizontal: boolean?,
	player: Player?,
	targetEntity: number?  -- NEW: Accept target entity to avoid re-lookup
): Vector3
	local direction: Vector3
	
	if targetingMode == 0 then
		-- Completely random direction (X, Y, Z all random)
		local angle = math.random() * math.pi * 2
		local yAngle = (math.random() * 2 - 1) * 0.5 -- Random Y angle between -0.5 and 0.5
		direction = Vector3.new(
			math.cos(angle),
			yAngle,
			math.sin(angle)
		).Unit

	elseif targetingMode == 1 then
		-- Random X/Z direction, but aim for closest enemy's Y position
		if targetPosition then
			-- Create random horizontal direction (normalized on X/Z plane)
			local angle = math.random() * math.pi * 2
			local horizontalDirection = Vector3.new(math.cos(angle), 0, math.sin(angle))
			
			-- Calculate horizontal distance and Y distance separately
			local horizontalDistance = Vector3.new(
				targetPosition.X - playerPosition.X,
				0,
				targetPosition.Z - playerPosition.Z
			).Magnitude
			
		-- If there's a horizontal distance, use it; otherwise use a default range
		if horizontalDistance < 1 then
			horizontalDistance = (targetingStats and targetingStats.targetingRange) or 100
		end
			
			-- Calculate Y component based on height difference
			local yDistance = targetPosition.Y - playerPosition.Y
			
			-- Build final direction: random horizontal + calculated vertical
			local finalDirection = horizontalDirection * horizontalDistance + Vector3.new(0, yDistance, 0)
			direction = finalDirection.Unit
		else
			-- Fallback to random horizontal direction
			local angle = math.random() * math.pi * 2
			direction = Vector3.new(
				math.cos(angle),
				0,
				math.sin(angle)
			).Unit
		end

	elseif targetingMode == 2 then
		-- Direct targeting with CONSERVATIVE prediction
		if targetPosition then
			local finalTargetPosition = targetPosition  -- Start with center position
			
			-- Only apply prediction if we have target entity and it's moving
			if targetEntity and world and Components and targetingStats and targetingStats.projectileSpeed then
				local targetVelocity = world:get(targetEntity, Components.Velocity)
				if targetVelocity then
					-- Calculate target speed
					local targetSpeed = math.sqrt(
						targetVelocity.x * targetVelocity.x + 
						targetVelocity.y * targetVelocity.y + 
						targetVelocity.z * targetVelocity.z
					)
					
					-- Only predict for moving targets (speed > threshold)
					if targetSpeed > MOVING_SPEED_THRESHOLD then
						local distance = (targetPosition - playerPosition).Magnitude
						local timeToTarget = distance / targetingStats.projectileSpeed
						
						-- CONSERVATIVE PREDICTION: Use 60% of predicted position (shorter lead)
						local predictedOffset = Vector3.new(
							targetVelocity.x * timeToTarget * PREDICTION_FACTOR,
							targetVelocity.y * timeToTarget * PREDICTION_FACTOR,
							targetVelocity.z * timeToTarget * PREDICTION_FACTOR
						)
						
						-- Limit prediction offset to reasonable bounds (max 10 studs lead)
						if predictedOffset.Magnitude > MAX_PREDICTION_OFFSET then
							predictedOffset = predictedOffset.Unit * MAX_PREDICTION_OFFSET
						end
						
						finalTargetPosition = targetPosition + predictedOffset
					else
						-- Target is slow/stationary, aim at center (no prediction)
						finalTargetPosition = targetPosition
					end
				end
			end
			
			direction = (finalTargetPosition - playerPosition).Unit
		else
			-- No target: fallback to player facing direction
			local character = player and player.Character
			local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
			if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
				direction = (humanoidRootPart :: BasePart).CFrame.LookVector
			else
				direction = Vector3.new(0, 0, 1)  -- Ultimate fallback
			end
		end

	else
		-- Mode 3 (homing) fallback to mode 2
		return AbilitySystemBase.calculateTargetingDirection(playerPosition, 2, targetPosition, targetingStats, stayHorizontal, player, targetEntity)
	end
	
	-- NEW: AlwaysStayHorizontal overrides stayHorizontal and works regardless of grounded state
	if targetingStats and targetingStats.AlwaysStayHorizontal then
		direction = flattenDirection(direction, playerPosition.Y)
	end
	
	-- Apply horizontal flattening if requested and player is grounded
	if stayHorizontal and isPlayerGrounded(player) then
		direction = flattenDirection(direction, playerPosition.Y)
	end
	
	return direction
end

-- Create a generic projectile for any ability
function AbilitySystemBase.createProjectile(
	abilityId: string,
	balance: any,
	spawnPosition: Vector3,
	direction: Vector3,
	owner: Player,
	targetPosition: Vector3
): number?
	if not world or not Components or not DirtyService or not ECSWorldService then
		warn("[AbilitySystemBase] Not initialized")
		return nil
	end
	
	-- Apply spawn offset relative to direction
	local spawnOffset = balance.spawnOffset or Vector3.new(0, 0, 0)
	local finalSpawnPosition = spawnPosition + spawnOffset

	-- Calculate velocity: direction * speed
	local velocity = direction * balance.projectileSpeed

	-- Ensure model is replicated before creating projectile
	if balance.modelPath then
		ModelReplicationService.replicateAbility(abilityId)
	end

	-- Determine travel time based on distance to target
	local distanceToTarget = (targetPosition - finalSpawnPosition).Magnitude
	local travelTime = balance.duration
	if balance.projectileSpeed > 0 then
		travelTime = math.max(distanceToTarget / balance.projectileSpeed, 0.01)
	end

	-- Create projectile using ECSWorldService
	local projectileStats = {
		damage = balance.damage,
		speed = balance.projectileSpeed,
		lifetime = balance.duration,
		radius = 1.0,
		gravity = 0
	}
	local entity = ECSWorldService.CreateProjectile(abilityId, finalSpawnPosition, velocity, owner, projectileStats)
	if not entity then
		-- Pool exhausted - queue projectile for later spawning
		if not projectileSpawnQueue[owner] then
			projectileSpawnQueue[owner] = {}
		end
		
		local queue = projectileSpawnQueue[owner]
		if #queue < MAX_QUEUE_SIZE_PER_PLAYER then
			table.insert(queue, {
				abilityId = abilityId,
				balance = balance,
				spawnPosition = finalSpawnPosition,
				direction = direction,
				targetPosition = targetPosition,
				timestamp = tick()
			})
		else
			-- Queue full - drop oldest projectile
			table.remove(queue, 1)
			table.insert(queue, {
				abilityId = abilityId,
				balance = balance,
				spawnPosition = finalSpawnPosition,
				direction = direction,
				targetPosition = targetPosition,
				timestamp = tick()
			})
			warn(string.format("[AbilitySystemBase] Spawn queue full for %s, dropped oldest projectile", owner.Name))
		end
		
		return nil  -- Return nil to indicate queued spawn
	end

	-- Update projectile data with ability-specific stats
	-- Explosion scale is MULTIPLICATIVE with projectile scale
	-- Config explosionScale (e.g., 2.5) is a multiplier RELATIVE to projectile size
	-- This ensures explosion inherits ALL scaling (upgrades, attributes, passives)
	local explosionScale = balance.explosionScale or 1.0
	
	-- CRITICAL: Check if explosionScale was already calculated by attribute (e.g., The Big One)
	-- If explosionScale is already larger than projectile scale, it's a final calculated value
	-- and shouldn't be multiplied again (to prevent double-scaling)
	local projectileScale = balance.scale or 1.0
	if explosionScale <= projectileScale * 2 then
		-- Normal case: explosionScale is a config multiplier, apply projectile scaling
		explosionScale = explosionScale * projectileScale
	end
	-- Else: explosionScale is pre-calculated (e.g., The Big One), use as-is
	
	-- Store scaled explosion damage (includes upgrades/passives)
	local explosionDamage = balance.explosionDamage or nil
	
	DirtyService.setIfChanged(world, entity, Components.ProjectileData, {
		type = abilityId,
		speed = balance.projectileSpeed,
		owner = owner,
		damage = balance.damage,
		gravity = 0,
		hasHit = false,
		stayHorizontal = balance.StayHorizontal or false,  -- Store for homing system
		alwaysStayHorizontal = balance.AlwaysStayHorizontal or false,  -- Y-lock at spawn
		stickToPlayer = balance.StickToPlayer or false,  -- Follow player X/Y/Z movement
		explosionScale = explosionScale,  -- Explosion scale (defaults to projectile scale)
		explosionDamage = explosionDamage,  -- Scaled explosion damage (includes upgrades/passives)
		startPosition = {
			x = finalSpawnPosition.X,
			y = finalSpawnPosition.Y,
			z = finalSpawnPosition.Z,
		},
		targetPosition = {
			x = targetPosition.X,
			y = targetPosition.Y,
			z = targetPosition.Z,
		},
		travelTime = travelTime,
	}, "ProjectileData")

	-- Set damage and piercing
	DirtyService.setIfChanged(world, entity, Components.Damage, { 
		amount = balance.damage, 
		type = "magic" 
	}, "Damage")

	DirtyService.setIfChanged(world, entity, Components.Piercing, { 
		remaining = 1 + (balance.penetration or 0),
		max = 1 + (balance.penetration or 0) 
	}, "Piercing")

	-- Set visual component with proper model path and scale
	if balance.modelPath then
		local visualData = { 
			modelPath = balance.modelPath,
			visible = true,
			scale = balance.scale or 1  -- Include scale for size upgrades
		}
		
		-- Add attribute color if present (for colored projectiles)
		if balance.attributeColor then
			visualData.color = balance.attributeColor
		end
		
		DirtyService.setIfChanged(world, entity, Components.Visual, visualData, "Visual")
	end

	-- Update collision radius based on actual hitbox size from model
	local baseCollisionRadius = 1.0  -- Fallback if no model/hitbox found
	
	if balance.modelPath then
		local hitboxSize = ModelHitboxHelper.getModelHitboxData(balance.modelPath)
		if hitboxSize then
			-- Use the largest horizontal dimension (X or Z) as the radius
			-- This matches how ProjectileCollisionSystem calculates collision
			baseCollisionRadius = math.max(hitboxSize.X, hitboxSize.Z) / 2
		end
	end
	
	-- Apply scale multiplier from size upgrades/passives
	local scaledCollisionRadius = baseCollisionRadius * (balance.scale or 1)
	
	DirtyService.setIfChanged(world, entity, Components.Collision, {
		radius = scaledCollisionRadius,
		solid = false
	}, "Collision")
	
	-- Set facing direction to the correct normalized direction
	local normalizedDirection = direction.Unit
	DirtyService.setIfChanged(world, entity, Components.FacingDirection, {
		x = normalizedDirection.X,
		y = normalizedDirection.Y,
		z = normalizedDirection.Z
	}, "FacingDirection")
	
	-- Add homing component if targetingMode = 3
	if balance.targetingMode == 3 then
		DirtyService.setIfChanged(world, entity, Components.Homing, {
			targetEntity = nil,  -- Will be acquired by HomingSystem on first update
			homingStrength = balance.homingStrength or 180,
			homingDistance = balance.homingDistance or 100,
			homingMaxAngle = balance.homingMaxAngle or 90,
			lastUpdateTime = 0,  -- Update immediately on first frame
		}, "Homing")
		
		-- Initialize HitTargets to track already-hit enemies
		DirtyService.setIfChanged(world, entity, Components.HitTargets, {
			targets = {}  -- Table of entity IDs that have been hit
		}, "HitTargets")
	end

	return entity
end

-- Check if player is alive (has character with humanoid > 0 health)
function AbilitySystemBase.isPlayerAlive(player: Player): boolean
	if not player or not player.Parent then
		return false
	end
	
	local character = player.Character
	if not character then
		return false
	end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	
	return true
end

-- Check if player is alive (has character with humanoid > 0 health)
function AbilitySystemBase.isPlayerAlive(player: Player): boolean
	if not player or not player.Parent then
		return false
	end
	
	local character = player.Character
	if not character then
		return false
	end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	
	return true
end

-- Get player position (prefers character position over ECS position)
function AbilitySystemBase.getPlayerPosition(playerEntity: number, player: Player): Vector3?
	if not world or not Components then
		warn("[AbilitySystemBase] Not initialized")
		return nil
	end
	
	local playerPositionComponent = world:get(playerEntity, Components.Position)
	if not playerPositionComponent then
		return nil
	end

	local character = player.Character
	if not character then
		return Vector3.new(playerPositionComponent.x, playerPositionComponent.y, playerPositionComponent.z)
	end
	
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
		return (humanoidRootPart :: BasePart).Position
	else
		return Vector3.new(playerPositionComponent.x, playerPositionComponent.y, playerPositionComponent.z)
	end
end

-- Process queued projectile spawns (call this from ability systems every frame)
function AbilitySystemBase.processSpawnQueue(dt: number)
	if not world or not Components or not ECSWorldService then
		return
	end
	
	-- Process up to QUEUE_PROCESS_RATE projectiles per frame
	local processed = 0
	
	for owner, queue in pairs(projectileSpawnQueue) do
		if not owner or not owner.Parent then
			-- Player disconnected, clear queue
			projectileSpawnQueue[owner] = nil
			continue
		end
		
		while #queue > 0 and processed < QUEUE_PROCESS_RATE do
			local queuedSpawn = table.remove(queue, 1)  -- Take oldest first (FIFO)
			
			-- Calculate velocity
			local velocity = queuedSpawn.direction * queuedSpawn.balance.projectileSpeed
			
			-- Try to spawn projectile again
			local projectileStats = {
				damage = queuedSpawn.balance.damage,
				speed = queuedSpawn.balance.projectileSpeed,
				lifetime = queuedSpawn.balance.duration,
				radius = 1.0,
				gravity = 0
			}
			
			local entity = ECSWorldService.CreateProjectile(
				queuedSpawn.abilityId,
				queuedSpawn.spawnPosition,
				velocity,
				owner,
				projectileStats
			)
			
			if entity then
				-- Successfully spawned from queue - configure it like normal spawn
				local balance = queuedSpawn.balance
				local explosionScale = balance.explosionScale or 1.0
				local projectileScale = balance.scale or 1.0
				if explosionScale <= projectileScale * 2 then
					explosionScale = explosionScale * projectileScale
				end
				
				DirtyService.setIfChanged(world, entity, Components.ProjectileData, {
					type = queuedSpawn.abilityId,
					speed = balance.projectileSpeed,
					owner = owner,
					damage = balance.damage,
					gravity = 0,
					hasHit = false,
					stayHorizontal = balance.StayHorizontal or false,
					alwaysStayHorizontal = balance.AlwaysStayHorizontal or false,
					stickToPlayer = balance.StickToPlayer or false,
					explosionScale = explosionScale,
					explosionDamage = balance.explosionDamage or nil,
					startPosition = {
						x = queuedSpawn.spawnPosition.X,
						y = queuedSpawn.spawnPosition.Y,
						z = queuedSpawn.spawnPosition.Z,
					},
					targetPosition = {
						x = queuedSpawn.targetPosition.X,
						y = queuedSpawn.targetPosition.Y,
						z = queuedSpawn.targetPosition.Z,
					},
					travelTime = 0,  -- Queue spawns don't have travel time
				}, "ProjectileData")
				
				DirtyService.setIfChanged(world, entity, Components.Damage, {
					amount = balance.damage,
					type = "magic"
				}, "Damage")
				
				DirtyService.setIfChanged(world, entity, Components.Piercing, {
					remaining = 1 + (balance.penetration or 0),
					max = 1 + (balance.penetration or 0)
				}, "Piercing")
				
				if balance.modelPath then
					local visualData = {
						modelPath = balance.modelPath,
						visible = true,
						scale = balance.scale or 1
					}
					DirtyService.setIfChanged(world, entity, Components.Visual, visualData, "Visual")
				end
				
				processed += 1
			else
				-- Still can't spawn, put it back at the front of queue
				table.insert(queue, 1, queuedSpawn)
				break  -- Stop processing this player's queue
			end
		end
		
		-- Clean up empty queues
		if #queue == 0 then
			projectileSpawnQueue[owner] = nil
		end
	end
end

-- Get spawn queue statistics (for debugging/monitoring)
function AbilitySystemBase.getSpawnQueueStats(): {total: number, perPlayer: {[string]: number}}
	local total = 0
	local perPlayer = {}
	
	for owner, queue in pairs(projectileSpawnQueue) do
		local count = #queue
		total += count
		perPlayer[owner.Name] = count
	end
	
	return {
		total = total,
		perPlayer = perPlayer
	}
end

return AbilitySystemBase
