--!strict
-- Bootstrap Script - wires ECS world, systems, and client synchronization

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ECS = require(game.ServerScriptService.ECS.ECSFacade)
local DirtyService = require(game.ServerScriptService.ECS.DirtyService)
local ProjectilePool = require(game.ServerScriptService.ECS.ProjectilePool)
local ExpOrbPool = require(game.ServerScriptService.ECS.ExpOrbPool)
local EnemyPool = require(game.ServerScriptService.ECS.EnemyPool)
local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local MovementSystem = require(game.ServerScriptService.ECS.Systems.MovementSystem)
local LifetimeSystem = require(game.ServerScriptService.ECS.Systems.LifetimeSystem)
local SyncSystem = require(game.ServerScriptService.ECS.Systems.SyncSystem)
local PlayerPositionSyncSystem = require(game.ServerScriptService.ECS.Systems.PlayerPositionSyncSystem)
local ZombieAISystem = require(game.ServerScriptService.ECS.Systems.ZombieAISystem)
local ChargerAISystem = require(game.ServerScriptService.ECS.Systems.ChargerAISystem)
local EnemyRepulsionSystem = require(game.ServerScriptService.ECS.Systems.EnemyRepulsionSystem)
local EnemySpawner = require(game.ServerScriptService.ECS.Systems.EnemySpawner)
local OctreeSystem = require(game.ServerScriptService.ECS.Systems.OctreeSystem)
local ProjectileCollisionSystem = require(game.ServerScriptService.ECS.Systems.ProjectileCollisionSystem)
local HomingSystem = require(game.ServerScriptService.ECS.Systems.HomingSystem)
local ProjectileOrbitSystem = require(game.ServerScriptService.ECS.Systems.ProjectileOrbitSystem)
local SpatialGridSystem = require(game.ServerScriptService.ECS.Systems.SpatialGridSystem)
local DamageSystem = require(game.ServerScriptService.ECS.Systems.DamageSystem)
local HitFlashSystem = require(game.ServerScriptService.ECS.Systems.HitFlashSystem)
local DeathAnimationSystem = require(game.ServerScriptService.ECS.Systems.DeathAnimationSystem)
local DeathSystem = require(game.ServerScriptService.ECS.Systems.DeathSystem)
local DeathBodyFadeSystem = require(game.ServerScriptService.ECS.Systems.DeathBodyFadeSystem)
local KnockbackSystem = require(game.ServerScriptService.ECS.Systems.KnockbackSystem)
local EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)
local GlobalBalance = require(game.ServerScriptService.Balance.GlobalBalance)
local ItemBalance = require(game.ServerScriptService.Balance.ItemBalance)
local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local DEBUG = GameOptions.Debug and GameOptions.Debug.Enabled

-- Ability Registry - Auto-discovers and loads all abilities
local AbilityRegistry = require(game.ServerScriptService.Abilities.AbilityRegistry)
local AbilitySystemBase = require(game.ServerScriptService.Abilities.AbilitySystemBase)

-- Enemy Registry - Auto-discovers and loads all enemy types
local EnemyRegistry = require(game.ServerScriptService.Enemies.EnemyRegistry)

-- EXP/Leveling Systems
local ExpOrbSpawner = require(game.ServerScriptService.ECS.Systems.ExpOrbSpawner)
local ExpCollectionSystem = require(game.ServerScriptService.ECS.Systems.ExpCollectionSystem)
local ExpSystem = require(game.ServerScriptService.ECS.Systems.ExpSystem)
local ExpSinkSystem = require(game.ServerScriptService.ECS.Systems.ExpSinkSystem)
local EnemyExpDropSystem = require(game.ServerScriptService.ECS.Systems.EnemyExpDropSystem)
local PauseSystem = require(game.ServerScriptService.ECS.Systems.PauseSystem)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)

-- Upgrade Systems
local UpgradeSystem = require(game.ServerScriptService.ECS.Systems.UpgradeSystem)
local PassiveEffectSystem = require(game.ServerScriptService.ECS.Systems.PassiveEffectSystem)

-- Status Effect System
local StatusEffectSystem = require(game.ServerScriptService.ECS.Systems.StatusEffectSystem)

-- Powerup Systems
local OverhealSystem = require(game.ServerScriptService.ECS.Systems.OverhealSystem)
local BuffSystem = require(game.ServerScriptService.ECS.Systems.BuffSystem)
local PowerupEffectSystem = require(game.ServerScriptService.ECS.Systems.PowerupEffectSystem)
local PowerupCollectionSystem = require(game.ServerScriptService.ECS.Systems.PowerupCollectionSystem)
local HealthRegenSystem = require(game.ServerScriptService.ECS.Systems.HealthRegenSystem)
local MagnetPullSystem = require(game.ServerScriptService.ECS.Systems.MagnetPullSystem)

-- Mobility System
local MobilitySystem = require(game.ServerScriptService.ECS.Systems.MobilitySystem)

-- Afterimage Clone System (for Afterimages attribute)
local AfterimageCloneSystem = require(game.ServerScriptService.ECS.Systems.AfterimageCloneSystem)

-- Game State Manager
local GameStateManager = require(game.ServerScriptService.ECS.Systems.GameStateManager)
local FriendsListSystem = require(game.ServerScriptService.ECS.Systems.FriendsListSystem)

-- Ability system throttle (PERFORMANCE FIX - don't run every frame!)
local ABILITY_SYSTEM_INTERVAL = 0.033  -- CRITICAL FIX: 30 FPS (was 20) - better responsiveness for abilities
local abilitySystemAccumulator = 0

-- OPTIMIZATION PHASE 2: AI System Throttling
-- Gate heavy AI/simulation systems to reduce O(n) CPU cost
local ZOMBIE_AI_INTERVAL = 0.0333  -- 30 FPS (was 60 FPS)
local zombieAIAccumulator = 0

local CHARGER_AI_INTERVAL = 0.0333  -- 30 FPS (was 60 FPS)
local chargerAIAccumulator = 0

local ENEMY_REPULSION_INTERVAL = 0.0333  -- 30 FPS (was 60 FPS)
local enemyRepulsionAccumulator = 0

local STATUS_EFFECT_INTERVAL = 0.05  -- 20 FPS (was 60 FPS) - expiration checks less critical
local statusEffectAccumulator = 0

local world = ECS.World
local Components = ECS.Components

local EntitySync = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS"):WaitForChild("EntitySync")
local EntityUpdate = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS"):WaitForChild("EntityUpdate")
local EntityDespawn = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS"):WaitForChild("EntityDespawn")
local RequestInitialSync = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS"):WaitForChild("RequestInitialSync")

local Position = Components.Position
local Velocity = Components.Velocity
local EntityType = Components.EntityType
local Health = Components.Health
local Damage = Components.Damage
local Collision = Components.Collision
local AI = Components.AI
local Projectile = Components.Projectile
local ProjectileData = Components.ProjectileData
local ItemData = Components.ItemData
local PlayerStats = Components.PlayerStats
local Visual = Components.Visual
local Lifetime = Components.Lifetime
local AttackCooldown = Components.AttackCooldown
local Target = Components.Target
local Experience = Components.Experience
local Level = Components.Level
local Upgrades = Components.Upgrades
local PassiveEffectsComp = Components.PassiveEffects
local StatusEffects = Components.StatusEffects

local ECSWorldService = {}

local entityCount = 0
local activeEntities: {[number]: boolean} = {}
local playerEntities: {[Player]: number} = {}
local entityToPlayer: {[number]: Player} = {}

local function setComponent(entity: number, component: any, value: any, componentName: string)

	local current = world:get(entity, component)
	if current ~= nil then
		DirtyService.setIfChanged(world, entity, component, value, componentName)
	else
		world:set(entity, component, value)
		DirtyService.mark(entity, componentName)
	end
end

local function markNewEntity(entity: number)
	SyncSystem.markForInitialSync(entity)
end

function ECSWorldService.Initialize()
	
	-- Initialize model replication first (clones models from ServerStorage to ReplicatedStorage)
	ModelReplicationService.init()
	
	-- Initialize object pools (PERFORMANCE OPTIMIZATION: pre-allocate reusable entities)
	ProjectilePool.init(world, Components)
	ExpOrbPool.init(world, Components)
	EnemyPool.init(world, Components)
	
	-- Initialize systems (using pure JECS patterns, no QueryPool)
	PlayerPositionSyncSystem.init(world, Components, DirtyService)
	SpatialGridSystem.init(world, Components, DirtyService)
	MovementSystem.init(world, Components, DirtyService)
	LifetimeSystem.init(world, Components, DirtyService)
	SyncSystem.init(world, Components, DirtyService, {
		EntitySync = EntitySync,
		EntityUpdate = EntityUpdate,
		EntityDespawn = EntityDespawn,
	}, {
		getPlayerFromEntity = function(entityId)
			return entityToPlayer[entityId]
		end,
	})
	-- Initialize OctreeSystem for fast spatial queries (BEFORE AI/Repulsion systems)
	OctreeSystem.init(world, Components)
	OctreeSystem.setStatusEffectSystem(StatusEffectSystem)
	ZombieAISystem.init(world, Components, DirtyService, ECSWorldService)
	ChargerAISystem.init(world, Components, DirtyService)
	EnemyRepulsionSystem.init(world, Components, DirtyService)
	EnemySpawner.init(world, Components, ECSWorldService, ModelReplicationService)
	
	-- Initialize Pause system (before ExpSystem, as ExpSystem depends on it)
	PauseSystem.init(world, Components, DirtyService)
	
	-- Initialize Death System (after PauseSystem)
	DeathSystem.init(world, Components, DirtyService)
	DeathSystem.setPauseSystem(PauseSystem)
	
	-- Note: GameStateManager reference will be set after GameStateManager.init()
	
	-- Create death system remotes early so clients don't yield
	local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	if not remotesFolder:FindFirstChild("PlayerDied") then
		local playerDied = Instance.new("RemoteEvent")
		playerDied.Name = "PlayerDied"
		playerDied.Parent = remotesFolder
	end
	if not remotesFolder:FindFirstChild("PlayerRespawned") then
		local playerRespawned = Instance.new("RemoteEvent")
		playerRespawned.Name = "PlayerRespawned"
		playerRespawned.Parent = remotesFolder
	end
	if not remotesFolder:FindFirstChild("PlayerBodyFade") then
		local playerBodyFade = Instance.new("RemoteEvent")
		playerBodyFade.Name = "PlayerBodyFade"
		playerBodyFade.Parent = remotesFolder
	end
	
	-- Create session timer sync remote
	if not remotesFolder:FindFirstChild("SessionTimerUpdate") then
		local SessionTimerUpdate = Instance.new("RemoteEvent")
		SessionTimerUpdate.Name = "SessionTimerUpdate"
		SessionTimerUpdate.Parent = remotesFolder
	end
	if not remotesFolder:FindFirstChild("PlayerBodyRestore") then
		local playerBodyRestore = Instance.new("RemoteEvent")
		playerBodyRestore.Name = "PlayerBodyRestore"
		playerBodyRestore.Parent = remotesFolder
	end
	
	-- Initialize Game Time system (after PauseSystem, before systems that use scaling)
	GameTimeSystem.init()
	
	-- Initialize Upgrade systems (before ExpSystem, as it depends on them)
	UpgradeSystem.init(world, Components, DirtyService)
	PassiveEffectSystem.init(world, Components, DirtyService)
	
	-- Initialize Status Effect system (before ExpSystem, as it depends on it)
	StatusEffectSystem.init(world, Components, DirtyService)
	StatusEffectSystem.setPassiveEffectSystem(PassiveEffectSystem)
	PassiveEffectSystem.setStatusEffectSystem(StatusEffectSystem)
	PauseSystem.setStatusEffectSystem(StatusEffectSystem)  -- Set reference for individual pause invincibility
	ZombieAISystem.setStatusEffectSystem(StatusEffectSystem)  -- Set reference for zombie damage invincibility check
	ZombieAISystem.setPauseSystem(PauseSystem)  -- Set reference for enemy pause transitions
	ChargerAISystem.setPauseSystem(PauseSystem)  -- Set reference for enemy pause transitions
	PauseSystem.setZombieAISystem(ZombieAISystem)  -- Set zombie AI system reference
	PauseSystem.setChargerAISystem(ChargerAISystem)  -- Set charger AI system reference
	ChargerAISystem.setOctreeSystem(OctreeSystem)
	ChargerAISystem.setDamageSystem(DamageSystem)
	ChargerAISystem.setStatusEffectSystem(StatusEffectSystem)
	ChargerAISystem.setGameTimeSystem(GameTimeSystem)
	
	-- Initialize Mobility system (after StatusEffectSystem for invincibility frames)
	MobilitySystem.init(world, Components, DirtyService)
	
	-- Initialize Game State Manager (before player systems)
	GameStateManager.init(world, Components, DirtyService, ECSWorldService)
	GameStateManager.setStatusEffectSystem(StatusEffectSystem)
	GameStateManager.setPauseSystem(PauseSystem)
	
	-- Initialize Session Stats Tracker
	local SessionStatsTracker = require(game.ServerScriptService.ECS.Systems.SessionStatsTracker)
	SessionStatsTracker.init(world, Components, DirtyService)
	
	-- Set GameStateManager reference in DeathSystem
	DeathSystem.setGameStateManager(GameStateManager)
	
	-- Initialize Friends List System
	FriendsListSystem.init()
	
	-- Initialize Powerup systems
	OverhealSystem.init(world, Components, DirtyService)
	BuffSystem.init(world, Components, DirtyService)
	BuffSystem.setPassiveEffectSystem(PassiveEffectSystem)
	PowerupEffectSystem.init(world, Components, DirtyService, ECSWorldService)
	PowerupEffectSystem.setDamageSystem(DamageSystem)
	PowerupEffectSystem.setOverhealSystem(OverhealSystem)
	PowerupEffectSystem.setStatusEffectSystem(StatusEffectSystem)
	PowerupEffectSystem.setBuffSystem(BuffSystem)
	PowerupEffectSystem.setEnemySpawner(EnemySpawner)
	PowerupCollectionSystem.init(world, Components, DirtyService, ECSWorldService)
	PowerupCollectionSystem.setPowerupEffectSystem(PowerupEffectSystem)
	
	-- Initialize Health Regen system
	HealthRegenSystem.init(world, Components, DirtyService)
	MagnetPullSystem.init(world, Components, DirtyService)
	DamageSystem.setOverhealSystem(OverhealSystem)
	
	-- Initialize EXP/Leveling systems
	ExpSystem.init(world, Components, DirtyService)
	ExpSinkSystem.init(world, Components, DirtyService, ECSWorldService, SyncSystem)
	EnemyExpDropSystem.init(world, Components, DirtyService, ECSWorldService, ExpSinkSystem)
	ExpCollectionSystem.init(world, Components, DirtyService, ECSWorldService)
	ExpCollectionSystem.setExpSystem(ExpSystem)  -- Set reference after ExpSystem is initialized
	ExpCollectionSystem.setExpSinkSystem(ExpSinkSystem)  -- Set reference after ExpSinkSystem is initialized
	ExpOrbSpawner.init(world, Components, ECSWorldService, ModelReplicationService, ExpSinkSystem, DirtyService)
	
	-- Setup unpause callback (after ExpSystem and UpgradeSystem are initialized)
	PauseSystem.setUnpauseCallback(function(action: string, player: Player, upgradeId: string?, pauseToken: number?)
		local playerEntity = playerEntities[player]
		
		if action == "skip" then
			if playerEntity then
				ExpSystem.skipLevel(playerEntity)
				-- Apply passive effects to restore walkspeed after skip
				PassiveEffectSystem.applyToPlayer(playerEntity)
			end
		elseif action == "upgrade" then
			if playerEntity and upgradeId then
				-- Apply the selected upgrade
				local success = UpgradeSystem.applyUpgrade(playerEntity, upgradeId)
				if success then
					-- Apply passive effects immediately (updates PassiveEffects component)
					PassiveEffectSystem.applyToPlayer(playerEntity)
				end
			end
		end
		
		-- Check if there are more queued levels (don't unpause yet)
		-- Calculate current pause duration BEFORE processing next level (which creates new pause)
		local pauseState = world:get(playerEntity, Components.PlayerPauseState)
		local oldPauseDuration = 0
		if pauseState and pauseState.pauseStartTime then
			local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
			oldPauseDuration = GameTimeSystem.getGameTime() - pauseState.pauseStartTime
		end
		
		local hasMoreLevels = playerEntity and ExpSystem.processNextQueuedLevel(playerEntity)
		if hasMoreLevels then
			-- More levels queued, extend pause-aware buffs using OLD pause duration
			if oldPauseDuration > 0 then
				StatusEffectSystem.onPlayerPaused(playerEntity, oldPauseDuration)
			end
			
			-- SAFETY: Verify pause state still exists after processing queued level
			-- If pause state was lost, unpause to prevent softlock
			local newPauseState = world:get(playerEntity, Components.PlayerPauseState)
			if not newPauseState then
				warn("[Bootstrap] ERROR: processNextQueuedLevel returned true but pause state is missing!")
				warn("[Bootstrap] This indicates a race condition - forcing unpause to prevent softlock")
				
				-- Fallback: unpause the player to prevent being stuck
				if not GameOptions.GlobalPause and playerEntity and player then
					PauseSystem.unpausePlayer(playerEntity, player)
				end
			end
			
			-- Release this level's pause token (stay paused if more levels queued)
			if not GameOptions.GlobalPause and playerEntity and player then
				PauseSystem.releasePauseToken(playerEntity, player, pauseToken, "queue_next")
			end
			
			return  -- Don't grant buffs yet or unpause (unless safety fallback triggered)
		end
		
		-- Unpause FIRST (this extends pause-aware buffs like spawn protection)
		if not GameOptions.GlobalPause and playerEntity then
			-- Individual pause: release final pause token (unpause happens when count hits 0)
			PauseSystem.releasePauseToken(playerEntity, player, pauseToken, "queue_empty")
		else
			-- Global pause: unpause entire game
			PauseSystem.unpause()
		end
		
		-- THEN grant level-up buffs (2s invincibility + 15% speed boost)
		-- Speed boost now uses PassiveEffects system - stacks properly with Haste and Cloak
		if playerEntity then
			StatusEffectSystem.grantInvincibility(playerEntity, 2.0, true, false, false)  -- Levelup invincibility (not spawn protection)
			StatusEffectSystem.grantSpeedBoost(playerEntity, 2.0, 1.15, "levelUp")  -- 15% speed boost for 2s
		end
	end)
	
	-- Initialize all ability systems from registry
	for abilityId, ability in pairs(AbilityRegistry.getAll()) do
		ability.init(world, Components, DirtyService, ECSWorldService)
	end
	
	-- Initialize Afterimage Clone System (for Afterimages attribute)
	AfterimageCloneSystem.init(world, Components, DirtyService, ECSWorldService)
	
	-- Initialize combat systems
	DamageSystem.init(world, Components, DirtyService)
	DamageSystem.setEnemyExpDropSystem(EnemyExpDropSystem)  -- Set reference for enemy death drops
	DamageSystem.setStatusEffectSystem(StatusEffectSystem)  -- Set reference for invincibility checks
	HitFlashSystem.init(world, Components)
	DeathAnimationSystem.init(world, Components, ECSWorldService)
	KnockbackSystem.init(world, Components, DirtyService)
	
	ProjectileCollisionSystem.init(world, Components, DirtyService, ECSWorldService)
	HomingSystem.init(world, Components, DirtyService)
	ProjectileOrbitSystem.init(world, Components, DirtyService)
	
end

function ECSWorldService.CreateEntity(entityTypeName: string, position: Vector3, owner: any?): any
	local entity: number
	
	-- Route entity creation through appropriate object pools for performance
	if entityTypeName == "Projectile" then
		-- Use projectile pool (includes explosions as subtype)
		entity = ProjectilePool.acquire(position, owner, "Generic")
		-- Caller will set ProjectileData, Damage, etc.
		markNewEntity(entity)
		entityCount += 1
		activeEntities[entity] = true
		return entity
	elseif entityTypeName == "ExpOrb" then
		-- Use exp orb pool
		entity = ExpOrbPool.acquire(position, owner)
		-- Caller will set ItemData value
		markNewEntity(entity)
		entityCount += 1
		activeEntities[entity] = true
		return entity
	elseif entityTypeName == "Enemy" then
		-- Use enemy pool (caller should specify subtype via owner or additional param)
		-- For now, default to Zombie; caller can override by modifying EntityType after
		entity = EnemyPool.acquire("Zombie", position, owner)
		markNewEntity(entity)
		entityCount += 1
		activeEntities[entity] = true
		return entity
	end
	
	-- Fall back to non-pooled entity creation for Player and other types
	entity = world:entity()

	setComponent(entity, Position, { x = position.X, y = position.Y, z = position.Z }, "Position")
	setComponent(entity, Velocity, { x = 0, y = 0, z = 0 }, "Velocity")

	local entityTypeData = {
		type = entityTypeName,
	}

	if owner ~= nil and entityTypeName ~= "Player" then
		entityTypeData.owner = owner
	elseif owner ~= nil and entityTypeName == "Player" then
		entityTypeData.player = owner
	end

	setComponent(entity, EntityType, entityTypeData, "EntityType")

	if entityTypeName ~= "Player" then
		setComponent(entity, Visual, { modelPath = nil, visible = true }, "Visual")
	end

	markNewEntity(entity)

	entityCount += 1
	activeEntities[entity] = true
    -- Entity created

	return entity
end

-- Helper: Calculate direction from enemy spawn position to nearest player
local function getDirectionToNearestPlayer(spawnPos: Vector3): {x: number, y: number, z: number}
	local nearestPlayer = nil
	local minDistSq = math.huge
	
	-- Find nearest player
	for player, entity in pairs(playerEntities) do
		if player.Character and player.Character.PrimaryPart then
			local playerPos = player.Character.PrimaryPart.Position
			local distSq = (playerPos - spawnPos).Magnitude ^ 2
			if distSq < minDistSq then
				minDistSq = distSq
				nearestPlayer = playerPos
			end
		end
	end
	
	-- Calculate direction to nearest player (or default forward)
	if nearestPlayer then
		local direction = (nearestPlayer - spawnPos)
		direction = Vector3.new(direction.X, 0, direction.Z) -- Flatten Y (horizontal facing only)
		if direction.Magnitude > 0.01 then
			direction = direction.Unit
			return {x = direction.X, y = 0, z = direction.Z}
		end
	end
	
	-- Default: face forward
	return {x = 0, y = 0, z = 1}
end

function ECSWorldService.CreateEnemy(enemyType: string, position: Vector3, owner: any?): any
	local entity = ECSWorldService.CreateEntity("Enemy", position, owner)
	if not entity then
		return nil
	end

	-- Get enemy configuration from registry
	local enemyConfig = EnemyRegistry.getEnemyConfig(enemyType or "Zombie")
	if not enemyConfig then
		warn("[Bootstrap] Failed to get config for enemy type:", enemyType)
		return nil
	end
	
	local visualPath = enemyConfig.modelPath

	-- Apply global health scaling based on game time
	local EasingUtils = require(game.ServerScriptService.Balance.EasingUtils)
	local gameTime = GameTimeSystem.getGameTime()
	local healthScaling = EasingUtils.evaluate(EnemyBalance.GlobalHealthScaling, gameTime)
	
	-- Apply multiplayer health scaling (configurable per player)
	local Players = game:GetService("Players")
	local playerCount = #Players:GetPlayers()
	local healthPerPlayer = EnemyBalance.Multiplayer.HealthPerPlayer or 0.66
	local multiplayerHealthScale = 1 + healthPerPlayer * math.max(0, playerCount - 1)
	
	local baseHealth = enemyConfig.baseHealth * (EnemyBalance.HealthMultiplier or 1) * (GlobalBalance.HealthMultiplier or 1) * healthScaling * multiplayerHealthScale
	
	-- Debug: Log multiplayer scaling for first few enemies
	if DEBUG then
		local debugCount = workspace:GetAttribute("MultiplayerHealthScalingDebug") or 0
		if debugCount < 3 then
			workspace:SetAttribute("MultiplayerHealthScalingDebug", debugCount + 1)
			print(string.format("[CreateEnemy] %s | Players: %d | Health: %.1f (base: %.1f, multiplayer: %.2fx)", 
				enemyType, playerCount, baseHealth, enemyConfig.baseHealth, multiplayerHealthScale))
		end
	end
	local baseDamage = enemyConfig.baseDamage * (EnemyBalance.DamageMultiplier or 1)
	local baseSpeed = enemyConfig.baseSpeed

	setComponent(entity, EntityType, {
		type = "Enemy",
		subtype = enemyType or "Zombie",
	}, "EntityType")
	setComponent(entity, Velocity, { x = 0, y = 0, z = 0 }, "Velocity")
	setComponent(entity, Health, { current = baseHealth, max = baseHealth }, "Health")
	setComponent(entity, Damage, { amount = baseDamage, type = "physical" }, "Damage")
	-- Don't set state for Chargers - let ChargerAISystem initialize it with numeric constants
	local initialState = (enemyType == "Charger") and nil or "Idle"
	
	setComponent(entity, AI, {
		state = initialState,
		target = nil,
		behavior = enemyConfig.behavior,
		behaviorType = enemyType or "Zombie",  -- Store enemy type for AI system dispatch
		speed = baseSpeed,
		attackRange = enemyConfig.attackRange,
		balance = enemyConfig,  -- Store full balance config for behavior-specific logic
	}, "AI")
	setComponent(entity, AttackCooldown, { remaining = 0, max = enemyConfig.attackCooldown }, "AttackCooldown")
	setComponent(entity, Visual, { modelPath = visualPath, visible = true }, "Visual")
	setComponent(entity, Target, { id = nil }, "Target")
	
	-- Add repulsion component for enemy separation
	if EnemyBalance.EnableRepulsion then
		setComponent(entity, Components.Repulsion, {
			radius = EnemyBalance.RepulsionRadius or 2.0,
			strength = EnemyBalance.RepulsionStrength or 8.0,
		}, "Repulsion")
	end
	
	-- Set spawn time for lifetime-based speed scaling
	local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
	setComponent(entity, Components.SpawnTime, {
		time = GameTimeSystem.getGameTime()
	}, "SpawnTime")
	
	-- Initialize paused time tracking for lifetime scaling during pause
	setComponent(entity, Components.EnemyPausedTime, {
		totalPausedTime = 0.0
	}, "EnemyPausedTime")
	
	-- Validate enemy has visual component (detect missing models early)
	local visual = world:get(entity, Components.Visual)
	if not visual or not visual.modelPath then
		warn(string.format("[Bootstrap] Created enemy %d (type: %s) without visual! modelPath missing.", entity, enemyType))
	end
	
	-- Add facing direction component - face nearest player on spawn
	local facingDir = getDirectionToNearestPlayer(position)
	setComponent(entity, Components.FacingDirection, facingDir, "FacingDirection")
	
	-- Add ChargerState component for Charger enemies
	if enemyType == "Charger" then
		setComponent(entity, Components.ChargerState, {
			state = nil,  -- ChargerAISystem will initialize on first frame
			stateEndTime = 0,
			dashDirection = nil,
			hitOnThisDash = false,
			preferredRange = 26,
		}, "ChargerState")
	end

	if DEBUG then
		assert(world:has(entity, Position), "[Bootstrap] Enemy missing Position after spawn")
		assert(world:has(entity, EntityType), "[Bootstrap] Enemy missing EntityType after spawn")
		assert(world:has(entity, Health), "[Bootstrap] Enemy missing Health after spawn")
	end

    -- Enemy created

	return entity
end

function ECSWorldService.CreateExpOrb(orbType: string, position: Vector3, ownerId: number?, startVisible: boolean?): any?
	local entity = ECSWorldService.CreateEntity("ExpOrb", position, nil)
	if not entity then
		return nil
	end
	
	local orbConfig = ItemBalance.OrbTypes[orbType]
	if not orbConfig then
		orbConfig = ItemBalance.OrbTypes.Blue  -- Fallback
	end
	
	local visualPath = "ReplicatedStorage.ContentDrawer.ItemModels.OrbTemplate"
	
	setComponent(entity, EntityType, {
		type = "ExpOrb",
		subtype = orbType,
	}, "EntityType")
	
	setComponent(entity, Velocity, { x = 0, y = 0, z = 0 }, "Velocity")
	
	setComponent(entity, Components.ItemData, {
		type = "ExpOrb",
		subtype = orbType,
		expAmount = orbConfig.expAmount,
		collected = false,
		color = orbConfig.color,  -- Store color in ItemData (not Visual) to avoid sharing
		uniqueId = entity,  -- CRITICAL: Prevents shared component reuse causing red orb color bleeding
		ownerId = ownerId,  -- MULTIPLAYER: Per-player orb ownership (nil = global/visible to all)
	}, "ItemData")
	
	-- Start visible immediately (no defer to prevent race conditions)
	setComponent(entity, Visual, {
		modelPath = visualPath,
		visible = true,  -- Always visible from creation
		scale = 1.0,  -- Regular orbs use default scale (red orb will be scaled when converted)
	}, "Visual")
	
	setComponent(entity, Collision, {
		radius = 1.5,  -- Orb collection radius
		solid = false
	}, "Collision")
	
	setComponent(entity, Lifetime, {
		remaining = ItemBalance.OrbLifetime,
		max = ItemBalance.OrbLifetime
	}, "Lifetime")
	
	if DEBUG then
		assert(world:has(entity, Position), "[Bootstrap] ExpOrb missing Position after spawn")
		assert(world:has(entity, EntityType), "[Bootstrap] ExpOrb missing EntityType after spawn")
		assert(world:has(entity, ItemData), "[Bootstrap] ExpOrb missing ItemData after spawn")
	end

	markNewEntity(entity)
	
	-- Exp orb created (visible from spawn)
	return entity
end

-- Spawn starter exp orbs around player when they join
function ECSWorldService.SpawnStarterExps(player: Player, playerPosition: Vector3, playerEntity: number)
	local config = ItemBalance.SpawnExps
	if not config or not config.Enabled then
		return
	end
	
	-- Calculate number of orbs to spawn
	local orbCount = math.random(config.MinOrbs or 85, config.MaxOrbs or 100)
	
	-- Use Random.new() for better randomization
	local RNG = Random.new()
	
	-- Build cumulative weight table for orb types
	local cumulative = {}
	local totalWeight = 0
	for _, orbType in ipairs(ItemBalance.OrbTypesList) do
		local weight = config.SpawnWeights[orbType] or 0
		totalWeight = totalWeight + weight
		table.insert(cumulative, {type = orbType, threshold = totalWeight})
	end
	
	-- Normalize to 0-1 range
	for _, entry in ipairs(cumulative) do
		entry.threshold = entry.threshold / totalWeight
	end
	
	-- Helper function to pick orb type
	local function pickOrbType(): string
		local roll = RNG:NextNumber()
		for _, entry in ipairs(cumulative) do
			if roll <= entry.threshold then
				return entry.type
			end
		end
		return "Blue"  -- Fallback
	end
	
	-- Spawn orbs
	local spawned = 0
	local spawnedEntities = {}  -- Track spawned orb entities
	
	for i = 1, orbCount do
		local maxAttempts = config.MaxSpawnAttempts or 3
		local validPosition = nil
		
		for attempt = 1, maxAttempts do
			-- Pick random angle and distance
			local angle = RNG:NextNumber() * math.pi * 2
			local minRadius = config.MinRadius or 25
			local maxRadius = config.MaxRadius or 40
			local distance = minRadius + RNG:NextNumber() * (maxRadius - minRadius)
			
			-- Calculate offset position
			local offsetX = math.cos(angle) * distance
			local offsetZ = math.sin(angle) * distance
			local spawnPos = Vector3.new(
				playerPosition.X + offsetX,
				playerPosition.Y,
				playerPosition.Z + offsetZ
			)
			
			-- Ground detection if enabled
			if config.UseGroundDetection then
				-- Simple ground raycast
				local origin = spawnPos + Vector3.new(0, 25, 0)
				local raycastParams = RaycastParams.new()
				raycastParams.FilterType = Enum.RaycastFilterType.Exclude
				raycastParams.IgnoreWater = true
				
				-- Exclude player character
				local partsToExclude = {}
				if player.Character then
					for _, part in pairs(player.Character:GetDescendants()) do
						if part:IsA("BasePart") then
							table.insert(partsToExclude, part)
						end
					end
				end
				raycastParams.FilterDescendantsInstances = partsToExclude
				
				local result = workspace:Raycast(origin, Vector3.new(0, -200, 0), raycastParams)
				if result then
					validPosition = Vector3.new(spawnPos.X, result.Position.Y + 0.5, spawnPos.Z)
					break
				end
			else
				validPosition = spawnPos
				break
			end
		end
		
		-- Spawn orb if valid position found
		if validPosition then
			local orbType = pickOrbType()
			-- All orbs now visible from creation
			local orbEntity = ECSWorldService.CreateExpOrb(orbType, validPosition, playerEntity, nil)
			if orbEntity then
				spawned = spawned + 1
			end
		end
	end
end

function ECSWorldService.CreatePowerup(powerupType: string, position: Vector3, ownerId: number?): any?
	local entity = ECSWorldService.CreateEntity("Powerup", position, nil)
	if not entity then
		return nil
	end
	
	-- CRITICAL: Replicate powerup model BEFORE setting visual component
	-- This ensures the model exists in ReplicatedStorage before clients try to render it
	local replicationSuccess = ModelReplicationService.replicatePowerup(powerupType)
	if not replicationSuccess then
		warn(string.format("[ECSWorldService] Failed to replicate powerup model '%s', destroying entity", powerupType))
		ECSWorldService.DestroyEntity(entity)
		return nil
	end
	
	local PowerupBalance = require(game.ServerScriptService.Balance.PowerupBalance)
	local powerupConfig = PowerupBalance.PowerupTypes[powerupType]
	if not powerupConfig then
		warn(string.format("[ECSWorldService] Unknown powerup type '%s', using Nuke as fallback", powerupType))
		powerupConfig = PowerupBalance.PowerupTypes.Nuke  -- Fallback
		powerupType = "Nuke"
	end
	
	-- Use the replicated path - model is guaranteed to exist now
	local visualPath = "ReplicatedStorage.ContentDrawer.ItemModels.Powerups." .. powerupType
	
	setComponent(entity, EntityType, {
		type = "Powerup",
		subtype = powerupType,
	}, "EntityType")
	
	setComponent(entity, Velocity, { x = 0, y = 0, z = 0 }, "Velocity")
	
	setComponent(entity, Components.PowerupData, {
		powerupType = powerupType,
		collected = false,
		ownerId = ownerId,  -- MULTIPLAYER: Per-player powerup ownership (Health only)
	}, "PowerupData")
	
	-- Start invisible to prevent visual issues before all data loads on client
	setComponent(entity, Visual, {
		modelPath = visualPath,
		visible = false,  -- Start invisible
		scale = PowerupBalance.PowerupScale or 1.0,  -- Use configured scale
	}, "Visual")
	
	setComponent(entity, Lifetime, {
		remaining = PowerupBalance.PowerupLifetime or 45.0,
		max = PowerupBalance.PowerupLifetime or 45.0,
	}, "Lifetime")
	
	markNewEntity(entity)
	
	-- Make visible after client has time to process all component data
	task.defer(function()
		if world:contains(entity) then
			local visual = world:get(entity, Visual)
			if visual then
				visual.visible = true
				world:set(entity, Visual, visual)
				DirtyService.mark(entity, "Visual")
			end
		end
	end)

	return entity
end

function ECSWorldService.CreateProjectile(projectileType: string, position: Vector3, velocity: Vector3, owner: any?, customStats: any?): any
	local entity = ECSWorldService.CreateEntity("Projectile", position, owner)
	if not entity then
		return nil
	end

	-- Use default stats for basic projectiles, but allow custom stats to override
	local defaultStats = {
		damage = 30, 
		speed = 15, 
		lifetime = 3.0, 
		radius = 1.0, 
		gravity = 0.2
	}
	local stats = customStats or defaultStats

	setComponent(entity, Velocity, { x = velocity.X, y = velocity.Y, z = velocity.Z }, "Velocity")
	
	-- Set proper EntityType with subtype
	local entityTypeData = {
		type = "Projectile",
		subtype = projectileType,
		owner = owner
	}
	setComponent(entity, EntityType, entityTypeData, "EntityType")
	
	setComponent(entity, Projectile, {}, "Projectile")
    setComponent(entity, ProjectileData, {
		type = projectileType,
		speed = stats.speed,
        owner = owner,
		damage = stats.damage,
		gravity = stats.gravity,
		hasHit = false,
	}, "ProjectileData")
    setComponent(entity, Collision, { radius = stats.radius, solid = false }, "Collision")
    -- Store ownership data on dedicated component so other systems can resolve it
    local ownerEntity = owner and playerEntities[owner]
    if owner ~= nil or ownerEntity ~= nil then
        setComponent(entity, Components.Owner, {
            player = owner,
            entity = ownerEntity,
        }, "Owner")
    end
	setComponent(entity, Lifetime, { remaining = stats.lifetime, max = stats.lifetime }, "Lifetime")
	setComponent(entity, Health, { current = 1, max = 1 }, "Health")

	return entity
end

function ECSWorldService.CreateItem(itemType: string, position: Vector3, value: number?): any
	local entity = ECSWorldService.CreateEntity("Item", position, nil)
	if not entity then
		return nil
	end

	setComponent(entity, ItemData, {
		type = itemType,
		value = value or 1,
		collected = false,
	}, "ItemData")
	setComponent(entity, Collision, { radius = 1, solid = false }, "Collision")
	setComponent(entity, Lifetime, { remaining = 30.0, max = 30.0 }, "Lifetime")
	setComponent(entity, Health, { current = 1, max = 1 }, "Health")

	return entity
end

function ECSWorldService.CreatePlayer(player: Player, position: Vector3): any
	local existingEntity = playerEntities[player]
	local spawnPosition = { x = position.X, y = position.Y, z = position.Z }

	if existingEntity then
		setComponent(existingEntity, Position, spawnPosition, "Position")
		setComponent(existingEntity, Velocity, { x = 0, y = 0, z = 0 }, "Velocity")
		setComponent(existingEntity, EntityType, { type = "Player", player = player }, "EntityType")

		local existingStats = world:get(existingEntity, PlayerStats)
		local stats = existingStats and {
			player = player,
			level = existingStats.level or PlayerBalance.StartingLevel,
			experience = existingStats.experience or PlayerBalance.StartingExperience,
			spells = existingStats.spells or {},
		} or {
			player = player,
			level = PlayerBalance.StartingLevel,
			experience = PlayerBalance.StartingExperience,
			spells = {},
		}
		setComponent(existingEntity, PlayerStats, stats, "PlayerStats")
		setComponent(existingEntity, Health, { 
			current = PlayerBalance.BaseMaxHealth, 
			max = PlayerBalance.BaseMaxHealth 
		}, "Health")
		setComponent(existingEntity, AttackCooldown, { 
			remaining = 0, 
			max = 1.0  -- Per-ability cooldown, not a base value
		}, "AttackCooldown")
		
		-- Ensure player has starting abilities
		local abilityData = world:get(existingEntity, Components.AbilityData)
		if not abilityData then
			-- Give player all abilities marked with StartWith = true
			local abilities = {}
			local cooldowns = {}
			
			for abilityId, ability in pairs(AbilityRegistry.getAll()) do
				if ability.balance.StartWith then
					-- Replicate ability model to client on-demand
					ModelReplicationService.replicateAbility(ability.id)
					
					-- Add to abilities table
					abilities[ability.id] = {
				enabled = true,
				level = 1,
						Name = ability.name,
						name = ability.name,
					}
					
					-- Add to cooldowns table
					cooldowns[ability.id] = {
						remaining = 0,
						max = ability.balance.cooldown,
					}
				end
			end
			
			-- Only set components if we have at least one ability
			if next(abilities) then
				setComponent(existingEntity, Components.Ability, {}, "Ability")
				setComponent(existingEntity, Components.AbilityData, {
					abilities = abilities
			}, "AbilityData")
			setComponent(existingEntity, Components.AbilityCooldown, {
					cooldowns = cooldowns
			}, "AbilityCooldown")
			end
		end
		
		-- CRITICAL FIX: Preserve mobility upgrades on reconnect (issue: Shield Bash sometimes resets to Dash)
		-- Only restore starter dash if player has NEVER had a mobility upgrade (should not happen after level 15)
		local mobilityData = world:get(existingEntity, Components.MobilityData)
		local upgrades = world:get(existingEntity, Components.Upgrades)
		
		-- Check if player should have a mobility upgrade (level 15+) based on their upgrades
		local hasSelectedMobility = false
		if upgrades and upgrades.abilities then
			-- Player has made upgrades, so they passed level 15 and could have a mobility choice
			-- In this case, NEVER reset to Dash even if MobilityData is missing
			hasSelectedMobility = true
		end
		
		-- Only equip starter dash if:
		-- 1. Player has no MobilityData AND
		-- 2. Player hasn't reached level 15+ (no upgrades yet)
		if not mobilityData and not hasSelectedMobility then
			UpgradeSystem.equipStarterDash(existingEntity)
		elseif not mobilityData and hasSelectedMobility then
			-- This shouldn't happen - player lost their mobility data on reconnect!
			-- Log this as a warning but don't reset their mobility
			warn(string.format("[Bootstrap] WARNING: Player %s reconnected without MobilityData (had upgrades). This is a sync issue.", player.Name))
		end
		
		playerEntities[player] = existingEntity
		entityToPlayer[existingEntity] = player
		return existingEntity
	end

	local entity = ECSWorldService.CreateEntity("Player", position, player)
	if not entity then
		return nil
	end

	setComponent(entity, EntityType, { type = "Player", player = player }, "EntityType")
	setComponent(entity, PlayerStats, {
		player = player,
		level = PlayerBalance.StartingLevel,
		experience = PlayerBalance.StartingExperience,
		spells = {},
	}, "PlayerStats")
	setComponent(entity, Collision, { radius = 3, solid = true }, "Collision")
	local playerBaseHealth = PlayerBalance.BaseMaxHealth * (GlobalBalance.HealthMultiplier or 1)
	setComponent(entity, Health, { current = playerBaseHealth, max = playerBaseHealth }, "Health")
	setComponent(entity, Damage, { amount = 20, type = "physical" }, "Damage")
	setComponent(entity, AttackCooldown, { 
		remaining = 0, 
		max = 1.0  -- Per-ability cooldown, not a base value
	}, "AttackCooldown")
	
	-- Initialize Level and Experience components for leveling system
	setComponent(entity, Level, {
		current = PlayerBalance.StartingLevel,
		max = ItemBalance.MaxLevel
	}, "Level")
	setComponent(entity, Experience, {
		current = PlayerBalance.StartingExperience,
		required = ItemBalance.BaseExpRequired,
		total = PlayerBalance.StartingExperience
	}, "Experience")
	
	-- Initialize Upgrades component (tracks upgrade progress)
	setComponent(entity, Upgrades, {
		abilities = {},
		passives = {}
	}, "Upgrades")
	
	-- Initialize PassiveEffects component (computed passive multipliers)
	-- Start with PlayerBalance base multipliers
	setComponent(entity, PassiveEffectsComp, {
		damageMultiplier = PlayerBalance.BaseDamageMultiplier,
		cooldownMultiplier = PlayerBalance.BaseCooldownMultiplier,
		expMultiplier = PlayerBalance.BaseExpMultiplier,
		healthMultiplier = 1.0,
		moveSpeedMultiplier = 1.0,  -- Haste passive only
		sizeMultiplier = 1.0,
		durationMultiplier = 1.0,
		pickupRangeMultiplier = 1.0,
		mobilityDistanceMultiplier = 1.0,  -- Calculated from moveSpeed + active buffs
		activeSpeedBuffs = {},  -- Track multiple speed buffs: {levelUp: {mult, endTime}, cloak: {mult, endTime}}
	}, "PassiveEffects")
	
	-- Initialize StatusEffects component (timed buffs)
	setComponent(entity, StatusEffects, {
		invincible = { endTime = 0 },
		speedBoost = { endTime = 0, multiplier = 1.0 }
	}, "StatusEffects")
	
	-- Initialize HealthRegen component
	setComponent(entity, Components.HealthRegen, {
		lastDamageTime = 0,
		isRegenerating = false,
	}, "HealthRegen")
	
	-- Give player all starting abilities
	local abilities = {}
	local cooldowns = {}
	
	for abilityId, ability in pairs(AbilityRegistry.getAll()) do
		if ability.balance.StartWith then
			-- Replicate ability model to client on-demand
			ModelReplicationService.replicateAbility(ability.id)
			
			-- Add to abilities table
			abilities[ability.id] = {
		enabled = true,
		level = 1,
				Name = ability.name,
				name = ability.name,
			}
			
			-- Add to cooldowns table
			cooldowns[ability.id] = {
				remaining = 0,
				max = ability.balance.cooldown,
			}
		end
	end
	
	-- Only set components if we have at least one ability
	if next(abilities) then
		setComponent(entity, Components.Ability, {}, "Ability")
		setComponent(entity, Components.AbilityData, {
			abilities = abilities
	}, "AbilityData")
	setComponent(entity, Components.AbilityCooldown, {
			cooldowns = cooldowns
	}, "AbilityCooldown")
	end
	
	-- Equip starter dash for all new players
	UpgradeSystem.equipStarterDash(entity)

	playerEntities[player] = entity
	entityToPlayer[entity] = player

	return entity
end

function ECSWorldService.DestroyEntity(entity: number)
	if not activeEntities[entity] then
		-- Entity not tracked, but still clean up any potential stale references
		ZombieAISystem.cleanupEntity(entity)
		EnemyRepulsionSystem.cleanupEntity(entity)
		return
	end

	for trackedPlayer, trackedEntity in pairs(playerEntities) do
		if trackedEntity == entity then
			playerEntities[trackedPlayer] = nil
			entityToPlayer[entity] = nil
			break
		end
	end
	activeEntities[entity] = nil
	SyncSystem.queueDespawn(entity)
	ZombieAISystem.cleanupEntity(entity)
	EnemyRepulsionSystem.cleanupEntity(entity)
	SpatialGridSystem.cleanupEntity(entity)  -- Clean up from spatial grid (memory leak prevention)
	ExpSinkSystem.cleanupEntity(entity)  -- Clean up from sink system (if it was a sink)
	world:delete(entity)
	entityCount -= 1
	if entityCount < 0 then
		entityCount = 0
	end
end

function ECSWorldService.GetEntityCount(): number
	return entityCount
end

function ECSWorldService.GetEntityStats(): {totalEntities: number, activeEntities: number, enemyEntities: number}
	local activeCount = 0
	for _ in pairs(activeEntities) do
		activeCount = activeCount + 1
	end
	
	local enemyCount = 0
	local enemyQuery = world:query(Components.EntityType)
	for _, entityType in enemyQuery do
		if entityType.type == "Enemy" then
			enemyCount = enemyCount + 1
		end
	end
	
	return {
		totalEntities = entityCount,
		activeEntities = activeCount,
		enemyEntities = enemyCount
	}
end

ECSWorldService.Initialize()

-- Export ECSWorldService for other systems to use (like ExpSinkSystem)
_G.ECSWorldService = ECSWorldService

-- Session timer sync throttle
local lastTimerSync = 0
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")

-- StepWorld debug throttle
local lastStepWorldDebug = 0
local STEP_WORLD_DEBUG_INTERVAL = 5.0  -- Log every 5 seconds

local function stepWorld(dt: number)
	-- Debug: Log that stepWorld is running
	local now = tick()
	-- Removed verbose stepWorld debug logging
	
	-- Check if game is paused - skip all ECS updates if so
	if PauseSystem.isPaused() then
		return
	end
	
	-- Step game time (pause-aware timer)
	debug.profilebegin("GameTime")
	GameTimeSystem.step(dt)
	debug.profileend()
	
	-- Player data and AI updates
	debug.profilebegin("PlayerPositionSync")
	PlayerPositionSyncSystem.step(dt)
	debug.profileend()
	
	-- Spatial grid system (before movement and collision)
	debug.profilebegin("SpatialGrid")
	SpatialGridSystem.step(dt)
	debug.profileend()
	
	-- Update octree with latest enemy positions (BEFORE AI/Repulsion systems)
	debug.profilebegin("OctreeUpdate")
	OctreeSystem.updateEnemyPositions()
	debug.profileend()
	
	debug.profilebegin("ZombieAI")
	zombieAIAccumulator += dt
	if zombieAIAccumulator >= ZOMBIE_AI_INTERVAL then
		zombieAIAccumulator = 0
		ZombieAISystem.step(dt)
	end
	debug.profileend()
	
	debug.profilebegin("ChargerAI")
	chargerAIAccumulator += dt
	if chargerAIAccumulator >= CHARGER_AI_INTERVAL then
		chargerAIAccumulator = 0
		ChargerAISystem.step(dt)
	end
	debug.profileend()
	
	debug.profilebegin("EnemySpawner")
	EnemySpawner.step(dt)
	debug.profileend()
	
	-- EXP/Leveling systems
	debug.profilebegin("ExpOrbSpawner")
	ExpOrbSpawner.step(dt)
	debug.profileend()
	
	debug.profilebegin("ExpCollection")
	ExpCollectionSystem.step(dt)
	debug.profileend()
	
	debug.profilebegin("ExpSystem")
	ExpSystem.step(dt)
	debug.profileend()
	
	debug.profilebegin("ExpSinkSystem")
	if ExpSinkSystem and ExpSinkSystem.step then
		ExpSinkSystem.step(dt)  -- Red orb teleportation
	else
		warn("[Bootstrap] ExpSinkSystem.step not available!")
	end
	debug.profileend()
	
	-- Pause system (for individual pause timeout checking)
	debug.profilebegin("PauseSystem")
	PauseSystem.step(dt)
	debug.profileend()
	
	-- Game State Manager (check continue timer)
	debug.profilebegin("GameStateManager")
	GameStateManager.step(dt)
	debug.profileend()
	
	-- Session timer sync (1fps throttled) - only send if game is active
	local now = tick()
	if now - lastTimerSync >= 1.0 then
		lastTimerSync = now
		local GameStateManager = require(game.ServerScriptService.ECS.Systems.GameStateManager)
		local currentState = GameStateManager.getCurrentState()
		-- Only send timer updates if game is IN_GAME or WIPED (not during cleanup or lobby)
		if currentState ~= "Lobby" then
			local GameSessionTimer = require(game.ServerScriptService.ECS.Systems.GameSessionTimer)
			local sessionTime = GameSessionTimer.getSessionTime()
			local SessionTimerUpdate = remotesFolder:FindFirstChild("SessionTimerUpdate")
			if SessionTimerUpdate then
				SessionTimerUpdate:FireAllClients(sessionTime)
			end
		end
	end
	
	-- Friends List System (broadcast + update game time)
	-- debug.profilebegin("FriendsListSystem")
	FriendsListSystem.step(dt)
	-- debug.profileend()
	
	-- Death system (for respawn timing)
	debug.profilebegin("DeathSystem")
	DeathSystem.step(dt)
	debug.profileend()
	
	-- Death body fade system (server-side transparency changes replicate to all clients)
	debug.profilebegin("DeathBodyFade")
	DeathBodyFadeSystem.step(dt)
	debug.profileend()
	
	-- Powerup systems
	debug.profilebegin("PowerupCollection")
	PowerupCollectionSystem.step(dt)
	debug.profileend()
	
	debug.profilebegin("OverhealSystem")
	OverhealSystem.step(dt)
	debug.profileend()
	
	debug.profilebegin("BuffSystem")
	BuffSystem.step(dt)
	debug.profileend()
	
	debug.profilebegin("HealthRegenSystem")
	HealthRegenSystem.step(dt)
	debug.profileend()
	
	-- Mobility system (server validation only, client handles movement)
	debug.profilebegin("MobilitySystem")
	MobilitySystem.step(dt)
	debug.profileend()
	
	-- Step all ability systems with throttle (PERFORMANCE FIX - 20 FPS instead of 60 FPS)
	abilitySystemAccumulator += dt
	if abilitySystemAccumulator >= ABILITY_SYSTEM_INTERVAL then
		local abilityDt = abilitySystemAccumulator  -- Pass accumulated time
		abilitySystemAccumulator = 0
		
		for abilityId, ability in pairs(AbilityRegistry.getAll()) do
			debug.profilebegin(abilityId .. "System")
			ability.step(abilityDt)
			debug.profileend()
		end
		
		-- Afterimage Clone System (manages clones for Afterimages attribute)
		debug.profilebegin("AfterimageCloneSystem")
		AfterimageCloneSystem.step(abilityDt)
		debug.profileend()
		
		-- Process projectile spawn queue (backpressure handling when pool is exhausted)
		debug.profilebegin("ProjectileSpawnQueue")
		AbilitySystemBase.processSpawnQueue(abilityDt)
		debug.profileend()
	end
	
	-- Enemy repulsion system (after AI but before movement)
	debug.profilebegin("EnemyRepulsion")
	enemyRepulsionAccumulator += dt
	if enemyRepulsionAccumulator >= ENEMY_REPULSION_INTERVAL then
		enemyRepulsionAccumulator = 0
		EnemyRepulsionSystem.step(dt)
	end
	debug.profileend()

	-- Projectile homing system (BEFORE movement so velocity updates apply immediately)
	debug.profilebegin("HomingSystem")
	HomingSystem.step(dt)
	debug.profileend()
	
	-- Projectile orbit system (for Fire Storm fireballs that orbit around player)
	debug.profilebegin("ProjectileOrbitSystem")
	ProjectileOrbitSystem.step(dt)
	debug.profileend()
	
	-- Magnet pull system (before movement)
	debug.profilebegin("MagnetPull")
	MagnetPullSystem.step(dt)
	debug.profileend()

	-- Core simulation systems (after homing/magnet so movement uses updated velocities)
	debug.profilebegin("Movement")
	MovementSystem.step(dt)
	debug.profileend()

	-- Projectile collision system (must run AFTER movement, BEFORE lifetime)
	debug.profilebegin("ProjectileCollision")
	ProjectileCollisionSystem.step(dt)
	debug.profileend()
	
	-- Combat systems (hit feedback, knockback, death animations)
	debug.profilebegin("HitFlash")
	HitFlashSystem.step(dt)
	debug.profileend()
	
	debug.profilebegin("Knockback")
	KnockbackSystem.step(dt)
	debug.profileend()
	
	debug.profilebegin("DeathAnimation")
	DeathAnimationSystem.step(dt)
	debug.profileend()
	
	debug.profilebegin("Lifetime")
	local expired = LifetimeSystem.step(dt)
	for _, entity in ipairs(expired) do
		-- Debug: Log what entity types are expiring
		local entityType = world:get(entity, Components.EntityType)
		local typeStr = entityType and entityType.type or "Unknown"
		if typeStr == "Enemy" then
			print(string.format("[Bootstrap] Lifetime expired: Enemy entity %d", entity))
		end
		
		-- Check if this is a FireBall projectile - trigger explosion before destroying
		-- ONLY if it expired naturally (not from hitting something)
		local projectileData = world:get(entity, Components.ProjectileData)
		if projectileData and projectileData.type == "FireBall" and not projectileData.hasHit then
			local position = world:get(entity, Components.Position)
			local owner = world:get(entity, Components.Owner)
			if position then
				local explosionPos = Vector3.new(position.x, position.y, position.z)
				local ownerPlayer = owner and owner.player or nil
				local ownerEntityId = owner and owner.entity or nil
				
				-- Get explosion scale (prioritize explosionScale from projectileData)
				local explosionScale = projectileData.explosionScale
				if not explosionScale then
					local visual = world:get(entity, Components.Visual)
					explosionScale = (visual and visual.scale) or 1.0
				end
				
				-- Get explosion damage from projectileData
				local explosionDamage = projectileData.explosionDamage
				
				ProjectileCollisionSystem.triggerFireBallExplosion(explosionPos, ownerPlayer, explosionScale, ownerEntityId, explosionDamage)
			end
		end
		-- Return poolable entities to their pools instead of destroying
		if typeStr == "Projectile" then
			SyncSystem.queueDespawn(entity)  -- Notify clients to remove visual
			ProjectilePool.release(entity)
		elseif typeStr == "ExpOrb" then
			SyncSystem.queueDespawn(entity)  -- Notify clients to remove visual
			ExpOrbPool.release(entity)
		elseif typeStr == "Enemy" then
			SyncSystem.queueDespawn(entity)  -- Notify clients to remove visual
			EnemyPool.release(entity)
		else
			-- Non-pooled entities are destroyed normally
			ECSWorldService.DestroyEntity(entity)
		end
	end
	debug.profileend()
	
	-- Periodic cleanup of stale cast predictions (memory leak prevention)
	AbilitySystemBase.cleanupStalePredictions()
	
	-- Status effect system (handle buff expiration, sync to clients)
	debug.profilebegin("StatusEffects")
	statusEffectAccumulator += dt
	if statusEffectAccumulator >= STATUS_EFFECT_INTERVAL then
		statusEffectAccumulator = 0
		StatusEffectSystem.step(dt)
	end
	debug.profileend()
	
	-- Passive effect system (applies passive multipliers to humanoid properties)
	debug.profilebegin("PassiveEffects")
	PassiveEffectSystem.step(dt)
	debug.profileend()

	-- Network synchronization
	debug.profilebegin("SyncSystem")
	SyncSystem.step(dt)
	debug.profileend()
end

RunService.Heartbeat:Connect(stepWorld)

RequestInitialSync.OnServerInvoke = function(player)
	local snapshot = SyncSystem.buildInitialSnapshot(player)
	local count = 0
	if snapshot.entities then
		for _ in pairs(snapshot.entities) do
			count += 1
		end
	end
	if next(snapshot) then
		EntitySync:FireClient(player, snapshot)
	end
	return snapshot
end


-- Set global respawn time from PlayerBalance
Players.RespawnTime = PlayerBalance.RespawnDelay

Players.PlayerAdded:Connect(function(player)
	-- Notify GameStateManager of player join
	GameStateManager.onPlayerJoin(player)
	
	-- Wait for character to load
	player.CharacterAdded:Connect(function(character)
		
		-- Spawn player at lobby position (GameStateManager will teleport to game when they press Play)
		local humanoidRootPart = character:WaitForChild("HumanoidRootPart", 5)
		if humanoidRootPart then
			-- Teleport to lobby spawn (near camera view)
			humanoidRootPart.CFrame = CFrame.new(220, 609, 400)
			
			-- DON'T create ECS entity here
			-- Wait for GameStateManager.addPlayerToGame() to create it after "Play" button
		end
		
		-- Death is now handled by DeathSystem (triggered from DamageSystem)
		-- No need for humanoid.Died event - custom death system prevents Roblox death
	end)

	-- Send initial ECS snapshot to client (AFTER they join game)
	-- Increased delay from 2s to 2.5s to ensure all initial components are set
	task.delay(2.5, function()
		if not player.Parent then
			return
		end
		local snapshot = SyncSystem.buildInitialSnapshot(player)
		if next(snapshot) then
			EntitySync:FireClient(player, snapshot)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	local entity = playerEntities[player]
	if entity then
		ECSWorldService.DestroyEntity(entity)
	end
end)

-- Death system - Spectator controls
local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local ChangeSpectatorTarget = remotes:FindFirstChild("ChangeSpectatorTarget")
if not ChangeSpectatorTarget then
	ChangeSpectatorTarget = Instance.new("RemoteEvent")
	ChangeSpectatorTarget.Name = "ChangeSpectatorTarget"
	ChangeSpectatorTarget.Parent = remotes
end

local SpectatorTargetChanged = remotes:FindFirstChild("SpectatorTargetChanged")
if not SpectatorTargetChanged then
	SpectatorTargetChanged = Instance.new("RemoteEvent")
	SpectatorTargetChanged.Name = "SpectatorTargetChanged"
	SpectatorTargetChanged.Parent = remotes
end

ChangeSpectatorTarget.OnServerEvent:Connect(function(player, direction: number)
	local playerEntity = playerEntities[player]
	if not playerEntity then return end
	
	local targetName = DeathSystem.changeSpectatorTarget(playerEntity, player, direction)
	if targetName then
		SpectatorTargetChanged:FireClient(player, targetName)
	end
end)

-- Periodic stats logging (minimal)
local statsAccumulator = 0
local STATS_LOG_INTERVAL = 15 -- Log stats every 15 seconds

RunService.Heartbeat:Connect(function(dt)
	statsAccumulator = statsAccumulator + dt
	-- Periodic stats logging removed for performance
end)

-- Memory monitoring
local memoryLogAccumulator = 0
local MEMORY_LOG_INTERVAL = 30 -- Log memory usage every 30 seconds

local function logMemoryUsage()
	local stats = ECSWorldService.GetEntityStats()
	local memoryUsage = gcinfo() -- Use gcinfo() instead of collectgarbage("count")
	print(string.format("[Bootstrap] Memory: %.1f MB | Entities: %d total, %d active, %d enemies", 
		memoryUsage / 1024, stats.totalEntities, stats.activeEntities, stats.enemyEntities))
	
	-- Force garbage collection if memory is high (OPTIMIZATION 3.1: lowered threshold)
	if memoryUsage > 1024 * 1024 then -- 1GB in KB (was 2GB)
		collectgarbage("collect")
		local newMemoryUsage = gcinfo()
		print(string.format("[Bootstrap] Memory after GC: %.1f MB (freed %.1f MB)", 
			newMemoryUsage / 1024, (memoryUsage - newMemoryUsage) / 1024))
	end
end

-- Add memory monitoring to the main loop
local originalStepWorld = stepWorld
stepWorld = function(dt: number)
	originalStepWorld(dt)
	
	-- Memory monitoring
	memoryLogAccumulator += dt
	if memoryLogAccumulator >= MEMORY_LOG_INTERVAL then
		memoryLogAccumulator = 0
		logMemoryUsage()
	end
end


return ECSWorldService

