--!strict
-- PlayerPressureSystem - Computes player power + pressure for adaptive enemy scaling

local EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)
local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)

local PlayerPressureSystem = {}

local world: any
local Components: any
local DirtyService: any

local PlayerStats: any
local Level: any
local PlayerPower: any
local AbilityData: any
local PassiveEffects: any

local playerQuery: any

local updateAccumulator = 0

local function normalizeCritChance(rawChance: number?): number
	if typeof(rawChance) ~= "number" then
		return 0
	end
	local critChance = rawChance
	if critChance > 1 then
		if critChance <= 100 then
			critChance = critChance / 100
		else
			critChance = 1
		end
	end
	return math.clamp(critChance, 0, 1)
end

function PlayerPressureSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService

	PlayerStats = Components.PlayerStats
	Level = Components.Level
	PlayerPower = Components.PlayerPower
	AbilityData = Components.AbilityData
	PassiveEffects = Components.PassiveEffects

	playerQuery = world:query(PlayerStats, Level):cached()
end

local function computeGeneralDeltas(effects: any): {[string]: number}
	local damageMult = effects and effects.damageMultiplier or 1.0
	local cooldownMult = effects and effects.cooldownMultiplier or 1.0
	local cooldownRate = if cooldownMult > 0 then 1 / cooldownMult else 1.0

	local critChance = normalizeCritChance(effects and effects.critChance or 0)
	local critDamage = effects and effects.critDamage or 0
	local critExpected = 1 + (critChance * (1 + critDamage))

	local projectileCountBonus = effects and effects.projectileCountBonus or 0
	local projectileCountMult = 1 + projectileCountBonus

	local penetrationBonus = effects and effects.penetrationBonus or 0
	local penetrationMult = (effects and effects.penetrationMultiplier or 1.0) * (1 + penetrationBonus)
	local sizeMult = effects and effects.sizeMultiplier or 1.0
	local durationMult = effects and effects.durationMultiplier or 1.0

	local baseHealth = PlayerBalance.BaseMaxHealth or 100
	local healthMult = effects and effects.healthMultiplier or 1.0
	local healthFlat = effects and effects.healthFlatBonus or 0
	local healthEffective = if baseHealth > 0 then (baseHealth * healthMult + healthFlat) / baseHealth else healthMult
	local armorReduction = effects and effects.armorReduction or 0
	local armorMult = 1 + armorReduction
	local baseRegen = PlayerBalance.HealthRegenRate or 0
	local regenMult = effects and effects.regenMultiplier or 1.0
	local regenFlat = effects and effects.regenFlatBonus or 0
	local regenRate = baseRegen * regenMult + regenFlat
	local regenEffective = if baseRegen > 0 then (regenRate / baseRegen) else regenRate
	local lifesteal = effects and effects.lifesteal or 0
	local lifestealMult = 1 + lifesteal

	local moveSpeedMult = effects and effects.moveSpeedMultiplier or 1.0
	-- Use base mobility distance (excludes temporary speed buffs)
	local mobilityBase = effects and (effects.mobilityDistanceBase or effects.mobilityDistanceMultiplier) or 1.0

	return {
		Damage = damageMult - 1,
		Cooldown = cooldownRate - 1,
		Crit = critExpected - 1,
		ProjectileCount = projectileCountMult - 1,
		Penetration = penetrationMult - 1,
		Size = sizeMult - 1,
		Duration = durationMult - 1,
		Health = healthEffective - 1,
		Armor = armorMult - 1,
		Regen = regenEffective - 1,
		Lifesteal = lifestealMult - 1,
		MoveSpeed = moveSpeedMult - 1,
		MobilityDistance = mobilityBase - 1,
	}
end

local function safeRatio(value: number?, baseValue: number?): number
	if typeof(value) ~= "number" or typeof(baseValue) ~= "number" or baseValue <= 0 then
		return 1.0
	end
	return value / baseValue
end

local function computeAbilityDeltas(abilityData: any): {[string]: number}
	if not abilityData or not abilityData.abilities then
		return {}
	end

	local total = {
		Damage = 0,
		Cooldown = 0,
		ProjectileCount = 0,
		ShotAmount = 0,
		Penetration = 0,
		Size = 0,
		Duration = 0,
	}

	local abilityCount = 0
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

			total.Damage += (damageMult - 1)
			total.Cooldown += (cooldownRate - 1)
			total.ProjectileCount += (projectileCountMult - 1)
			total.ShotAmount += (shotAmountMult - 1)
			total.Penetration += (penetrationMult - 1)
			total.Size += (sizeMult - 1)
			total.Duration += (durationMult - 1)
			abilityCount += 1
		end
	end

	if abilityCount > 0 then
		for key, value in pairs(total) do
			total[key] = value / abilityCount
		end
	end

	return total
end

local function applyWeights(delta: {[string]: number}, weights: {[string]: number}?): number
	if not weights then
		return 0
	end
	local sum = 0
	for key, weight in pairs(weights) do
		sum += (delta[key] or 0) * weight
	end
	return sum
end

local function computePowerTargets(effects: any, abilityData: any): {[string]: number}
	local rawCfg = EnemyBalance.RawStatScaling
	if not rawCfg or not rawCfg.Enabled then
		return {}
	end

	local generalDelta = computeGeneralDeltas(effects)
	local abilityDelta = computeAbilityDeltas(abilityData)
	local abilityWeight = rawCfg.AbilityWeight or 0.45

	local general = rawCfg.General or {}
	local ability = rawCfg.Ability or {}

	local healthDelta = applyWeights(generalDelta, general.Health)
	local spawnDelta = applyWeights(generalDelta, general.Spawn)
	local damageDelta = applyWeights(generalDelta, general.Damage)
	local speedDelta = applyWeights(generalDelta, general.Speed)

	local abilityHealthDelta = applyWeights(abilityDelta, ability.Health)
	local abilitySpawnDelta = applyWeights(abilityDelta, ability.Spawn)

	local health = 1 + healthDelta + (abilityHealthDelta * abilityWeight)
	local spawn = 1 + spawnDelta + (abilitySpawnDelta * abilityWeight)
	local damage = 1 + damageDelta
	local speed = 1 + speedDelta

	return {
		health = math.max(1, health),
		spawn = math.max(1, spawn),
		damage = math.max(1, damage),
		speed = math.max(1, speed),
	}
end

function PlayerPressureSystem.step(dt: number)
	if not world then
		return
	end

	local pressureConfig = EnemyBalance.Pressure or {}
	local interval = pressureConfig.UpdateInterval or 0.5

	updateAccumulator += dt
	if updateAccumulator < interval then
		return
	end

	local stepDt = updateAccumulator
	updateAccumulator = 0

	local GameStateManager = require(game.ServerScriptService.ECS.Systems.GameStateManager)
	local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
	local now = GameTimeSystem.getGameTime()

	local tauEarly = pressureConfig.TauEarly
	local tauLate = pressureConfig.TauLate
	local tauRampMinutes = pressureConfig.TauRampMinutes or 0
	local tau = pressureConfig.Tau or 30
	if typeof(tauEarly) == "number" and typeof(tauLate) == "number" and tauRampMinutes > 0 then
		local minutes = now / 60
		local t = math.clamp(minutes / tauRampMinutes, 0, 1)
		tau = tauEarly + (tauLate - tauEarly) * t
	end
	tau = math.max(0.01, tau)
	local alpha = 1 - math.exp(-stepDt / tau)

	for entity, stats, levelComp in playerQuery do
		if not stats or not stats.player or not stats.player.Parent then
			continue
		end
		if not GameStateManager.isPlayerInGame(stats.player) then
			continue
		end

		local levelValue = (levelComp and levelComp.current) or stats.level or 1
		local abilityData = world:get(entity, AbilityData)
		local effects = world:get(entity, PassiveEffects)

		local powerTargets = computePowerTargets(effects, abilityData)
		local powerState = world:get(entity, PlayerPower)
		if not powerState then
			powerState = {
				power = powerTargets,
				pressure = powerTargets,
				lastUpdate = now,
			}
		else
			local currentPressure = powerState.pressure or powerTargets
			local newPressure = {
				health = (currentPressure.health or powerTargets.health) + (powerTargets.health - (currentPressure.health or powerTargets.health)) * alpha,
				damage = (currentPressure.damage or powerTargets.damage) + (powerTargets.damage - (currentPressure.damage or powerTargets.damage)) * alpha,
				speed = (currentPressure.speed or powerTargets.speed) + (powerTargets.speed - (currentPressure.speed or powerTargets.speed)) * alpha,
				spawn = (currentPressure.spawn or powerTargets.spawn) + (powerTargets.spawn - (currentPressure.spawn or powerTargets.spawn)) * alpha,
			}

			powerState.power = powerTargets
			powerState.pressure = newPressure
			powerState.lastUpdate = now
		end

		DirtyService.setIfChanged(world, entity, PlayerPower, powerState, "PlayerPower")
	end
end

return PlayerPressureSystem
