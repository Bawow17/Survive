--!strict
-- Refractions System - Handles auto-casting Refractions laser ability for players

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilitySystemBase = require(script.Parent.Parent.AbilitySystemBase)
local TargetingService = require(script.Parent.Parent.TargetingService)
local SpatialGridSystem = require(game.ServerScriptService.ECS.Systems.SpatialGridSystem)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
local ModelHitboxHelper = require(game.ServerScriptService.Utilities.ModelHitboxHelper)
local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local Config = require(script.Parent.Config)
local Balance = Config

local AbilityCastRemote = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("AbilityCast")

local RefractionsSystem = {}

local world: any
local Components: any
local DirtyService: any
local ECSWorldService: any

-- Component references
local Position: any
local EntityType: any
local AbilityData: any
local AbilityCooldown: any
local Health: any
local SpawnTime: any
local DeathAnimation: any

local REFRACTIONS_ID = "Refractions"
local REFRACTIONS_NAME = Balance.Name

local playerQuery: any

local GRID_SIZE = SpatialGridSystem.getGridSize()
local DEFAULT_MIN_TARGETABLE_AGE = 0.6

local function gatherEnemyCandidates(center: Vector3, maxRange: number): {number}
	local radiusCells = math.max(1, math.ceil(maxRange / GRID_SIZE))
	local candidates = SpatialGridSystem.getNeighboringEntities(center, radiusCells)
	if #candidates == 0 then
		candidates = SpatialGridSystem.getNeighboringEntities(center, radiusCells + 1)
	end
	return candidates
end

local function pickRandomTarget(origin: Vector3, maxRange: number, minAge: number): (number?, Vector3?)
	local candidates = gatherEnemyCandidates(origin, maxRange)
	if #candidates == 0 then
		return nil, nil
	end

	local gameTime = GameTimeSystem.getGameTime()
	local valid: {number} = {}
	local aimById: {[number]: Vector3} = {}

	for _, enemyId in ipairs(candidates) do
		local entityType = world:get(enemyId, EntityType)
		if entityType and entityType.type == "Enemy" then
			local health = world:get(enemyId, Health)
			if not health or health.current <= 0 then
				continue
			end
			if world:has(enemyId, DeathAnimation) then
				continue
			end
			local spawnTime = world:get(enemyId, SpawnTime)
			if spawnTime and (gameTime - (spawnTime.time or 0)) < minAge then
				continue
			end
			local aimPoint = TargetingService.getEnemyAimPoint(enemyId)
			if aimPoint and (aimPoint - origin).Magnitude <= maxRange then
				valid[#valid + 1] = enemyId
				aimById[enemyId] = aimPoint
			end
		end
	end

	if #valid == 0 then
		return nil, nil
	end

	local pick = valid[math.random(1, #valid)]
	return pick, aimById[pick]
end

local function computeDirection(origin: Vector3, aimPoint: Vector3?, stats: any, player: Player?): Vector3
	if aimPoint then
		local dir = aimPoint - origin
		if stats.StayHorizontal or stats.AlwaysStayHorizontal then
			dir = Vector3.new(dir.X, 0, dir.Z)
		end
		if dir.Magnitude == 0 then
			return Vector3.new(0, 0, 1)
		end
		return dir.Unit
	end

	-- Fallback: random horizontal direction
	local angle = math.random() * math.pi * 2
	local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
	if dir.Magnitude == 0 then
		return Vector3.new(0, 0, 1)
	end
	return dir.Unit
end

local function getBeamSize(stats: any, fallbackLength: number): (Vector3, Vector3, CFrame?, string)
	local scale = stats.scale or 1
	local hitboxSize, hitboxOffset, hitboxRotation = ModelHitboxHelper.getModelHitboxTransform(Balance.modelPath)
	if not hitboxSize and typeof(Balance.modelPath) == "string" then
		local serverPath = Balance.modelPath:gsub("^ReplicatedStorage%.", "ServerStorage.")
		if serverPath ~= Balance.modelPath then
			hitboxSize, hitboxOffset, hitboxRotation = ModelHitboxHelper.getModelHitboxTransform(serverPath)
		end
	end

	if hitboxSize then
		local size = Vector3.new(hitboxSize.X * scale, hitboxSize.Y * scale, hitboxSize.Z * scale)
		local offset = (hitboxOffset or Vector3.new(0, 0, 0)) * scale
		local axis = "Z"
		if size.X >= size.Y and size.X >= size.Z then
			axis = "X"
		elseif size.Y >= size.X and size.Y >= size.Z then
			axis = "Y"
		end
		return size, offset, hitboxRotation, axis
	end

	return Vector3.new(2 * scale, 2 * scale, fallbackLength), Vector3.new(0, 0, 0), nil, "Z"
end


local function castRefractions(playerEntity: number, player: Player): boolean
	local position = AbilitySystemBase.getPlayerPosition(playerEntity, player)
	if not position then
		return false
	end

	local stats = AbilitySystemBase.getAbilityStats(playerEntity, REFRACTIONS_ID, Balance)
	ModelReplicationService.replicateAbility(REFRACTIONS_ID)
	stats.targetingMode = 0
	local shotAmount = math.max(stats.shotAmount or 1, 1)
	local projectileCount = math.max(stats.projectileCount or 1, 1)
	local laserCount = math.max(1, math.floor(shotAmount + projectileCount - 1 + 0.0001))
	local maxRange = stats.targetingRange or 1000
	local minAge = stats.minTargetableAge or DEFAULT_MIN_TARGETABLE_AGE
	local beamSize, beamOffset, beamRotation, beamAxis = getBeamSize(stats, maxRange)
	local beamLength = beamSize.Z > 0 and beamSize.Z or maxRange
	if beamAxis == "X" then
		beamLength = beamSize.X > 0 and beamSize.X or beamLength
	elseif beamAxis == "Y" then
		beamLength = beamSize.Y > 0 and beamSize.Y or beamLength
	end
	local effectiveRange = math.min(maxRange, beamLength)
	local beamRadius = math.max(beamSize.X, beamSize.Y) * 0.5

	local created = 0
	for _ = 1, laserCount do
		local aimPoint: Vector3? = nil
		if stats.targetingMode ~= 0 then
			_, aimPoint = pickRandomTarget(position, effectiveRange, minAge)
		end
		local direction = computeDirection(position, aimPoint, stats, player)
		local targetPoint = aimPoint or (position + direction * effectiveRange)

		local projectileEntity = AbilitySystemBase.createProjectile(
			REFRACTIONS_ID,
			stats,
			position,
			direction,
			player,
			targetPoint,
			playerEntity,
			{
				beam = {
					length = beamLength,
					size = beamSize,
					offset = beamOffset,
					rotation = beamRotation,
					lengthAxis = beamAxis,
				},
				radius = beamRadius,
			}
		)
		if projectileEntity then
			created += 1
		end
	end

	return created > 0
end

function RefractionsSystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService

	AbilitySystemBase.init(worldRef, components, dirtyService, ecsWorldService)

	Position = Components.Position
	EntityType = Components.EntityType
	AbilityData = Components.AbilityData
	AbilityCooldown = Components.AbilityCooldown
	Health = Components.Health
	SpawnTime = Components.SpawnTime
	DeathAnimation = Components.DeathAnimation

	playerQuery = world:query(Components.EntityType, Components.Position, Components.Ability):cached()
end

function RefractionsSystem.step(dt: number)
	if not world then
		return
	end

	for entity, entityType, position, ability in playerQuery do
		if entityType.type == "Player" and entityType.player then
			local player = entityType.player

			if not AbilitySystemBase.isPlayerAlive(player) then
				continue
			end

			local cooldownsFrozen = player:GetAttribute("CooldownsFrozen")
			if cooldownsFrozen then
				continue
			end

			local abilityData = world:get(entity, AbilityData)
			if abilityData and abilityData.abilities and abilityData.abilities[REFRACTIONS_ID]
				and abilityData.abilities[REFRACTIONS_ID].enabled then

				local stats = AbilitySystemBase.getAbilityStats(entity, REFRACTIONS_ID, Balance)
				local cooldownData = world:get(entity, AbilityCooldown)
				local cooldowns = cooldownData and cooldownData.cooldowns or {}
				local cooldown = cooldowns[REFRACTIONS_ID] or { remaining = 0, max = stats.cooldown }

				if cooldown.remaining <= 0 then
					local success = castRefractions(entity, player)
					if success then
						local shotAmount = math.max(stats.shotAmount or 1, 1)
						local projectileCount = math.max(stats.projectileCount or 1, 1)
						local laserCount = math.max(1, math.floor(shotAmount + projectileCount - 1 + 0.0001))
						AbilityCastRemote:FireClient(player, REFRACTIONS_ID, stats.cooldown, REFRACTIONS_NAME, {
							projectileCount = laserCount,
							pulseInterval = 0,
						})

						cooldowns[REFRACTIONS_ID] = {
							remaining = stats.cooldown,
							max = stats.cooldown,
						}
						DirtyService.setIfChanged(world, entity, AbilityCooldown, {
							cooldowns = cooldowns
						}, "AbilityCooldown")
					end
				else
					cooldowns[REFRACTIONS_ID] = {
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

return RefractionsSystem
