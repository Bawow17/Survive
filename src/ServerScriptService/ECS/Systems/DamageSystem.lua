--!strict
-- DamageSystem - Centralized damage application with hit feedback, knockback, and death handling
-- Manages all damage sources and applies consistent visual/physics effects

local DamageSystem = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)
local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)

local world: any
local Components: any
local DirtyService: any
local EnemyExpDropSystem: any  -- Reference to enemy drop system
local StatusEffectSystem: any  -- Reference to status effect system
local OverhealSystem: any  -- Reference to overheal system
local PlayerHitMarkerRemote: RemoteEvent? = nil

-- Component references
local Health: any
local Position: any
local EntityType: any
local HitFlash: any
local Knockback: any
local DeathAnimation: any
local PassiveEffects: any
local EnemyAggro: any
local AttackCooldown: any
local EnemyTier: any

local RNG = Random.new()

local damageAttemptCount = 0
local damageAppliedCount = 0
local DEBUG_DAMAGE_LOGS = false
local INVINCIBLE_ENEMY_DIAGNOSTICS = GameOptions.Debug and GameOptions.Debug.InvincibleEnemyDiagnostics or false
local LAST_HIT_DAMAGE_DIAGNOSTICS = GameOptions.Debug and GameOptions.Debug.LastHitDamageDiagnostics or false
local ENEMY_DIAG_SAMPLE_LIMIT = 20
local enemyDiagCounters = {
	enemyDamageAttempts = 0,
	enemyDamageApplied = 0,
	enemyRejectedMissingHealth = 0,
	enemyRejectedTargetMissing = 0,
	enemyRejectedWorldMissing = 0,
	enemyRejectedNonEnemyType = 0,
	enemyHadDeathAnimationAtHit = 0,
}
local enemyDiagSamples: {any} = {}
local lastPlayerHitByEntity: {[number]: any} = {}

-- Configuration
local HIT_FLASH_DURATION = 0.15  -- Increased from 0.2 to 0.15 for snappier response
local KNOCKBACK_MIN_DISTANCE = 1 -- Minimum knockback distance
local KNOCKBACK_MAX_DISTANCE = 2.5 -- Maximum knockback distance
local KNOCKBACK_DURATION = 0.2

-- OPTIMIZATION PHASE 3: Ensure HitFlash plays before death fade
-- Buffer time between HitFlash end and death fade start
local DEATH_ANIMATION_BUFFER = 0.12  -- Allow HitFlash to be visible before death fade

local function recordEnemyDiagSample(reason: string, targetEntity: number?, entityType: any?, health: any?, hasDeathAnimation: boolean?)
	if not INVINCIBLE_ENEMY_DIAGNOSTICS then
		return
	end
	table.insert(enemyDiagSamples, {
		t = tick(),
		targetEntity = targetEntity,
		reason = reason,
		hasEntityType = entityType ~= nil,
		hasHealth = health ~= nil,
		hasDeathAnimation = hasDeathAnimation == true,
		healthCurrent = health and health.current or nil,
	})
	if #enemyDiagSamples > ENEMY_DIAG_SAMPLE_LIMIT then
		table.remove(enemyDiagSamples, 1)
	end
end

local function resetEnemyDiagnostics()
	for key in pairs(enemyDiagCounters) do
		enemyDiagCounters[key] = 0
	end
	table.clear(enemyDiagSamples)
end

local function isPlayerSourceEntity(sourceEntity: number?): boolean
	if not sourceEntity then
		return false
	end
	local sourceType = world:get(sourceEntity, EntityType)
	if sourceType and sourceType.type == "Player" then
		return true
	end
	local sourceStats = world:get(sourceEntity, Components.PlayerStats)
	return sourceStats and sourceStats.player ~= nil
end

local function isEnemySourceEntity(sourceEntity: number?): boolean
	if not sourceEntity then
		return false
	end
	local sourceType = world:get(sourceEntity, EntityType)
	return sourceType and sourceType.type == "Enemy"
end

local function normalizeCritChance(rawChance: number?): number
	if typeof(rawChance) ~= "number" then
		return 0
	end
	local critChance = rawChance
	if critChance > 1 then
		if critChance <= 100 then
			critChance = critChance / 100
		else
			critChance = 1
		end
	end
	return math.clamp(critChance, 0, 1)
end

-- Pseudo-random distribution to smooth crit streaks without changing average rate.
local critAccumulators: {[number]: number} = {}

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
	PassiveEffects = Components.PassiveEffects
	EnemyAggro = Components.EnemyAggro
	AttackCooldown = Components.AttackCooldown
	EnemyTier = Components.EnemyTier

	local remotesFolder = ReplicatedStorage:FindFirstChild("RemoteEvents")
	if not remotesFolder then
		remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents", 5)
	end
	if remotesFolder then
		local remote = remotesFolder:FindFirstChild("PlayerHitMarker")
		if remote and remote:IsA("RemoteEvent") then
			PlayerHitMarkerRemote = remote
		end
	end
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

-- Direct heal path for instant effects (e.g. lifesteal).
-- Intentionally independent from regen delay/recent damage state.
local function applyDirectPlayerHeal(playerEntity: number, healAmount: number)
	if healAmount <= 0 then
		return
	end

	local sourceHealth = world:get(playerEntity, Health)
	if sourceHealth then
		local healed = math.min(sourceHealth.current + healAmount, sourceHealth.max)
		DirtyService.setIfChanged(world, playerEntity, Health, {
			current = healed,
			max = sourceHealth.max,
		}, "Health")
	end

	local sourceStats = world:get(playerEntity, Components.PlayerStats)
	if sourceStats and sourceStats.player and sourceStats.player.Character then
		local humanoid = sourceStats.player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + healAmount)
		end
	end
end

local function updateEnemyAggro(enemyEntity: number, sourceEntity: number, appliedDamage: number, maxHealth: number)
	if not EnemyAggro or not world then
		return
	end
	local aggro = world:get(enemyEntity, EnemyAggro)
	if not aggro then
		return
	end

	local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
	local now = GameTimeSystem.getGameTime()
	local aggroConfig = EnemyBalance.Aggro or {}
	local threatTau = aggroConfig.ThreatTau or 4.0
	local decay = math.exp(-(now - (aggro.lastThreatTime or now)) / math.max(0.01, threatTau))

	local threatByPlayer = aggro.threatByPlayer or {}
	for id, threat in pairs(threatByPlayer) do
		local newThreat = threat * decay
		if newThreat <= 0.001 then
			threatByPlayer[id] = nil
		else
			threatByPlayer[id] = newThreat
		end
	end

	aggro.lastThreatTime = now
	aggro.threatByPlayer = threatByPlayer

	local damageByPlayer = aggro.damageByPlayer or {}
	damageByPlayer[sourceEntity] = (damageByPlayer[sourceEntity] or 0) + appliedDamage
	aggro.damageByPlayer = damageByPlayer

	threatByPlayer[sourceEntity] = (threatByPlayer[sourceEntity] or 0) + appliedDamage

	if aggro.owner == nil and aggro.target ~= nil then
		aggro.owner = aggro.target
	end

	local currentTarget = aggro.target or aggro.owner
	if currentTarget and StatusEffectSystem and StatusEffectSystem.hasSpawnProtection(currentTarget) then
		aggro.target = nil
		currentTarget = nil
	end
	local currentDamage = currentTarget and damageByPlayer[currentTarget] or 0

	local topPlayer = currentTarget
	local topDamage = currentDamage
	for id, dmg in pairs(damageByPlayer) do
		if StatusEffectSystem and StatusEffectSystem.hasSpawnProtection(id) then
			continue
		end
		if dmg > topDamage then
			topDamage = dmg
			topPlayer = id
		end
	end

	local minFrac = aggroConfig.MinDamageFractionToSwitch or 0.30
	local switchThreshold = aggro.nextSwitchThreshold or minFrac
	if topPlayer and not currentTarget then
		aggro.target = topPlayer
		currentTarget = topPlayer
		local targetComp = world:get(enemyEntity, Components.Target)
		if targetComp then
			targetComp.id = topPlayer
			world:set(enemyEntity, Components.Target, targetComp)
		else
			world:set(enemyEntity, Components.Target, { id = topPlayer })
		end
		DirtyService.mark(enemyEntity, "Target")
	end
	if topPlayer and currentTarget and topPlayer ~= currentTarget and maxHealth > 0 then
		if topDamage >= maxHealth * switchThreshold and topDamage > currentDamage then
			local cooldown = aggroConfig.SwitchCooldown or 1.2
			if not aggro.lastSwitchTime or (now - aggro.lastSwitchTime) >= cooldown then
				local currentThreat = threatByPlayer[currentTarget] or 0
				local candidateThreat = threatByPlayer[topPlayer] or 0
				local margin = aggroConfig.ThreatMargin or 0.2
				if candidateThreat >= currentThreat * (1 + margin) then
					aggro.target = topPlayer
					aggro.lastSwitchTime = now
					aggro.nextSwitchThreshold = math.min(1.0, switchThreshold + minFrac)

					local targetComp = world:get(enemyEntity, Components.Target)
					if targetComp then
						targetComp.id = topPlayer
						world:set(enemyEntity, Components.Target, targetComp)
					else
						world:set(enemyEntity, Components.Target, { id = topPlayer })
					end
					DirtyService.mark(enemyEntity, "Target")
				end
			end
		end
	end

	world:set(enemyEntity, EnemyAggro, aggro)
	DirtyService.mark(enemyEntity, "EnemyAggro")
end

-- Apply damage to an entity with all feedback effects
-- sourceEntity: optional player entity that dealt the damage (for ability tracking)
-- abilityId: optional ability identifier (for damage stat tracking)
function DamageSystem.applyDamage(targetEntity: number, damageAmount: number, damageType: string, sourceEntity: number?, abilityId: string?): boolean
	if not world then
		if INVINCIBLE_ENEMY_DIAGNOSTICS then
			enemyDiagCounters.enemyRejectedWorldMissing += 1
			recordEnemyDiagSample("world_missing", targetEntity, nil, nil, false)
		end
		return false, false
	end
	if not targetEntity then
		if INVINCIBLE_ENEMY_DIAGNOSTICS then
			enemyDiagCounters.enemyRejectedTargetMissing += 1
			recordEnemyDiagSample("target_missing", nil, nil, nil, false)
		end
		return false, false
	end
	damageAttemptCount += 1
	local requestedDamageAmount = damageAmount

	-- Get entity type to determine if this is a player or enemy
	local entityType = world:get(targetEntity, EntityType)
	local isPlayer = entityType and entityType.type == "Player"
	local isEnemy = entityType and entityType.type == "Enemy"
	local playerStats = world:get(targetEntity, Components.PlayerStats)
	if not isEnemy and not isPlayer and playerStats and playerStats.player then
		isPlayer = true
	end
	if INVINCIBLE_ENEMY_DIAGNOSTICS then
		if isEnemy then
			enemyDiagCounters.enemyDamageAttempts += 1
			local hasDeathAnimation = world:has(targetEntity, DeathAnimation)
			if hasDeathAnimation then
				enemyDiagCounters.enemyHadDeathAnimationAtHit += 1
				recordEnemyDiagSample("enemy_has_death_animation", targetEntity, entityType, world:get(targetEntity, Health), true)
			end
		elseif not isPlayer then
			enemyDiagCounters.enemyRejectedNonEnemyType += 1
			recordEnemyDiagSample("non_enemy_type", targetEntity, entityType, world:get(targetEntity, Health), world:has(targetEntity, DeathAnimation))
		end
	end
	
	-- Check invincibility (players only)
	if isPlayer and not isEnemy and StatusEffectSystem and StatusEffectSystem.hasInvincibility(targetEntity) then
		return false, false  -- Damage blocked by invincibility
	end

	-- Apply player defensive modifiers (armor)
	if isPlayer then
		local targetEffects = world:get(targetEntity, PassiveEffects)
		if targetEffects then
			local armorReduction = math.clamp(targetEffects.armorReduction or 0, 0, 0.6)
			if armorReduction > 0 then
				local effectiveArmor = armorReduction * armorReduction
				damageAmount = damageAmount * (1 - effectiveArmor)
			end
		end
	end

	-- Apply player offensive modifiers (crit)
	local wasCrit = false
	if isEnemy and sourceEntity and isPlayerSourceEntity(sourceEntity) then
		local sourceEffects = world:get(sourceEntity, PassiveEffects)
		if sourceEffects then
			local critChance = normalizeCritChance(sourceEffects.critChance)
			if critChance > 0 then
				local acc = critAccumulators[sourceEntity] or 0
				acc += critChance
				if RNG:NextNumber() < acc then
					local critDamage = sourceEffects.critDamage or 0
					damageAmount = damageAmount * (2 + critDamage)
					wasCrit = true
					acc -= 1
				end
				critAccumulators[sourceEntity] = acc
			end
		end
	end
	
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
	if sourceEntity and abilityId and isEnemy and isPlayerSourceEntity(sourceEntity) then
		local currentStats = world:get(sourceEntity, Components.AbilityDamageStats)
		local damageStats = {}
		if currentStats and typeof(currentStats) == "table" then
			for key, value in pairs(currentStats) do
				damageStats[key] = value
			end
		end

		-- Accumulate damage for this ability
		damageStats[abilityId] = (damageStats[abilityId] or 0) + damageAmount
		DirtyService.setIfChanged(world, sourceEntity, Components.AbilityDamageStats, damageStats, "AbilityDamageStats")
	end
	
	-- Track session damage for player sources (damage to enemies)
	if sourceEntity and isEnemy and isPlayerSourceEntity(sourceEntity) then
		local SessionStatsTracker = require(game.ServerScriptService.ECS.Systems.SessionStatsTracker)
		SessionStatsTracker.trackDamage(sourceEntity, damageAmount, abilityId)
	end
	
	-- Get health component
	local health = world:get(targetEntity, Health)
	if not health then
		if INVINCIBLE_ENEMY_DIAGNOSTICS then
			if isEnemy then
				enemyDiagCounters.enemyRejectedMissingHealth += 1
				recordEnemyDiagSample("missing_health", targetEntity, entityType, nil, world:has(targetEntity, DeathAnimation))
			end
		end
		return false, false
	end

	-- Update per-enemy aggro tracking (player damage only)
	if isEnemy and sourceEntity and isPlayerSourceEntity(sourceEntity) then
		local appliedDamage = math.min(damageAmount, health.current)
		if appliedDamage > 0 then
			updateEnemyAggro(targetEntity, sourceEntity, appliedDamage, health.max)
		end
	end
	
	-- Apply damage to overheal first (for players)
	local remainingDamage = damageAmount
	if isPlayer and OverhealSystem then
		remainingDamage = OverhealSystem.damageOverheal(targetEntity, damageAmount)
	end

	local appliedToTarget = 0
	if isEnemy then
		appliedToTarget = math.min(remainingDamage, health.current)
	end
	
	-- Apply remaining damage to ECS health
	local newHealth = math.max(health.current - remainingDamage, 0)
	local died = newHealth <= 0
	local healthBefore = health.current
	
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
		if INVINCIBLE_ENEMY_DIAGNOSTICS and isEnemy then
			enemyDiagCounters.enemyDamageApplied += 1
		end
	end
	DirtyService.setIfChanged(world, targetEntity, Health, {
		current = newHealth,
		max = health.max
	}, "Health")

	if isPlayer and remainingDamage > 0 then
		local sourceType = sourceEntity and world:get(sourceEntity, EntityType) or nil
		local sourceDamage = sourceEntity and world:get(sourceEntity, Components.Damage) or nil
		local sourceCooldown = sourceEntity and AttackCooldown and world:get(sourceEntity, AttackCooldown) or nil
		local sourceTier = sourceEntity and EnemyTier and world:get(sourceEntity, EnemyTier) or nil
		local playerStatsAtHit = world:get(targetEntity, Components.PlayerStats)
		local humanoidHealthBefore: number? = nil
		local humanoidMaxHealth: number? = nil
		local playerName = if playerStatsAtHit and playerStatsAtHit.player then playerStatsAtHit.player.Name else tostring(targetEntity)
		if playerStatsAtHit and playerStatsAtHit.player and playerStatsAtHit.player.Character then
			local humanoid = playerStatsAtHit.player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoidHealthBefore = humanoid.Health
				humanoidMaxHealth = humanoid.MaxHealth
			end
		end
		local appliedHealthDamage = math.max(healthBefore - newHealth, 0)
		local lastHit = {
			t = tick(),
			targetEntity = targetEntity,
			playerName = playerName,
			requestedDamage = requestedDamageAmount,
			postMitigationDamage = damageAmount,
			damageToHealth = appliedHealthDamage,
			damageToOverheal = math.max(remainingDamage - appliedHealthDamage, 0),
			damageType = damageType,
			abilityId = abilityId,
			healthBefore = healthBefore,
			healthAfter = newHealth,
			maxHealth = health.max,
			sourceEntity = sourceEntity,
			sourceType = sourceType and sourceType.type or nil,
			sourceSubtype = sourceType and sourceType.subtype or nil,
			sourceTier = sourceTier and sourceTier.tier or nil,
			sourceDamage = sourceDamage and sourceDamage.amount or nil,
			sourceCooldownRemaining = sourceCooldown and sourceCooldown.remaining or nil,
			sourceCooldownMax = sourceCooldown and sourceCooldown.max or nil,
			humanoidHealthBefore = humanoidHealthBefore,
			humanoidMaxHealth = humanoidMaxHealth,
		}
		lastPlayerHitByEntity[targetEntity] = lastHit

		if playerStatsAtHit and playerStatsAtHit.player then
			local player = playerStatsAtHit.player
			player:SetAttribute("Debug_LastHitDamage", appliedHealthDamage)
			player:SetAttribute("Debug_LastHitSource", string.format(
				"%s/%s",
				tostring(lastHit.sourceType or "Unknown"),
				tostring(lastHit.sourceSubtype or "Unknown")
			))
			player:SetAttribute("Debug_LastHitTime", lastHit.t)
		end

		if LAST_HIT_DAMAGE_DIAGNOSTICS then
			warn(string.format(
				"[LastHitDebug] player=%s dmgReq=%.2f dmgPostMit=%.2f hpDmg=%.2f hp=%.2f->%.2f hum=%.2f/%.2f src=%s/%s tier=%s srcDmg=%.2f srcCD=%.2f/%.2f type=%s",
				tostring(playerName),
				tonumber(requestedDamageAmount) or 0,
				tonumber(damageAmount) or 0,
				tonumber(appliedHealthDamage) or 0,
				tonumber(healthBefore) or 0,
				tonumber(newHealth) or 0,
				tonumber(lastHit.humanoidHealthBefore) or -1,
				tonumber(lastHit.humanoidMaxHealth) or -1,
				tostring(lastHit.sourceType or "Unknown"),
				tostring(lastHit.sourceSubtype or "Unknown"),
				tostring(lastHit.sourceTier or "Normal"),
				tonumber(lastHit.sourceDamage) or 0,
				tonumber(lastHit.sourceCooldownRemaining) or 0,
				tonumber(lastHit.sourceCooldownMax) or 0,
				tostring(damageType or "unknown")
			))
		end
	end

	-- Apply short post-hit invincibility for players when damaged by enemies.
	-- Prevents rapid stacked hits from feeling like instant one-shots.
	if applied and isPlayer and remainingDamage > 0 and StatusEffectSystem and isEnemySourceEntity(sourceEntity) then
		local iFrames = PlayerBalance.BaseInvincibilityFrames or 0
		if iFrames > 0 then
			StatusEffectSystem.grantInvincibility(targetEntity, iFrames, false, false, false)
		end
	end
	
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

	-- Apply lifesteal for player sources damaging enemies
	if isEnemy and sourceEntity and appliedToTarget > 0 and isPlayerSourceEntity(sourceEntity) then
		if PlayerHitMarkerRemote then
			local sourceStats = world:get(sourceEntity, Components.PlayerStats)
			if sourceStats and sourceStats.player then
				PlayerHitMarkerRemote:FireClient(sourceStats.player)
			end
		end

		local sourceEffects = world:get(sourceEntity, PassiveEffects)
		local lifesteal = sourceEffects and sourceEffects.lifesteal or 0
		if lifesteal > 0 then
			-- No cooldown or recent-damage lockout: lifesteal always applies on dealt damage.
			local healAmount = appliedToTarget * lifesteal
			applyDirectPlayerHeal(sourceEntity, healAmount)
		end
	end
	
	-- Trigger hit flash VFX (skip for nuke)
	local currentTime = tick()
	local flashEndTime = currentTime
	if damageType ~= "nuke" then
		local existingFlash = world:get(targetEntity, HitFlash)
		local hitCount = existingFlash and existingFlash.hitCount or 0
		flashEndTime = currentTime + HIT_FLASH_DURATION
		if existingFlash and typeof(existingFlash.endTime) == "number" then
			flashEndTime = math.max(flashEndTime, existingFlash.endTime)
		end
		
		DirtyService.setIfChanged(world, targetEntity, HitFlash, {
			endTime = flashEndTime,
			hitCount = hitCount + 1,
			crit = wasCrit,
		}, "HitFlash")
	end
	
	-- Apply knockback (if not already in death animation)
	local deathAnim = world:get(targetEntity, DeathAnimation)
	if not deathAnim and damageType ~= "nuke" then
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
					local knockbackMin = KNOCKBACK_MIN_DISTANCE
					local knockbackMax = KNOCKBACK_MAX_DISTANCE
					if abilityId == "Refractions" then
						knockbackMin = knockbackMin * 0.2
						knockbackMax = knockbackMax * 0.2
					end
					local knockbackDistance = knockbackMin + math.random() * (knockbackMax - knockbackMin)
					local knockbackVelocity = knockbackDirection * (knockbackDistance / KNOCKBACK_DURATION)

					DirtyService.setIfChanged(world, targetEntity, Knockback, {
						velocity = {
							x = knockbackVelocity.X,
							y = knockbackVelocity.Y,
							z = knockbackVelocity.Z
						},
						endTime = currentTime + KNOCKBACK_DURATION,
						stunned = isEnemy and false or true
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
			-- Nuke kills: no hit/death animation, despawn immediately after exp drop
			if damageType == "nuke" then
				if EnemyExpDropSystem then
					local entityPos = world:get(targetEntity, Position)
					if entityPos then
						local pos = Vector3.new(entityPos.x, entityPos.y, entityPos.z)
						EnemyExpDropSystem.onEnemyDeath(targetEntity, pos, health.max)
					end
				end
				local EnemyPool = require(game.ServerScriptService.ECS.EnemyPool)
				local SyncSystem = require(game.ServerScriptService.ECS.Systems.SyncSystem)
				SyncSystem.queueDespawn(targetEntity)
				EnemyPool.release(targetEntity)
				return died, applied
			end

			-- Death animation starts AFTER hit flash completes
			local deathStartTime = flashEndTime + DEATH_ANIMATION_BUFFER
			DirtyService.setIfChanged(world, targetEntity, DeathAnimation, {
				startTime = deathStartTime, -- Start after HitFlash
				duration = 0.2, -- Fade duration
				flashEndTime = flashEndTime,
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

function DamageSystem.getInvincibleEnemyDebugSnapshot(reset: boolean?): {[string]: any}
	local samples = table.create(#enemyDiagSamples)
	for i, sample in ipairs(enemyDiagSamples) do
		samples[i] = sample
	end

	local snapshot = {
		enemyDamageAttempts = enemyDiagCounters.enemyDamageAttempts,
		enemyDamageApplied = enemyDiagCounters.enemyDamageApplied,
		enemyRejectedMissingHealth = enemyDiagCounters.enemyRejectedMissingHealth,
		enemyRejectedTargetMissing = enemyDiagCounters.enemyRejectedTargetMissing,
		enemyRejectedWorldMissing = enemyDiagCounters.enemyRejectedWorldMissing,
		enemyRejectedNonEnemyType = enemyDiagCounters.enemyRejectedNonEnemyType,
		enemyHadDeathAnimationAtHit = enemyDiagCounters.enemyHadDeathAnimationAtHit,
		samples = samples,
	}

	if reset then
		resetEnemyDiagnostics()
	end

	return snapshot
end

function DamageSystem.getLastPlayerHitDebugSnapshot(reset: boolean?): {[number]: any}
	local snapshot: {[number]: any} = {}
	for entityId, record in pairs(lastPlayerHitByEntity) do
		snapshot[entityId] = record
	end
	if reset then
		table.clear(lastPlayerHitByEntity)
	end
	return snapshot
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
	local entityType = world:get(targetEntity, EntityType)
	local isEnemyTarget = entityType and entityType.type == "Enemy"
	local knockbackDuration = math.max(duration or 0.2, 0.05)
	local knockbackVelocity = direction.Unit * (math.max(distance or 0, 0) / knockbackDuration)
	local stunFlag = isEnemyTarget and false or (stunned == nil and true or stunned)
	DirtyService.setIfChanged(world, targetEntity, Knockback, {
		velocity = {
			x = knockbackVelocity.X,
			y = knockbackVelocity.Y,
			z = knockbackVelocity.Z,
		},
		endTime = tick() + knockbackDuration,
		stunned = stunFlag,
	}, "Knockback")
	return true
end

return DamageSystem
