--!strict
-- MagicBolt System - Handles auto-casting Magic Bolt ability for players
-- Manages targeting, cooldowns, and projectile spawning

local _Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AbilitySystemBase = require(script.Parent.Parent.AbilitySystemBase)
local Config = require(script.Parent.Config)
local Balance = Config  -- For backward compatibility

local AbilityCastRemote = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("AbilityCast")

local MagicBoltSystem = {}

local world: any
local Components: any
local DirtyService: any
local _ECSWorldService: any

-- Component references
local Position: any
local _EntityType: any
local AbilityData: any
local AbilityCooldown: any
local AbilityPulse: any
local AttributeSelections: any
local AfterimageClones: any

-- Magic Bolt constants
local MAGIC_BOLT_ID = "MagicBolt"
local MAGIC_BOLT_NAME = Balance.Name

local playerQuery: any

-- Spawn a burst of Magic Bolt projectiles (handles shotgun spread)
local function spawnMagicBoltBurst(
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
			MAGIC_BOLT_ID,
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

-- Perform a Magic Bolt burst from a given position (shared by player and clones)
-- This ensures IDENTICAL targeting logic for both
local function performMagicBoltBurstFromPosition(playerEntity: number, player: Player, position: Vector3, stats: any): boolean
	-- Find target using smart targeting if mode 2, otherwise nearest
	local targetEntity: number?
	if stats.targetingMode == 2 then
		targetEntity = AbilitySystemBase.findBestTarget(playerEntity, position, stats.targetingRange, stats.damage)
		-- Record predicted damage for this burst
		if targetEntity then
			AbilitySystemBase.recordPredictedDamage(playerEntity, targetEntity, stats.damage)
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
			targetPosition = position + Vector3.new(Balance.targetingRange, 0, 0)
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
		targetEntity
	)

	local created = spawnMagicBoltBurst(playerEntity, player, position, baseDirection, targetPosition, targetDistance, stats)
	return created > 0
end

-- Perform a Magic Bolt burst (finds target and spawns projectiles)
local function performMagicBoltBurst(playerEntity: number, player: Player): boolean
	-- Get player position (prefers character position)
	local position = AbilitySystemBase.getPlayerPosition(playerEntity, player)
	if not position then
		return false
	end
	
	-- Get upgraded stats for this player (includes ability upgrades + passive effects)
	local stats = AbilitySystemBase.getAbilityStats(playerEntity, MAGIC_BOLT_ID, Balance)
	
	-- Use shared targeting and spawning logic
	return performMagicBoltBurstFromPosition(playerEntity, player, position, stats)
end

-- Handle clone shooting for Afterimages attribute
local function handleAfterimageCloneShooting(playerEntity: number, player: Player, clonesData: any, dt: number)
	if not clonesData or not clonesData.clones then
		return
	end
	
	-- Get player's full ability stats (includes: base + upgrades + passives + attribute modifiers)
	-- Clones inherit ALL of the player's stats: damage, projectileCount, cooldown, targetingMode, etc.
	local stats = AbilitySystemBase.getAbilityStats(playerEntity, MAGIC_BOLT_ID, Balance)
	
	-- Each clone shoots independently with its own pulse tracking
	for _, cloneInfo in ipairs(clonesData.clones) do
		if world:contains(cloneInfo.entity) then
			-- Handle multi-shot pulse for this clone (EXACT same logic as player)
			if cloneInfo.pulseRemaining and cloneInfo.pulseRemaining > 0 then
				local interval = cloneInfo.pulseInterval or stats.pulseInterval or 0.08
				local timer = cloneInfo.pulseTimer or interval
				
				-- Update timer (same as player pulse system)
				timer = timer - dt
				
				-- Fire bursts when timer expires (can fire multiple per frame if dt is large)
				while cloneInfo.pulseRemaining > 0 and timer <= 0 do
					-- Get current clone position
					local clonePos = world:get(cloneInfo.entity, Position)
					if clonePos then
						local clonePosVec = Vector3.new(clonePos.x, clonePos.y, clonePos.z)
						-- Re-target for EACH projectile (same as player)
						if performMagicBoltBurstFromPosition(playerEntity, player, clonePosVec, stats) then
							cloneInfo.pulseRemaining = cloneInfo.pulseRemaining - 1
							timer = timer + interval
						else
							cloneInfo.pulseRemaining = 0
						end
					else
						cloneInfo.pulseRemaining = 0
					end
				end
				
				-- Update pulse timer
				cloneInfo.pulseTimer = timer
				
				-- End prediction when pulse completes
				if cloneInfo.pulseRemaining <= 0 then
					cloneInfo.pulseTimer = nil
					cloneInfo.pulseInterval = nil
					cloneInfo.pulsePredictionActive = false
					AbilitySystemBase.endCastPrediction(playerEntity)
				end
			end
			
			-- Update cooldown
			cloneInfo.cooldown = math.max((cloneInfo.cooldown or 0) - dt, 0)
			
			-- Check if ready to start a new cast (cooldown ready and no pulse active)
			if cloneInfo.cooldown <= 0 and not (cloneInfo.pulseRemaining and cloneInfo.pulseRemaining > 0) then
				-- Get clone position
				local clonePos = world:get(cloneInfo.entity, Position)
				if clonePos then
					local clonePosVec = Vector3.new(clonePos.x, clonePos.y, clonePos.z)
					
					-- Start prediction tracking for this cast (same as player)
					AbilitySystemBase.startCastPrediction(playerEntity)
					cloneInfo.pulsePredictionActive = true
					
					-- Spawn first burst immediately
					local firstCreated = performMagicBoltBurstFromPosition(playerEntity, player, clonePosVec, stats)
					
					if firstCreated then
						-- Reset cooldown
						cloneInfo.cooldown = stats.cooldown
						cloneInfo.lastShot = tick()
						
						-- Setup pulse for remaining projectiles (same as player)
						local projectileCount = stats.projectileCount or 1
						if projectileCount > 1 then
							cloneInfo.pulseRemaining = projectileCount - 1
							cloneInfo.pulseTimer = stats.pulseInterval or 0.08
							cloneInfo.pulseInterval = stats.pulseInterval or 0.08
						else
							-- Single shot, end prediction immediately
							AbilitySystemBase.endCastPrediction(playerEntity)
							cloneInfo.pulsePredictionActive = false
						end
						
						-- Update clone facing direction
						local facingTargetEntity = stats.targetingMode == 2 
							and AbilitySystemBase.findBestTarget(playerEntity, clonePosVec, stats.targetingRange, stats.damage)
							or AbilitySystemBase.findNearestEnemy(clonePosVec, stats.targetingRange)
						
						if facingTargetEntity then
							local facingTargetPos = AbilitySystemBase.getEnemyCenterPosition(facingTargetEntity)
							if facingTargetPos then
								local facingDir = (facingTargetPos - clonePosVec).Unit
								world:set(cloneInfo.entity, Components.FacingDirection, {
									x = facingDir.X,
									y = facingDir.Y,
									z = facingDir.Z,
								})
								DirtyService.mark(cloneInfo.entity, "FacingDirection")
							end
						end
					end
				end
			end
		end
	end
	
	-- Update clones data
	DirtyService.setIfChanged(world, playerEntity, AfterimageClones, clonesData, "AfterimageClones")
end

-- Cast Magic Bolt ability (handles initial cast and multi-shot setup)
local function castMagicBolt(playerEntity: number, player: Player): boolean
	-- Get upgraded stats
	local stats = AbilitySystemBase.getAbilityStats(playerEntity, MAGIC_BOLT_ID, Balance)
	
	-- Start prediction tracking for smart multi-targeting
	AbilitySystemBase.startCastPrediction(playerEntity)
	
	-- Get animation anticipation delay from Config
	local anticipation = 0
	if Config.animations and Config.animations.anticipation then
		anticipation = Config.animations.anticipation
	end
	
	if stats.projectileCount > 1 then
		-- Multi-shot: Fire initial burst + set up pulse for remaining bursts
		local interval = math.max(stats.pulseInterval or 0, 0.01)
		
		if anticipation > 0 then
			-- Delay both initial burst AND pulse setup until after anticipation
			task.delay(anticipation, function()
				performMagicBoltBurst(playerEntity, player)
				
				-- Now set up pulse for remaining bursts (no anticipation added to timer)
				local pulseData = {
					ability = MAGIC_BOLT_ID,
					remaining = stats.projectileCount - 1,
					timer = interval,  -- Just interval, pulse starts fresh after initial burst
					interval = interval,
				}
				DirtyService.setIfChanged(world, playerEntity, AbilityPulse, pulseData, "AbilityPulse")
			end)
		else
			-- No anticipation: fire immediately and set up pulse
			performMagicBoltBurst(playerEntity, player)
			
			local pulseData = {
				ability = MAGIC_BOLT_ID,
				remaining = stats.projectileCount - 1,
				timer = interval,
				interval = interval,
			}
			DirtyService.setIfChanged(world, playerEntity, AbilityPulse, pulseData, "AbilityPulse")
		end
	else
		-- Single shot cast, end prediction after delay
		if anticipation > 0 then
			task.delay(anticipation, function()
				performMagicBoltBurst(playerEntity, player)
				AbilitySystemBase.endCastPrediction(playerEntity)
			end)
		else
			performMagicBoltBurst(playerEntity, player)
			AbilitySystemBase.endCastPrediction(playerEntity)
		end
	end

	return true  -- Cast initiated (actual spawn happens after delay)
end

-- Initialize the system
function MagicBoltSystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	_ECSWorldService = ecsWorldService

	-- Initialize base system with shared references
	AbilitySystemBase.init(worldRef, components, dirtyService, ecsWorldService)

	-- Get component references
	Position = Components.Position
	_EntityType = Components.EntityType
	AbilityData = Components.AbilityData
	AbilityCooldown = Components.AbilityCooldown
	AbilityPulse = Components.AbilityPulse
	AttributeSelections = Components.AttributeSelections
	AfterimageClones = Components.AfterimageClones

	playerQuery = world:query(Components.EntityType, Components.Position, Components.Ability):cached()
end

-- Step function (called every frame)
function MagicBoltSystem.step(dt: number)
	if not world then
		return
	end

	-- Query all players with Magic Bolt ability
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
			-- Check if player has Magic Bolt ability enabled
			if abilityData and abilityData.abilities and abilityData.abilities[MAGIC_BOLT_ID] 
				and abilityData.abilities[MAGIC_BOLT_ID].enabled then
				
				-- Check if player has Afterimages attribute selected for Magic Bolt
				local attributeSelections = world:get(entity, AttributeSelections)
				if attributeSelections and attributeSelections[MAGIC_BOLT_ID] == "Afterimages" then
					-- Handle clone-based shooting (clones shoot, not player)
					local clonesData = world:get(entity, AfterimageClones)
					if clonesData then
						-- Track when clone last shot to trigger player animation
						local lastCloneShot = clonesData.lastCloneShot or 0
						
						handleAfterimageCloneShooting(entity, player, clonesData, dt)
						
						-- Update UI cooldown based on the first clone's cooldown
						-- All clones shoot at the same time so we can show one shared cooldown
						if clonesData.clones and #clonesData.clones > 0 then
							local firstClone = clonesData.clones[1]
							local cooldownData = world:get(entity, AbilityCooldown)
							local cooldowns = cooldownData and cooldownData.cooldowns or {}
							
							-- Get stats for cooldown max value
							local cloneStats = AbilitySystemBase.getAbilityStats(entity, MAGIC_BOLT_ID, Balance)
							
							-- Update Magic Bolt cooldown for UI display
							cooldowns[MAGIC_BOLT_ID] = {
								remaining = math.max(firstClone.cooldown or 0, 0),
								max = cloneStats.cooldown,
							}
							DirtyService.setIfChanged(world, entity, AbilityCooldown, {
								cooldowns = cooldowns
							}, "AbilityCooldown")
							
							-- PLAYER ANIMATION: Trigger animation when clones shoot
							-- Check if clones just shot (cooldown was reset)
							local cloneJustShot = (firstClone.cooldown or 0) > (cloneStats.cooldown * 0.9)
							if cloneJustShot and lastCloneShot ~= firstClone.lastShot then
								-- Calculate animation loop count based on projectile count
								local burstCount = cloneStats.projectileCount or 1
								
								-- Get animation config from unified Config
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
								
								-- Get damage stats for animation priority
								local damageStats = world:get(entity, Components.AbilityDamageStats) or {}
								
								-- Notify client to play casting animation (even though clones shoot)
								AbilityCastRemote:FireClient(player, MAGIC_BOLT_ID, cloneStats.cooldown, MAGIC_BOLT_NAME, {
									projectileCount = burstCount,  -- Number of animation loops
									pulseInterval = cloneStats.pulseInterval or 0,
									damageStats = damageStats,
									animationData = animationData,
								})
								
								-- Update last shot time
								clonesData.lastCloneShot = firstClone.lastShot
								DirtyService.setIfChanged(world, entity, AfterimageClones, clonesData, "AfterimageClones")
							end
						end
					end
					continue  -- Skip normal player casting
				end
				
				-- Normal casting logic below
				-- Handle multi-shot pulse
				local pulseComponent = world:get(entity, AbilityPulse)
				if pulseComponent and pulseComponent.ability == MAGIC_BOLT_ID then
					local interval = (pulseComponent.interval or Balance.pulseInterval or 0)
					local timer = 0
					local remaining = pulseComponent.remaining or 0

					if interval <= 0 then
						-- Fire all remaining shots immediately
						while remaining > 0 do
							if performMagicBoltBurst(entity, player) then
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
							if performMagicBoltBurst(entity, player) then
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
							ability = MAGIC_BOLT_ID,
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
				local pulseActive = pulseComponent and pulseComponent.ability == MAGIC_BOLT_ID

				-- Handle cooldown for this ability
				-- Get upgraded stats for cooldown
				local stats = AbilitySystemBase.getAbilityStats(entity, MAGIC_BOLT_ID, Balance)
				
				local cooldownData = world:get(entity, AbilityCooldown)
				local cooldowns = cooldownData and cooldownData.cooldowns or {}
				local cooldown = cooldowns[MAGIC_BOLT_ID] or { remaining = 0, max = stats.cooldown }

			-- Cast ability when cooldown is ready and no pulse active
			if cooldown.remaining <= 0 and not pulseActive then
				local success = castMagicBolt(entity, player)
				if success then
					-- Get damage stats for animation priority
					local damageStats = world:get(entity, Components.AbilityDamageStats) or {}
					
					-- Calculate animation loop count (number of bursts, not total projectiles)
					-- 1 initial burst + (projectileCount - 1) pulse bursts if projectileCount > 1
					local burstCount = 1  -- Always at least 1 burst (initial cast)
					if stats.projectileCount > 1 then
						burstCount = stats.projectileCount  -- Total bursts = projectileCount
					end
					
					-- Get animation config from unified Config
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
					AbilityCastRemote:FireClient(player, MAGIC_BOLT_ID, stats.cooldown, MAGIC_BOLT_NAME, {
						projectileCount = burstCount,  -- Number of animation loops
						pulseInterval = stats.pulseInterval or 0,
						damageStats = damageStats,
						animationData = animationData,  -- Send all animation config from server
					})
					
					-- Update this ability's cooldown
					cooldowns[MAGIC_BOLT_ID] = {
						remaining = stats.cooldown,
						max = stats.cooldown,
					}
					DirtyService.setIfChanged(world, entity, AbilityCooldown, {
						cooldowns = cooldowns
					}, "AbilityCooldown")
				end
			else
					-- Update cooldown timer
					cooldowns[MAGIC_BOLT_ID] = {
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

	-- Update facing direction for Magic Bolt projectiles
end

return MagicBoltSystem
