--!strict
-- PowerupEffectSystem - Applies powerup effects when collected
-- Handles: Nuke, Magnet, Health, Cloak, ArcaneRune

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PowerupBalance = require(game.ServerScriptService.Balance.PowerupBalance)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)

local PowerupEffectSystem = {}

local world: any
local Components: any
local DirtyService: any
local ECSWorldService: any

-- System references
local DamageSystem: any
local OverhealSystem: any
local StatusEffectSystem: any
local BuffSystem: any
local EnemySpawner: any

-- Remotes for notifying clients
local PowerupEffectUpdate: RemoteEvent
local BuffDurationUpdate: RemoteEvent

function PowerupEffectSystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService
	
	-- Get or create remotes
	local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
	PowerupEffectUpdate = remotes:FindFirstChild("PowerupEffectUpdate")
	if not PowerupEffectUpdate then
		PowerupEffectUpdate = Instance.new("RemoteEvent")
		PowerupEffectUpdate.Name = "PowerupEffectUpdate"
		PowerupEffectUpdate.Parent = remotes
	end
	
	BuffDurationUpdate = remotes:WaitForChild("BuffDurationUpdate")
end

-- Set system references (called after systems are initialized)
function PowerupEffectSystem.setDamageSystem(damageSystem: any)
	DamageSystem = damageSystem
end

function PowerupEffectSystem.setOverhealSystem(overhealSystem: any)
	OverhealSystem = overhealSystem
end

function PowerupEffectSystem.setStatusEffectSystem(statusEffectSystem: any)
	StatusEffectSystem = statusEffectSystem
end

function PowerupEffectSystem.setBuffSystem(buffSystem: any)
	BuffSystem = buffSystem
end

function PowerupEffectSystem.setEnemySpawner(enemySpawner: any)
	EnemySpawner = enemySpawner
end

-- Broadcast powerup effect to client for visual highlights and buff tracker
local function broadcastToClient(playerEntity: number, powerupType: string, healthPercent: number?, overhealPercent: number?)
	local playerStats = world:get(playerEntity, Components.PlayerStats)
	if not playerStats or not playerStats.player then
		return
	end
	
	local config = PowerupBalance.PowerupTypes[powerupType]
	if not config then
		return
	end
	
	-- Get duration based on powerup type (some use special duration fields)
	local duration = config.duration or 0
	if powerupType == "Nuke" then
		duration = config.nukeDuration or 3.0
	elseif powerupType == "Magnet" then
		duration = config.pullDuration or 3.0
	elseif powerupType == "Health" then
		duration = 2.0  -- 2s popup for health
	end
	
	-- Send highlight update
	PowerupEffectUpdate:FireClient(playerStats.player, {
		powerupType = powerupType,
		duration = duration,
		highlightColor = config.highlightColor,
		characterTransparency = config.characterTransparency or 0,
	})
	
	-- Send buff duration update
	BuffDurationUpdate:FireClient(playerStats.player, {
		buffId = powerupType,
		displayName = config.displayName or powerupType,
		duration = duration,
		healthPercent = healthPercent,
		overhealPercent = overhealPercent,
	})
end

-- NUKE: Kill all enemies and prevent spawns
local function applyNuke(playerEntity: number)
	if not DamageSystem or not EnemySpawner then
		warn("[PowerupEffectSystem] DamageSystem or EnemySpawner not initialized!")
		return
	end
	
	-- Get all enemy entities
	local enemies = {}
	for entity, entityType in world:query(Components.EntityType) do
		if entityType.type == "Enemy" then
			table.insert(enemies, entity)
		end
	end
	
	-- Kill all enemies (with nukeKill flag to prevent powerup drops)
	for _, enemyEntity in ipairs(enemies) do
		local health = world:get(enemyEntity, Components.Health)
		if health and health.current > 0 then
			-- Apply massive damage to kill instantly
			DamageSystem.applyDamage(enemyEntity, health.max * 10, "nuke")
		end
	end
	
	-- Prevent enemy spawns for nukeDuration
	local nukeDuration = PowerupBalance.PowerupTypes.Nuke.nukeDuration
	EnemySpawner.setNukeActive(nukeDuration)
	
	-- Broadcast to client for highlight
	broadcastToClient(playerEntity, "Nuke")
end

-- MAGNET: Pull player's exp orbs towards them (and tag new ones during duration)
local function applyMagnet(playerEntity: number)
	if not world then return end
	
	local now = GameTimeSystem.getGameTime()
	local pullDuration = PowerupBalance.PowerupTypes.Magnet.pullDuration
	
	-- Start magnet session (new orbs will be auto-tagged by spawn systems)
	local MagnetPullSystem = require(game.ServerScriptService.ECS.Systems.MagnetPullSystem)
	MagnetPullSystem.startMagnetSession(playerEntity, pullDuration)
	
	-- MULTIPLAYER: Tag only this player's exp orbs with MagnetPull component
	for entity, entityType, itemData in world:query(Components.EntityType, Components.ItemData) do
		if entityType.type == "ExpOrb" then
			-- Skip red sink orbs (they are special and should not be magnetized)
			if itemData and itemData.isSink then
				continue
			end
			
			-- MULTIPLAYER: Only magnetize orbs owned by this player
			if itemData and itemData.ownerId ~= playerEntity then
				continue
			end
			
			-- Check if it doesn't already have MagnetPull
			local existingPull = world:get(entity, Components.MagnetPull)
			if not existingPull then
				DirtyService.setIfChanged(world, entity, Components.MagnetPull, {
					targetPlayer = playerEntity,
					startTime = now,
					duration = pullDuration,
				}, "MagnetPull")
			end
		end
	end
	
	-- Broadcast to client for highlight
	broadcastToClient(playerEntity, "Magnet")
end

-- HEALTH: Heal 45% of max HP + overheal
local function applyHealth(playerEntity: number)
	if not OverhealSystem then
		warn("[PowerupEffectSystem] OverhealSystem not initialized!")
		return
	end
	
	-- Get player health
	local health = world:get(playerEntity, Components.Health)
	if not health then
		return
	end
	
	-- Calculate heal amounts for display
	local healAmount = health.max * PowerupBalance.PowerupTypes.Health.healPercent
	local actualHealAmount = math.min(healAmount, health.max - health.current)
	local overhealAmount = healAmount - actualHealAmount
	
	-- Convert to percentages for display
	local healthPercent = math.floor((actualHealAmount / health.max) * 100)
	local overhealPercent = math.floor((overhealAmount / health.max) * 100)
	
	-- Heal up to max HP
	local newHealth = math.min(health.current + healAmount, health.max)
	
	-- Calculate overheal (any healing beyond max HP)
	local overheal = (health.current + healAmount) - health.max
	if overheal > 0 then
		OverhealSystem.grantOverheal(playerEntity, overheal)
	end
	
	-- Update health
	DirtyService.setIfChanged(world, playerEntity, Components.Health, {
		current = newHealth,
		max = health.max,
	}, "Health")
	
	-- Also update Roblox humanoid health
	local playerStats = world:get(playerEntity, Components.PlayerStats)
	if playerStats and playerStats.player then
		local player = playerStats.player
		local character = player.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Health = math.min(humanoid.Health + healAmount, humanoid.MaxHealth)
			end
		end
	end
	
	-- Broadcast to client with percentages for display
	broadcastToClient(playerEntity, "Health", healthPercent, overhealPercent)
end

-- CLOAK: Grant invincibility + speed boost
local function applyCloak(playerEntity: number)
	if not StatusEffectSystem then
		warn("[PowerupEffectSystem] StatusEffectSystem not initialized!")
		return
	end
	
	local config = PowerupBalance.PowerupTypes.Cloak
	local duration = config.duration
	local speedBoost = config.speedBoost
	
	-- Grant invincibility (don't show in tracker, Cloak buff handles the display)
	StatusEffectSystem.grantInvincibility(playerEntity, duration, false, false, false)  -- Cloak powerup invincibility
	
	-- Grant speed boost (30% = 1.3x multiplier) - stacks with Haste and level-up
	StatusEffectSystem.grantSpeedBoost(playerEntity, duration, speedBoost, "cloak")
	
	-- Broadcast to client for highlight + transparency effect
	broadcastToClient(playerEntity, "Cloak")
end

-- ARCANE RUNE: Grant damage + cooldown + homing + penetration + duration + speed buff
local function applyArcaneRune(playerEntity: number)
	if not BuffSystem then
		warn("[PowerupEffectSystem] BuffSystem not initialized!")
		return
	end
	
	local config = PowerupBalance.PowerupTypes.ArcaneRune
	local duration = config.duration
	local damageMult = config.damageMult
	local cooldownMult = config.cooldownMult
	local homingMult = config.homingMult
	local penetrationMult = config.penetrationMult
	local durationMult = config.durationMult
	local projectileSpeedMult = config.projectileSpeedMult
	
	-- Add buff with all multipliers from config
	BuffSystem.addBuff(
		playerEntity, 
		"ArcaneRune", 
		duration, 
		damageMult, 
		cooldownMult,
		homingMult,
		penetrationMult,
		durationMult,
		projectileSpeedMult
	)
	
	-- Broadcast to client for highlight
	broadcastToClient(playerEntity, "ArcaneRune")
end

-- PUBLIC API: Apply powerup effect to player
function PowerupEffectSystem.applyPowerup(playerEntity: number, powerupType: string)
	if not world then
		warn("[PowerupEffectSystem] World not initialized!")
		return
	end
	
	-- MULTIPLAYER: Health is per-player, other buffs apply to ALL players
	if powerupType == "Health" then
		-- Health: only buff collector
		applyHealth(playerEntity)
	elseif powerupType == "Nuke" or powerupType == "Magnet" or powerupType == "Cloak" or powerupType == "ArcaneRune" then
		-- Global buffs: apply to ALL players
		local Players = game:GetService("Players")
		for _, player in ipairs(Players:GetPlayers()) do
			-- Find player entity
			local targetPlayerEntity = nil
			for entity, stats in world:query(Components.PlayerStats) do
				if stats.player == player then
					targetPlayerEntity = entity
					break
				end
			end
			
			if targetPlayerEntity then
				-- Apply effect to this player
				if powerupType == "Nuke" then
					applyNuke(targetPlayerEntity)
				elseif powerupType == "Magnet" then
					applyMagnet(targetPlayerEntity)
				elseif powerupType == "Cloak" then
					applyCloak(targetPlayerEntity)
				elseif powerupType == "ArcaneRune" then
					applyArcaneRune(targetPlayerEntity)
				end
			end
		end
	else
		warn("[PowerupEffectSystem] Unknown powerup type:", powerupType)
	end
end

return PowerupEffectSystem

