--!strict
-- FireBall System - Handles auto-casting FireBall ability for players
-- Manages targeting, cooldowns, and projectile spawning

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AbilitySystemBase = require(script.Parent.Parent.AbilitySystemBase)
local Config = require(script.Parent.Config)
local Attributes = require(script.Parent.Attributes)
local Balance = Config  -- Backward compatibility alias

local AbilityCastRemote = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("AbilityCast")

local FireBallSystem = {}

local world: any
local Components: any
local DirtyService: any
local ECSWorldService: any

-- Component references
local Position: any
local EntityType: any
local AbilityData: any
local AbilityCooldown: any
local AbilityPulse: any
local AttributeSelections: any

-- FireBall constants
local FIREBALL_ID = "FireBall"
local FIREBALL_NAME = Balance.Name

local playerQuery: any
local projectileFacingQuery: any

-- Apply "The Big One" attribute scaling (combines all projectiles into one massive shot)
local function applyTheBigOneScaling(stats: any, playerEntity: number): any
	local attributeSelections = world:get(playerEntity, AttributeSelections)
	if not attributeSelections or attributeSelections[FIREBALL_ID] ~= "TheBigOne" then
		return stats
	end
	
	-- Calculate bonus based on projectile count (per increment above base)
	-- Examples: 1 projectile = 0 bonus, 2 projectiles = 1 bonus, 3 projectiles = 2 bonus
	local bonusCount = (stats.projectileCount - 1) + (stats.shotAmount - 1)
	
	-- Store the current values (includes upgrades/passives) before applying The Big One modifiers
	local baseScale = stats.scale or 1.0
	local baseDamage = stats.damage or 0
	local baseExplosionDamage = stats.explosionDamage or 0
	
	-- Apply projectile size scaling: +35% per bonus projectile
	stats.scale = baseScale * (1 + bonusCount * 0.35)
	
	-- Apply damage/duration scaling: +15% per bonus projectile
	stats.damage = baseDamage * (1 + bonusCount * 0.15)
	stats.explosionDamage = baseExplosionDamage * (1 + bonusCount * 0.15)
	stats.duration = stats.duration * (1 + bonusCount * 0.15)
	
	-- Apply explosion size scaling: +50% per bonus projectile
	-- Explosion inherits all projectile scaling (including passives + The Big One)
	-- then adds additional 50% per bonus projectile on top
	stats.explosionScale = stats.scale * (1 + bonusCount * 0.5)
	
	-- Apply penetration bonus: +1 per bonus projectile
	stats.penetration = stats.penetration + bonusCount
	
	-- Combine all into one projectile
	stats.projectileCount = 1
	stats.shotAmount = 1
	
	return stats
end

-- Spawn a burst of FireBall projectiles (handles shotgun spread)
local function spawnFireBallBurst(
	player: Player,
	position: Vector3,
	baseDirection: Vector3,
	targetPosition: Vector3,
	targetDistance: number,
	stats: any  -- Upgraded stats (from getAbilityStats)
): number
	local created = 0
	local shots = math.max(stats.shotAmount, 1)
	local totalSpread = math.min(math.abs(stats.targetingAngle) * 2, math.rad(10))
	local step = shots > 1 and totalSpread / (shots - 1) or 0
	local midpoint = (shots - 1) * 0.5

	for shotIndex = 1, shots do
		local direction = baseDirection

		if shots > 1 then
			-- Apply spread for shotgun pattern
			local offsetIndex = (shotIndex - 1) - midpoint
			local finalAngle = offsetIndex * step
			local cos = math.cos(finalAngle)
			local sin = math.sin(finalAngle)
			direction = Vector3.new(
				direction.X * cos - direction.Z * sin,
				direction.Y,
				direction.X * sin + direction.Z * cos
			)
		end

		if direction.Magnitude == 0 then
			direction = Vector3.new(0, 0, 1)
		end

		direction = direction.Unit

		-- Calculate target point for this projectile
		local targetPoint: Vector3
		if targetDistance > 0 then
			targetPoint = position + direction * targetDistance
		else
			targetPoint = position + direction * (stats.projectileSpeed * stats.duration)
		end

		-- Use shared projectile creation from base (with upgraded stats)
		-- Note: stats already contains attributeColor if an attribute is selected
		local projectileEntity = AbilitySystemBase.createProjectile(
			FIREBALL_ID,
			stats,  -- Pass upgraded stats (includes attributeColor from attribute)
			position,
			direction,
			player,
			targetPoint
		)
		
		if projectileEntity then
			created += 1
		end
	end

	return created
end

-- Perform a FireBall burst (finds target and spawns projectiles)
local function performFireBallBurst(playerEntity: number, player: Player): boolean
	-- Get player position (prefers character position)
	local position = AbilitySystemBase.getPlayerPosition(playerEntity, player)
	if not position then
		return false
	end
	
	-- Get upgraded stats for this player (includes ability upgrades + passive effects)
	local stats = AbilitySystemBase.getAbilityStats(playerEntity, FIREBALL_ID, Balance)
	
	-- Apply "The Big One" attribute scaling (must be done after getting stats)
	stats = applyTheBigOneScaling(stats, playerEntity)

	-- Find target using smart targeting if mode 2, otherwise nearest
	local targetEntity: number?
	if stats.targetingMode == 2 then
		targetEntity = AbilitySystemBase.findBestTarget(playerEntity, position, stats.targetingRange, stats.damage)
		-- Record predicted damage for this burst (direct hit + explosion)
		if targetEntity then
			local totalDamage = stats.damage
			if stats.hasExplosion then
				totalDamage = totalDamage + stats.explosionDamage
			end
			AbilitySystemBase.recordPredictedDamage(playerEntity, targetEntity, totalDamage)
		end
	else
		targetEntity = AbilitySystemBase.findNearestEnemy(position, stats.targetingRange)
	end
	
	local targetPosition: Vector3

	if targetEntity then
		local enemyPos = AbilitySystemBase.getEnemyCenterPosition(targetEntity)
		if enemyPos then
			targetPosition = enemyPos
		else
			targetPosition = position + Vector3.new(stats.targetingRange, 0, 0)
		end
	else
		-- No target found - behavior depends on targeting mode
		if stats.targetingMode < 2 then
			-- Random targeting modes (0, 1): fire in a random direction
			local angle = math.random() * math.pi * 2
			local randomDirection = Vector3.new(math.cos(angle), 0, math.sin(angle))
			targetPosition = position + randomDirection * stats.targetingRange
		else
			-- Direct targeting modes (2+): fire forward
			local character = player.Character
			local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
			if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
				targetPosition = position + (humanoidRootPart :: BasePart).CFrame.LookVector * stats.targetingRange
			else
				targetPosition = position + Vector3.new(stats.targetingRange, 0, 0)
			end
		end
	end

	-- Calculate direction based on targeting mode
	local targetDistance = (targetPosition - position).Magnitude
	local baseDirection = AbilitySystemBase.calculateTargetingDirection(
		position,
		stats.targetingMode,
		targetPosition,
		stats,
		stats.StayHorizontal,
		player,
		targetEntity  -- NEW: Pass selected target entity
	)

	local created = spawnFireBallBurst(player, position, baseDirection, targetPosition, targetDistance, stats)
	return created > 0
end

-- Spawn a single Fire Storm projectile at a random orbit position
local function spawnFireStormProjectile(playerEntity: number, player: Player, stats: any): boolean
	local position = AbilitySystemBase.getPlayerPosition(playerEntity, player)
	if not position then
		return false
	end
	
	-- Pick random angle around player (0-360°)
	local angleRadians = math.random() * math.pi * 2
	
	-- Get Fire Storm special settings from Attributes
	local fireStormData = Attributes.FireStorm
	local baseRadius = (fireStormData and fireStormData.special and fireStormData.special.orbitRadius) or 15
	local variance = (fireStormData and fireStormData.special and fireStormData.special.orbitRadiusVariance) or 5
	
	-- Random orbit radius (base ± variance)
	-- Creates a radius ring instead of perfect circle
	local orbitRadius = baseRadius + (math.random() * variance * 2 - variance)
	
	-- Calculate spawn position (orbit around player)
	local spawnOffset = Vector3.new(
		math.cos(angleRadians) * orbitRadius,
		0,
		math.sin(angleRadians) * orbitRadius
	)
	local spawnPosition = position + spawnOffset
	
	-- Direction is tangent to circle (clockwise)
	-- Perpendicular to radius = (-sin, 0, cos) for clockwise rotation
	local direction = Vector3.new(-math.sin(angleRadians), 0, math.cos(angleRadians)).Unit
	
	-- Target point for projectile (continues in tangent direction)
	local targetPoint = spawnPosition + direction * (stats.projectileSpeed * stats.duration)
	
	-- Create projectile with orbit behavior
	-- Note: stats already contains attributeColor from Fire Storm attribute
	local projectileEntity = AbilitySystemBase.createProjectile(
		FIREBALL_ID,
		stats,
		spawnPosition,
		direction,
		player,
		targetPoint
	)
	
	if projectileEntity then
		-- Get orbit speed from Fire Storm attributes
		local orbitSpeed = (fireStormData and fireStormData.special and fireStormData.special.orbitSpeed) or 120
		
		-- Add orbit component to make projectile actively orbit around player
		DirtyService.setIfChanged(world, projectileEntity, Components.ProjectileOrbit, {
			ownerEntity = playerEntity,
			orbitRadius = orbitRadius,
			orbitSpeed = orbitSpeed,
			currentAngle = angleRadians,
		}, "ProjectileOrbit")
		
		-- CRITICAL: Set velocity to zero so MovementSystem doesn't move the projectile
		-- ProjectileOrbitSystem will handle all position updates
		DirtyService.setIfChanged(world, projectileEntity, Components.Velocity, {
			x = 0,
			y = 0,
			z = 0,
		}, "Velocity")
	end
	
	return projectileEntity ~= nil
end

-- Cast FireBall ability (handles initial cast and multi-shot setup)
local function castFireBall(playerEntity: number, player: Player): boolean
	-- Get upgraded stats
	local stats = AbilitySystemBase.getAbilityStats(playerEntity, FIREBALL_ID, Balance)
	
	-- Apply "The Big One" attribute scaling
	stats = applyTheBigOneScaling(stats, playerEntity)
	
	-- Check for Fire Storm attribute
	local attributeSelections = world:get(playerEntity, AttributeSelections)
	local hasFireStorm = attributeSelections and attributeSelections[FIREBALL_ID] == "FireStorm"
	
	-- Start prediction tracking for smart multi-targeting
	AbilitySystemBase.startCastPrediction(playerEntity)
	
	local success: boolean
	
	if hasFireStorm then
		-- Fire Storm: spawn single projectile at random orbit position
		success = spawnFireStormProjectile(playerEntity, player, stats)
		
		-- Setup continuous spawning using pulse system
		if success and stats.projectileCount > 1 then
			local interval = math.max(stats.pulseInterval or 0, 0.01)
			local pulseData = {
				ability = FIREBALL_ID,
				remaining = stats.projectileCount - 1,
				timer = interval,
				interval = interval,
				isFireStorm = true,  -- Flag to identify Fire Storm pulse
			}
			DirtyService.setIfChanged(world, playerEntity, AbilityPulse, pulseData, "AbilityPulse")
		else
			AbilitySystemBase.endCastPrediction(playerEntity)
		end
	else
		-- Normal casting
		success = performFireBallBurst(playerEntity, player)

		if success and stats.projectileCount > 1 then
			-- Setup multi-shot pulse (predictions will persist through pulse)
			local interval = math.max(stats.pulseInterval or 0, 0.01)
			local pulseData = {
				ability = FIREBALL_ID,
				remaining = stats.projectileCount - 1,
				timer = interval,
				interval = interval,
			}
			DirtyService.setIfChanged(world, playerEntity, AbilityPulse, pulseData, "AbilityPulse")
		else
			-- Single shot cast, end prediction immediately
			AbilitySystemBase.endCastPrediction(playerEntity)
		end
	end

	return success
end

-- Initialize the system
function FireBallSystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService

	-- Initialize base system with shared references
	AbilitySystemBase.init(worldRef, components, dirtyService, ecsWorldService)

	-- Get component references
	Position = Components.Position
	EntityType = Components.EntityType
	AbilityData = Components.AbilityData
	AbilityCooldown = Components.AbilityCooldown
	AbilityPulse = Components.AbilityPulse
	AttributeSelections = Components.AttributeSelections

	playerQuery = world:query(Components.EntityType, Components.Position, Components.Ability):cached()
	projectileFacingQuery = world:query(Components.Projectile, Components.Velocity, Components.ProjectileData):cached()
end

-- Step function (called every frame)
function FireBallSystem.step(dt: number)
	if not world then
		return
	end

	-- Query all players with FireBall ability
	for entity, entityType, position, ability in playerQuery do
		if entityType.type == "Player" and entityType.player then
			local player = entityType.player
			
			-- Don't cast abilities if player is dead
			if not AbilitySystemBase.isPlayerAlive(player) then
				continue
			end
			
			-- Skip cooldown updates if player has frozen cooldowns (individual pause)
			local cooldownsFrozen = player:GetAttribute("CooldownsFrozen")
			if cooldownsFrozen then
				continue
			end

			local abilityData = world:get(entity, AbilityData)
			-- Check if player has FireBall ability enabled
			if abilityData and abilityData.abilities and abilityData.abilities[FIREBALL_ID] 
				and abilityData.abilities[FIREBALL_ID].enabled then
				-- Handle multi-shot pulse
				local pulseComponent = world:get(entity, AbilityPulse)
				if pulseComponent and pulseComponent.ability == FIREBALL_ID then
					local stats = AbilitySystemBase.getAbilityStats(entity, FIREBALL_ID, Balance)
					
					-- Apply "The Big One" scaling for stats calculation
					stats = applyTheBigOneScaling(stats, entity)
					
					local interval = (pulseComponent.interval or stats.pulseInterval or 0)
					local timer = 0
					local remaining = pulseComponent.remaining or 0
					local isFireStorm = pulseComponent.isFireStorm or false

					if interval <= 0 then
						-- Fire all remaining shots immediately
						while remaining > 0 do
							local shotSuccess: boolean
							if isFireStorm then
								shotSuccess = spawnFireStormProjectile(entity, player, stats)
							else
								shotSuccess = performFireBallBurst(entity, player)
							end
							
							if shotSuccess then
								remaining -= 1
							else
								remaining = 0
							end
						end
					else
						-- Fire shots with interval timing
						local actualInterval = math.max(interval, 0.01)
						timer = (pulseComponent.timer or actualInterval) - dt
						while remaining > 0 and timer <= 0 do
							local shotSuccess: boolean
							if isFireStorm then
								shotSuccess = spawnFireStormProjectile(entity, player, stats)
							else
								shotSuccess = performFireBallBurst(entity, player)
							end
							
							if shotSuccess then
								remaining -= 1
								timer += actualInterval
							else
								remaining = 0
							end
						end
						interval = actualInterval
					end

					-- Update or remove pulse component
					if remaining <= 0 then
						world:remove(entity, AbilityPulse)
						pulseComponent = nil
						-- End prediction tracking when cast completes
						AbilitySystemBase.endCastPrediction(entity)
					else
						local newPulse = {
							ability = FIREBALL_ID,
							timer = timer,
							remaining = remaining,
							interval = interval,
							isFireStorm = isFireStorm,
						}
						DirtyService.setIfChanged(world, entity, AbilityPulse, newPulse, "AbilityPulse")
						pulseComponent = newPulse
					end
				end

				-- Check if pulse is still active
				pulseComponent = world:get(entity, AbilityPulse)
				local pulseActive = pulseComponent and pulseComponent.ability == FIREBALL_ID

				-- Handle cooldown for this ability
				-- Get upgraded stats for cooldown
				local stats = AbilitySystemBase.getAbilityStats(entity, FIREBALL_ID, Balance)
				
				-- Apply "The Big One" scaling (affects cooldown)
				stats = applyTheBigOneScaling(stats, entity)
				
				local cooldownData = world:get(entity, AbilityCooldown)
				local cooldowns = cooldownData and cooldownData.cooldowns or {}
				local cooldown = cooldowns[FIREBALL_ID] or { remaining = 0, max = stats.cooldown }
				
			-- Cast ability when cooldown is ready and no pulse active
			if cooldown.remaining <= 0 and not pulseActive then
				local success = castFireBall(entity, player)
				if success then
				-- Get damage stats for animation priority
				local damageStats = world:get(entity, Components.AbilityDamageStats) or {}
				
				-- Get animation config from Config (if it exists)
				local animationData = nil
				if Config.animations then
					animationData = {
						animationIds = Config.animations.animationIds,
						loopFrame = Config.animations.loopFrame,
						totalFrames = Config.animations.totalFrames,
						duration = Config.animations.duration,
						animationPriority = Config.animations.animationPriority,
					}
				end
					
					-- Notify client of ability cast with animation data
					AbilityCastRemote:FireClient(player, FIREBALL_ID, stats.cooldown, FIREBALL_NAME, {
						projectileCount = stats.projectileCount or 1,
						pulseInterval = stats.pulseInterval or 0,
						damageStats = damageStats,
						animationData = animationData,  -- Send all animation config from server
					})
					
					-- Update this ability's cooldown
					cooldowns[FIREBALL_ID] = {
						remaining = stats.cooldown,
						max = stats.cooldown,
					}
					DirtyService.setIfChanged(world, entity, AbilityCooldown, {
						cooldowns = cooldowns
					}, "AbilityCooldown")
				end
			else
					-- Update cooldown timer
					cooldowns[FIREBALL_ID] = {
						remaining = math.max((cooldown.remaining or 0) - dt, 0),
						max = cooldown.max or stats.cooldown,
					}
					DirtyService.setIfChanged(world, entity, AbilityCooldown, {
						cooldowns = cooldowns
					}, "AbilityCooldown")
				end
			end
		end
	end

	-- Update facing direction for FireBall projectiles
	for projectileEntity, projectile, velocity, projectileData in projectileFacingQuery do
		if projectileData.type == FIREBALL_ID then
			DirtyService.setIfChanged(world, projectileEntity, Components.FacingDirection, {
				x = velocity.x,
				y = velocity.y,
				z = velocity.z
			}, "FacingDirection")
		end
	end
end

return FireBallSystem
