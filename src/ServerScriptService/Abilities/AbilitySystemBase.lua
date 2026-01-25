--!strict
-- AbilitySystemBase.lua - Shared utilities for all ability systems
-- Contains common targeting, spawning, and helper functions

local _ReplicatedStorage = game:GetService("ReplicatedStorage")
local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local SpatialGridSystem = require(game.ServerScriptService.ECS.Systems.SpatialGridSystem)
local ModelHitboxHelper = require(game.ServerScriptService.Utilities.ModelHitboxHelper)
local ProjectileService = require(game.ServerScriptService.Services.ProjectileService)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
local UpgradeDefs = require(game.ServerScriptService.Balance.Upgrades.UpgradeDefs)

-- Targeting prediction tuning
local PREDICTION_FACTOR = 0.6  -- Used only when targetingStats.enablePrediction is true.
local MOVING_SPEED_THRESHOLD = 5  -- studs/sec - below this, aim at center
local MAX_PREDICTION_OFFSET = 10  -- studs - cap prediction lead distance
local TARGETABLE_SPAWN_DELAY = 0.6 -- seconds after spawn before enemies are eligible to target (matches fade-in)
local HORIZONTAL_AIM_Y_DIFF = 1.5 -- allow vertical aim if target is significantly above/below player

local AbilitySystemBase = {}

-- Shared references (initialized by each system)
local world: any = nil
local Components: any = nil
local DirtyService: any = nil
local ECSWorldService: any = nil

local playerEntityQuery: any
local playerEntityCache: {[Player]: number} = setmetatable({}, { __mode = "k" })

-- Virtual damage tracking for smart multi-targeting
-- Structure: {playerEntity: {enemyEntity: predictedDamageTaken}}
local activeCastPredictions: {[number]: {[number]: number}} = {}

-- Current target tracking for target stickiness
-- Structure: {playerEntity: enemyEntity}
local currentCastTargets: {[number]: number} = {}
local pendingTargetSwitchUntil: {[number]: number} = {}
local pendingTargetId: {[number]: number} = {}

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

local function isEnemyTargetable(enemyEntity: number, currentTime: number): boolean
	if not world or not Components then
		return true
	end
	local spawnTime = world:get(enemyEntity, Components.SpawnTime)
	if not spawnTime or typeof(spawnTime.time) ~= "number" then
		return true
	end
	return (currentTime - spawnTime.time) >= TARGETABLE_SPAWN_DELAY
end

-- Initialize base with ECS references
function AbilitySystemBase.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService
	ensureEnemyQuery()
	playerEntityQuery = world:query(Components.PlayerStats):cached()
end

local function resolvePlayerEntity(player: Player): number?
	local cached = playerEntityCache[player]
	if cached and world and world:contains(cached) then
		return cached
	end
	if not playerEntityQuery then
		return nil
	end
	for entity, stats in playerEntityQuery do
		if stats and stats.player == player then
			playerEntityCache[player] = entity
			return entity
		end
	end
	return nil
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

		-- Apply penetration multiplier (rounded for integer penetration)
		if stats.penetration and passiveEffects.penetrationMultiplier then
			stats.penetration = math.max(0, math.floor(stats.penetration * passiveEffects.penetrationMultiplier + 0.0001))
		end

		-- Apply projectile count bonus (cap at 5x base)
		if stats.projectileCount and passiveEffects.projectileCountBonus then
			local baseCount = baseBalance.projectileCount or stats.projectileCount
			local maxCount = math.floor(baseCount * UpgradeDefs.SoftCaps.countMaxMultiplier + 0.0001)
			stats.projectileCount = math.min(maxCount, math.floor(stats.projectileCount + passiveEffects.projectileCountBonus + 0.0001))
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
	local currentTime = GameTimeSystem.getGameTime()

	for _, entity in ipairs(candidates) do
		local entityType = world:get(entity, Components.EntityType)
		if entityType and entityType.type == "Enemy" then
			if not isEnemyTargetable(entity, currentTime) then
				continue
			end
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
	_damageAmount: number
): number?
	if not world or not Components then
		warn("[AbilitySystemBase] Not initialized")
		return nil
	end

	-- Prefer current target when valid; delay switching briefly when a target is predicted to die.
	local nearestValidTarget: number? = nil
	local nearestDistance = math.huge
	local candidates = gatherEnemyCandidates(playerPosition, maxRange)
	local now = tick()
	local currentTime = GameTimeSystem.getGameTime()
	local currentTarget = currentCastTargets[playerEntity]

	if currentTarget and world:contains(currentTarget) then
		if not isEnemyTargetable(currentTarget, currentTime) then
			currentTarget = nil
			currentCastTargets[playerEntity] = nil
			pendingTargetSwitchUntil[playerEntity] = nil
			pendingTargetId[playerEntity] = nil
		end
	end

	if currentTarget and world:contains(currentTarget) then
		local position = world:get(currentTarget, Components.Position)
		if position then
			local ecsPosition = Vector3.new(position.x, position.y, position.z)
			local distance = (ecsPosition - playerPosition).Magnitude
			if distance <= maxRange then
				local health = world:get(currentTarget, Components.Health)
				local predictedDamage = AbilitySystemBase.getPredictedDamage(playerEntity, currentTarget)
				if health and health.current > predictedDamage then
					-- Keep current target while it's still alive and in range.
					pendingTargetSwitchUntil[playerEntity] = nil
					pendingTargetId[playerEntity] = nil
					return currentTarget
				elseif health and health.current <= predictedDamage then
					local pendingId = pendingTargetId[playerEntity]
					local pendingUntil = pendingTargetSwitchUntil[playerEntity]
					if pendingId ~= currentTarget or not pendingUntil then
						pendingTargetId[playerEntity] = currentTarget
						pendingTargetSwitchUntil[playerEntity] = now + 0.08
					end
					if pendingTargetSwitchUntil[playerEntity] and now < pendingTargetSwitchUntil[playerEntity] then
						return currentTarget
					end
				else
					pendingTargetSwitchUntil[playerEntity] = nil
					pendingTargetId[playerEntity] = nil
				end
			end
		end
	end

	for _, entity in ipairs(candidates) do
		local entityType = world:get(entity, Components.EntityType)
		if entityType and entityType.type == "Enemy" then
			if not isEnemyTargetable(entity, currentTime) then
				continue
			end
			local health = world:get(entity, Components.Health)
			local position = world:get(entity, Components.Position)
			if health and position then
				local predictedDamage = AbilitySystemBase.getPredictedDamage(playerEntity, entity)
				-- Skip enemies predicted to die from previously fired shots.
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

	-- If all enemies are predicted to die, fall back to nearest enemy anyway.
	if not nearestValidTarget then
		nearestValidTarget = AbilitySystemBase.findNearestEnemy(playerPosition, maxRange)
	end

	if nearestValidTarget then
		currentCastTargets[playerEntity] = nearestValidTarget
		pendingTargetSwitchUntil[playerEntity] = nil
		pendingTargetId[playerEntity] = nil
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

	-- Aim at the entity position used for collision to avoid lateral offsets.
	return basePosition
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

function AbilitySystemBase.getTargetDistance(
	playerPosition: Vector3,
	targetPosition: Vector3,
	stayHorizontal: boolean?,
	alwaysStayHorizontal: boolean?,
	player: Player?
): number
	if alwaysStayHorizontal or (stayHorizontal and isPlayerGrounded(player)) then
		local dx = targetPosition.X - playerPosition.X
		local dz = targetPosition.Z - playerPosition.Z
		return math.sqrt(dx * dx + dz * dz)
	end
	return (targetPosition - playerPosition).Magnitude
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
			local finalTargetPosition = targetPosition

			-- Prediction is opt-in to avoid overshooting fast or small targets.
			if targetingStats and targetingStats.enablePrediction and targetEntity and world and Components and targetingStats.projectileSpeed then
				local targetVelocity = world:get(targetEntity, Components.Velocity)
				if targetVelocity then
					local targetSpeed = math.sqrt(
						targetVelocity.x * targetVelocity.x +
						targetVelocity.y * targetVelocity.y +
						targetVelocity.z * targetVelocity.z
					)
					if targetSpeed > MOVING_SPEED_THRESHOLD then
						local distance = (targetPosition - playerPosition).Magnitude
						local timeToTarget = distance / targetingStats.projectileSpeed
						local predictedOffset = Vector3.new(
							targetVelocity.x * timeToTarget * PREDICTION_FACTOR,
							targetVelocity.y * timeToTarget * PREDICTION_FACTOR,
							targetVelocity.z * timeToTarget * PREDICTION_FACTOR
						)
						if predictedOffset.Magnitude > MAX_PREDICTION_OFFSET then
							predictedOffset = predictedOffset.Unit * MAX_PREDICTION_OFFSET
						end
						finalTargetPosition = targetPosition + predictedOffset
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
		local shouldFlatten = true
		if targetPosition then
			local yDiff = math.abs(targetPosition.Y - playerPosition.Y)
			if yDiff > HORIZONTAL_AIM_Y_DIFF then
				shouldFlatten = false
			end
		end
		if shouldFlatten then
			direction = flattenDirection(direction, playerPosition.Y)
		end
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
	targetPosition: Vector3,
	ownerEntityOverride: number?,
	extraConfig: any?
): number?
	if not world or not Components or not DirtyService or not ECSWorldService then
		warn("[AbilitySystemBase] Not initialized")
		return nil
	end
	
	-- Apply spawn offset relative to direction
	local spawnOffset = balance.spawnOffset or Vector3.new(0, 0, 0)
	local finalSpawnPosition = spawnPosition + spawnOffset

	-- Ensure model is replicated before creating projectile
	if balance.modelPath then
		ModelReplicationService.replicateAbility(abilityId)
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

	local ownerEntity = ownerEntityOverride or resolvePlayerEntity(owner)
	local homing = nil
	if balance.targetingMode == 3 then
		homing = {
			strengthDeg = balance.homingStrength or 180,
			maxAngleDeg = balance.homingMaxAngle or 90,
			acquireRadius = balance.homingDistance or 100,
			stayHorizontal = balance.StayHorizontal or false,
			alwaysStayHorizontal = balance.AlwaysStayHorizontal or false,
		}
	end

	local aoe = nil
	if balance.hasExplosion then
		local explosionScale = balance.explosionScale or 1.0
		local projectileScale = balance.scale or 1.0
		if explosionScale <= projectileScale * 2 then
			explosionScale = explosionScale * projectileScale
		end

		local explosionModelPath = balance.explosionModelPath
		local explosionClientPath = explosionModelPath
		if typeof(explosionModelPath) == "string" and explosionModelPath:sub(1, #"ServerStorage.") == "ServerStorage." then
			local serverPath = explosionModelPath:sub(#"ServerStorage." + 1)
			local parts = string.split(serverPath, ".")
			if #parts > 1 then
				table.remove(parts, #parts)
				local replicatedPath = table.concat(parts, ".")
				ModelReplicationService.replicateModel(serverPath, replicatedPath)
			end
			explosionClientPath = "ReplicatedStorage." .. serverPath
		end
		local explosionRadius = 10
		if explosionModelPath then
			local hitboxSize = ModelHitboxHelper.getModelHitboxData(explosionModelPath)
			if hitboxSize then
				local baseRadius = math.max(hitboxSize.X, hitboxSize.Y, hitboxSize.Z) / 2
				explosionRadius = baseRadius * explosionScale
			end
		end

		aoe = {
			radius = explosionRadius,
			damage = balance.explosionDamage or 0,
			trigger = "hit",
			triggerOnExpire = true,
			delay = balance.explosionDelay or 0,
			duration = balance.explosionDuration or 0.5,
			tickInterval = balance.explosionTickInterval or 0,
			modelPath = explosionClientPath,
			scale = explosionScale,
		}
	end

	local payload = {
		kind = abilityId,
		origin = finalSpawnPosition,
		direction = direction,
		speed = balance.projectileSpeed,
		damage = balance.damage,
		radius = scaledCollisionRadius,
		lifetime = balance.duration,
		ownerEntity = ownerEntity,
		pierce = balance.penetration,
		modelPath = balance.modelPath,
		visualScale = balance.scale or 1,
		visualColor = balance.attributeColor,
		homing = homing,
		aoe = aoe,
		hitCooldown = balance.hitCooldown or 0.04,
		stayHorizontal = balance.StayHorizontal or false,
		alwaysStayHorizontal = balance.AlwaysStayHorizontal or false,
		stickToPlayer = balance.StickToPlayer or false,
	}

	if extraConfig and type(extraConfig) == "table" then
		for key, value in pairs(extraConfig) do
			payload[key] = value
		end
	end

	return ProjectileService.spawnProjectile(payload)
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
	return
end

-- Get spawn queue statistics (for debugging/monitoring)
function AbilitySystemBase.getSpawnQueueStats(): {total: number, perPlayer: {[string]: number}}
	return {
		total = 0,
		perPlayer = {},
	}
end

return AbilitySystemBase
