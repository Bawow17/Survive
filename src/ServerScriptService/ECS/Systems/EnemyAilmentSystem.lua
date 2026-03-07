--!strict
-- EnemyAilmentSystem - Handles flame, poison, and bleed debuffs for enemies.

local CombatScaling = require(game.ReplicatedStorage.Shared.CombatScaling)

local EnemyAilmentSystem = {}

local world: any
local Components: any
local DirtyService: any
local DamageSystemRef: any

local EntityType: any
local Health: any
local Level: any
local EnemyTier: any
local DeathAnimation: any
local EnemyTimeStopped: any
local EnemyLesserFlame: any
local EnemyGreaterFlame: any
local EnemyLesserPoison: any
local EnemyGreaterPoison: any
local EnemyBleed: any

local lesserFlameQuery: any
local greaterFlameQuery: any
local lesserPoisonQuery: any
local greaterPoisonQuery: any
local bleedQuery: any

local LESSER_FLAME_DURATION = 5.0
local GREATER_FLAME_DURATION = 15.0
local LESSER_POISON_BASE_DURATION = 5.0
local GREATER_POISON_BASE_DURATION = 3.0
local BLEED_DURATION = 3.0

local LESSER_FLAME_DAMAGE_MULT = 1.75
local GREATER_FLAME_BASE_DAMAGE_MULT = 3.0
local GREATER_FLAME_SNAPSHOT_DAMAGE_MULT = 0.20
local LESSER_POISON_RATE = 0.025
local LESSER_POISON_BOSS_RATE = 0.0075
local GREATER_POISON_RATE = 0.05
local GREATER_POISON_BOSS_RATE = 0.03
local BLEED_DAMAGE_MULT = 2.5
local DOT_TICKS_PER_SECOND = 4
local DOT_TICK_INTERVAL = 1 / DOT_TICKS_PER_SECOND

local function isEnemyEntity(enemyEntity: number): boolean
	if not world or not enemyEntity or not EntityType or not world:contains(enemyEntity) then
		return false
	end
	local entityType = world:get(enemyEntity, EntityType)
	return entityType and entityType.type == "Enemy" or false
end

local function isBossEnemy(_enemyEntity: number): boolean
	return false
end

local function isEnemyAlive(enemyEntity: number): boolean
	if not isEnemyEntity(enemyEntity) then
		return false
	end
	if DeathAnimation and world:has(enemyEntity, DeathAnimation) then
		return false
	end
	local health = world:get(enemyEntity, Health)
	return health and typeof(health.current) == "number" and health.current > 0 or false
end

local function getClampedProcCoefficient(procCoefficient: number?): number
	if typeof(procCoefficient) ~= "number" then
		return 1
	end
	if procCoefficient ~= procCoefficient then
		return 1
	end
	if procCoefficient == math.huge or procCoefficient == -math.huge then
		return 1
	end
	return math.max(procCoefficient, 0)
end

local function getSourceBaseDamage(sourceEntity: number?): number?
	if not world or not sourceEntity or not Level or not world:contains(sourceEntity) then
		return nil
	end
	local sourceType = world:get(sourceEntity, EntityType)
	if not (sourceType and sourceType.type == "Player") then
		return nil
	end

	local levelValue = 1
	local levelComponent = world:get(sourceEntity, Level)
	if levelComponent and typeof(levelComponent.current) == "number" then
		levelValue = levelComponent.current
	end

	return CombatScaling.getBaseDamageAtLevel(levelValue)
end

local function shouldPauseTicks(enemyEntity: number): boolean
	if not EnemyTimeStopped then
		return false
	end
	local state = world:get(enemyEntity, EnemyTimeStopped)
	return state and state.active == true or false
end

local function touchExecuteThreshold(enemyEntity: number)
	if DamageSystemRef and DamageSystemRef.refreshEnemyExecuteThreshold then
		DamageSystemRef.refreshEnemyExecuteThreshold(enemyEntity)
	end
end

local function removeStatusComponent(enemyEntity: number, component: any, dirtyName: string, affectsExecute: boolean)
	if not world or not component or not enemyEntity or not world:contains(enemyEntity) then
		return
	end
	if world:has(enemyEntity, component) then
		world:remove(enemyEntity, component)
		if DirtyService and DirtyService.mark then
			DirtyService.mark(enemyEntity, dirtyName)
		end
		if affectsExecute then
			touchExecuteThreshold(enemyEntity)
		end
	end
end

local function applyTickDamage(enemyEntity: number, damageAmount: number, sourceEntity: number?, abilityId: string)
	if damageAmount <= 0 or not DamageSystemRef or not DamageSystemRef.applyDamage then
		return
	end
	DamageSystemRef.applyDamage(enemyEntity, damageAmount, "magic", sourceEntity, abilityId, {
		procCoefficient = 0,
		skipTemporalStasis = true,
	})
end

local function getInitialNextTickTime(existing: any, existingActive: boolean, now: number): number
	if existingActive and existing and typeof(existing.nextTickTime) == "number" and existing.nextTickTime > now then
		return existing.nextTickTime
	end
	return now + DOT_TICK_INTERVAL
end

local function getTickCountUntil(now: number, nextTickTime: number, endTime: number): (number, number)
	if nextTickTime > now or nextTickTime > endTime then
		return 0, nextTickTime
	end

	local tickCount = 0
	local cursor = nextTickTime
	while cursor <= now and cursor <= endTime do
		tickCount += 1
		cursor += DOT_TICK_INTERVAL
	end
	return tickCount, cursor
end

function EnemyAilmentSystem.init(worldRef: any, components: any, dirtyService: any, services: any?)
	world = worldRef
	Components = components
	DirtyService = dirtyService

	EntityType = Components.EntityType
	Health = Components.Health
	Level = Components.Level
	EnemyTier = Components.EnemyTier
	DeathAnimation = Components.DeathAnimation
	EnemyTimeStopped = Components.EnemyTimeStopped
	EnemyLesserFlame = Components.EnemyLesserFlame
	EnemyGreaterFlame = Components.EnemyGreaterFlame
	EnemyLesserPoison = Components.EnemyLesserPoison
	EnemyGreaterPoison = Components.EnemyGreaterPoison
	EnemyBleed = Components.EnemyBleed

	DamageSystemRef = services and services.DamageSystem or DamageSystemRef

	lesserFlameQuery = world:query(EnemyLesserFlame, Health):cached()
	greaterFlameQuery = world:query(EnemyGreaterFlame, Health):cached()
	lesserPoisonQuery = world:query(EnemyLesserPoison, Health):cached()
	greaterPoisonQuery = world:query(EnemyGreaterPoison, Health):cached()
	bleedQuery = world:query(EnemyBleed, Health):cached()
end

function EnemyAilmentSystem.setDamageSystem(damageSystem: any)
	DamageSystemRef = damageSystem
end

function EnemyAilmentSystem.applyLesserFlame(
	enemyEntity: number,
	sourceEntity: number?,
	stacksToAdd: number,
	procCoefficient: number?,
	duration: number?
): boolean
	if not world or not EnemyLesserFlame or not isEnemyAlive(enemyEntity) then
		return false
	end

	local addStacks = math.max(math.floor((stacksToAdd or 0) + 0.0001), 0)
	if addStacks <= 0 then
		return false
	end

	local baseDamage = getSourceBaseDamage(sourceEntity)
	if not baseDamage or baseDamage <= 0 then
		return false
	end

	local proc = getClampedProcCoefficient(procCoefficient)
	local now = tick()
	local existing = world:get(enemyEntity, EnemyLesserFlame)
	local existingStacks = 0
	local existingDps = 0
	local existingActive = false
	if existing and typeof(existing) == "table" and (tonumber(existing.endTime) or 0) > now then
		existingActive = true
		existingStacks = math.max(math.floor(tonumber(existing.stacks) or 0), 0)
		existingDps = math.max(tonumber(existing.damagePerSecond) or 0, 0)
	end

	local addedDps = baseDamage * LESSER_FLAME_DAMAGE_MULT * proc * addStacks
	local nextStacks = existingStacks + addStacks
	local applyDuration = math.max(duration or LESSER_FLAME_DURATION, 0)

	DirtyService.setIfChanged(world, enemyEntity, EnemyLesserFlame, {
		statusId = "LesserFlame",
		stacks = nextStacks,
		damagePerSecond = existingDps + addedDps,
		startTime = existingActive and (tonumber(existing.startTime) or now) or now,
		endTime = now + applyDuration,
		nextTickTime = getInitialNextTickTime(existing, existingActive, now),
		sourceEntity = sourceEntity,
	}, "EnemyLesserFlame")

	touchExecuteThreshold(enemyEntity)
	return true
end

function EnemyAilmentSystem.applyGreaterFlame(
	enemyEntity: number,
	sourceEntity: number?,
	stacksToAdd: number,
	appliedHitDamage: number,
	procCoefficient: number?,
	duration: number?
): boolean
	if not world or not EnemyGreaterFlame or not isEnemyAlive(enemyEntity) then
		return false
	end

	local addStacks = math.max(math.floor((stacksToAdd or 0) + 0.0001), 0)
	if addStacks <= 0 then
		return false
	end

	local baseDamage = getSourceBaseDamage(sourceEntity)
	if not baseDamage or baseDamage <= 0 then
		return false
	end

	local proc = getClampedProcCoefficient(procCoefficient)
	local now = tick()
	local existing = world:get(enemyEntity, EnemyGreaterFlame)
	local existingStacks = 0
	local existingBaseDps = 0
	local existingSnapshotDps = 0
	local existingActive = false
	if existing and typeof(existing) == "table" and (tonumber(existing.endTime) or 0) > now then
		existingActive = true
		existingStacks = math.max(math.floor(tonumber(existing.stacks) or 0), 0)
		existingBaseDps = math.max(tonumber(existing.baseDamagePerSecond) or 0, 0)
		existingSnapshotDps = math.max(tonumber(existing.snapshotDamagePerSecond) or 0, 0)
	end

	local nextStacks = existingStacks + addStacks
	local applyDuration = math.max(duration or GREATER_FLAME_DURATION, 0)
	local snapshotBase = math.max(tonumber(appliedHitDamage) or 0, 0)

	DirtyService.setIfChanged(world, enemyEntity, EnemyGreaterFlame, {
		statusId = "GreaterFlame",
		stacks = nextStacks,
		baseDamagePerSecond = existingBaseDps + (baseDamage * GREATER_FLAME_BASE_DAMAGE_MULT * proc * addStacks),
		snapshotDamagePerSecond = existingSnapshotDps + (snapshotBase * GREATER_FLAME_SNAPSHOT_DAMAGE_MULT * addStacks),
		startTime = existingActive and (tonumber(existing.startTime) or now) or now,
		endTime = now + applyDuration,
		nextTickTime = getInitialNextTickTime(existing, existingActive, now),
		sourceEntity = sourceEntity,
	}, "EnemyGreaterFlame")

	touchExecuteThreshold(enemyEntity)
	return true
end

function EnemyAilmentSystem.applyLesserPoison(
	enemyEntity: number,
	sourceEntity: number?,
	stacksToAdd: number,
	procCoefficient: number?,
	duration: number?
): boolean
	if not world or not EnemyLesserPoison or not isEnemyAlive(enemyEntity) then
		return false
	end

	local addStacks = math.max(math.floor((stacksToAdd or 0) + 0.0001), 0)
	if addStacks <= 0 then
		return false
	end

	local proc = getClampedProcCoefficient(procCoefficient)
	local now = tick()
	local existing = world:get(enemyEntity, EnemyLesserPoison)
	local existingStacks = 0
	local existingRate = 0
	local existingActive = false
	if existing and typeof(existing) == "table" and (tonumber(existing.endTime) or 0) > now then
		existingActive = true
		existingStacks = math.max(math.floor(tonumber(existing.stacks) or 0), 0)
		existingRate = math.max(tonumber(existing.maxHealthPercentPerSecond) or 0, 0)
	end

	local nextStacks = existingStacks + addStacks
	local perStackRate = if isBossEnemy(enemyEntity) then LESSER_POISON_BOSS_RATE else LESSER_POISON_RATE
	local baseDuration = math.max(duration or LESSER_POISON_BASE_DURATION, 0)

	DirtyService.setIfChanged(world, enemyEntity, EnemyLesserPoison, {
		statusId = "LesserPoison",
		stacks = nextStacks,
		maxHealthPercentPerSecond = existingRate + (perStackRate * proc * addStacks),
		startTime = existingActive and (tonumber(existing.startTime) or now) or now,
		endTime = now + baseDuration + math.max(nextStacks - 1, 0),
		nextTickTime = getInitialNextTickTime(existing, existingActive, now),
		sourceEntity = sourceEntity,
	}, "EnemyLesserPoison")

	return true
end

function EnemyAilmentSystem.applyGreaterPoison(
	enemyEntity: number,
	sourceEntity: number?,
	stacksToAdd: number,
	procCoefficient: number?,
	duration: number?
): boolean
	if not world or not EnemyGreaterPoison or not isEnemyAlive(enemyEntity) then
		return false
	end

	local addStacks = math.max(math.floor((stacksToAdd or 0) + 0.0001), 0)
	if addStacks <= 0 then
		return false
	end

	local proc = getClampedProcCoefficient(procCoefficient)
	local now = tick()
	local existing = world:get(enemyEntity, EnemyGreaterPoison)
	local existingStacks = 0
	local existingRate = 0
	local existingActive = false
	if existing and typeof(existing) == "table" and (tonumber(existing.endTime) or 0) > now then
		existingActive = true
		existingStacks = math.max(math.floor(tonumber(existing.stacks) or 0), 0)
		existingRate = math.max(tonumber(existing.maxHealthPercentPerSecond) or 0, 0)
	end

	local nextStacks = existingStacks + addStacks
	local perStackRate = if isBossEnemy(enemyEntity) then GREATER_POISON_BOSS_RATE else GREATER_POISON_RATE
	local baseDuration = math.max(duration or GREATER_POISON_BASE_DURATION, 0)

	DirtyService.setIfChanged(world, enemyEntity, EnemyGreaterPoison, {
		statusId = "GreaterPoison",
		stacks = nextStacks,
		maxHealthPercentPerSecond = existingRate + (perStackRate * proc * addStacks),
		startTime = existingActive and (tonumber(existing.startTime) or now) or now,
		endTime = now + baseDuration + math.max(nextStacks - 1, 0),
		nextTickTime = getInitialNextTickTime(existing, existingActive, now),
		sourceEntity = sourceEntity,
	}, "EnemyGreaterPoison")

	touchExecuteThreshold(enemyEntity)
	return true
end

function EnemyAilmentSystem.applyBleed(
	enemyEntity: number,
	sourceEntity: number?,
	stacksToAdd: number,
	procCoefficient: number?,
	duration: number?
): boolean
	if not world or not EnemyBleed or not isEnemyAlive(enemyEntity) then
		return false
	end

	local addStacks = math.max(math.floor((stacksToAdd or 0) + 0.0001), 0)
	if addStacks <= 0 then
		return false
	end

	local baseDamage = getSourceBaseDamage(sourceEntity)
	if not baseDamage or baseDamage <= 0 then
		return false
	end

	local proc = getClampedProcCoefficient(procCoefficient)
	local now = tick()
	local existing = world:get(enemyEntity, EnemyBleed)
	local existingStacks = 0
	local existingDps = 0
	local existingActive = false
	if existing and typeof(existing) == "table" and (tonumber(existing.endTime) or 0) > now then
		existingActive = true
		existingStacks = math.max(math.floor(tonumber(existing.stacks) or 0), 0)
		existingDps = math.max(tonumber(existing.damagePerSecond) or 0, 0)
	end

	local nextStacks = existingStacks + addStacks
	local applyDuration = math.max(duration or BLEED_DURATION, 0)

	DirtyService.setIfChanged(world, enemyEntity, EnemyBleed, {
		statusId = "Bleed",
		stacks = nextStacks,
		damagePerSecond = existingDps + (baseDamage * BLEED_DAMAGE_MULT * proc * addStacks),
		startTime = existingActive and (tonumber(existing.startTime) or now) or now,
		endTime = now + applyDuration,
		nextTickTime = getInitialNextTickTime(existing, existingActive, now),
		sourceEntity = sourceEntity,
	}, "EnemyBleed")

	return true
end

function EnemyAilmentSystem.step(dt: number)
	if not world or dt <= 0 then
		return
	end

	local now = tick()

	if lesserFlameQuery then
		for enemyEntity, lesserFlame, health in lesserFlameQuery do
			if not health or not health.current or health.current <= 0 or (DeathAnimation and world:has(enemyEntity, DeathAnimation)) then
				removeStatusComponent(enemyEntity, EnemyLesserFlame, "EnemyLesserFlame", true)
			elseif (tonumber(lesserFlame.endTime) or 0) <= now then
				removeStatusComponent(enemyEntity, EnemyLesserFlame, "EnemyLesserFlame", true)
			elseif not shouldPauseTicks(enemyEntity) then
				local tickCount, nextTickTime = getTickCountUntil(
					now,
					tonumber(lesserFlame.nextTickTime) or (now + DOT_TICK_INTERVAL),
					tonumber(lesserFlame.endTime) or 0
				)
				if tickCount > 0 then
					applyTickDamage(
						enemyEntity,
						math.max(tonumber(lesserFlame.damagePerSecond) or 0, 0) * DOT_TICK_INTERVAL * tickCount,
						lesserFlame.sourceEntity,
						lesserFlame.statusId or "LesserFlame"
					)
					local updated = table.clone(lesserFlame)
					updated.nextTickTime = nextTickTime
					DirtyService.setIfChanged(world, enemyEntity, EnemyLesserFlame, updated, "EnemyLesserFlame")
				end
			end
		end
	end

	if greaterFlameQuery then
		for enemyEntity, greaterFlame, health in greaterFlameQuery do
			if not health or not health.current or health.current <= 0 or (DeathAnimation and world:has(enemyEntity, DeathAnimation)) then
				removeStatusComponent(enemyEntity, EnemyGreaterFlame, "EnemyGreaterFlame", true)
			elseif (tonumber(greaterFlame.endTime) or 0) <= now then
				removeStatusComponent(enemyEntity, EnemyGreaterFlame, "EnemyGreaterFlame", true)
			elseif not shouldPauseTicks(enemyEntity) then
				local damagePerSecond = math.max(tonumber(greaterFlame.baseDamagePerSecond) or 0, 0)
					+ math.max(tonumber(greaterFlame.snapshotDamagePerSecond) or 0, 0)
				local tickCount, nextTickTime = getTickCountUntil(
					now,
					tonumber(greaterFlame.nextTickTime) or (now + DOT_TICK_INTERVAL),
					tonumber(greaterFlame.endTime) or 0
				)
				if tickCount > 0 then
					applyTickDamage(
						enemyEntity,
						damagePerSecond * DOT_TICK_INTERVAL * tickCount,
						greaterFlame.sourceEntity,
						greaterFlame.statusId or "GreaterFlame"
					)
					local updated = table.clone(greaterFlame)
					updated.nextTickTime = nextTickTime
					DirtyService.setIfChanged(world, enemyEntity, EnemyGreaterFlame, updated, "EnemyGreaterFlame")
				end
			end
		end
	end

	if lesserPoisonQuery then
		for enemyEntity, lesserPoison, health in lesserPoisonQuery do
			if not health or not health.current or health.current <= 0 or (DeathAnimation and world:has(enemyEntity, DeathAnimation)) then
				removeStatusComponent(enemyEntity, EnemyLesserPoison, "EnemyLesserPoison", false)
			elseif (tonumber(lesserPoison.endTime) or 0) <= now then
				removeStatusComponent(enemyEntity, EnemyLesserPoison, "EnemyLesserPoison", false)
			elseif not shouldPauseTicks(enemyEntity) and health.max and health.max > 0 then
				local tickCount, nextTickTime = getTickCountUntil(
					now,
					tonumber(lesserPoison.nextTickTime) or (now + DOT_TICK_INTERVAL),
					tonumber(lesserPoison.endTime) or 0
				)
				if tickCount > 0 then
					applyTickDamage(
						enemyEntity,
						health.max * math.max(tonumber(lesserPoison.maxHealthPercentPerSecond) or 0, 0) * DOT_TICK_INTERVAL * tickCount,
						lesserPoison.sourceEntity,
						lesserPoison.statusId or "LesserPoison"
					)
					local updated = table.clone(lesserPoison)
					updated.nextTickTime = nextTickTime
					DirtyService.setIfChanged(world, enemyEntity, EnemyLesserPoison, updated, "EnemyLesserPoison")
				end
			end
		end
	end

	if greaterPoisonQuery then
		for enemyEntity, greaterPoison, health in greaterPoisonQuery do
			if not health or not health.current or health.current <= 0 or (DeathAnimation and world:has(enemyEntity, DeathAnimation)) then
				removeStatusComponent(enemyEntity, EnemyGreaterPoison, "EnemyGreaterPoison", true)
			elseif (tonumber(greaterPoison.endTime) or 0) <= now then
				removeStatusComponent(enemyEntity, EnemyGreaterPoison, "EnemyGreaterPoison", true)
			elseif not shouldPauseTicks(enemyEntity) and health.max and health.max > 0 then
				local tickCount, nextTickTime = getTickCountUntil(
					now,
					tonumber(greaterPoison.nextTickTime) or (now + DOT_TICK_INTERVAL),
					tonumber(greaterPoison.endTime) or 0
				)
				if tickCount > 0 then
					applyTickDamage(
						enemyEntity,
						health.max * math.max(tonumber(greaterPoison.maxHealthPercentPerSecond) or 0, 0) * DOT_TICK_INTERVAL * tickCount,
						greaterPoison.sourceEntity,
						greaterPoison.statusId or "GreaterPoison"
					)
					local updated = table.clone(greaterPoison)
					updated.nextTickTime = nextTickTime
					DirtyService.setIfChanged(world, enemyEntity, EnemyGreaterPoison, updated, "EnemyGreaterPoison")
				end
			end
		end
	end

	if bleedQuery then
		for enemyEntity, bleed, health in bleedQuery do
			if not health or not health.current or health.current <= 0 or (DeathAnimation and world:has(enemyEntity, DeathAnimation)) then
				removeStatusComponent(enemyEntity, EnemyBleed, "EnemyBleed", false)
			elseif (tonumber(bleed.endTime) or 0) <= now then
				removeStatusComponent(enemyEntity, EnemyBleed, "EnemyBleed", false)
			elseif not shouldPauseTicks(enemyEntity) then
				local tickCount, nextTickTime = getTickCountUntil(
					now,
					tonumber(bleed.nextTickTime) or (now + DOT_TICK_INTERVAL),
					tonumber(bleed.endTime) or 0
				)
				if tickCount > 0 then
					applyTickDamage(
						enemyEntity,
						math.max(tonumber(bleed.damagePerSecond) or 0, 0) * DOT_TICK_INTERVAL * tickCount,
						bleed.sourceEntity,
						bleed.statusId or "Bleed"
					)
					local updated = table.clone(bleed)
					updated.nextTickTime = nextTickTime
					DirtyService.setIfChanged(world, enemyEntity, EnemyBleed, updated, "EnemyBleed")
				end
			end
		end
	end
end

return EnemyAilmentSystem
