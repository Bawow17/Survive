--!strict
-- EnemySpawner - Handles spawning enemies around players
-- Spawns zombies at intervals near players

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)
local DifficultyCoeff = require(game.ServerScriptService.Balance.DifficultyCoeff)
local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local DamageSystem = require(game.ServerScriptService.ECS.Systems.DamageSystem)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
local EnemyRegistry = require(game.ServerScriptService.Enemies.EnemyRegistry)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local SpatialGridSystem = require(game.ServerScriptService.ECS.Systems.SpatialGridSystem)
local EnemyColliderService = require(game.ServerScriptService.Services.EnemyColliderService)

local ProfilingConfig = require(ReplicatedStorage.Shared.ProfilingConfig)
local Prof = ProfilingConfig.ENABLED and require(ReplicatedStorage.Shared.ProfilingServer) or require(ReplicatedStorage.Shared.ProfilingStub)
local PROFILING_ENABLED = ProfilingConfig.ENABLED

local function profGauge(name: string, value: number)
	if PROFILING_ENABLED then
		Prof.gauge(name, value)
	end
end

local function profInc(name: string, value: number?)
	if PROFILING_ENABLED then
		Prof.incCounter(name, value)
	end
end

local EnemySpawner = {}

-- Spatial grid size for density checking
local GRID_SIZE = SpatialGridSystem.getGridSize()

local world: any
local Components: any
local ECSWorldService: any
local ModelReplicationService: any
local QueryPool: any

local PlayerStats: any
local Position: any
local PassiveEffects: any
local AbilityData: any

local playerSpawnCredits: {[number]: number} = {}
local scalingCorrectionState: {[number]: {spawn: number, health: number, damage: number, speed: number}} = {}
local initialDelayAccumulator = 0
local hasInitialDelayPassed = false
local zombieSpawnCounter = 0 -- Track total zombie spawns for debug messages
local spawnEnabled = true

-- Spawn check throttle (PERFORMANCE FIX - don't run spawn logic every frame!)
local SPAWN_CHECK_INTERVAL = 0.5  -- Only check/spawn every 0.5 seconds
local spawnCheckAccumulator = 0

-- Cached queries for performance
local enemyCountQuery: any
local playerPositionQuery: any
local enemyOwnerQuery: any
local enemyTierQuery: any

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local SPAWN_GROUND_CLEARANCE = 0
local GROUND_RAYCAST_UP = 120
local GROUND_RAYCAST_DOWN = 600
local MAX_GROUND_DELTA_FROM_PLAYER_Y = 80
local MAX_CANOPY_DELTA_FROM_PLAYER_Y = 40
local MAX_SPAWN_HEIGHT_OFFSET = 12

-- RNG for enemy type selection
local enemyTypeRNG = Random.new()
local tierRNG = Random.new()

-- Cache for enemy types and weights
local enemyTypes = {}
local enemyWeights = {}
local enemyCosts: {[string]: number} = {}
local minEnemyCost = 1.0

local function normalizePositiveNumber(value: any, defaultValue: number): number
	if typeof(value) ~= "number" then
		return defaultValue
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return defaultValue
	end
	if value <= 0 then
		return defaultValue
	end
	return value
end

local function resolveEnemySpawnCost(enemyType: string, enemyConfig: any): number
	local directorCfg = EnemyBalance.SpawnDirector or {}
	local configuredCosts = directorCfg.MonsterCosts or {}
	local directCost = configuredCosts[enemyType]
	if typeof(directCost) == "number" and directCost > 0 then
		return directCost
	end

	local baseHealth = normalizePositiveNumber(enemyConfig and enemyConfig.baseHealth, 80)
	local baseDamage = normalizePositiveNumber(enemyConfig and enemyConfig.baseDamage, 20)
	local inferred = math.floor((baseHealth * 0.09) + (baseDamage * 0.55) + 0.5)
	return math.max(1, inferred)
end

-- Build weighted selection tables
local function rebuildEnemyWeights()
	table.clear(enemyTypes)
	table.clear(enemyWeights)
	table.clear(enemyCosts)
	minEnemyCost = math.huge
	
	local weights = EnemyBalance.SpawnWeights or {}
	
	-- Get all available enemy types from registry
	for enemyType, _ in pairs(weights) do
		local config = EnemyRegistry.getEnemyConfig(enemyType)
		if config then
			local weight = weights[enemyType] or 0
			if weight > 0 then
				local cost = resolveEnemySpawnCost(enemyType, config)
				table.insert(enemyTypes, enemyType)
				table.insert(enemyWeights, weight)
				enemyCosts[enemyType] = cost
				if cost < minEnemyCost then
					minEnemyCost = cost
				end
			end
		end
	end

	if minEnemyCost == math.huge then
		minEnemyCost = 1.0
	end
end

local function selectEnemyTypeForCredits(availableCredits: number, tooCheapMultiplier: number): (string?, number?)
	if #enemyTypes == 0 then
		return nil, nil
	end

	local candidateIndices = table.create(#enemyTypes)
	local affordableWeight = 0

	for i, enemyType in ipairs(enemyTypes) do
		local cost = enemyCosts[enemyType] or 1
		if cost <= availableCredits then
			local weight = enemyWeights[i] or 0
			if weight > 0 then
				affordableWeight += weight
				candidateIndices[#candidateIndices + 1] = i
			end
		end
	end

	if #candidateIndices == 0 or affordableWeight <= 0 then
		return nil, nil
	end

	if tooCheapMultiplier > 1 then
		local minDesiredCost = availableCredits / tooCheapMultiplier
		if minDesiredCost > 0 then
			local expensiveIndices = table.create(#candidateIndices)
			local expensiveWeight = 0
			for _, idx in ipairs(candidateIndices) do
				local enemyType = enemyTypes[idx]
				local cost = enemyCosts[enemyType] or 1
				if cost >= minDesiredCost then
					local weight = enemyWeights[idx] or 0
					if weight > 0 then
						expensiveIndices[#expensiveIndices + 1] = idx
						expensiveWeight += weight
					end
				end
			end
			if #expensiveIndices > 0 and expensiveWeight > 0 then
				candidateIndices = expensiveIndices
				affordableWeight = expensiveWeight
			end
		end
	end

	local roll = enemyTypeRNG:NextNumber(0, affordableWeight)
	local running = 0
	for _, idx in ipairs(candidateIndices) do
		local weight = enemyWeights[idx] or 0
		running += weight
		if roll <= running then
			local enemyType = enemyTypes[idx]
			return enemyType, enemyCosts[enemyType] or 1
		end
	end

	local fallbackIdx = candidateIndices[#candidateIndices]
	if fallbackIdx then
		local enemyType = enemyTypes[fallbackIdx]
		return enemyType, enemyCosts[enemyType] or 1
	end

	return nil, nil
end

-- Cache for player parts to avoid recreating tables every frame
local playerPartsCache = {}
local lastPlayerPartsUpdate = 0
local PLAYER_PARTS_CACHE_INTERVAL = 1.0 -- Update cache every 1 second

-- Cache for transparent/non-collidable parts
local TRANSPARENT_PARTS_REBUILD_INTERVAL = 5.0  -- Rebuild every 5 seconds
local lastTransparentPartsRebuild = 0

-- Function to get all player-related parts to exclude from ground detection
local function getPlayerPartsToExclude()
	local currentTime = tick()
	
	-- Check if transparent parts need rebuilding
	local needsTransparentRebuild = (currentTime - lastTransparentPartsRebuild) >= TRANSPARENT_PARTS_REBUILD_INTERVAL
	
	-- Use cached result if it's recent enough and transparent parts are fresh
	if currentTime - lastPlayerPartsUpdate < PLAYER_PARTS_CACHE_INTERVAL and #playerPartsCache > 0 and not needsTransparentRebuild then
		return playerPartsCache
	end
	
	-- Clear and rebuild cache
	table.clear(playerPartsCache)
	local Players = game:GetService("Players")
	
	for _, player in pairs(Players:GetPlayers()) do
		if player.Character then
			-- Exclude character body parts
			for _, part in pairs(player.Character:GetChildren()) do
				if part:IsA("BasePart") then
					table.insert(playerPartsCache, part)
				end
			end
			
			-- Exclude accessories
			for _, accessory in pairs(player.Character:GetChildren()) do
				if accessory:IsA("Accessory") then
					local handle = accessory:FindFirstChild("Handle")
					if handle then
						table.insert(playerPartsCache, handle)
					end
				end
			end
		end
	end
	
	-- Exclude exp orbs
	local expOrbsFolder = Workspace:FindFirstChild("ExpOrbs")
	if expOrbsFolder then
		for _, orbModel in pairs(expOrbsFolder:GetChildren()) do
			if orbModel:IsA("Model") then
				for _, part in pairs(orbModel:GetDescendants()) do
					if part:IsA("BasePart") then
						table.insert(playerPartsCache, part)
					end
				end
			end
		end
	end
	
	-- Exclude projectiles
	local projectilesFolder = Workspace:FindFirstChild("Projectiles")
	if projectilesFolder then
		for _, projectileModel in pairs(projectilesFolder:GetChildren()) do
			if projectileModel:IsA("Model") then
				for _, part in pairs(projectileModel:GetDescendants()) do
					if part:IsA("BasePart") then
						table.insert(playerPartsCache, part)
					end
				end
			end
		end
	end
	
	-- Exclude transparent and non-collidable parts (rebuild every 5 seconds)
	if needsTransparentRebuild then
		lastTransparentPartsRebuild = currentTime
		
		for _, descendant in pairs(Workspace:GetDescendants()) do
			if descendant:IsA("BasePart") or descendant:IsA("MeshPart") then
				-- Exclude if: (Transparency >= 1 OR CanCollide == false)
				if descendant.Transparency >= 1 or not descendant.CanCollide then
					table.insert(playerPartsCache, descendant)
				end
			end
		end
	end
	
	lastPlayerPartsUpdate = currentTime
	return playerPartsCache
end

-- Update raycast parameters to exclude player parts
local function updateRaycastParams()
	raycastParams.FilterDescendantsInstances = getPlayerPartsToExclude()
end

local function isGeneratedChunkSurface(hitInstance: Instance?): boolean
	local chunksRoot = Workspace:FindFirstChild("GeneratedWorldChunks")
	if not chunksRoot then
		return false
	end
	local current = hitInstance
	while current do
		if current == chunksRoot then
			return true
		end
		current = current.Parent
	end
	return false
end

function EnemySpawner.init(worldRef: any, components: any, ecsWorldService: any, modelReplicationService: any)
	world = worldRef
	Components = components
	ECSWorldService = ecsWorldService
	ModelReplicationService = modelReplicationService

	PlayerStats = Components.PlayerStats
	Position = Components.Position
	PassiveEffects = Components.PassiveEffects
	AbilityData = Components.AbilityData
	
	-- Create cached queries for performance (CRITICAL FIX)
	enemyCountQuery = world:query(Components.EntityType):cached()
	playerPositionQuery = world:query(Components.Position, Components.PlayerStats):cached()
	enemyOwnerQuery = world:query(Components.EntityType, Components.EnemyOwner):cached()
	enemyTierQuery = world:query(Components.EntityType, Components.EnemyTier):cached()
	
	-- Build enemy type weights
	rebuildEnemyWeights()

	DifficultyCoeff.validate()
end

local function getGroundedPosition(position: Vector3, heightOffset: number): Vector3?
	updateRaycastParams() -- Update to exclude player parts
	local origin = position + Vector3.new(0, GROUND_RAYCAST_UP, 0)
	local result = Workspace:Raycast(origin, Vector3.new(0, -GROUND_RAYCAST_DOWN, 0), raycastParams)
	if result then
		if not isGeneratedChunkSurface(result.Instance) then
			return nil
		end
		local groundY = result.Position.Y
		local yDifference = math.abs(groundY - position.Y)
		
		-- Keep spawns near player elevation, but allow chunk-height variance.
		if yDifference > MAX_GROUND_DELTA_FROM_PLAYER_Y then
			-- Ground too far above or below - reject this spawn position
			return nil
		end
		
		-- Validate: Don't spawn on canopies far above spawn origin
		if groundY > position.Y + MAX_CANOPY_DELTA_FROM_PLAYER_Y then
			-- Likely hit a tree canopy or elevated structure, reject
			return nil
		end
		
		return Vector3.new(position.X, groundY + heightOffset, position.Z)
	end
	
	-- No ground found, reject spawn
	return nil
end

local function getEnemySpawnHeightOffset(enemyType: string, scale: number?): number
	return EnemyColliderService.getGroundSnapOffsetForSubtype(enemyType, scale, SPAWN_GROUND_CLEARANCE, MAX_SPAWN_HEIGHT_OFFSET)
end

local function adjustSpawnHeightForEnemy(groundedPos: Vector3, enemyType: string, scale: number?): Vector3
	if not groundedPos then
		return groundedPos
	end
	local spawnOffset = getEnemySpawnHeightOffset(enemyType, scale)
	return Vector3.new(groundedPos.X, groundedPos.Y + spawnOffset, groundedPos.Z)
end

local function getRandomSpawnPosition(playerPos: {x: number, y: number, z: number}, sectorAngleMin: number?, sectorAngleMax: number?): Vector3
	-- Safety check for player position
	if not playerPos or not playerPos.x or not playerPos.y or not playerPos.z then
		warn("[EnemySpawner] Invalid player position provided to getRandomSpawnPosition:", playerPos)
		return Vector3.new(0, 0, 0) -- Fallback position
	end
	
	-- Generate random angle (constrained to sector if specified)
	local angle
	if sectorAngleMin and sectorAngleMax then
		angle = sectorAngleMin + math.random() * (sectorAngleMax - sectorAngleMin)
	else
		angle = math.random() * math.pi * 2
	end
	
	local minRadius = EnemyBalance.MinSpawnRadius or 15
	local maxRadius = EnemyBalance.MaxSpawnRadius or 35
	local distance = minRadius + math.random() * (maxRadius - minRadius)

	local offsetX = math.cos(angle) * distance
	local offsetZ = math.sin(angle) * distance

    return Vector3.new(playerPos.x + offsetX, playerPos.y, playerPos.z + offsetZ)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function computeTierOdds(timeMinutes: number, cfg: any): (number, number)
	if not cfg then
		return 0, 0
	end
	local startMin = cfg.StartMinutes or 0
	local midMin = cfg.MidMinutes or 25
	local lateMin = cfg.LateMinutes or 50
	local scale = cfg.SpawnScale or 1.0
	local t = math.max(0, timeMinutes * scale)

	local function getOdds(odds: any): number
		if not odds then
			return 0
		end
		local startVal = odds.start or 0
		local midVal = odds.mid or startVal
		local lateVal = odds.late or midVal
		if t <= midMin then
			local denom = math.max(1e-6, midMin - startMin)
			local alpha = math.clamp((t - startMin) / denom, 0, 1)
			return lerp(startVal, midVal, alpha)
		end
		local denom = math.max(1e-6, lateMin - midMin)
		local alpha = math.clamp((t - midMin) / denom, 0, 1)
		return lerp(midVal, lateVal, alpha)
	end

	local superOdds = getOdds(cfg.SuperOdds)
	local eliteOdds = getOdds(cfg.EliteOdds)

	superOdds = math.clamp(superOdds, 0, 0.5)
	eliteOdds = math.clamp(eliteOdds, 0, 0.5)

	local total = superOdds + eliteOdds
	if total > 0.5 then
		local scaleDown = 0.5 / total
		superOdds *= scaleDown
		eliteOdds *= scaleDown
	end

	return superOdds, eliteOdds
end

local function rollTier(superOdds: number, eliteOdds: number): string
	local roll = tierRNG:NextNumber()
	if roll < eliteOdds then
		return "Elite"
	end
	if roll < eliteOdds + superOdds then
		return "Super"
	end
	return "Normal"
end

local function safeNumber(value: any, defaultValue: number): number
	if typeof(value) ~= "number" then
		return defaultValue
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return defaultValue
	end
	return value
end

local function normalizeCritChance(rawChance: any): number
	local critChance = safeNumber(rawChance, 0)
	if critChance > 1 then
		if critChance <= 100 then
			critChance = critChance / 100
		else
			critChance = 1
		end
	end
	return math.clamp(critChance, 0, 1)
end

local function safeRatio(value: any, baseValue: any): number
	local v = safeNumber(value, 0)
	local b = safeNumber(baseValue, 0)
	if b <= 0 then
		return 1
	end
	local ratio = v / b
	if ratio <= 0 then
		return 1
	end
	return ratio
end

local function computeAbilityPowerMultiplier(playerEntity: number): number
	if not AbilityData then
		return 1
	end
	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or typeof(abilityData) ~= "table" or typeof(abilityData.abilities) ~= "table" then
		return 1
	end

	local totalDelta = 0
	local count = 0

	for _, record in pairs(abilityData.abilities) do
		if record and record.enabled and record.baseStats then
			local base = record.baseStats
			local damageMult = safeRatio(record.damage, base.damage)
			local cooldownRate = safeRatio(base.cooldown, record.cooldown)
			local projectileCountMult = safeRatio(record.projectileCount or 1, base.projectileCount or 1)
			local shotAmountMult = safeRatio(record.shotAmount or 1, base.shotAmount or 1)
			local penetrationMult = safeRatio(record.penetration or base.penetration or 0, base.penetration or 0)
			local sizeMult = safeRatio(record.scale or base.scale or 1, base.scale or 1)
			local durationMult = safeRatio(record.duration or base.duration or 0, base.duration or 0)

			local abilityScore = 1
				+ (damageMult - 1) * 0.45
				+ (cooldownRate - 1) * 0.30
				+ (projectileCountMult - 1) * 0.20
				+ (shotAmountMult - 1) * 0.15
				+ (penetrationMult - 1) * 0.08
				+ (sizeMult - 1) * 0.04
				+ (durationMult - 1) * 0.04
			totalDelta += (abilityScore - 1)
			count += 1
		end
	end

	if count <= 0 then
		return 1
	end

	return math.clamp(1 + (totalDelta / count), 0.5, 4)
end

local function computePlayerPowerScore(playerEntity: number): number
	local effects = PassiveEffects and world:get(playerEntity, PassiveEffects) or nil
	if not effects or typeof(effects) ~= "table" then
		return 1
	end

	local damageMult = math.max(0.1, safeNumber(effects.damageMultiplier, 1))
	local cooldownMult = math.max(0.05, safeNumber(effects.cooldownMultiplier, 1))
	local cooldownRate = 1 / cooldownMult

	local critChance = normalizeCritChance(effects.critChance)
	local critDamage = safeNumber(effects.critDamage, 0)
	local critExpected = 1 + critChance * (1 + math.max(0, critDamage))

	local projectileCountBonus = math.max(0, safeNumber(effects.projectileCountBonus, 0))
	local projectileCountMult = 1 + projectileCountBonus * 0.18

	local penetrationBonus = math.max(0, safeNumber(effects.penetrationBonus, 0))
	local penetrationMult = math.max(0.1, safeNumber(effects.penetrationMultiplier, 1)) * (1 + penetrationBonus * 0.08)

	local offense = damageMult * cooldownRate * critExpected * projectileCountMult * penetrationMult

	local baseHealth = math.max(1, safeNumber(PlayerBalance.BaseMaxHealth, 100))
	local healthMult = math.max(0.1, safeNumber(effects.healthMultiplier, 1))
	local healthFlat = safeNumber(effects.healthFlatBonus, 0)
	local healthEffective = (baseHealth * healthMult + healthFlat) / baseHealth

	local playerArmor = safeNumber(PlayerBalance.BaseArmor, 0) + safeNumber(effects.armor, 0)
	local armorMultiplier = DamageSystem.getArmorDamageMultiplier(playerArmor)
	local armorEffective = 1 / math.max(0.0001, armorMultiplier)

	local baseRegen = math.max(0.01, safeNumber(PlayerBalance.HealthRegenRate, 1))
	local regenMult = math.max(0, safeNumber(effects.regenMultiplier, 1))
	local regenFlat = safeNumber(effects.regenFlatBonus, 0)
	local regenRate = baseRegen * regenMult + regenFlat
	local regenEffective = math.max(0.1, regenRate / baseRegen)

	local lifesteal = math.max(0, safeNumber(effects.lifesteal, 0))
	local defense = healthEffective * armorEffective * (1 + (regenEffective - 1) * 0.35) * (1 + lifesteal * 0.4)

	local moveSpeedMult = math.max(0.1, safeNumber(effects.moveSpeedMultiplier, 1))
	local mobility = 1 + (moveSpeedMult - 1) * 0.5

	local abilityPower = computeAbilityPowerMultiplier(playerEntity)

	local score = 1
		+ (offense - 1) * 0.60
		+ (defense - 1) * 0.28
		+ (mobility - 1) * 0.12
		+ (abilityPower - 1) * 0.40

	return math.clamp(score, 0.4, 6)
end

local function computeExpectedPowerForTime(timeMinutes: number): number
	local corrCfg = EnemyBalance.ScalingCorrection or {}
	local expectedCfg = corrCfg.TimeExpectation or {}
	local earlyMinutes = safeNumber(expectedCfg.EarlyMinutes, 20)
	local earlyPerMinute = safeNumber(expectedCfg.EarlyPerMinute, 0.03)
	local latePerMinute = safeNumber(expectedCfg.LatePerMinute, 0.015)

	local clampedTime = math.max(0, safeNumber(timeMinutes, 0))
	local earlyTime = math.min(clampedTime, math.max(0, earlyMinutes))
	local lateTime = math.max(0, clampedTime - math.max(0, earlyMinutes))
	return 1 + earlyTime * earlyPerMinute + lateTime * latePerMinute
end

local function getPlayerScaling(_playerEntity: number, coeffData: any): any
	local playerEntity = _playerEntity
	local coeff = (coeffData and coeffData.coeff) or 1.0
	if typeof(coeff) ~= "number" or coeff ~= coeff or coeff <= 0 then
		coeff = 1.0
	end

	local scaleCfg = EnemyBalance.DifficultyScaling or {}
	local playerCount = math.max(1, math.floor(safeNumber((coeffData and coeffData.playerCount) or 1, 1)))
	local playerFactor = safeNumber((coeffData and coeffData.playerFactor), 0.7 + 0.3 * playerCount)
	local scalingMode = scaleCfg.Mode
	local coeffHealth = 1.0
	local coeffDamage = 1.0
	local coeffSpeed = 1.0
	local ambientLevel = 1.0

	if scalingMode == "LegacyExponent" then
		local healthExp = scaleCfg.HealthExponent or 0.9
		local damageExp = scaleCfg.DamageExponent or 0.6
		local speedExp = scaleCfg.SpeedExponent or 0.4
		coeffHealth = coeff ^ healthExp
		coeffDamage = coeff ^ damageExp
		coeffSpeed = coeff ^ speedExp
	else
		-- RoR2-like scaling: ambient level is derived from coefficient delta over player baseline.
		-- Each ambient level grants +30% HP and +20% damage (speed mostly static).
		local ambientStep = math.max(1e-3, safeNumber(scaleCfg.AmbientLevelStep, 0.33))
		local healthPerLevel = safeNumber(scaleCfg.HealthPerLevel, 0.30)
		local damagePerLevel = safeNumber(scaleCfg.DamagePerLevel, 0.20)
		local speedPerLevel = safeNumber(scaleCfg.SpeedPerLevel, 0.00)
		local levelCap = math.max(1, safeNumber(scaleCfg.LevelCap, 99))

		local levelDelta = math.max(0, (coeff - playerFactor) / ambientStep)
		ambientLevel = math.clamp(1 + levelDelta, 1, levelCap)
		local ambientGrowth = ambientLevel - 1
		coeffHealth = math.max(0.05, 1 + healthPerLevel * ambientGrowth)
		coeffDamage = math.max(0.05, 1 + damagePerLevel * ambientGrowth)
		coeffSpeed = math.max(0.05, 1 + speedPerLevel * ambientGrowth)
	end

	local spawnCorrection = 1
	local healthCorrection = 1
	local damageCorrection = 1
	local speedCorrection = 1

	local powerScore = 1
	local expectedPower = 1
	local powerGap = 0

	-- Stat-vs-time correction layer: compare player power against expected power
	-- at the current time, and apply only a bounded correction.
	local corrCfg = EnemyBalance.ScalingCorrection or {}
	if corrCfg.Enabled ~= false then
		local spawnClamp = corrCfg.SpawnClamp
		if typeof(spawnClamp) ~= "number" then
			spawnClamp = 0.12
		end
		local statClamp = corrCfg.StatClamp
		if typeof(statClamp) ~= "number" then
			statClamp = 0.12
		end
		-- Hard guardrail: never exceed +/-12%.
		spawnClamp = math.clamp(spawnClamp, 0, 0.12)
		statClamp = math.clamp(statClamp, 0, 0.12)

		local weights = corrCfg.Weights or {}
		local spawnWeight = safeNumber(weights.Spawn, 1.0)
		local healthWeight = safeNumber(weights.Health, 1.0)
		local damageWeight = safeNumber(weights.Damage, 1.0)
		local speedWeight = safeNumber(weights.Speed, 1.0)

		powerScore = computePlayerPowerScore(playerEntity)
		expectedPower = computeExpectedPowerForTime((coeffData and coeffData.timeMinutes) or 0)
		powerGap = (powerScore / math.max(0.1, expectedPower)) - 1

		local targetSpawn = 1 + math.clamp(powerGap * spawnWeight, -spawnClamp, spawnClamp)
		local targetHealth = 1 + math.clamp(powerGap * healthWeight, -statClamp, statClamp)
		local targetDamage = 1 + math.clamp(powerGap * damageWeight, -statClamp, statClamp)
		local targetSpeed = 1 + math.clamp(powerGap * speedWeight, -statClamp, statClamp)

		local alpha = math.clamp(safeNumber(corrCfg.SmoothingAlpha, 0.35), 0, 1)
		local state = scalingCorrectionState[playerEntity]
		if not state then
			state = {
				spawn = targetSpawn,
				health = targetHealth,
				damage = targetDamage,
				speed = targetSpeed,
			}
		else
			state.spawn = state.spawn + (targetSpawn - state.spawn) * alpha
			state.health = state.health + (targetHealth - state.health) * alpha
			state.damage = state.damage + (targetDamage - state.damage) * alpha
			state.speed = state.speed + (targetSpeed - state.speed) * alpha
		end
		scalingCorrectionState[playerEntity] = state

		spawnCorrection = math.clamp(state.spawn, 1 - spawnClamp, 1 + spawnClamp)
		healthCorrection = math.clamp(state.health, 1 - statClamp, 1 + statClamp)
		damageCorrection = math.clamp(state.damage, 1 - statClamp, 1 + statClamp)
		speedCorrection = math.clamp(state.speed, 1 - statClamp, 1 + statClamp)
	end

	local spawnDirector = EnemyBalance.SpawnDirector or {}
	local spawnCreditsPerSecond = 0
	local spawnRate = 0

	if spawnDirector.Enabled ~= false then
		-- RoR2-inspired credit income:
		-- totalIncome ~= creditMultiplier * (1 + 0.4 * coeff) * ((players + 1) / 2)
		local creditMultiplier = math.max(0.01, safeNumber(spawnDirector.CreditMultiplier, 1.5))
		local totalIncome = creditMultiplier * (1 + 0.4 * coeff) * ((playerCount + 1) * 0.5)
		local perPlayerIncome = totalIncome / playerCount
		spawnCreditsPerSecond = math.max(0.01, perPlayerIncome * spawnCorrection)
		spawnRate = spawnCreditsPerSecond
	else
		local spawnExp = scaleCfg.SpawnExponent or 1.0
		local coeffSpawn = coeff ^ spawnExp
		local baseSpawn = EnemyBalance.BaseSpawnRatePerPlayer or 2.5
		spawnRate = baseSpawn * coeffSpawn * spawnCorrection
		if typeof(spawnRate) ~= "number" or spawnRate ~= spawnRate or spawnRate <= 0 then
			spawnRate = baseSpawn
		end
		spawnCreditsPerSecond = spawnRate
	end

	return {
		healthMult = coeffHealth * healthCorrection,
		damageMult = coeffDamage * damageCorrection,
		speedMult = coeffSpeed * speedCorrection,
		spawnRate = spawnRate,
		spawnCreditsPerSecond = spawnCreditsPerSecond,
		corrections = {
			spawn = spawnCorrection,
			health = healthCorrection,
			damage = damageCorrection,
			speed = speedCorrection,
		},
		powerScore = powerScore,
		expectedPower = expectedPower,
		powerGap = powerGap,
		coeff = coeff,
		ambientLevel = ambientLevel,
	}
end

-- Count enemies within a sector (angular wedge) of the spawn ring
local function countEnemiesInSector(playerPos: {x: number, y: number, z: number}, sectorAngleMin: number, sectorAngleMax: number): number
	if not world or not Components or not Position then
		return 0
	end
	
	local playerPosVec = Vector3.new(playerPos.x, playerPos.y, playerPos.z)
	local minRadius = EnemyBalance.MinSpawnRadius or 90
	local maxRadius = EnemyBalance.MaxSpawnRadius or 170
	
	-- Use SpatialGridSystem to efficiently find enemies in the spawn ring
	local searchRadius = maxRadius + 10  -- Add buffer
	local radiusCells = math.ceil(searchRadius / GRID_SIZE)
	local nearbyEntities = SpatialGridSystem.getNeighboringEntities(playerPosVec, radiusCells)
	
	local count = 0
	for _, entity in ipairs(nearbyEntities) do
		if world:contains(entity) then
			local entityType = world:get(entity, Components.EntityType)
			if entityType and entityType.type == "Enemy" then
				local enemyPos = world:get(entity, Position)
				if enemyPos then
					local enemyPosVec = Vector3.new(enemyPos.x, enemyPos.y, enemyPos.z)
					local offset = enemyPosVec - playerPosVec
					local dist = Vector3.new(offset.X, 0, offset.Z).Magnitude  -- Ignore Y axis
					
					-- Check if enemy is within spawn ring radius
					if dist >= minRadius and dist <= maxRadius then
						-- Calculate angle from player to enemy
						local angle = math.atan2(offset.Z, offset.X)
						if angle < 0 then
							angle = angle + math.pi * 2  -- Normalize to 0-2π
						end
						
						-- Check if angle is within sector
						if angle >= sectorAngleMin and angle <= sectorAngleMax then
							count = count + 1
						end
					end
				end
			end
		end
	end
	
	return count
end

-- Select the emptiest sector around the player
-- Returns: (sectorAngleMin, sectorAngleMax, enemyCount)
local function selectEmptiestsector(playerPos: {x: number, y: number, z: number}): (number, number, number)
	local config = EnemyBalance.SectorSpawning
	local sectorCount = config.SectorCount or 8
	local sectorSize = (math.pi * 2) / sectorCount  -- Radians per sector
	
	local bestSectorMin = 0
	local bestSectorMax = sectorSize
	local lowestCount = math.huge
	
	-- Check each sector
	for i = 0, sectorCount - 1 do
		local sectorMin = i * sectorSize
		local sectorMax = (i + 1) * sectorSize
		
		local enemyCount = countEnemiesInSector(playerPos, sectorMin, sectorMax)
		
		if enemyCount < lowestCount then
			lowestCount = enemyCount
			bestSectorMin = sectorMin
			bestSectorMax = sectorMax
		end
	end
	
	return bestSectorMin, bestSectorMax, lowestCount
end

-- Count enemies within radius of a position using SpatialGridSystem
local function countEnemiesNearPosition(position: Vector3, radius: number): number
	if not world or not Components then
		return 0
	end
	
	-- Use SpatialGridSystem to efficiently find nearby enemies
	local radiusCells = math.ceil(radius / GRID_SIZE)
	local nearbyEntities = SpatialGridSystem.getNeighboringEntities(position, radiusCells)
	
	local count = 0
	for _, entity in ipairs(nearbyEntities) do
		if world:contains(entity) then
			local entityType = world:get(entity, Components.EntityType)
			if entityType and entityType.type == "Enemy" then
				local enemyPos = world:get(entity, Position)
				if enemyPos then
					local enemyPosVec = Vector3.new(enemyPos.x, enemyPos.y, enemyPos.z)
					local dist = (enemyPosVec - position).Magnitude
					if dist <= radius then
						count = count + 1
					end
				end
			end
		end
	end
	
	return count
end

local function getSpawnPositionForPlayer(ownerPos: {x: number, y: number, z: number}, otherPlayers: {Vector3}): Vector3?
	local placement = EnemyBalance.SpawnPlacement or {}
	local samples = placement.Samples or 8
	local desiredRadius = placement.DesiredRadius or ((EnemyBalance.MinSpawnRadius + EnemyBalance.MaxSpawnRadius) * 0.5)
	local minRadius = EnemyBalance.MinSpawnRadius or 90
	local maxRadius = EnemyBalance.MaxSpawnRadius or 170
	local avoidRadius = placement.AvoidOtherPlayersRadius or 60
	local weightOwner = placement.WeightOwner or 1.0
	local weightOthers = placement.WeightOthers or 4.0
	local weightDensity = placement.WeightDensity or 0.0
	local densityRadius = placement.DensityRadius or 30

	local bestPos: Vector3? = nil
	local bestCost = math.huge
	local ownerVec = Vector3.new(ownerPos.x, ownerPos.y, ownerPos.z)
	local angleOffset = math.random() * math.pi * 2

	for i = 1, samples do
		local angle = angleOffset + (i - 1) * (math.pi * 2 / samples)
		local distance = minRadius + math.random() * (maxRadius - minRadius)
		local offsetX = math.cos(angle) * distance
		local offsetZ = math.sin(angle) * distance
		local candidate = Vector3.new(ownerPos.x + offsetX, ownerPos.y, ownerPos.z + offsetZ)

		local grounded = getGroundedPosition(candidate, 0)
		if grounded then
			local distToOwner = (grounded - ownerVec).Magnitude
			local cost = math.abs(distToOwner - desiredRadius) * weightOwner

			if #otherPlayers > 0 then
				local nearestOther = math.huge
				for _, otherPos in ipairs(otherPlayers) do
					local dist = (grounded - otherPos).Magnitude
					if dist < nearestOther then
						nearestOther = dist
					end
				end
				if nearestOther < avoidRadius then
					cost += (avoidRadius - nearestOther) * weightOthers
				end
			end

			if weightDensity > 0 then
				local density = countEnemiesNearPosition(grounded, densityRadius)
				cost += density * weightDensity
			end

			if cost < bestCost then
				bestCost = cost
				bestPos = grounded
			end
		end
	end

	return bestPos
end

-- Get spawn position with sector-based distribution and density checking
-- Returns: (position: Vector3?, localDensity: number, sectorInfo: string?)
local function getDensityAwareSpawnPosition(playerPos: {x: number, y: number, z: number}): (Vector3?, number, string?)
	local densityConfig = EnemyBalance.SpawnDensityCheck
	local sectorConfig = EnemyBalance.SectorSpawning
	
	-- Check if sector spawning is enabled
	if not sectorConfig or not sectorConfig.Enabled then
		-- Fallback to old behavior (random position with density check)
		if not densityConfig or not densityConfig.Enabled then
			local pos = getRandomSpawnPosition(playerPos)
			local grounded = getGroundedPosition(pos, 0)
			return grounded, 999, nil
		end
		
		-- Old density-only logic
		local maxAttempts = densityConfig.MaxAttempts or 8
		local maxDensity = densityConfig.MaxEnemiesInRadius or 2
		local checkRadius = densityConfig.CheckRadius or 40
		
		local bestPosition = nil
		local bestDensity = math.huge
		
		for attempt = 1, maxAttempts do
			local candidatePos = getRandomSpawnPosition(playerPos)
			local groundedPos = getGroundedPosition(candidatePos, 0)
			
			if groundedPos then
				local density = countEnemiesNearPosition(groundedPos, checkRadius)
				
				if density < maxDensity then
					return groundedPos, density, nil
				end
				
				if density < bestDensity then
					bestDensity = density
					bestPosition = groundedPos
				end
			end
		end
		
		return bestPosition, bestDensity, nil
	end
	
	-- Sector-based spawning logic
	local sectorMin, sectorMax, sectorEnemyCount = selectEmptiestsector(playerPos)
	local attemptsPerSector = sectorConfig.AttemptsPerSector or 3
	
	local bestPosition = nil
	local bestDensity = math.huge
	
	-- Try multiple positions within the selected sector
	for attempt = 1, attemptsPerSector do
		local candidatePos = getRandomSpawnPosition(playerPos, sectorMin, sectorMax)
		local groundedPos = getGroundedPosition(candidatePos, 0)
		
		if groundedPos then
			-- Check local density if density checking is enabled
			local localDensity = 0
			if densityConfig and densityConfig.Enabled then
				local checkRadius = densityConfig.CheckRadius or 40
				localDensity = countEnemiesNearPosition(groundedPos, checkRadius)
				
				-- Early exit if we find a clean spot
				local maxDensity = densityConfig.MaxEnemiesInRadius or 2
				if localDensity < maxDensity then
					local sectorInfo = string.format("Sector %.0f°-%.0f° (%d enemies)", 
						math.deg(sectorMin), math.deg(sectorMax), sectorEnemyCount)
					return groundedPos, localDensity, sectorInfo
				end
			else
				-- No density check, just use first valid ground position
				local sectorInfo = string.format("Sector %.0f°-%.0f° (%d enemies)", 
					math.deg(sectorMin), math.deg(sectorMax), sectorEnemyCount)
				return groundedPos, localDensity, sectorInfo
			end
			
			-- Track best position as fallback
			if localDensity < bestDensity then
				bestDensity = localDensity
				bestPosition = groundedPos
			end
		end
	end
	
	-- Return best position found in sector (even if above density threshold)
	local sectorInfo = string.format("Sector %.0f°-%.0f° (%d enemies)", 
		math.deg(sectorMin), math.deg(sectorMax), sectorEnemyCount)
	return bestPosition, bestDensity, sectorInfo
end

function EnemySpawner.setEnabled(enabled: boolean)
	spawnEnabled = enabled
	if enabled then
		table.clear(playerSpawnCredits)
		table.clear(scalingCorrectionState)
	end
end

function EnemySpawner.step(dt: number)
	if not world or not spawnEnabled then
		return
	end
	-- Handle initial delay
	if not hasInitialDelayPassed then
		initialDelayAccumulator += dt
		if initialDelayAccumulator >= EnemyBalance.InitialSpawnDelay then
			hasInitialDelayPassed = true
		else
			return
		end
	end
	
	-- Throttle spawn checks (PERFORMANCE FIX - don't run every frame!)
	spawnCheckAccumulator += dt
	if spawnCheckAccumulator < SPAWN_CHECK_INTERVAL then
		return  -- Early exit, saves 95% of work
	end
	spawnCheckAccumulator -= SPAWN_CHECK_INTERVAL

	-- Global difficulty coefficient (RoR2-style)
	local coeff, coeffDetails = DifficultyCoeff.getCoeff()
	profGauge("Difficulty.Coeff", math.floor(coeff * 1000 + 0.5))
	profGauge("Difficulty.PlayerFactor", math.floor((coeffDetails.playerFactor or 0) * 1000 + 0.5))
	profGauge("Difficulty.TimeMinutes", math.floor((coeffDetails.timeMinutes or 0) * 100 + 0.5))
	local tierCfg = EnemyBalance.SuperElite or {}
	local superOdds, eliteOdds = computeTierOdds(coeffDetails.timeMinutes or 0, tierCfg)
	profGauge("SuperOdds", math.floor(superOdds * 10000 + 0.5))
	profGauge("EliteOdds", math.floor(eliteOdds * 10000 + 0.5))

	local GameStateManager = require(game.ServerScriptService.ECS.Systems.GameStateManager)
	-- Count current enemies using cached query
	local enemyCount = 0
	for entity, entityType in enemyCountQuery do
		if entityType and entityType.type == "Enemy" then
			enemyCount = enemyCount + 1
		end
	end

	-- Get player positions using cached query
	local eligiblePlayers = {}
	local playerPositions = {}
	local activePlayers: {[number]: boolean} = {}
	for entity, position, playerStats in playerPositionQuery do
		if playerStats and playerStats.player and playerStats.player.Parent then
			-- Skip players not in the game (in menu or wipe screen)
			if not GameStateManager.isPlayerInGame(playerStats.player) then
				-- Fallback: if the overall state is InGame, allow spawning even if the tracking table is out of sync.
				if GameStateManager.getCurrentState() ~= "InGame" then
					continue
				end
			end
			
			-- Skip paused players in individual pause mode (don't spawn enemies for them)
			if not GameOptions.GlobalPause then
				local pauseState = world:get(entity, Components.PlayerPauseState)
				if pauseState and pauseState.isPaused then
					continue
				end
				-- If a stale CooldownsFrozen flag exists without a pause state, don't block spawns.
			end
			
			table.insert(eligiblePlayers, {
				entity = entity,
				position = position,
				positionVec = Vector3.new(position.x, position.y, position.z),
				stats = playerStats,
				playerName = playerStats.player.Name,
			})
			activePlayers[entity] = true
		end
	end

	local activePlayerCount = math.max(1, #eligiblePlayers)
	for _, playerData in ipairs(eligiblePlayers) do
		local scaling = getPlayerScaling(playerData.entity, {
			coeff = coeff,
			timeMinutes = coeffDetails.timeMinutes or 0,
			playerCount = activePlayerCount,
			playerFactor = coeffDetails.playerFactor,
		})
		playerData.scaling = scaling
		if PROFILING_ENABLED then
			local playerName = playerData.playerName
			profGauge("SpawnRate." .. playerName, math.floor((scaling.spawnRate or 0) * 100 + 0.5))
			profGauge("SpawnCredits." .. playerName, math.floor((scaling.spawnCreditsPerSecond or scaling.spawnRate or 0) * 100 + 0.5))
			profGauge("AmbientLevel." .. playerName, math.floor((scaling.ambientLevel or 1) * 100 + 0.5))
			local corr = scaling.corrections or {}
			profGauge("ScalingCorr.Spawn." .. playerName, math.floor((corr.spawn or 1) * 1000 + 0.5))
			profGauge("ScalingCorr.HP." .. playerName, math.floor((corr.health or 1) * 1000 + 0.5))
			profGauge("ScalingCorr.Dmg." .. playerName, math.floor((corr.damage or 1) * 1000 + 0.5))
			profGauge("ScalingCorr.Spd." .. playerName, math.floor((corr.speed or 1) * 1000 + 0.5))
			profGauge("ScalingPower." .. playerName, math.floor((scaling.powerScore or 1) * 1000 + 0.5))
			profGauge("ScalingExpectedPower." .. playerName, math.floor((scaling.expectedPower or 1) * 1000 + 0.5))
		end
		table.insert(playerPositions, playerData)
	end

	if #playerPositions == 0 then
		-- No players, reset accumulators to prevent spawning when players join
		table.clear(playerSpawnCredits)
		table.clear(scalingCorrectionState)
		return
	end

	-- Active enemies per owner (profiling)
	local enemiesByOwner: {[number]: number} = {}
	for entity, entityType, ownerData in enemyOwnerQuery do
		if entityType and entityType.type == "Enemy" and ownerData and ownerData.id then
			enemiesByOwner[ownerData.id] = (enemiesByOwner[ownerData.id] or 0) + 1
		end
	end

	-- Active enemy tiers (profiling)
	local activeSuper = 0
	local activeElite = 0
	for entity, entityType, tierData in enemyTierQuery do
		if entityType and entityType.type == "Enemy" and tierData and tierData.tier then
			if tierData.tier == "Super" then
				activeSuper += 1
			elseif tierData.tier == "Elite" then
				activeElite += 1
			end
		end
	end

	if PROFILING_ENABLED then
		for _, playerData in ipairs(playerPositions) do
			local count = enemiesByOwner[playerData.entity] or 0
			profGauge("ActiveEnemies." .. playerData.playerName, count)
		end
		profGauge("ActiveSuper", activeSuper)
		profGauge("ActiveElite", activeElite)
	end

	-- Clear accumulators for players who left
	for entity in pairs(playerSpawnCredits) do
		if not activePlayers[entity] then
			playerSpawnCredits[entity] = nil
			scalingCorrectionState[entity] = nil
		end
	end

	-- Build per-player other-position lists once
	for _, playerData in ipairs(playerPositions) do
		local others = {}
		for _, otherData in ipairs(playerPositions) do
			if otherData.entity ~= playerData.entity then
				table.insert(others, otherData.positionVec)
			end
		end
		playerData.otherPositions = others
	end

	-- Global credit budget (RoR2-like director income clamp)
	local totalCreditsPerSecond = 0
	for _, playerData in ipairs(playerPositions) do
		totalCreditsPerSecond += (playerData.scaling.spawnCreditsPerSecond or playerData.scaling.spawnRate or 0)
	end

	local spawnBudget = EnemyBalance.SpawnBudget or {}
	local maxCreditsPerSecond = spawnBudget.MaxCreditsPerSecond or spawnBudget.MaxSpawnsPerSecond or totalCreditsPerSecond
	local globalSpawnScale = 1.0
	if totalCreditsPerSecond > 0 and totalCreditsPerSecond > maxCreditsPerSecond then
		globalSpawnScale = maxCreditsPerSecond / totalCreditsPerSecond
	end


	for _, playerData in ipairs(playerPositions) do
		local acc = playerSpawnCredits[playerData.entity] or 0
		acc += (playerData.scaling.spawnCreditsPerSecond or playerData.scaling.spawnRate or 0) * globalSpawnScale * SPAWN_CHECK_INTERVAL
		playerSpawnCredits[playerData.entity] = acc
	end

	-- Spawn enemies per player, respecting global caps
	local maxSpawnThisTick = EnemyBalance.SpawnBudget.MaxSpawnsPerTick or 12
	local spawnedThisTick = 0
	local maxEnemies = EnemyBalance.MaxEnemies or 275
	local directorCfg = EnemyBalance.SpawnDirector or {}
	if directorCfg.Enabled ~= false then
		local baseCap = math.max(1, math.floor(safeNumber(directorCfg.MaxMonstersBase, 40)))
		local additionalPerPlayer = math.max(0, safeNumber(directorCfg.AdditionalMonstersPerPlayer, 0))
		local directorCap = math.floor(baseCap + math.max(0, #playerPositions - 1) * additionalPerPlayer + 0.5)
		maxEnemies = math.min(maxEnemies, math.max(1, directorCap))
	end
	local tooCheapMultiplier = math.max(1.01, safeNumber(directorCfg.TooCheapMultiplier, 6.0))

	for _, playerData in ipairs(playerPositions) do
		if enemyCount >= maxEnemies or spawnedThisTick >= maxSpawnThisTick then
			break
		end

		local acc = playerSpawnCredits[playerData.entity] or 0
		while acc >= minEnemyCost and enemyCount < maxEnemies and spawnedThisTick < maxSpawnThisTick do
			-- Select an affordable spawn card (enemy type + base credit cost)
			local enemyType, enemyCost = selectEnemyTypeForCredits(acc, tooCheapMultiplier)
			if not enemyType or not enemyCost then
				break
			end

			local tier = rollTier(superOdds, eliteOdds)
			local tierMult = { health = 1.0, damage = 1.0, speed = 1.0, size = 1.0 }
			local tierCostMultiplier = 1.0
			if tier == "Super" then
				tierMult = tierCfg.SuperMult or tierMult
				tierCostMultiplier = math.max(1.0, safeNumber(tierCfg.SuperCreditCostMult, 4.0))
				profInc("SuperSpawned", 1)
			elseif tier == "Elite" then
				tierMult = tierCfg.EliteMult or tierMult
				tierCostMultiplier = math.max(1.0, safeNumber(tierCfg.EliteCreditCostMult, 6.0))
				profInc("EliteSpawned", 1)
			end

			local spendCost = enemyCost * tierCostMultiplier
			if spendCost > acc then
				tier = "Normal"
				tierMult = { health = 1.0, damage = 1.0, speed = 1.0, size = 1.0 }
				spendCost = enemyCost
			end
			acc -= spendCost

			-- Ensure hitbox data is cached for this enemy type
			local replicationSuccess = ModelReplicationService.ensureEnemyHitbox(enemyType)
			if not replicationSuccess then
				warn(string.format("[EnemySpawner] Could not find %s model in ReplicatedStorage, skipping spawn this frame", enemyType))
				break
			end

			-- Choose spawn position around the owner, biased away from other players
			local groundedPos = getSpawnPositionForPlayer(playerData.position, playerData.otherPositions or {})
			if not groundedPos then
				continue
			end

			local finalSpawnPos = adjustSpawnHeightForEnemy(groundedPos, enemyType, tierMult.size or 1.0)

			local baseScaling = playerData.scaling or {}
			local spawnScaling = {
				healthMult = (baseScaling.healthMult or 1) * (tierMult.health or 1),
				damageMult = (baseScaling.damageMult or 1) * (tierMult.damage or 1),
				speedMult = (baseScaling.speedMult or 1) * (tierMult.speed or 1),
				spawnRate = baseScaling.spawnRate,
				spawnCreditsPerSecond = baseScaling.spawnCreditsPerSecond,
				corrections = baseScaling.corrections,
				coeff = baseScaling.coeff,
				tier = tier,
				visualScale = tierMult.size or 1,
			}

			local enemyEntity = ECSWorldService.CreateEnemy(enemyType, finalSpawnPos, playerData.entity, spawnScaling)

			if enemyEntity then
				enemyCount += 1
				zombieSpawnCounter += 1
				spawnedThisTick += 1
			end
		end

		playerSpawnCredits[playerData.entity] = acc
	end
end

return EnemySpawner

