--!strict
-- EnemyFrostSystem - Handles Lesser Frost, Greater Frost, and shared enemy freeze.

local CombatScaling = require(game.ReplicatedStorage.Shared.CombatScaling)

local EnemyFrostSystem = {}

local world: any
local Components: any
local DirtyService: any
local DamageSystemRef: any

local EntityType: any
local Health: any
local Level: any
local EnemyLesserFrost: any
local EnemyGreaterFrost: any
local EnemyFreeze: any
local DeathAnimation: any

local lesserFrostQuery: any
local greaterFrostQuery: any
local freezeQuery: any
local greaterFrostSourceByEntity: {[number]: number} = {}

local LESSER_FROST_DURATION = 7.0
local LESSER_FROST_FREEZE_DURATION = 4.0
local GREATER_FROST_DURATION = 10.0
local GREATER_FROST_BURST_DELAY = 7.0
local GREATER_FROST_FREEZE_DURATION = 10.0
local BASE_EXECUTE_THRESHOLD = 0.25
local MAX_EXECUTE_THRESHOLD = 0.75
local LESSER_FROST_EXTRA_STACK_DAMAGE_MULT = 2.0
local GREATER_FROST_BURST_DAMAGE_MULT = 20.0

local function isEnemyEntity(enemyEntity: number): boolean
	if not world or not enemyEntity or not EntityType then
		return false
	end
	local entityType = world:get(enemyEntity, EntityType)
	return entityType and entityType.type == "Enemy" or false
end

local function removeStatusComponent(enemyEntity: number, component: any, dirtyName: string)
	if not world or not component or not enemyEntity or not world:contains(enemyEntity) then
		return
	end
	if world:has(enemyEntity, component) then
		world:remove(enemyEntity, component)
		if component == EnemyGreaterFrost then
			greaterFrostSourceByEntity[enemyEntity] = nil
		end
		if DirtyService and DirtyService.mark then
			DirtyService.mark(enemyEntity, dirtyName)
		end
	end
end

local function getSourceBaseDamage(sourceEntity: number?): number?
	if not world or not sourceEntity or not Level then
		return nil
	end
	if not world:contains(sourceEntity) then
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

local function getActiveFreezeData(enemyEntity: number, now: number): any?
	if not EnemyFreeze then
		return nil
	end
	local freezeData = world:get(enemyEntity, EnemyFreeze)
	if freezeData and typeof(freezeData) == "table" then
		if (tonumber(freezeData.endTime) or 0) > now then
			return freezeData
		end
		removeStatusComponent(enemyEntity, EnemyFreeze, "EnemyFreeze")
	end
	return nil
end

local function refreshCombinedExecuteThreshold(enemyEntity: number)
	if DamageSystemRef and DamageSystemRef.refreshEnemyExecuteThreshold then
		DamageSystemRef.refreshEnemyExecuteThreshold(enemyEntity)
	end
end

local function getGreaterFrostExecuteThresholdForStacks(stacks: number): number
	local normalizedStacks = math.max(math.floor(stacks or 0), 0)
	if normalizedStacks <= 0 then
		return 0
	end
	return math.min(BASE_EXECUTE_THRESHOLD + (0.15 * math.max(normalizedStacks - 1, 0)), MAX_EXECUTE_THRESHOLD)
end

local function refreshFreezeExecuteContribution(enemyEntity: number, nowOverride: number?)
	if not world or not EnemyFreeze or not enemyEntity or not world:contains(enemyEntity) then
		return
	end

	local now = nowOverride or tick()
	local freezeData = world:get(enemyEntity, EnemyFreeze)
	if not (freezeData and typeof(freezeData) == "table") then
		refreshCombinedExecuteThreshold(enemyEntity)
		return
	end
	if (tonumber(freezeData.endTime) or 0) <= now then
		refreshCombinedExecuteThreshold(enemyEntity)
		return
	end

	local executeThreshold = 0
	if EnemyGreaterFrost then
		local greaterFrost = world:get(enemyEntity, EnemyGreaterFrost)
		if greaterFrost and typeof(greaterFrost) == "table" and (tonumber(greaterFrost.endTime) or 0) > now then
			executeThreshold = getGreaterFrostExecuteThresholdForStacks(tonumber(greaterFrost.stacks) or 0)
		end
	end

	local updated = table.clone(freezeData)
	updated.executeThreshold = executeThreshold
	DirtyService.setIfChanged(world, enemyEntity, EnemyFreeze, updated, "EnemyFreeze")
	refreshCombinedExecuteThreshold(enemyEntity)
end

local function refreshFreeze(
	enemyEntity: number,
	source: string,
	duration: number,
	executeThreshold: number,
	pauseDuringTimeStop: boolean
)
	if not world or not EnemyFreeze then
		return
	end

	local now = tick()
	local existing = getActiveFreezeData(enemyEntity, now)
	local newEndTime = now + math.max(duration, 0)
	local mergedThreshold = math.clamp(executeThreshold or 0, 0, MAX_EXECUTE_THRESHOLD)
	local pauseFlag = pauseDuringTimeStop == true
	local freezeSource = source

	if existing then
		newEndTime = math.max(tonumber(existing.endTime) or 0, newEndTime)
		mergedThreshold = math.max(tonumber(existing.executeThreshold) or 0, mergedThreshold)
		if existing.pauseDuringTimeStop == false then
			pauseFlag = false
		end
		if freezeSource ~= "GreaterFrost" and existing.source == "GreaterFrost" then
			freezeSource = existing.source
		end
	end

	DirtyService.setIfChanged(world, enemyEntity, EnemyFreeze, {
		source = freezeSource,
		startTime = existing and (tonumber(existing.startTime) or now) or now,
		endTime = newEndTime,
		executeThreshold = math.min(mergedThreshold, MAX_EXECUTE_THRESHOLD),
		pauseDuringTimeStop = pauseFlag,
	}, "EnemyFreeze")
end

local function tryExecuteFrozenEnemy(enemyEntity: number, sourceEntity: number?): boolean
	if not DamageSystemRef or not DamageSystemRef.tryExecuteEnemyByThreshold then
		return false
	end
	return DamageSystemRef.tryExecuteEnemyByThreshold(enemyEntity, sourceEntity, "EnemyFreezeExecute")
end

local function applyFrostDamage(enemyEntity: number, amount: number, sourceEntity: number?, abilityId: string)
	if not DamageSystemRef or amount <= 0 then
		return
	end
	local _, applied = DamageSystemRef.applyDamage(
		enemyEntity,
		amount,
		"magic",
		sourceEntity,
		abilityId,
		{
			skipTemporalStasis = true,
			skipExecuteCheck = true,
		}
	)
	return applied
end

local function applyLesserFrostBonusDamage(enemyEntity: number, sourceEntity: number?, bonusHits: number)
	if bonusHits <= 0 then
		return
	end
	local baseDamage = getSourceBaseDamage(sourceEntity)
	if not baseDamage or baseDamage <= 0 then
		return
	end
	for _ = 1, bonusHits do
		if not world or not world:contains(enemyEntity) then
			break
		end
		local health = world:get(enemyEntity, Health)
		if not health or not health.current or health.current <= 0 then
			break
		end
		applyFrostDamage(enemyEntity, baseDamage * LESSER_FROST_EXTRA_STACK_DAMAGE_MULT, sourceEntity, "LesserFrost")
	end
end

local function applyGreaterFrostBurst(enemyEntity: number, sourceEntity: number?)
	local baseDamage = getSourceBaseDamage(sourceEntity)
	if not baseDamage or baseDamage <= 0 then
		return
	end
	applyFrostDamage(enemyEntity, baseDamage * GREATER_FROST_BURST_DAMAGE_MULT, sourceEntity, "GreaterFrost")
end

function EnemyFrostSystem.init(worldRef: any, components: any, dirtyService: any, services: any?)
	world = worldRef
	Components = components
	DirtyService = dirtyService

	EntityType = Components.EntityType
	Health = Components.Health
	Level = Components.Level
	EnemyLesserFrost = Components.EnemyLesserFrost
	EnemyGreaterFrost = Components.EnemyGreaterFrost
	EnemyFreeze = Components.EnemyFreeze
	DeathAnimation = Components.DeathAnimation

	DamageSystemRef = services and services.DamageSystem or DamageSystemRef

	lesserFrostQuery = world:query(EnemyLesserFrost, Health):cached()
	greaterFrostQuery = world:query(EnemyGreaterFrost, Health):cached()
	freezeQuery = world:query(EnemyFreeze, Health):cached()
end

function EnemyFrostSystem.setDamageSystem(damageSystem: any)
	DamageSystemRef = damageSystem
end

function EnemyFrostSystem.isEnemyFrozen(enemyEntity: number, nowOverride: number?): boolean
	if not world or not enemyEntity or not EnemyFreeze then
		return false
	end
	local now = nowOverride or tick()
	return getActiveFreezeData(enemyEntity, now) ~= nil
end

function EnemyFrostSystem.getFrostMovementMultiplier(enemyEntity: number, nowOverride: number?): number
	if not world or not enemyEntity or not EnemyLesserFrost then
		return 1.0
	end
	local now = nowOverride or tick()
	if EnemyFrostSystem.isEnemyFrozen(enemyEntity, now) then
		return 0.0
	end

	local lesserFrost = world:get(enemyEntity, EnemyLesserFrost)
	if lesserFrost and typeof(lesserFrost) == "table" then
		if (tonumber(lesserFrost.endTime) or 0) <= now then
			removeStatusComponent(enemyEntity, EnemyLesserFrost, "EnemyLesserFrost")
			return 1.0
		end

		local stacks = math.max(0, math.floor(tonumber(lesserFrost.stacks) or 0))
		if stacks >= 2 then
			return 0.4
		end
		if stacks >= 1 then
			return 0.7
		end
	end

	return 1.0
end

function EnemyFrostSystem.applyLesserFrost(
	enemyEntity: number,
	sourceEntity: number?,
	stacksToAdd: number,
	duration: number?
): boolean
	if not world or not EnemyLesserFrost or not isEnemyEntity(enemyEntity) then
		return false
	end
	local currentHealth = world:get(enemyEntity, Health)
	if not currentHealth or not currentHealth.current or currentHealth.current <= 0 then
		return false
	end

	local addStacks = math.max(math.floor((stacksToAdd or 0) + 0.0001), 0)
	if addStacks <= 0 then
		return false
	end

	local now = tick()
	local applyDuration = math.max(duration or LESSER_FROST_DURATION, 0)
	local existing = world:get(enemyEntity, EnemyLesserFrost)
	local existingStacks = 0
	local existingActive = false
	if existing and typeof(existing) == "table" then
		existingActive = (tonumber(existing.endTime) or 0) > now
		if existingActive then
			existingStacks = math.max(math.floor(tonumber(existing.stacks) or 0), 0)
		end
	end

	local nextStacks = existingStacks + addStacks
	if nextStacks <= 0 then
		return false
	end

	DirtyService.setIfChanged(world, enemyEntity, EnemyLesserFrost, {
		statusId = "LesserFrost",
		stacks = nextStacks,
		startTime = existingActive and (tonumber(existing.startTime) or now) or now,
		endTime = now + applyDuration,
	}, "EnemyLesserFrost")

	local bonusHits = math.max(nextStacks - 1, 0) - math.max(existingStacks - 1, 0)
	applyLesserFrostBonusDamage(enemyEntity, sourceEntity, bonusHits)

	local healthAfterBonus = world:get(enemyEntity, Health)
	if nextStacks >= 3 and healthAfterBonus and healthAfterBonus.current and healthAfterBonus.current > 0 then
		refreshFreeze(enemyEntity, "LesserFrost", LESSER_FROST_FREEZE_DURATION, 0, true)
		refreshFreezeExecuteContribution(enemyEntity, now)
	end
	return true
end

function EnemyFrostSystem.applyGreaterFrost(
	enemyEntity: number,
	sourceEntity: number?,
	stacksToAdd: number,
	duration: number?
): boolean
	if not world or not EnemyGreaterFrost or not isEnemyEntity(enemyEntity) then
		return false
	end
	local currentHealth = world:get(enemyEntity, Health)
	if not currentHealth or not currentHealth.current or currentHealth.current <= 0 then
		return false
	end

	local addStacks = math.max(math.floor((stacksToAdd or 0) + 0.0001), 0)
	if addStacks <= 0 then
		return false
	end

	local now = tick()
	local applyDuration = math.max(duration or GREATER_FROST_DURATION, 0)
	local existing = world:get(enemyEntity, EnemyGreaterFrost)
	local existingStacks = 0
	local existingActive = false
	if existing and typeof(existing) == "table" then
		existingActive = (tonumber(existing.endTime) or 0) > now
		if existingActive then
			existingStacks = math.max(math.floor(tonumber(existing.stacks) or 0), 0)
		end
	end

	local nextStacks = existingStacks + addStacks
	if nextStacks <= 0 then
		return false
	end

	local executeThreshold = getGreaterFrostExecuteThresholdForStacks(nextStacks)

	DirtyService.setIfChanged(world, enemyEntity, EnemyGreaterFrost, {
		statusId = "GreaterFrost",
		stacks = nextStacks,
		startTime = existingActive and (tonumber(existing.startTime) or now) or now,
		endTime = now + applyDuration,
		burstAt = now + GREATER_FROST_BURST_DELAY,
		executeThreshold = executeThreshold,
	}, "EnemyGreaterFrost")
	if sourceEntity and world:contains(sourceEntity) then
		greaterFrostSourceByEntity[enemyEntity] = sourceEntity
	end

	refreshFreeze(enemyEntity, "GreaterFrost", GREATER_FROST_FREEZE_DURATION, executeThreshold, false)
	refreshFreezeExecuteContribution(enemyEntity, now)

	if existingActive then
		applyGreaterFrostBurst(enemyEntity, sourceEntity or greaterFrostSourceByEntity[enemyEntity])
	end
	return true
end

function EnemyFrostSystem.onEnemyDamaged(enemyEntity: number, sourceEntity: number?)
	return tryExecuteFrozenEnemy(enemyEntity, sourceEntity)
end

function EnemyFrostSystem.step(_dt: number)
	if not world then
		return
	end

	local now = tick()

	for enemyEntity in pairs(greaterFrostSourceByEntity) do
		if not world:contains(enemyEntity) or not (EnemyGreaterFrost and world:has(enemyEntity, EnemyGreaterFrost)) then
			greaterFrostSourceByEntity[enemyEntity] = nil
		end
	end

	if lesserFrostQuery then
		for enemyEntity, lesserFrost, health in lesserFrostQuery do
			if not health or not health.current or health.current <= 0 then
				removeStatusComponent(enemyEntity, EnemyLesserFrost, "EnemyLesserFrost")
			elseif (tonumber(lesserFrost.endTime) or 0) <= now then
				removeStatusComponent(enemyEntity, EnemyLesserFrost, "EnemyLesserFrost")
			end
		end
	end

	if greaterFrostQuery then
		for enemyEntity, greaterFrost, health in greaterFrostQuery do
			if not health or not health.current or health.current <= 0 then
				removeStatusComponent(enemyEntity, EnemyGreaterFrost, "EnemyGreaterFrost")
				refreshFreezeExecuteContribution(enemyEntity, now)
			else
				local endTime = tonumber(greaterFrost.endTime) or 0
				if endTime <= now then
					removeStatusComponent(enemyEntity, EnemyGreaterFrost, "EnemyGreaterFrost")
					refreshFreezeExecuteContribution(enemyEntity, now)
				else
					local burstAt = tonumber(greaterFrost.burstAt)
					if burstAt and burstAt <= now then
						applyGreaterFrostBurst(enemyEntity, greaterFrostSourceByEntity[enemyEntity])
						local updated = table.clone(greaterFrost)
						updated.burstAt = nil
						DirtyService.setIfChanged(world, enemyEntity, EnemyGreaterFrost, updated, "EnemyGreaterFrost")
					end
				end
			end
		end
	end

	if freezeQuery then
		for enemyEntity, freezeData, health in freezeQuery do
			if not health or not health.current or health.current <= 0 then
				removeStatusComponent(enemyEntity, EnemyFreeze, "EnemyFreeze")
				refreshCombinedExecuteThreshold(enemyEntity)
			elseif (tonumber(freezeData.endTime) or 0) <= now then
				removeStatusComponent(enemyEntity, EnemyFreeze, "EnemyFreeze")
				refreshCombinedExecuteThreshold(enemyEntity)
			end
		end
	end
end

return EnemyFrostSystem
