--!strict
-- IceShard System - Handles auto-casting IceShard ability for players
-- Manages targeting, cooldowns, and projectile spawning

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AbilitySystemBase = require(script.Parent.Parent.AbilitySystemBase)
local TargetingService = require(script.Parent.Parent.TargetingService)
local Config = require(script.Parent.Config)
local Attributes = require(script.Parent.Attributes)
local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local ProjectileService = require(game.ServerScriptService.Services.ProjectileService)
local ModelHitboxHelper = require(game.ServerScriptService.Utilities.ModelHitboxHelper)
local Balance = Config  -- Backward compatibility alias

local AbilityCastRemote = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("AbilityCast")

local IceShardSystem = {}

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

-- IceShard constants
local ICESHARD_ID = "IceShard"
local ICESHARD_NAME = Balance.Name

local playerQuery: any

local petalStateByEntity: {[number]: {petalIds: {number}, repelTimer: number}} = {}

-- Spawn a burst of IceShard projectiles (handles shotgun spread)
local function spawnIceShardBurst(
	playerEntity: number,
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
		local projectileEntity = AbilitySystemBase.createProjectile(
			ICESHARD_ID,
			stats,  -- Pass upgraded stats instead of base Balance
			position,
			direction,
			player,
			targetPoint,
			playerEntity
		)
		
		if projectileEntity then
			created += 1
		end
	end

	return created
end

local function getIceShardAttribute(playerEntity: number, abilityData: any): string?
	local attributeSelections = world:get(playerEntity, AttributeSelections)
	if attributeSelections and attributeSelections[ICESHARD_ID] then
		return attributeSelections[ICESHARD_ID]
	end
	local abilityRecord = abilityData and abilityData.abilities and abilityData.abilities[ICESHARD_ID]
	if abilityRecord and abilityRecord.selectedAttribute then
		return abilityRecord.selectedAttribute
	end
	return nil
end

local function applyCrystalShardsOverrides(stats: any)
	if not stats then
		return
	end
	local shotAmount = math.max(stats.shotAmount or 1, 1)
	local extraShots = math.max(shotAmount - 1, 0)
	if extraShots > 0 then
		stats.shotAmount = 1
		stats.projectileCount = (stats.projectileCount or 1) + extraShots
	else
		stats.shotAmount = shotAmount
		stats.projectileCount = stats.projectileCount or 1
	end
	stats.cooldown = (stats.cooldown or 0) * 1.2
end

local function getAdjustedIceShardStats(playerEntity: number, abilityData: any): (any, string?)
	local stats = AbilitySystemBase.getAbilityStats(playerEntity, ICESHARD_ID, Balance)
	local attributeId = getIceShardAttribute(playerEntity, abilityData)
	if attributeId == "CrystalShards" then
		applyCrystalShardsOverrides(stats)
	end
	return stats, attributeId
end

local function buildIceShardExtraConfig(attributeId: string?, stats: any): any?
	if not attributeId then
		return nil
	end
	if attributeId == "ImpalingFrost" then
		local special = Attributes.ImpalingFrost and Attributes.ImpalingFrost.special
		if special then
			return {
				slowOnHit = {
					duration = special.slowDuration or 5,
					multiplier = special.slowMultiplier or 0.6,
					impaleModelPath = special.impaleModelPath,
				},
			}
		end
	elseif attributeId == "CrystalShards" then
		local special = Attributes.CrystalShards and Attributes.CrystalShards.special
		if special then
			local penetration = stats.penetration or 0
			local splitCount = 2 + math.floor(penetration / 2)
			return {
				splitOnHit = {
					count = splitCount,
					damageMultiplier = special.splitDamageMultiplier or 0.7,
					scaleMultiplier = special.splitScaleMultiplier or 0.5,
					maxSpreadDeg = special.maxSpreadDegrees or 180,
					targetingAngle = stats.targetingAngle,
				},
			}
		end
	end
	return nil
end

local function ensureFrozenPetalModelsReplicated()
	ModelReplicationService.replicateModel(
		"ContentDrawer.Attacks.Abilties.IceShard.FrozenPetals",
		"ContentDrawer.Attacks.Abilties.IceShard"
	)
	ModelReplicationService.replicateModel(
		"ContentDrawer.Attacks.Abilties.IceShard.Repel",
		"ContentDrawer.Attacks.Abilties.IceShard"
	)
end

local function getRepelRadius(): number
	local hitboxSize = ModelHitboxHelper.getModelHitboxData("ServerStorage.ContentDrawer.Attacks.Abilties.IceShard.Repel")
	if hitboxSize then
		return math.max(hitboxSize.X, hitboxSize.Z) * 0.5
	end
	return 12
end

local function spawnPetalProjectile(
	playerEntity: number,
	player: Player,
	stats: any,
	special: any,
	index: number
): number?
	local position = AbilitySystemBase.getPlayerPosition(playerEntity, player)
	if not position then
		return nil
	end

	local direction = Vector3.new(0, 0, 1)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		direction = (hrp :: BasePart).CFrame.LookVector
	end

	local offsetDir = Vector3.new(1, 0, 0)
	if hrp and hrp:IsA("BasePart") then
		offsetDir = (hrp :: BasePart).CFrame.RightVector
	end
	local offsetSign = (index % 2 == 1) and -1 or 1
	position = position + offsetDir * offsetSign * 2

	local petalStats = {
		modelPath = "ReplicatedStorage.ContentDrawer.Attacks.Abilties.IceShard.FrozenPetals",
		damage = stats.damage,
		projectileSpeed = (stats.projectileSpeed or 0) * (special.petalSpeedMultiplier or 0.5),
		penetration = 999,
		duration = special.petalLifetime or 999999,
		scale = stats.scale or 1,
		hitCooldown = special.petalHitCooldown or 0.3,
		targetingMode = 3,
		homingStrength = special.petalHomingStrength or 360,
		homingMaxAngle = special.petalHomingMaxAngle or 360,
		homingDistance = special.petalMaxRange or 100,
		StayHorizontal = stats.StayHorizontal,
		AlwaysStayHorizontal = stats.AlwaysStayHorizontal,
		StickToPlayer = false,
	}

	local targetPoint = position + direction * (petalStats.projectileSpeed * petalStats.duration)
	return AbilitySystemBase.createProjectile(
		ICESHARD_ID,
		petalStats,
		position,
		direction,
		player,
		targetPoint,
		playerEntity,
		{
			petal = {
				ownerEntity = playerEntity,
				maxRange = special.petalMaxRange or 100,
				homingStrength = special.petalHomingStrength or 360,
				homingMaxAngle = special.petalHomingMaxAngle or 360,
				stayHorizontal = petalStats.StayHorizontal,
				alwaysStayHorizontal = petalStats.AlwaysStayHorizontal,
				role = (index == 1 and "closest") or (index == 2 and "toughest") or "closest",
			},
		}
	)
end

local function spawnRepelPulse(playerEntity: number, player: Player, special: any)
	local position = AbilitySystemBase.getPlayerPosition(playerEntity, player)
	if not position then
		return
	end

	local aoeRadius = getRepelRadius()
	ProjectileService.spawnProjectile({
		kind = ICESHARD_ID,
		origin = position,
		direction = Vector3.new(0, 1, 0),
		speed = 0,
		damage = 0,
		radius = 0.1,
		lifetime = 0.05,
		ownerEntity = playerEntity,
		pierce = 0,
		modelPath = "",
		visualScale = 1,
		aoe = {
			radius = aoeRadius,
			damage = special.repelDamage or 100,
			triggerOnExpire = true,
			trigger = "hit",
			duration = 0.5,
			modelPath = "ReplicatedStorage.ContentDrawer.Attacks.Abilties.IceShard.Repel",
			scale = 1,
			knockbackDistance = special.repelKnockbackDistance or 10,
			knockbackDuration = 0.25,
			knockbackStunned = true,
			retargetPetalsOwner = playerEntity,
		},
	})
end

local function updateFrozenPetals(playerEntity: number, player: Player, stats: any, dt: number)
	local special = Attributes.FrozenPetals and Attributes.FrozenPetals.special
	if not special then
		return
	end

	ensureFrozenPetalModelsReplicated()

	local state = petalStateByEntity[playerEntity]
	if not state then
		state = {
			petalIds = {},
			repelTimer = special.repelInterval or 3,
		}
		petalStateByEntity[playerEntity] = state
	end

	local petalCount = special.petalCount or 2
	for i = 1, petalCount do
		local id = state.petalIds[i]
		if not id or not ProjectileService.isProjectileActive(id) then
			local newId = spawnPetalProjectile(playerEntity, player, stats, special, i)
			if newId then
				state.petalIds[i] = newId
			end
		end
	end

	state.repelTimer = (state.repelTimer or (special.repelInterval or 3)) - dt
	if state.repelTimer <= 0 then
		spawnRepelPulse(playerEntity, player, special)
		state.repelTimer = special.repelInterval or 3
	end
end

-- Perform a IceShard burst (finds target and spawns projectiles)
local function performIceShardBurst(playerEntity: number, player: Player, statsOverride: any?, attributeOverride: string?): boolean
	-- Get player position (prefers character position)
	local position = AbilitySystemBase.getPlayerPosition(playerEntity, player)
	if not position then
		return false
	end
	
	-- Get upgraded stats for this player (includes ability upgrades + passive effects)
	local abilityData = world:get(playerEntity, AbilityData)
	local stats = statsOverride
	local attributeId = attributeOverride
	if not stats then
		stats, attributeId = getAdjustedIceShardStats(playerEntity, abilityData)
	end

	local shots = math.max(stats.shotAmount, 1)
	local totalSpread = math.min(math.abs(stats.targetingAngle) * 2, math.rad(10))
	local step = shots > 1 and totalSpread / (shots - 1) or 0
	local offsets = table.create(shots)
	if shots == 1 then
		offsets[1] = 0
	elseif shots % 2 == 1 then
		local midpoint = (shots - 1) * 0.5
		for i = 1, shots do
			offsets[i] = (i - 1) - midpoint
		end
	else
		local middleIndex = math.ceil(shots / 2)
		offsets[middleIndex] = 0
		local stepIndex = 1
		for i = 1, shots do
			if i ~= middleIndex then
				local sign = (stepIndex % 2 == 1) and 1 or -1
				local magnitude = math.floor((stepIndex + 1) / 2)
				offsets[i] = sign * magnitude
				stepIndex += 1
			end
		end
	end
	local targetingResult = TargetingService.acquireTarget({
		playerEntity = playerEntity,
		player = player,
		origin = position,
		maxRange = stats.targetingRange,
		mode = stats.targetingMode,
		stayHorizontal = stats.StayHorizontal,
		alwaysStayHorizontal = stats.AlwaysStayHorizontal,
		stickToPlayer = stats.StickToPlayer,
		enablePrediction = stats.enablePrediction,
		projectileSpeed = stats.projectileSpeed,
		duration = stats.duration,
		lockDuration = stats.targetLockDuration,
		reacquireDelay = stats.reacquireDelay,
		minTargetableAge = stats.minTargetableAge,
		fovAngle = stats.targetingFov,
		damage = stats.damage,
		abilityId = ICESHARD_ID,
	})

	local created = 0
	for shotIndex = 1, shots do
		local targetEntity = targetingResult.targetEntity
		if targetEntity then
			TargetingService.recordPredictedDamage(playerEntity, ICESHARD_ID, targetEntity, stats.damage)
		end

		local baseDirection = targetingResult.direction
		if baseDirection.Magnitude == 0 then
			baseDirection = Vector3.new(0, 0, 1)
		end
		baseDirection = baseDirection.Unit

		local direction = baseDirection
		if shots > 1 then
			local offsetIndex = offsets[shotIndex] or 0
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

		local aimPoint = targetingResult.aimPoint or (position + baseDirection * stats.targetingRange)
		local targetDistance = (aimPoint - position).Magnitude
		local targetPoint: Vector3
		if targetDistance > 0 then
			targetPoint = position + direction * targetDistance
		else
			targetPoint = position + direction * (stats.projectileSpeed * stats.duration)
		end

		local extraConfig = buildIceShardExtraConfig(attributeId, stats)
		local projectileEntity = AbilitySystemBase.createProjectile(
			ICESHARD_ID,
			stats,
			position,
			direction,
			player,
			targetPoint,
			playerEntity,
			extraConfig
		)
		if projectileEntity then
			created += 1
		end
	end

	return created > 0
end

-- Cast IceShard ability (handles initial cast and multi-shot setup)
local function castIceShard(playerEntity: number, player: Player): boolean
	-- Get upgraded stats
	local abilityData = world:get(playerEntity, AbilityData)
	local stats, attributeId = getAdjustedIceShardStats(playerEntity, abilityData)
	
	-- Start prediction tracking for smart multi-targeting
	TargetingService.startCastPrediction(playerEntity, ICESHARD_ID)
	
	local success = performIceShardBurst(playerEntity, player, stats, attributeId)

	if success and stats.projectileCount > 1 then
		-- Setup multi-shot pulse (predictions will persist through pulse)
		local interval = math.max(stats.pulseInterval or 0, 0.01)
		local pulseData = {
			ability = ICESHARD_ID,
			remaining = stats.projectileCount - 1,
			timer = interval,
			interval = interval,
		}
		DirtyService.setIfChanged(world, playerEntity, AbilityPulse, pulseData, "AbilityPulse")
	else
		-- Single shot cast, end prediction immediately
		TargetingService.endCastPrediction(playerEntity, ICESHARD_ID)
	end

	return success
end

-- Initialize the system
function IceShardSystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
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
end

-- Step function (called every frame)
function IceShardSystem.step(dt: number)
	if not world then
		return
	end

	-- Query all players with IceShard ability
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
			-- Check if player has IceShard ability enabled
			if abilityData and abilityData.abilities and abilityData.abilities[ICESHARD_ID] 
				and abilityData.abilities[ICESHARD_ID].enabled then
				local attributeId = getIceShardAttribute(entity, abilityData)
				if attributeId == "FrozenPetals" then
					local stats = AbilitySystemBase.getAbilityStats(entity, ICESHARD_ID, Balance)
					updateFrozenPetals(entity, player, stats, dt)

					local pulseComponent = world:get(entity, AbilityPulse)
					if pulseComponent and pulseComponent.ability == ICESHARD_ID then
						world:remove(entity, AbilityPulse)
						TargetingService.endCastPrediction(entity, ICESHARD_ID)
					end

					local cooldownData = world:get(entity, AbilityCooldown)
					local cooldowns = cooldownData and cooldownData.cooldowns or {}
					local currentCooldown = cooldowns[ICESHARD_ID]
					if not currentCooldown or currentCooldown.remaining ~= 0 or currentCooldown.max ~= stats.cooldown then
						cooldowns[ICESHARD_ID] = {
							remaining = 0,
							max = stats.cooldown,
						}
						DirtyService.setIfChanged(world, entity, AbilityCooldown, {
							cooldowns = cooldowns
						}, "AbilityCooldown")
					end

					continue
				end
				-- Handle multi-shot pulse
				local pulseComponent = world:get(entity, AbilityPulse)
				if pulseComponent and pulseComponent.ability == ICESHARD_ID then
					local stats, attributeId = getAdjustedIceShardStats(entity, abilityData)
					local interval = (pulseComponent.interval or stats.pulseInterval or 0)
					local timer = 0
					local remaining = pulseComponent.remaining or 0

					if interval <= 0 then
						-- Fire all remaining shots immediately
						while remaining > 0 do
							if performIceShardBurst(entity, player, stats, attributeId) then
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
							if performIceShardBurst(entity, player, stats, attributeId) then
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
						TargetingService.endCastPrediction(entity, ICESHARD_ID)
					else
						local newPulse = {
							ability = ICESHARD_ID,
							timer = timer,
							remaining = remaining,
							interval = interval,
						}
						DirtyService.setIfChanged(world, entity, AbilityPulse, newPulse, "AbilityPulse")
						pulseComponent = newPulse
					end
				end

				-- Check if pulse is still active
				pulseComponent = world:get(entity, AbilityPulse)
				local pulseActive = pulseComponent and pulseComponent.ability == ICESHARD_ID

				-- Handle cooldown for this ability
				-- Get upgraded stats for cooldown
				local stats = getAdjustedIceShardStats(entity, abilityData)

				local cooldownData = world:get(entity, AbilityCooldown)
				local cooldowns = cooldownData and cooldownData.cooldowns or {}
				local cooldown = cooldowns[ICESHARD_ID] or { remaining = 0, max = stats.cooldown }

				-- Cast ability when cooldown is ready and no pulse active
				if cooldown.remaining <= 0 and not pulseActive then
					local success = castIceShard(entity, player)
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
						AbilityCastRemote:FireClient(player, ICESHARD_ID, stats.cooldown, ICESHARD_NAME, {
							projectileCount = stats.projectileCount or 1,
							pulseInterval = stats.pulseInterval or 0,
							damageStats = damageStats,
							animationData = animationData,  -- Send all animation config from server
						})

						-- Update this ability's cooldown
						cooldowns[ICESHARD_ID] = {
							remaining = stats.cooldown,
							max = stats.cooldown,
						}
						DirtyService.setIfChanged(world, entity, AbilityCooldown, {
							cooldowns = cooldowns
						}, "AbilityCooldown")
					end
				else
					-- Update cooldown timer
					cooldowns[ICESHARD_ID] = {
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

end

return IceShardSystem
