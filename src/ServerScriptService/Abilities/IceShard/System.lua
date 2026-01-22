--!strict
-- IceShard System - Handles auto-casting IceShard ability for players
-- Manages targeting, cooldowns, and projectile spawning

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AbilitySystemBase = require(script.Parent.Parent.AbilitySystemBase)
local TargetingService = require(script.Parent.Parent.TargetingService)
local Config = require(script.Parent.Config)
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

-- IceShard constants
local ICESHARD_ID = "IceShard"
local ICESHARD_NAME = Balance.Name

local playerQuery: any

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

-- Perform a IceShard burst (finds target and spawns projectiles)
local function performIceShardBurst(playerEntity: number, player: Player): boolean
	-- Get player position (prefers character position)
	local position = AbilitySystemBase.getPlayerPosition(playerEntity, player)
	if not position then
		return false
	end
	
	-- Get upgraded stats for this player (includes ability upgrades + passive effects)
	local stats = AbilitySystemBase.getAbilityStats(playerEntity, ICESHARD_ID, Balance)

	local shots = math.max(stats.shotAmount, 1)
	local totalSpread = math.min(math.abs(stats.targetingAngle) * 2, math.rad(10))
	local step = shots > 1 and totalSpread / (shots - 1) or 0
	local midpoint = (shots - 1) * 0.5

	local created = 0
	for shotIndex = 1, shots do
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
			lockDuration = stats.targetLockDuration,
			reacquireDelay = stats.reacquireDelay,
			minTargetableAge = stats.minTargetableAge,
			fovAngle = stats.targetingFov,
			damage = stats.damage,
			abilityId = ICESHARD_ID,
		})

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

		local aimPoint = targetingResult.aimPoint or (position + baseDirection * stats.targetingRange)
		local targetDistance = (aimPoint - position).Magnitude
		local targetPoint: Vector3
		if targetDistance > 0 then
			targetPoint = position + direction * targetDistance
		else
			targetPoint = position + direction * (stats.projectileSpeed * stats.duration)
		end

		local projectileEntity = AbilitySystemBase.createProjectile(
			ICESHARD_ID,
			stats,
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

	return created > 0
end

-- Cast IceShard ability (handles initial cast and multi-shot setup)
local function castIceShard(playerEntity: number, player: Player): boolean
	-- Get upgraded stats
	local stats = AbilitySystemBase.getAbilityStats(playerEntity, ICESHARD_ID, Balance)
	
	-- Start prediction tracking for smart multi-targeting
	TargetingService.startCastPrediction(playerEntity, ICESHARD_ID)
	
	local success = performIceShardBurst(playerEntity, player)

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
				-- Handle multi-shot pulse
				local pulseComponent = world:get(entity, AbilityPulse)
				if pulseComponent and pulseComponent.ability == ICESHARD_ID then
					local stats = AbilitySystemBase.getAbilityStats(entity, ICESHARD_ID, Balance)
					local interval = (pulseComponent.interval or stats.pulseInterval or 0)
					local timer = 0
					local remaining = pulseComponent.remaining or 0

					if interval <= 0 then
						-- Fire all remaining shots immediately
						while remaining > 0 do
							if performIceShardBurst(entity, player) then
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
							if performIceShardBurst(entity, player) then
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
				local stats = AbilitySystemBase.getAbilityStats(entity, ICESHARD_ID, Balance)
				
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
