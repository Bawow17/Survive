--!strict
-- DamageSystem - Centralized damage application with hit feedback, knockback, and death handling
-- Manages all damage sources and applies consistent visual/physics effects

local DamageSystem = {}

local world: any
local Components: any
local DirtyService: any
local EnemyExpDropSystem: any  -- Reference to enemy drop system
local StatusEffectSystem: any  -- Reference to status effect system
local OverhealSystem: any  -- Reference to overheal system

-- Component references
local Health: any
local Position: any
local EntityType: any
local HitFlash: any
local Knockback: any
local DeathAnimation: any

local damageAttemptCount = 0
local damageAppliedCount = 0
local DEBUG_DAMAGE_LOGS = false

-- Configuration
local HIT_FLASH_DURATION = 0.15  -- Increased from 0.2 to 0.15 for snappier response
local KNOCKBACK_MIN_DISTANCE = 1 -- Minimum knockback distance
local KNOCKBACK_MAX_DISTANCE = 2.5 -- Maximum knockback distance
local KNOCKBACK_DURATION = 0.2

-- OPTIMIZATION PHASE 3: Ensure HitFlash plays before death fade
-- Buffer time between HitFlash end and death fade start
local DEATH_ANIMATION_BUFFER = 0.05  -- 50ms buffer for client to render HitFlash

function DamageSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	Health = Components.Health
	Position = Components.Position
	EntityType = Components.EntityType
	HitFlash = Components.HitFlash
	Knockback = Components.Knockback
	DeathAnimation = Components.DeathAnimation
end

-- Set EnemyExpDropSystem reference (called after it's initialized)
function DamageSystem.setEnemyExpDropSystem(enemyExpDropSystem: any)
	EnemyExpDropSystem = enemyExpDropSystem
end

-- Set StatusEffectSystem reference (called after it's initialized)
function DamageSystem.setStatusEffectSystem(statusEffectSystem: any)
	StatusEffectSystem = statusEffectSystem
end

-- Set OverhealSystem reference (called after it's initialized)
function DamageSystem.setOverhealSystem(overhealSystem: any)
	OverhealSystem = overhealSystem
end

-- Find the closest player to a given position
local function findClosestPlayer(position: Vector3): Player?
	local Players = game:GetService("Players")
	local closestPlayer: Player? = nil
	local closestDistance = math.huge
	
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character then
			local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
			if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
				local distance = (humanoidRootPart.Position - position).Magnitude
				if distance < closestDistance then
					closestDistance = distance
					closestPlayer = player
				end
			end
		end
	end
	
	return closestPlayer
end

-- Apply damage to an entity with all feedback effects
-- sourceEntity: optional player entity that dealt the damage (for ability tracking)
-- abilityId: optional ability identifier (for damage stat tracking)
function DamageSystem.applyDamage(targetEntity: number, damageAmount: number, damageType: string, sourceEntity: number?, abilityId: string?): boolean
	if not world or not targetEntity then
		return false, false
	end
	damageAttemptCount += 1
	
	-- Check invincibility
	if StatusEffectSystem and StatusEffectSystem.hasInvincibility(targetEntity) then
		return false, false  -- Damage blocked by invincibility
	end
	
	-- Get entity type to determine if this is a player or enemy
	local entityType = world:get(targetEntity, EntityType)
	local isPlayer = entityType and entityType.type == "Player"
	local isEnemy = entityType and entityType.type == "Enemy"
	
	-- CRITICAL: Check if player is Shield Bashing - absorb ALL damage and prevent death
	if isPlayer then
		local MobilitySystem = require(game.ServerScriptService.ECS.Systems.MobilitySystem)
		if MobilitySystem and MobilitySystem.absorbShieldBashDamage then
			local absorbed = MobilitySystem.absorbShieldBashDamage(targetEntity, damageAmount)
			if absorbed then
				return false, false  -- Damage absorbed by Shield Bash, will be healed at end
			end
		end
	end
	
	-- Prevent damage to dead players
	if isPlayer then
		local pauseState = world:get(targetEntity, Components.PlayerPauseState)
		if pauseState and pauseState.pauseReason == "death" then
			return false, false  -- Dead players cannot take damage
		end
	end
	
	-- Track ability damage for player sources (only count damage to enemies)
	if sourceEntity and abilityId and isEnemy then
		local sourceEntityType = world:get(sourceEntity, EntityType)
		local isPlayerSource = sourceEntityType and sourceEntityType.type == "Player"
		
		if isPlayerSource then
			local damageStats = world:get(sourceEntity, Components.AbilityDamageStats)
			if not damageStats then
				damageStats = {}
			end
			
			-- Accumulate damage for this ability
			damageStats[abilityId] = (damageStats[abilityId] or 0) + damageAmount
			DirtyService.setIfChanged(world, sourceEntity, Components.AbilityDamageStats, damageStats, "AbilityDamageStats")
		end
	end
	
	-- Track session damage for player sources (damage to enemies)
	if sourceEntity and isEnemy then
		local sourceEntityType = world:get(sourceEntity, EntityType)
		local isPlayerSource = sourceEntityType and sourceEntityType.type == "Player"
		
		if isPlayerSource then
			local SessionStatsTracker = require(game.ServerScriptService.ECS.Systems.SessionStatsTracker)
			SessionStatsTracker.trackDamage(sourceEntity, damageAmount)
		end
	end
	
	-- Get health component
	local health = world:get(targetEntity, Health)
	if not health then
		return false, false
	end
	
	-- Apply damage to overheal first (for players)
	local remainingDamage = damageAmount
	if isPlayer and OverhealSystem then
		remainingDamage = OverhealSystem.damageOverheal(targetEntity, damageAmount)
	end
	
	-- Apply remaining damage to ECS health
	local newHealth = math.max(health.current - remainingDamage, 0)
	local died = newHealth <= 0
	
	-- CUSTOM DEATH: Check if player died (< 0.0001 HP)
	if isPlayer and newHealth <= 0.0001 then
		local playerStats = world:get(targetEntity, Components.PlayerStats)
		if playerStats and playerStats.player then
			-- Trigger custom death system
			local DeathSystem = require(game.ServerScriptService.ECS.Systems.DeathSystem)
			DeathSystem.triggerPlayerDeath(targetEntity, playerStats.player)
			
			-- Clamp health to 0.01 to prevent Roblox death
			newHealth = 0.01
			
			-- Update humanoid health to 0.01 (prevents Roblox death/respawn)
			local character = playerStats.player.Character
			if character then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid.Health = 0.01
				end
			end
			
			return true  -- Player entered death state
		end
	end
	
	-- Update ECS health (clamped to 0.01 minimum for players)
	local applied = newHealth ~= health.current
	if applied then
		damageAppliedCount += 1
	end
	DirtyService.setIfChanged(world, targetEntity, Health, {
		current = newHealth,
		max = health.max
	}, "Health")
	
	-- CRITICAL: If target is a player, also damage the Roblox Humanoid
	-- ONLY if actual health was damaged (not if overheal absorbed all damage)
	if isPlayer and remainingDamage > 0 and newHealth > 0.01 then
		-- COMPREHENSIVE DEBUG: Log what damaged the player
		local sourceType = "Unknown"
		local sourceName = "None"
		local sourcePosition = "Unknown"
		
		if sourceEntity then
			local sourceEntityType = world:get(sourceEntity, EntityType)
			if sourceEntityType then
				sourceType = sourceEntityType.type
				if sourceType == "Enemy" then
					sourceName = sourceEntityType.subtype or "Unknown Enemy"
					
					-- Check if enemy has visual
					local visual = world:get(sourceEntity, Components.Visual)
					if not visual or not visual.modelPath then
						sourceName = sourceName .. " (INVISIBLE - NO VISUAL)"
					end
				elseif sourceType == "Projectile" then
					local projData = world:get(sourceEntity, Components.ProjectileData)
					sourceName = projData and projData.type or "Unknown Projectile"
				end
			end
			
			local sourcePos = world:get(sourceEntity, Components.Position)
			if sourcePos then
				sourcePosition = string.format("(%.1f, %.1f, %.1f)", sourcePos.x, sourcePos.y, sourcePos.z)
			end
		end
		
		-- Get player info
		local playerStats = world:get(targetEntity, Components.PlayerStats)
		local playerName = playerStats and playerStats.player and playerStats.player.Name or "Unknown"

		if DEBUG_DAMAGE_LOGS then
			if sourceEntity and world:has(sourceEntity, Components.EntityType) then
				local sourceEntityType = world:get(sourceEntity, Components.EntityType)
				if sourceEntityType and sourceEntityType.type == "Enemy" then
					local sourcePos = world:get(sourceEntity, Components.Position)
					local targetPos = world:get(targetEntity, Components.Position)
					local distance = 0
					if sourcePos and targetPos then
						distance = math.sqrt((sourcePos.x - targetPos.x)^2 + (sourcePos.y - targetPos.y)^2 + (sourcePos.z - targetPos.z)^2)
					end
					print(string.format(
						"[DamageSystem] ENEMY ATTACK | %s took %.1f dmg | Enemy#%d | HP: %.1f->%.1f | Distance: %.1f studs | Enemy:(%.1f,%.1f,%.1f) Player:(%.1f,%.1f,%.1f)",
						playerName,
						remainingDamage,
						sourceEntity,
						health.current,
						newHealth,
						distance,
						sourcePos and sourcePos.x or 0, sourcePos and sourcePos.y or 0, sourcePos and sourcePos.z or 0,
						targetPos and targetPos.x or 0, targetPos and targetPos.y or 0, targetPos and targetPos.z or 0
					))
				else
					print(string.format(
						"[DamageSystem] %s took %.1f dmg from %s (%s) at %s | HP: %.1f | Type: %s | AbilityID: %s",
						playerName,
						remainingDamage,
						sourceName,
						sourceType,
						sourcePosition,
						newHealth,
						damageType or "unknown",
						abilityId or "none"
					))
				end
			else
				print(string.format(
					"[DamageSystem] %s took %.1f dmg from %s (%s) at %s | HP: %.1f | Type: %s | AbilityID: %s",
					playerName,
					remainingDamage,
					sourceName,
					sourceType,
					sourcePosition,
					newHealth,
					damageType or "unknown",
					abilityId or "none"
				))
			end
		end

		if playerStats and playerStats.player then
			local player = playerStats.player
			local character = player.Character
			if character then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				-- Only apply damage if humanoid exists and is alive
				if humanoid and humanoid.Health > 0.01 then
					-- Use remaining damage after overheal absorption
					-- Clamp humanoid health to minimum 0.01
					local newHumanoidHealth = math.max(humanoid.Health - remainingDamage, 0.01)
					humanoid.Health = newHumanoidHealth
					
					-- Notify HealthRegenSystem that player took damage
					local HealthRegenSystem = require(game.ServerScriptService.ECS.Systems.HealthRegenSystem)
					HealthRegenSystem.onPlayerDamaged(targetEntity)
				end
			end
		end
	end
	
	-- Trigger hit flash VFX
	local currentTime = tick()
	local existingFlash = world:get(targetEntity, HitFlash)
	local hitCount = existingFlash and existingFlash.hitCount or 0
	
	DirtyService.setIfChanged(world, targetEntity, HitFlash, {
		endTime = currentTime + HIT_FLASH_DURATION,
		hitCount = hitCount + 1
	}, "HitFlash")
	
	-- Apply knockback (if not already in death animation)
	local deathAnim = world:get(targetEntity, DeathAnimation)
	if not deathAnim then
		local entityPos = world:get(targetEntity, Position)
		if entityPos then
			local position = Vector3.new(entityPos.x, entityPos.y, entityPos.z)
			local closestPlayer = findClosestPlayer(position)
			
			if closestPlayer and closestPlayer.Character then
				local hrp = closestPlayer.Character:FindFirstChild("HumanoidRootPart")
				if hrp and hrp:IsA("BasePart") then
					local playerPos = hrp.Position
					local knockbackDirection = (position - playerPos).Unit
					-- Random knockback distance between min and max
					local knockbackDistance = KNOCKBACK_MIN_DISTANCE + math.random() * (KNOCKBACK_MAX_DISTANCE - KNOCKBACK_MIN_DISTANCE)
					local knockbackVelocity = knockbackDirection * (knockbackDistance / KNOCKBACK_DURATION)
					
					DirtyService.setIfChanged(world, targetEntity, Knockback, {
						velocity = {
							x = knockbackVelocity.X,
							y = knockbackVelocity.Y,
							z = knockbackVelocity.Z
						},
						endTime = currentTime + KNOCKBACK_DURATION,
						stunned = true
					}, "Knockback")
				end
			end
		end
	end
	
	-- If entity died, handle death
	if died then
		-- For players: Let Roblox handle death/respawn, ECS cleanup happens in CharacterAdded
		-- For enemies: Trigger death animation and exp drop
		if not isPlayer then
			-- Death animation starts AFTER hit flash completes
			DirtyService.setIfChanged(world, targetEntity, DeathAnimation, {
				startTime = currentTime + HIT_FLASH_DURATION + DEATH_ANIMATION_BUFFER, -- Start after HitFlash
				duration = 0.2, -- Fade duration
				flashEndTime = currentTime + HIT_FLASH_DURATION
			}, "DeathAnimation")
			
			-- Track kill for player sources
			if sourceEntity then
				local sourceEntityType = world:get(sourceEntity, EntityType)
				local isPlayerSource = sourceEntityType and sourceEntityType.type == "Player"
				
				if isPlayerSource then
					local SessionStatsTracker = require(game.ServerScriptService.ECS.Systems.SessionStatsTracker)
					SessionStatsTracker.trackKill(sourceEntity)
				end
			end
			
			-- Trigger enemy exp drop
			if EnemyExpDropSystem then
				local entityPos = world:get(targetEntity, Position)
				if entityPos then
					local pos = Vector3.new(entityPos.x, entityPos.y, entityPos.z)
					EnemyExpDropSystem.onEnemyDeath(targetEntity, pos, health.max)
				end
			end
		end
	end
	
	return died, applied
end

function DamageSystem.getStats()
	return {
		damageAttempts = damageAttemptCount,
		damageApplied = damageAppliedCount,
	}
end

function DamageSystem.applyKnockback(targetEntity: number, direction: Vector3, distance: number, duration: number, stunned: boolean?): boolean
	if not world or not targetEntity then
		return false
	end
	if typeof(direction) ~= "Vector3" or direction.Magnitude <= 0.001 then
		return false
	end
	local entityPos = world:get(targetEntity, Position)
	if not entityPos then
		return false
	end
	local knockbackDuration = math.max(duration or 0.2, 0.05)
	local knockbackVelocity = direction.Unit * (math.max(distance or 0, 0) / knockbackDuration)
	DirtyService.setIfChanged(world, targetEntity, Knockback, {
		velocity = {
			x = knockbackVelocity.X,
			y = knockbackVelocity.Y,
			z = knockbackVelocity.Z,
		},
		endTime = tick() + knockbackDuration,
		stunned = stunned == nil and true or stunned,
	}, "Knockback")
	return true
end

return DamageSystem
