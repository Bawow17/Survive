--!strict
-- Bootstrap Script - wires ECS world, systems, and client synchronization

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ProfilingConfig = require(ReplicatedStorage.Shared.ProfilingConfig)
local Prof = ProfilingConfig.ENABLED and require(ReplicatedStorage.Shared.ProfilingServer) or require(ReplicatedStorage.Shared.ProfilingStub)
local PROFILING_ENABLED = ProfilingConfig.ENABLED

local function profInc(name: string, amount: number?)
	if PROFILING_ENABLED then
		Prof.incCounter(name, amount)
	end
end

local function profGauge(name: string, value: number)
	if PROFILING_ENABLED then
		Prof.gauge(name, value)
	end
end

local ModelReplicationService: any

local ECS = require(game.ServerScriptService.ECS.ECSFacade)
local DirtyService = require(game.ServerScriptService.ECS.DirtyService)
local ProjectilePool = require(game.ServerScriptService.ECS.ProjectilePool)
local ExpOrbPool = require(game.ServerScriptService.ECS.ExpOrbPool)
local EnemyPool = require(game.ServerScriptService.ECS.EnemyPool)
ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local EnemyColliderService = require(game.ServerScriptService.Services.EnemyColliderService)
local EnemyColliderOverlayService = require(game.ServerScriptService.Services.EnemyColliderOverlayService)
local MovementSystem = require(game.ServerScriptService.ECS.Systems.MovementSystem)
local LifetimeSystem = require(game.ServerScriptService.ECS.Systems.LifetimeSystem)
local SyncSystem = require(game.ServerScriptService.ECS.Systems.SyncSystem)
local PlayerPositionSyncSystem = require(game.ServerScriptService.ECS.Systems.PlayerPositionSyncSystem)
local ZombieAISystem = require(game.ServerScriptService.ECS.Systems.ZombieAISystem)
local ChargerAISystem = require(game.ServerScriptService.ECS.Systems.ChargerAISystem)
local EnemyRepulsionSystem = require(game.ServerScriptService.ECS.Systems.EnemyRepulsionSystem)
local EnemySpawner = require(game.ServerScriptService.ECS.Systems.EnemySpawner)
local OctreeSystem = require(game.ServerScriptService.ECS.Systems.OctreeSystem)
local SpatialGridSystem = require(game.ServerScriptService.ECS.Systems.SpatialGridSystem)
local DamageSystem = require(game.ServerScriptService.ECS.Systems.DamageSystem)
local ItemSystem = require(game.ServerScriptService.ECS.Systems.ItemSystem)
local HitFlashSystem = require(game.ServerScriptService.ECS.Systems.HitFlashSystem)
local DeathAnimationSystem = require(game.ServerScriptService.ECS.Systems.DeathAnimationSystem)
local DeathSystem = require(game.ServerScriptService.ECS.Systems.DeathSystem)
local DeathBodyFadeSystem = require(game.ServerScriptService.ECS.Systems.DeathBodyFadeSystem)
local KnockbackSystem = require(game.ServerScriptService.ECS.Systems.KnockbackSystem)
local EnemySlowSystem = require(game.ServerScriptService.ECS.Systems.EnemySlowSystem)
local EnemyFrostSystem = require(game.ServerScriptService.ECS.Systems.EnemyFrostSystem)
local EnemyAilmentSystem = require(game.ServerScriptService.ECS.Systems.EnemyAilmentSystem)
local EnemyStunSystem = require(game.ServerScriptService.ECS.Systems.EnemyStunSystem)
local EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)
local GlobalBalance = require(game.ServerScriptService.Balance.GlobalBalance)
local ItemBalance = require(game.ServerScriptService.Balance.ItemBalance)
local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local DEBUG = GameOptions.Debug and GameOptions.Debug.Enabled
local INVINCIBLE_ENEMY_DIAGNOSTICS = GameOptions.Debug and GameOptions.Debug.InvincibleEnemyDiagnostics or false
local ENEMY_VISUAL_HITBOX_DIAGNOSTICS = GameOptions.Debug and GameOptions.Debug.EnemyVisualHitboxDiagnostics or false
local ENEMY_COLLIDER_OVERLAY = GameOptions.Debug and GameOptions.Debug.EnemyColliderOverlay or false
local COMMON_ITEM_DIAGNOSTICS = GameOptions.Debug and GameOptions.Debug.CommonItemDiagnostics or false

-- Ability Registry - Auto-discovers and loads all abilities
local AbilityRegistry = require(game.ServerScriptService.Abilities.AbilityRegistry)
local AbilitySystemBase = require(game.ServerScriptService.Abilities.AbilitySystemBase)
local TargetingService = require(game.ServerScriptService.Abilities.TargetingService)
local ModelHitboxHelper = require(game.ServerScriptService.Utilities.ModelHitboxHelper)

-- Enemy Registry - Auto-discovers and loads all enemy types
local EnemyRegistry = require(game.ServerScriptService.Enemies.EnemyRegistry)

-- EXP/Leveling Systems
local ExpOrbSpawner = require(game.ServerScriptService.ECS.Systems.ExpOrbSpawner)
local ExpSystem = require(game.ServerScriptService.ECS.Systems.ExpSystem)
local ExpSinkSystem = require(game.ServerScriptService.ECS.Systems.ExpSinkSystem)
local EnemyExpDropSystem = require(game.ServerScriptService.ECS.Systems.EnemyExpDropSystem)
local PauseSystem = require(game.ServerScriptService.ECS.Systems.PauseSystem)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
local PickupService = require(game.ServerScriptService.Services.PickupService)
local ItemSpawnService = require(game.ServerScriptService.Services.ItemSpawnService)
local MobilityLoadoutService = require(game.ServerScriptService.Services.MobilityLoadoutService)
local ProjectileService = require(game.ServerScriptService.Services.ProjectileService)
local WeaponService = require(game.ServerScriptService.Services.WeaponService)
local LoopGameService = require(game.ServerScriptService.Services.LoopGameService)
local DebugModMenuService = require(game.ServerScriptService.Services.DebugModMenuService)
local PlayerSettingsService = require(game.ServerScriptService.Services.PlayerSettingsService)
local TixService = require(game.ServerScriptService.Services.TixService)
local DifficultyCoeff = require(game.ServerScriptService.Balance.DifficultyCoeff)
local GameSessionTimer = require(game.ServerScriptService.ECS.Systems.GameSessionTimer)
local ChunkGenerationService = require(game.ServerScriptService.WorldGen.ChunkGenerationService)

local PassiveEffectSystem = require(game.ServerScriptService.ECS.Systems.PassiveEffectSystem)

-- Status Effect System
local StatusEffectSystem = require(game.ServerScriptService.ECS.Systems.StatusEffectSystem)

local OverhealSystem = require(game.ServerScriptService.ECS.Systems.OverhealSystem)
local BuffSystem = require(game.ServerScriptService.ECS.Systems.BuffSystem)
local HealthRegenSystem = require(game.ServerScriptService.ECS.Systems.HealthRegenSystem)

-- Mobility System
local MobilitySystem = require(game.ServerScriptService.ECS.Systems.MobilitySystem)
local UltimateSystem = require(game.ServerScriptService.ECS.Systems.UltimateSystem)
local TemporalStasisSystem = require(game.ServerScriptService.ECS.Systems.TemporalStasisSystem)

-- Afterimage Clone System (for Afterimages attribute)
local AfterimageCloneSystem = require(game.ServerScriptService.ECS.Systems.AfterimageCloneSystem)

-- Game State Manager
local GameStateManager = require(game.ServerScriptService.ECS.Systems.GameStateManager)
local FriendsListSystem = require(game.ServerScriptService.ECS.Systems.FriendsListSystem)
local Oathkeeper = require(game.ServerScriptService.Balance.Weapons.Oathkeeper)

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
local PassiveEffectsComp = Components.PassiveEffects
local StatusEffects = Components.StatusEffects

local ECSWorldService = {}

local entityCount = 0
local warnedProjectileEntity = false
local warnedActiveEcsProjectiles = false
local activeEntities: {[number]: boolean} = {}
local projectileEntityQuery = world:query(Components.Projectile):cached()
local playerEntities: {[Player]: number} = {}
local entityToPlayer: {[number]: Player} = {}

local STARTER_WEAPON_ID_ATTRIBUTE = "StarterWeaponId"
local STARTER_WEAPON_IDLE_ATTRIBUTE = "StarterWeaponIdleAnimationId"
local STARTER_WEAPON_WALK_ATTRIBUTE = "StarterWeaponWalkAnimationId"
local STARTER_WEAPON_M1_ATTRIBUTE = "StarterWeaponM1AnimationId"
local STARTER_WEAPON_M2_ATTRIBUTE = "StarterWeaponM2AnimationId"
local STARTER_WEAPON_RELOAD_ATTRIBUTE = "StarterWeaponReloadAnimationId"
local STARTER_WEAPON_ACTIVE_WALK_WINDOW_ATTRIBUTE = "StarterWeaponActiveWalkWindow"
local STARTER_WEAPON_RANGE_ATTRIBUTE = "StarterWeaponRange"
local STARTER_WEAPON_TRACER_LIFETIME_ATTRIBUTE = "StarterWeaponTracerLifetime"
local STARTER_WEAPON_TRACER_FADE_DURATION_ATTRIBUTE = "StarterWeaponTracerFadeDuration"
local STARTER_WEAPON_M2_CAST_DURATION_ATTRIBUTE = "StarterWeaponM2CastDuration"
local STARTER_WEAPON_M2_FIRE_DELAY_ATTRIBUTE = "StarterWeaponM2FireDelay"
local STARTER_WEAPON_M2_CHARGES_ATTRIBUTE = "StarterWeaponM2Charges"
local STARTER_WEAPON_M2_MAX_CHARGES_ATTRIBUTE = "StarterWeaponM2MaxCharges"
local STARTER_WEAPON_M2_RECHARGE_DURATION_ATTRIBUTE = "StarterWeaponM2RechargeDuration"
local STARTER_WEAPON_M2_RECHARGE_END_ATTRIBUTE = "StarterWeaponM2RechargeEnd"
local STARTER_WEAPON_PATH = Oathkeeper.assetPaths.weaponFolder
local STARTER_WEAPON_MODEL_NAME = Oathkeeper.assetPaths.model
local STARTER_WEAPON_GRIP_C0_NAME = Oathkeeper.assetPaths.gripC0
local STARTER_WEAPON_GRIP_C1_NAME = Oathkeeper.assetPaths.gripC1
local STARTER_WEAPON_MOTOR_NAME = "WeaponGrip"

local function ensureRemoteEvent(parent: Instance, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function disableFluidForcesOnPart(part: BasePart)
	pcall(function()
		(part :: any).EnableFluidForces = false
	end)
end

local function disableCharacterFluidForces(character: Model)
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			disableFluidForcesOnPart(descendant)
		end
	end

	character.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("BasePart") then
			disableFluidForcesOnPart(descendant)
		end
	end)
end

local warnedWorkspaceFluidForcesRuntimeConfig = false

local function disableWorkspaceFluidForces()
	local enumSuccess, fluidForcesEnum = pcall(function()
		return Enum.FluidForces
	end)
	if not enumSuccess or not fluidForcesEnum then
		return
	end

	local targetValue = fluidForcesEnum.Default or fluidForcesEnum.Disabled
	if not targetValue then
		for _, enumItem in ipairs(fluidForcesEnum:GetEnumItems()) do
			local enumName = string.lower(enumItem.Name)
			if enumName == "default" or enumName == "disabled" then
				targetValue = enumItem
				break
			end
		end
	end

	if targetValue then
		local writeSuccess, writeError = pcall(function()
			(Workspace :: any).FluidForces = targetValue
		end)
		if not writeSuccess and not warnedWorkspaceFluidForcesRuntimeConfig then
			warnedWorkspaceFluidForcesRuntimeConfig = true
			if RunService:IsStudio() then
				warn(string.format(
					"[Bootstrap] Workspace.FluidForces cannot be configured at runtime in this environment; configure it in Studio/engine settings instead. Details: %s",
					tostring(writeError)
				))
			end
		end
	end
end

local function findByPath(root: Instance, path: string): Instance?
	local current: Instance = root
	for _, part in ipairs(string.split(path, ".")) do
		local child = current:FindFirstChild(part)
		if not child then
			return nil
		end
		current = child
	end
	return current
end

local function normalizeAnimationId(rawId: string?): string?
	if not rawId or rawId == "" then
		return nil
	end
	if string.sub(rawId, 1, 13) == "rbxassetid://" then
		return rawId
	end
	if string.match(rawId, "^%d+$") then
		return "rbxassetid://" .. rawId
	end
	return nil
end

local function resolveAnimationIdFromInstance(source: Instance?): string?
	if not source then
		return nil
	end
	if source:IsA("Animation") then
		return normalizeAnimationId(source.AnimationId)
	end
	if source:IsA("StringValue") then
		return normalizeAnimationId(source.Value)
	end
	if source:IsA("NumberValue") then
		return normalizeAnimationId(tostring(math.floor(source.Value)))
	end
	return nil
end

local function resolveAnimationIdByPath(root: Instance, relativePath: string): string?
	local source = findByPath(root, relativePath)
	return resolveAnimationIdFromInstance(source)
end

local function clearStarterWeaponAttributes(character: Model)
	character:SetAttribute(STARTER_WEAPON_ID_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_IDLE_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_WALK_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_M1_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_M2_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_RELOAD_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_ACTIVE_WALK_WINDOW_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_RANGE_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_TRACER_LIFETIME_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_TRACER_FADE_DURATION_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_M2_CAST_DURATION_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_M2_FIRE_DELAY_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_M2_CHARGES_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_M2_MAX_CHARGES_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_M2_RECHARGE_DURATION_ATTRIBUTE, nil)
	character:SetAttribute(STARTER_WEAPON_M2_RECHARGE_END_ATTRIBUTE, nil)
end

local function attachStarterWeapon(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warn("[Bootstrap] Starter weapon attach skipped: missing Humanoid")
		clearStarterWeaponAttributes(character)
		return
	end

	local rightArmInstance = character:FindFirstChild("Right Arm") or character:WaitForChild("Right Arm", 5)
	if not rightArmInstance or not rightArmInstance:IsA("BasePart") then
		warn(string.format("[Bootstrap] Starter weapon attach skipped for %s: missing R6 Right Arm", character.Name))
		clearStarterWeaponAttributes(character)
		return
	end
	local rightArm = rightArmInstance

	local weaponFolder = findByPath(ReplicatedStorage, STARTER_WEAPON_PATH)
	if not weaponFolder then
		warn(string.format("[Bootstrap] Starter weapon folder missing at ReplicatedStorage.%s", STARTER_WEAPON_PATH))
		clearStarterWeaponAttributes(character)
		return
	end

	local modelTemplate = weaponFolder:FindFirstChild(STARTER_WEAPON_MODEL_NAME)
	if not modelTemplate or not modelTemplate:IsA("Model") then
		warn("[Bootstrap] Starter weapon attach skipped: missing OathkeeperModel")
		clearStarterWeaponAttributes(character)
		return
	end

	local gripC0Value = weaponFolder:FindFirstChild(STARTER_WEAPON_GRIP_C0_NAME)
	local gripC1Value = weaponFolder:FindFirstChild(STARTER_WEAPON_GRIP_C1_NAME)
	if not gripC0Value or not gripC0Value:IsA("CFrameValue") or not gripC1Value or not gripC1Value:IsA("CFrameValue") then
		warn("[Bootstrap] Starter weapon attach skipped: GripC0/GripC1 missing or invalid")
		clearStarterWeaponAttributes(character)
		return
	end

	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Model") and child.Name == STARTER_WEAPON_MODEL_NAME then
			child:Destroy()
		end
	end
	local existingMotor = rightArm:FindFirstChild(STARTER_WEAPON_MOTOR_NAME)
	if existingMotor and existingMotor:IsA("Motor6D") then
		existingMotor:Destroy()
	end

	local equippedModel = modelTemplate:Clone()
	equippedModel.Name = STARTER_WEAPON_MODEL_NAME
	equippedModel.Parent = character

	local handle = equippedModel:FindFirstChild("Handle", true)
	if not handle or not handle:IsA("BasePart") then
		equippedModel:Destroy()
		warn("[Bootstrap] Starter weapon attach skipped: OathkeeperModel missing Handle")
		clearStarterWeaponAttributes(character)
		return
	end

	for _, descendant in ipairs(equippedModel:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Massless = true
			descendant.Anchored = false
		end
	end

	if not equippedModel.PrimaryPart then
		equippedModel.PrimaryPart = handle
	end

	local motor = Instance.new("Motor6D")
	motor.Name = STARTER_WEAPON_MOTOR_NAME
	motor.Part0 = rightArm
	motor.Part1 = handle
	motor.C0 = gripC0Value.Value
	motor.C1 = gripC1Value.Value
	motor.Parent = rightArm

	local idleAnimationId = resolveAnimationIdByPath(weaponFolder, Oathkeeper.assetPaths.animations.idle)
	local walkAnimationId = resolveAnimationIdByPath(weaponFolder, Oathkeeper.assetPaths.animations.walk)
	local m1AnimationId = resolveAnimationIdByPath(weaponFolder, Oathkeeper.assetPaths.animations.m1)
	local m2AnimationId = resolveAnimationIdByPath(weaponFolder, Oathkeeper.assetPaths.animations.m2)
	local reloadAnimationId = resolveAnimationIdByPath(weaponFolder, Oathkeeper.assetPaths.animations.reloadLoop)

	character:SetAttribute(STARTER_WEAPON_ID_ATTRIBUTE, Oathkeeper.id)
	character:SetAttribute(STARTER_WEAPON_IDLE_ATTRIBUTE, idleAnimationId)
	character:SetAttribute(STARTER_WEAPON_WALK_ATTRIBUTE, walkAnimationId)
	character:SetAttribute(STARTER_WEAPON_M1_ATTRIBUTE, m1AnimationId)
	character:SetAttribute(STARTER_WEAPON_M2_ATTRIBUTE, m2AnimationId)
	character:SetAttribute(STARTER_WEAPON_RELOAD_ATTRIBUTE, reloadAnimationId)
	local configuredActiveWalkWindow = Oathkeeper.activeWalkWindow
	if typeof(configuredActiveWalkWindow) ~= "number" or configuredActiveWalkWindow < 0 then
		configuredActiveWalkWindow = 5.0
	end
	local configuredRange = Oathkeeper.range
	if typeof(configuredRange) ~= "number" or configuredRange <= 0 then
		configuredRange = 1000
	end
	local configuredTracerLifetime = Oathkeeper.tracerLifetime
	if typeof(configuredTracerLifetime) ~= "number" or configuredTracerLifetime <= 0 then
		configuredTracerLifetime = 2.0
	end
	local configuredTracerFadeDuration = Oathkeeper.tracerFadeDuration
	if typeof(configuredTracerFadeDuration) ~= "number" or configuredTracerFadeDuration < 0 then
		configuredTracerFadeDuration = 0.5
	end
	local configuredM2CastDuration = Oathkeeper.m2CastDuration
	if typeof(configuredM2CastDuration) ~= "number" or configuredM2CastDuration <= 0 then
		configuredM2CastDuration = 0.60
	end
	local configuredM2FireDelay = Oathkeeper.m2FireDelay
	if typeof(configuredM2FireDelay) ~= "number" or configuredM2FireDelay < 0 then
		configuredM2FireDelay = 8 / 60
	end
	character:SetAttribute(STARTER_WEAPON_ACTIVE_WALK_WINDOW_ATTRIBUTE, configuredActiveWalkWindow)
	character:SetAttribute(STARTER_WEAPON_RANGE_ATTRIBUTE, configuredRange)
	character:SetAttribute(STARTER_WEAPON_TRACER_LIFETIME_ATTRIBUTE, configuredTracerLifetime)
	character:SetAttribute(STARTER_WEAPON_TRACER_FADE_DURATION_ATTRIBUTE, configuredTracerFadeDuration)
	character:SetAttribute(STARTER_WEAPON_M2_CAST_DURATION_ATTRIBUTE, configuredM2CastDuration)
	character:SetAttribute(STARTER_WEAPON_M2_FIRE_DELAY_ATTRIBUTE, configuredM2FireDelay)
	character:SetAttribute(STARTER_WEAPON_M2_CHARGES_ATTRIBUTE, 1)
	character:SetAttribute(STARTER_WEAPON_M2_MAX_CHARGES_ATTRIBUTE, 1)
	character:SetAttribute(STARTER_WEAPON_M2_RECHARGE_DURATION_ATTRIBUTE, Oathkeeper.m2SharedLockout)
	character:SetAttribute(STARTER_WEAPON_M2_RECHARGE_END_ATTRIBUTE, 0)
end

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
	disableWorkspaceFluidForces()

	-- Create commonly-used remotes before heavy startup work so clients do not
	-- stall waiting for events during initial join.
	local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	local staleBankedHandsFolder = remotesFolder:FindFirstChild("BankedHands")
	if staleBankedHandsFolder then
		staleBankedHandsFolder:Destroy()
	end
	ensureRemoteEvent(remotesFolder, "PlayerDied")
	ensureRemoteEvent(remotesFolder, "PlayerRespawned")
	ensureRemoteEvent(remotesFolder, "PlayerBodyFade")
	ensureRemoteEvent(remotesFolder, "SessionTimerUpdate")
	ensureRemoteEvent(remotesFolder, "PlayerBodyRestore")
	ensureRemoteEvent(remotesFolder, "PlayerHitMarker")
	ensureRemoteEvent(remotesFolder, "SprintState")

	local weaponsRemotesFolder = ensureFolder(remotesFolder, "Weapons")
	local primaryFireRequestRemote = ensureRemoteEvent(weaponsRemotesFolder, "PrimaryFireRequest")
	local primaryFireReleaseRemote = ensureRemoteEvent(weaponsRemotesFolder, "PrimaryFireRelease")
	local primaryShotRemote = ensureRemoteEvent(weaponsRemotesFolder, "PrimaryShot")
	local secondaryFireRequestRemote = ensureRemoteEvent(weaponsRemotesFolder, "SecondaryFireRequest")
	local secondaryShotRemote = ensureRemoteEvent(weaponsRemotesFolder, "SecondaryShot")
	local sprintForceOffRemote = ensureRemoteEvent(weaponsRemotesFolder, "SprintForceOff")

	local debugFlags = ReplicatedStorage:FindFirstChild("DebugFlags")
	if not debugFlags then
		debugFlags = Instance.new("Folder")
		debugFlags.Name = "DebugFlags"
		debugFlags.Parent = ReplicatedStorage
	end
	local invisibleEnemyDiagFlag = debugFlags:FindFirstChild("InvisibleEnemyDiagnostics")
	if not invisibleEnemyDiagFlag or not invisibleEnemyDiagFlag:IsA("BoolValue") then
		if invisibleEnemyDiagFlag then
			invisibleEnemyDiagFlag:Destroy()
		end
		invisibleEnemyDiagFlag = Instance.new("BoolValue")
		invisibleEnemyDiagFlag.Name = "InvisibleEnemyDiagnostics"
		invisibleEnemyDiagFlag.Parent = debugFlags
	end
	invisibleEnemyDiagFlag.Value = INVINCIBLE_ENEMY_DIAGNOSTICS

	local enemyVisualHitboxDiagFlag = debugFlags:FindFirstChild("EnemyVisualHitboxDiagnostics")
	if not enemyVisualHitboxDiagFlag or not enemyVisualHitboxDiagFlag:IsA("BoolValue") then
		if enemyVisualHitboxDiagFlag then
			enemyVisualHitboxDiagFlag:Destroy()
		end
		enemyVisualHitboxDiagFlag = Instance.new("BoolValue")
		enemyVisualHitboxDiagFlag.Name = "EnemyVisualHitboxDiagnostics"
		enemyVisualHitboxDiagFlag.Parent = debugFlags
	end
	enemyVisualHitboxDiagFlag.Value = ENEMY_VISUAL_HITBOX_DIAGNOSTICS

	local commonItemDiagFlag = debugFlags:FindFirstChild("CommonItemDiagnostics")
	if not commonItemDiagFlag or not commonItemDiagFlag:IsA("BoolValue") then
		if commonItemDiagFlag then
			commonItemDiagFlag:Destroy()
		end
		commonItemDiagFlag = Instance.new("BoolValue")
		commonItemDiagFlag.Name = "CommonItemDiagnostics"
		commonItemDiagFlag.Parent = debugFlags
	end
	commonItemDiagFlag.Value = COMMON_ITEM_DIAGNOSTICS

	local enemyColliderOverlayFlag = debugFlags:FindFirstChild("EnemyColliderOverlay")
	if not enemyColliderOverlayFlag or not enemyColliderOverlayFlag:IsA("BoolValue") then
		if enemyColliderOverlayFlag then
			enemyColliderOverlayFlag:Destroy()
		end
		enemyColliderOverlayFlag = Instance.new("BoolValue")
		enemyColliderOverlayFlag.Name = "EnemyColliderOverlay"
		enemyColliderOverlayFlag.Parent = debugFlags
	end
	enemyColliderOverlayFlag.Value = ENEMY_COLLIDER_OVERLAY
	enemyColliderOverlayDebugFlag = enemyColliderOverlayFlag

	local projectileRemotesFolder = remotesFolder:FindFirstChild("Projectiles")
	if projectileRemotesFolder and not projectileRemotesFolder:IsA("Folder") then
		projectileRemotesFolder:Destroy()
		projectileRemotesFolder = nil
	end
	if not projectileRemotesFolder then
		projectileRemotesFolder = Instance.new("Folder")
		projectileRemotesFolder.Name = "Projectiles"
		projectileRemotesFolder.Parent = remotesFolder
	end
	ensureRemoteEvent(projectileRemotesFolder, "ProjectilesSpawnBatch")
	ensureRemoteEvent(projectileRemotesFolder, "ProjectilesDespawnBatch")
	ensureRemoteEvent(projectileRemotesFolder, "ProjectilesImpactBatch")
	ensureRemoteEvent(projectileRemotesFolder, "ProjectilesFreezeBatch")
	ensureRemoteEvent(projectileRemotesFolder, "ProjectilesResumeBatch")

	local itemSpawnRemotesFolder = ensureFolder(remotesFolder, "ItemSpawns")
	ensureRemoteEvent(itemSpawnRemotesFolder, "ItemSpawnsSpawnBatch")
	ensureRemoteEvent(itemSpawnRemotesFolder, "ItemSpawnsDespawnBatch")
	
	-- Pre-compute hitbox data for common enemies (ContentDrawer is now in ReplicatedStorage natively)
	ModelReplicationService.init()
	EnemyColliderService.init(world, Components)
	EnemyColliderOverlayService.init(world, Components)
	
	-- Initialize seeded chunk world generation before gameplay systems depend on spawn/terrain.
	ChunkGenerationService.init()
	
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
	
	-- Remotes are created at the start of Initialize.
	
	-- Initialize Game Time system (after PauseSystem, before systems that use scaling)
	GameTimeSystem.init()
	
	-- Initialize systems that apply player multipliers.
	PassiveEffectSystem.init(world, Components, DirtyService)
	MobilityLoadoutService.init(world, Components, DirtyService)
	
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

	-- Initialize Enemy Slow system (after StatusEffectSystem, before AI)
	EnemySlowSystem.init(world, Components, DirtyService)
	
	-- Initialize Mobility system (after StatusEffectSystem for invincibility frames)
	MobilitySystem.init(world, Components, DirtyService)
	
	-- Initialize Game State Manager (before player systems)
	GameStateManager.init(world, Components, DirtyService, ECSWorldService)
	GameStateManager.setStatusEffectSystem(StatusEffectSystem)
	GameStateManager.setPauseSystem(PauseSystem)
	TixService.init()
	UltimateSystem.init(world, Components, DirtyService)
	
	-- Initialize Session Stats Tracker
	local SessionStatsTracker = require(game.ServerScriptService.ECS.Systems.SessionStatsTracker)
	SessionStatsTracker.init(world, Components, DirtyService)
	
	-- Set GameStateManager reference in DeathSystem
	DeathSystem.setGameStateManager(GameStateManager)
	
	-- Initialize Friends List System
	FriendsListSystem.init()
	
	-- Initialize shared buff/overheal systems
	OverhealSystem.init(world, Components, DirtyService)
	BuffSystem.init(world, Components, DirtyService)
	BuffSystem.setPassiveEffectSystem(PassiveEffectSystem)
	
	-- Initialize Health Regen system
	HealthRegenSystem.init(world, Components, DirtyService)
	DamageSystem.setOverhealSystem(OverhealSystem)
	
	-- Initialize EXP/Leveling systems
	ExpSystem.init(world, Components, DirtyService)
	PickupService.init(world, Components, ExpSystem, function(player)
		return playerEntities[player]
	end)
	ItemSpawnService.init(world, Components)
	ExpSinkSystem.init(world, Components, PickupService)
	PickupService.setExpSinkSystem(ExpSinkSystem)
	EnemyExpDropSystem.init(world, Components, ECSWorldService, ExpSinkSystem, PickupService)
	ExpOrbSpawner.init(world, Components, ECSWorldService, ExpSinkSystem, PickupService)
	
	-- Initialize all ability systems from registry
	for abilityId, ability in pairs(AbilityRegistry.getAll()) do
		ability.init(world, Components, DirtyService, ECSWorldService)
	end

	-- Initialize centralized targeting (aim point + prediction)
	TargetingService.init(world, Components, EnemyRegistry, ModelHitboxHelper)
	
	-- Initialize Afterimage Clone System (for Afterimages attribute)
	AfterimageCloneSystem.init(world, Components, DirtyService, ECSWorldService)
	
	-- Initialize combat systems
	DamageSystem.init(world, Components, DirtyService)
	EnemyFrostSystem.init(world, Components, DirtyService, {
		DamageSystem = DamageSystem,
	})
	EnemyAilmentSystem.init(world, Components, DirtyService, {
		DamageSystem = DamageSystem,
	})
	EnemyStunSystem.init(world, Components, DirtyService)
	TemporalStasisSystem.init(world, Components, DirtyService, {
		DamageSystem = DamageSystem,
		EnemyFrostSystem = EnemyFrostSystem,
		EnemyAilmentSystem = EnemyAilmentSystem,
	})
	TemporalStasisSystem.setDamageSystem(DamageSystem)
	TemporalStasisSystem.setEnemyFrostSystem(EnemyFrostSystem)
	TemporalStasisSystem.setEnemyAilmentSystem(EnemyAilmentSystem)
	EnemyFrostSystem.setDamageSystem(DamageSystem)
	EnemyAilmentSystem.setDamageSystem(DamageSystem)
	DamageSystem.setUltimateSystem(UltimateSystem)
	DamageSystem.setTemporalStasisSystem(TemporalStasisSystem)
	DamageSystem.setEnemyFrostSystem(EnemyFrostSystem)
	DamageSystem.setEnemyAilmentSystem(EnemyAilmentSystem)
	UltimateSystem.setTemporalStasisSystem(TemporalStasisSystem)
	DamageSystem.setEnemyExpDropSystem(EnemyExpDropSystem)  -- Set reference for enemy death drops
	DamageSystem.setStatusEffectSystem(StatusEffectSystem)  -- Set reference for invincibility checks
	ProjectileService.init(world, Components, function(entityId)
		return entityToPlayer[entityId]
	end)
	ItemSystem.init(world, Components, {
		PickupService = PickupService,
		ProjectileService = ProjectileService,
		ModelReplicationService = ModelReplicationService,
		PassiveEffectSystem = PassiveEffectSystem,
		ExpSystem = ExpSystem,
	})
	ItemSystem.setEnemyStunSystem(EnemyStunSystem)
	ItemSystem.setEnemyAilmentSystem(EnemyAilmentSystem)
	ItemSystem.setItemSpawnService(ItemSpawnService)
	HealthRegenSystem.setItemSystem(ItemSystem)
	AbilitySystemBase.setItemSystem(ItemSystem)
	ProjectileService.setTemporalStasisSystem(TemporalStasisSystem)
	DamageSystem.setItemSystem(ItemSystem)
	WeaponService.init({
		world = world,
		Components = Components,
		PassiveEffectSystem = PassiveEffectSystem,
		DamageSystem = DamageSystem,
		ItemSystem = ItemSystem,
		getPlayerEntity = function(player: Player): number?
			return playerEntities[player]
		end,
		PrimaryFireRequest = primaryFireRequestRemote,
		PrimaryFireRelease = primaryFireReleaseRemote,
		PrimaryShot = primaryShotRemote,
		SecondaryFireRequest = secondaryFireRequestRemote,
		SecondaryShot = secondaryShotRemote,
		SprintForceOff = sprintForceOffRemote,
	})
	WeaponService.setItemSystem(ItemSystem)
	WeaponService.setTemporalStasisSystem(TemporalStasisSystem)
	LoopGameService.init(world, Components, ExpSystem)
	DebugModMenuService.init(world, Components, GameTimeSystem, DifficultyCoeff, GameSessionTimer, ItemSystem)
	PlayerSettingsService.init()
	HitFlashSystem.init(world, Components)
	DeathAnimationSystem.init(world, Components, ECSWorldService)
	KnockbackSystem.init(world, Components, DirtyService)
	
end

function ECSWorldService.CreateEntity(entityTypeName: string, position: Vector3, owner: any?): any
	local entity: number
	
	-- Route entity creation through appropriate object pools for performance
	if entityTypeName == "Projectile" then
		if not warnedProjectileEntity then
			warnedProjectileEntity = true
			warn("[ECSWorldService] Projectile ECS entities are disabled; use ProjectileService records instead.")
		end
		return nil
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

function ECSWorldService.CreateEnemy(enemyType: string, position: Vector3, owner: any?, scaling: any?): any
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

	-- Adaptive scaling (per-player snapshot)
	local scalingHealth = (scaling and scaling.healthMult) or 1.0
	local scalingDamage = (scaling and scaling.damageMult) or 1.0
	local scalingSpeed = (scaling and scaling.speedMult) or 1.0

	local baseHealth = enemyConfig.baseHealth
		* (EnemyBalance.HealthMultiplier or 1)
		* (GlobalBalance.HealthMultiplier or 1)
		* scalingHealth
	local baseDamage = enemyConfig.baseDamage
		* (EnemyBalance.DamageMultiplier or 1)
		* scalingDamage
	local baseSpeed = enemyConfig.baseSpeed * scalingSpeed
	local baseArmor = enemyConfig.baseArmor or 0

	local visualScale = (scaling and scaling.visualScale) or 1.0
	local enemyTier = (scaling and scaling.tier) or "Normal"

	setComponent(entity, EntityType, {
		type = "Enemy",
		subtype = enemyType or "Zombie",
	}, "EntityType")
	setComponent(entity, Velocity, { x = 0, y = 0, z = 0 }, "Velocity")
	setComponent(entity, Components.DesiredVelocity, { x = 0, y = 0, z = 0 }, "DesiredVelocity")
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
	setComponent(entity, Visual, { modelPath = visualPath, visible = true, scale = visualScale }, "Visual")
	setComponent(entity, Target, { id = owner }, "Target")
	setComponent(entity, Components.EnemyTier, { tier = enemyTier, scale = visualScale }, "EnemyTier")
	setComponent(entity, Components.EnemyArmor, { current = baseArmor }, "EnemyArmor")
	local collisionRadius = 2.5
	local enemyHitbox = ModelReplicationService.getEnemyHitbox(enemyType or "Zombie")
	if not enemyHitbox then
		ModelReplicationService.ensureEnemyHitbox(enemyType or "Zombie")
		enemyHitbox = ModelReplicationService.getEnemyHitbox(enemyType or "Zombie")
	end
	if enemyHitbox and enemyHitbox.size then
		collisionRadius = math.max(enemyHitbox.size.X, enemyHitbox.size.Z) * 0.5
	end
	-- Keep physical collision radius in sync with exact visual scale.
	collisionRadius = collisionRadius * (if typeof(visualScale) == "number" and visualScale > 0 then visualScale else 1.0)
	setComponent(entity, Collision, { radius = collisionRadius, solid = true }, "Collision")

	-- Owner/aggro metadata for adaptive targeting/exp
	setComponent(entity, Components.EnemyOwner, { id = owner }, "EnemyOwner")
	setComponent(entity, Components.EnemyAggro, {
		owner = owner,
		target = owner,
		damageByPlayer = {},
		threatByPlayer = {},
		lastThreatTime = GameTimeSystem.getGameTime(),
		lastSwitchTime = 0,
		nextSwitchThreshold = (EnemyBalance.Aggro and EnemyBalance.Aggro.MinDamageFractionToSwitch) or 0.30,
	}, "EnemyAggro")
	
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
					validPosition = Vector3.new(spawnPos.X, result.Position.Y + 1.5, spawnPos.Z)
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
			if PickupService then
				PickupService.spawnExpPickup(orbType, validPosition, playerEntity)
				spawned = spawned + 1
			end
		end
	end
end

function ECSWorldService.CreateProjectile(projectileType: string, position: Vector3, velocity: Vector3, owner: any?, customStats: any?): any
	if not warnedProjectileEntity then
		warnedProjectileEntity = true
		warn("[ECSWorldService] CreateProjectile is disabled; use ProjectileService records instead.")
	end
	return nil
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

local function buildStarterAbilityState(): ({[string]: any}, {[string]: any})
	local abilities = {}
	local cooldowns = {}

	for _, ability in pairs(AbilityRegistry.getAll()) do
		if ability.balance.StartWith then
			abilities[ability.id] = {
				enabled = true,
				level = 1,
				Name = ability.name,
				name = ability.name,
			}
			cooldowns[ability.id] = {
				remaining = 0,
				max = ability.balance.cooldown,
			}
		end
	end

	return abilities, cooldowns
end

local function resetPlayerProgressionToBaseline(playerEntity: number)
	if world:has(playerEntity, Components.AttributeSelections) then
		world:remove(playerEntity, Components.AttributeSelections)
		DirtyService.mark(playerEntity, "AttributeSelections")
	end

	local abilities, cooldowns = buildStarterAbilityState()
	if next(abilities) then
		setComponent(playerEntity, Components.Ability, {}, "Ability")
		setComponent(playerEntity, Components.AbilityData, { abilities = abilities }, "AbilityData")
		setComponent(playerEntity, Components.AbilityCooldown, { cooldowns = cooldowns }, "AbilityCooldown")
	else
		if world:has(playerEntity, Components.AbilityData) then
			world:remove(playerEntity, Components.AbilityData)
			DirtyService.mark(playerEntity, "AbilityData")
		end
		if world:has(playerEntity, Components.AbilityCooldown) then
			world:remove(playerEntity, Components.AbilityCooldown)
			DirtyService.mark(playerEntity, "AbilityCooldown")
		end
	end

	MobilityLoadoutService.equipStarterMobility(playerEntity)
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

		resetPlayerProgressionToBaseline(existingEntity)
		
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

	-- Initialize PassiveEffects component (computed passive multipliers)
	-- Start with PlayerBalance base multipliers
	setComponent(entity, PassiveEffectsComp, {
		damageMultiplier = PlayerBalance.BaseDamageMultiplier,
		cooldownMultiplier = PlayerBalance.BaseCooldownMultiplier,
		expMultiplier = PlayerBalance.BaseExpMultiplier,
		healthMultiplier = 1.0,
		healthFlatBonus = 0,
		moveSpeedMultiplier = 1.0,  -- Haste passive only
		levelExpCostMultiplier = 1.0,
		sprintMoveSpeedMultiplier = 1.0,
		closeRangeDamageMultiplier = 1.0,
		sizeMultiplier = 1.0,
		durationMultiplier = 1.0,
		pickupRangeMultiplier = 1.0,
		penetrationMultiplier = 1.0,
		mobilityCooldownMultiplier = 1.0,
		mobilityDistanceMultiplier = 1.0,  -- Calculated from mobility power + 20% move-speed bonus
		mobilityDistanceBase = 1.0,
		mobilityVerticalMultiplier = 1.0,
		grappleDistanceMultiplier = 1.0,
		regenMultiplier = 1.0,
		regenDelayMultiplier = 1.0,
		critChance = 0.01,
		critDamage = 0,
		armor = 0,
		primaryAttackSpeedBonus = 0,
		lifesteal = 0,
		luck = 0,
		powerupChance = 0,
		projectileCountBonus = 0,
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

	setComponent(entity, Components.PlayerArmorBuffs, {
		instances = {},
	}, "PlayerArmorBuffs")
	
	resetPlayerProgressionToBaseline(entity)

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
	if PassiveEffectSystem.clearSprintIntent then
		PassiveEffectSystem.clearSprintIntent(entity)
	end
	activeEntities[entity] = nil
	SyncSystem.queueDespawn(entity)
	ZombieAISystem.cleanupEntity(entity)
	EnemyRepulsionSystem.cleanupEntity(entity)
	SpatialGridSystem.cleanupEntity(entity)  -- Clean up from spatial grid (memory leak prevention)
	ExpSinkSystem.cleanupEntity(entity)  -- Clean up from sink system (if it was a sink)
	if ItemSystem and ItemSystem.onEntityRemoved then
		ItemSystem.onEntityRemoved(entity)
	end
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
local lastInvincibleDiagReport = 0
local lastEnemyVisualHitboxDiagReport = 0
local enemyColliderOverlayDebugFlag: BoolValue? = nil

-- StepWorld debug throttle
local lastStepWorldDebug = 0
local STEP_WORLD_DEBUG_INTERVAL = 5.0  -- Log every 5 seconds

local function printInvincibleProjectileSamples(samples: {any})
	local printed = 0
	for i = #samples, 1, -1 do
		local sample = samples[i]
		if typeof(sample) == "table" then
			print(string.format(
				"[INVDBG][projSample] t=%.2f proj=%s enemy=%s kind=%s reason=%s hp=%s deathAnim=%s scale=%s subtype=%s tier=%s blocker=%s",
				tonumber(sample.t) or 0,
				tostring(sample.projectileId),
				tostring(sample.enemyId),
				tostring(sample.kind),
				tostring(sample.reason),
				tostring(sample.enemyHealth),
				tostring(sample.hasDeathAnimation),
				tostring(sample.enemyScale),
				tostring(sample.enemySubtype),
				tostring(sample.enemyTier),
				tostring(sample.blocker)
			))
			printed += 1
			if printed >= 3 then
				break
			end
		end
	end
end

local function printInvincibleDamageSamples(samples: {any})
	local printed = 0
	for i = #samples, 1, -1 do
		local sample = samples[i]
		if typeof(sample) == "table" then
			print(string.format(
				"[INVDBG][dmgSample] t=%.2f target=%s reason=%s hasType=%s hasHealth=%s deathAnim=%s hp=%s",
				tonumber(sample.t) or 0,
				tostring(sample.targetEntity),
				tostring(sample.reason),
				tostring(sample.hasEntityType),
				tostring(sample.hasHealth),
				tostring(sample.hasDeathAnimation),
				tostring(sample.healthCurrent)
			))
			printed += 1
			if printed >= 3 then
				break
			end
		end
	end
end

local function emitInvincibleEnemyDiagnostics(now: number)
	if not INVINCIBLE_ENEMY_DIAGNOSTICS then
		return
	end
	if (now - lastInvincibleDiagReport) < 1.0 then
		return
	end
	lastInvincibleDiagReport = now

	local projectileDiag = ProjectileService.getInvincibleEnemyDebugSnapshot(true)
	local damageDiag = DamageSystem.getInvincibleEnemyDebugSnapshot(true)
	local targetingDiag = TargetingService.getInvincibleEnemyDebugSnapshot(true)

	print(string.format(
		"[INVDBG] proj(spawn=%d sim=%d/%d players=%d noPlayers=%d collOn=%d collOff=%d collOffNoPlayers=%d rayBlock=%d near1=%d near3=%d closestMiss=%.2f missY=%.2f missXZ=%.2f hitGeom=%d dmgOk=%d dmgReject=%d skipSim=%d skipCol=%d skipHit=%d) dmg(enemyAttempts=%d applied=%d missHealth=%d deathAnim=%d) target(acq=%d gridScan=%d fbScan=%d fbPick=%d rejDead=%d rejAge=%d rejRange=%d)",
		projectileDiag.projectilesSpawned or 0,
		projectileDiag.projectilesSimulated or 0,
		projectileDiag.projectilesTotalSeen or 0,
		projectileDiag.lastPlayerCount or 0,
		projectileDiag.framesWithoutPlayers or 0,
		projectileDiag.projectilesCollisionEnabled or 0,
		projectileDiag.projectilesCollisionDisabledByRelevance or 0,
		projectileDiag.projectilesCollisionDisabledNoPlayers or 0,
		projectileDiag.projectileRaycastBlocked or 0,
		projectileDiag.nearMissUnder1Stud or 0,
		projectileDiag.nearMissUnder3Stud or 0,
		tonumber(projectileDiag.closestMissGap) or -1,
		tonumber(projectileDiag.closestMissVerticalDelta) or -1,
		tonumber(projectileDiag.closestMissHorizontalDelta) or -1,
		projectileDiag.geometricHits or 0,
		projectileDiag.damageApplied or 0,
		projectileDiag.damageRejectedAfterHit or 0,
		projectileDiag.projectilesSkippedBySimBudget or 0,
		projectileDiag.projectilesSkippedByCollisionBudget or 0,
		projectileDiag.projectilesSkippedByHitBudget or 0,
		damageDiag.enemyDamageAttempts or 0,
		damageDiag.enemyDamageApplied or 0,
		damageDiag.enemyRejectedMissingHealth or 0,
		damageDiag.enemyHadDeathAnimationAtHit or 0,
		targetingDiag.acquireCalls or 0,
		targetingDiag.candidatesFromGridScanned or targetingDiag.candidatesFromGrid or 0,
		targetingDiag.candidatesFromFallbackScanned or targetingDiag.candidatesFromFallback or 0,
		targetingDiag.targetsChosenFromFallback or 0,
		targetingDiag.rejectDeadOrNoHealth or 0,
		targetingDiag.rejectSpawnAge or 0,
		targetingDiag.rejectOutOfRange or 0
	))

	if (projectileDiag.damageRejectedAfterHit or 0) > 0
		or (damageDiag.enemyRejectedMissingHealth or 0) > 0
		or (projectileDiag.projectileRaycastBlocked or 0) > 0
		or (projectileDiag.framesWithoutPlayers or 0) > 0
		or (projectileDiag.nearMissUnder1Stud or 0) > 0 then
		printInvincibleProjectileSamples(projectileDiag.samples or {})
		printInvincibleDamageSamples(damageDiag.samples or {})
	end
end

local function emitEnemyVisualHitboxDiagnostics(now: number)
	if not ENEMY_VISUAL_HITBOX_DIAGNOSTICS then
		return
	end
	if (now - lastEnemyVisualHitboxDiagReport) < 1.0 then
		return
	end
	lastEnemyVisualHitboxDiagReport = now

	local samples = ProjectileService.getEnemyVisualHitboxDebugSamples(3)
	for _, sample in ipairs(samples) do
		local basePos = sample.basePos
		local center = sample.center
		local halfExtents = sample.halfExtents
		if typeof(basePos) == "Vector3" and typeof(center) == "Vector3" and typeof(halfExtents) == "Vector3" then
			local facingYaw = tonumber(sample.facingYaw)
			local boxYaw = tonumber(sample.boxYaw)
			local yawDelta = -1
			if facingYaw and boxYaw then
				yawDelta = math.abs((boxYaw - facingYaw + 180) % 360 - 180)
			end
			print(string.format(
				"[EVHDBG][srv] enemy=%s subtype=%s tier=%s scale=%.2f pos=(%.2f,%.2f,%.2f) center=(%.2f,%.2f,%.2f) half=(%.2f,%.2f,%.2f) dY=%.2f bottomY=%s facingYaw=%s boxYaw=%s yawDelta=%s",
				tostring(sample.enemyId),
				tostring(sample.subtype),
				tostring(sample.tier),
				tonumber(sample.scale) or 1,
				basePos.X, basePos.Y, basePos.Z,
				center.X, center.Y, center.Z,
				halfExtents.X, halfExtents.Y, halfExtents.Z,
				tonumber(sample.baseToCenterY) or 0,
				tostring(sample.bottomY),
				tostring(facingYaw),
				tostring(boxYaw),
				if yawDelta >= 0 then string.format("%.2f", yawDelta) else "nil"
			))
			if yawDelta > 10 then
				print(string.format("[EVHDBG][srv][yawWarn] enemy=%s yawDelta=%.2f", tostring(sample.enemyId), yawDelta))
			end
		end
	end
end

local function isEnemyColliderOverlayEnabled(): boolean
	if enemyColliderOverlayDebugFlag and enemyColliderOverlayDebugFlag.Parent then
		return enemyColliderOverlayDebugFlag.Value == true
	end
	return ENEMY_COLLIDER_OVERLAY
end

local function stepWorld(dt: number)
	-- Debug: Log that stepWorld is running
	local now = tick()
	-- Removed verbose stepWorld debug logging
	
	-- Check if game is paused - skip all ECS updates if so
	if PauseSystem.isPaused() then
		-- Keep record-based projectiles moving during pause.
		debug.profilebegin("ProjectileService")
		ProjectileService.step(dt)
		debug.profileend()
		debug.profilebegin("ItemSpawnService")
		ItemSpawnService.step(dt)
		debug.profileend()
		emitInvincibleEnemyDiagnostics(now)
		emitEnemyVisualHitboxDiagnostics(now)
		EnemyColliderOverlayService.step(dt, isEnemyColliderOverlayEnabled())
		return
	end
	
	-- Step game time (pause-aware timer)
	debug.profilebegin("GameTime")
	GameTimeSystem.step(dt)
	debug.profileend()

	debug.profilebegin("WeaponService")
	WeaponService.step(dt)
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

	-- Enemy slow debuffs (expire/cleanup before AI)
	debug.profilebegin("TemporalStasis")
	TemporalStasisSystem.step(dt)
	debug.profileend()

	-- Enemy slow debuffs (expire/cleanup before AI)
	debug.profilebegin("EnemySlow")
	EnemySlowSystem.step(dt)
	debug.profileend()

	debug.profilebegin("EnemyFrost")
	EnemyFrostSystem.step(dt)
	debug.profileend()

	debug.profilebegin("EnemyAilments")
	EnemyAilmentSystem.step(dt)
	debug.profileend()

	debug.profilebegin("EnemyStun")
	EnemyStunSystem.step(dt)
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

	debug.profilebegin("ItemSpawnService")
	ItemSpawnService.step(dt)
	debug.profileend()

	debug.profilebegin("PickupService")
	PickupService.step(dt)
	debug.profileend()

	debug.profilebegin("ItemSystem")
	ItemSystem.step(dt)
	debug.profileend()
	
	-- Pause system (for individual pause timeout checking)
	debug.profilebegin("PauseSystem")
	PauseSystem.step(dt)
	debug.profileend()
	
	-- Game State Manager (check continue timer)
	debug.profilebegin("GameStateManager")
	GameStateManager.step(dt)
	debug.profileend()

	debug.profilebegin("UltimateSystem")
	UltimateSystem.step(dt)
	debug.profileend()

	debug.profilebegin("LoopGameService")
	LoopGameService.step(dt)
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
		
	end
	
	-- Enemy repulsion system (after AI but before movement)
	debug.profilebegin("EnemyRepulsion")
	enemyRepulsionAccumulator += dt
	if enemyRepulsionAccumulator >= ENEMY_REPULSION_INTERVAL then
		enemyRepulsionAccumulator = 0
		EnemyRepulsionSystem.step(dt)
	end
	debug.profileend()

	-- Core simulation systems
	debug.profilebegin("Movement")
	MovementSystem.step(dt)
	debug.profileend()

	-- Refresh octree after movement so projectile collision queries use up-to-date enemy positions.
	debug.profilebegin("OctreePostMove")
	OctreeSystem.updateEnemyPositions()
	debug.profileend()

	-- Record-based projectile simulation (no ECS entities)
	debug.profilebegin("ProjectileService")
	ProjectileService.step(dt)
	debug.profileend()

	local ecsProjectileCount = 0
	for _ in projectileEntityQuery do
		ecsProjectileCount += 1
	end
	profGauge("ActiveEcsProjectiles", ecsProjectileCount)
	if ecsProjectileCount > 0 and not warnedActiveEcsProjectiles then
		warnedActiveEcsProjectiles = true
		warn("[Bootstrap] ECS projectiles detected after record migration; check for legacy spawns.")
	end

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

	emitInvincibleEnemyDiagnostics(tick())
	emitEnemyVisualHitboxDiagnostics(tick())
	EnemyColliderOverlayService.step(dt, isEnemyColliderOverlayEnabled())
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
		profInc("initialSyncSentCount", 1)
	end
	return snapshot
end


-- Set global respawn time from PlayerBalance
Players.RespawnTime = PlayerBalance.RespawnDelay

Players.PlayerAdded:Connect(function(player)
	-- Notify GameStateManager of player join
	GameStateManager.onPlayerJoin(player)
	
	local function onCharacterAdded(character: Model)
		disableCharacterFluidForces(character)

		-- Spawn player at lobby position (GameStateManager will teleport to game when they press Play)
		local humanoidRootPart = character:WaitForChild("HumanoidRootPart", 5)
		if humanoidRootPart then
			-- Teleport to lobby spawn (near camera view)
			humanoidRootPart.CFrame = CFrame.new(220, 609, 400)
			
			-- DON'T create ECS entity here
			-- Wait for GameStateManager.addPlayerToGame() to create it after "Play" button
		end

		-- Always equip starter weapon on spawn (lobby + in-game + respawns).
		attachStarterWeapon(character)
		
		-- Death is now handled by DeathSystem (triggered from DamageSystem)
		-- No need for humanoid.Died event - custom death system prevents Roblox death
	end

	-- Wait for character to load
	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		task.defer(onCharacterAdded, player.Character)
	end

	-- Send initial ECS snapshot to client (AFTER they join game)
	-- Increased delay from 2s to 2.5s to ensure all initial components are set
	task.delay(2.5, function()
		if not player.Parent then
			return
		end
		local snapshot = SyncSystem.buildInitialSnapshot(player)
		if next(snapshot) then
			EntitySync:FireClient(player, snapshot)
			profInc("initialSyncSentCount", 1)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	local entity = playerEntities[player]
	if entity then
		PickupService.cleanupPlayer(player, entity)
	else
		PickupService.cleanupPlayer(player, nil)
	end
	if entity then
		ECSWorldService.DestroyEntity(entity)
	end
end)

-- Death system - Spectator controls
local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local SprintStateRemote = remotes:FindFirstChild("SprintState")
if not SprintStateRemote or not SprintStateRemote:IsA("RemoteEvent") then
	if SprintStateRemote then
		SprintStateRemote:Destroy()
	end
	SprintStateRemote = Instance.new("RemoteEvent")
	SprintStateRemote.Name = "SprintState"
	SprintStateRemote.Parent = remotes
end

SprintStateRemote.OnServerEvent:Connect(function(player: Player, isSprintIntent: any)
	if typeof(isSprintIntent) ~= "boolean" then
		return
	end
	local playerEntity = playerEntities[player]
	if not playerEntity then
		return
	end
	if PassiveEffectSystem.setSprintIntent then
		PassiveEffectSystem.setSprintIntent(playerEntity, isSprintIntent)
	end
end)

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

