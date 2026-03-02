--!strict

local PlayerBalance = require(script.Parent.PlayerBalance)
local CombatScaling = require(script.Parent.CombatScaling)

local RegenMath = {}

local INITIAL_NO_HEAL_DURATION = 1.0

local function safeNumber(value: any, fallback: number): number
	if typeof(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return fallback
end

function RegenMath.getEffectiveRegenDelay(passiveEffects: any, balance: any?): number
	local cfg = balance or PlayerBalance
	return math.max(0, safeNumber(cfg.HealthRegenDelay, 0))
end

function RegenMath.getRegenRampMultiplier(timeSinceDamage: number, regenDelay: number): number
	local elapsed = safeNumber(timeSinceDamage, 0)
	local delay = math.max(0, safeNumber(regenDelay, 0))

	if elapsed < INITIAL_NO_HEAL_DURATION then
		return 0
	end
	if delay <= INITIAL_NO_HEAL_DURATION then
		return 1
	end
	if elapsed >= delay then
		return 1
	end

	local scalingDuration = delay - INITIAL_NO_HEAL_DURATION
	local scalingElapsed = elapsed - INITIAL_NO_HEAL_DURATION
	if scalingDuration <= 0 then
		return 1
	end

	return math.clamp(scalingElapsed / scalingDuration, 0, 1)
end

function RegenMath.getRegenerationCoilFlatBonus(
	stacks: number,
	timeSinceDamage: number,
	basePerStack: number,
	outOfCombatPerStack: number,
	outOfCombatDelay: number
): number
	local safeStacks = math.max(0, math.floor(safeNumber(stacks, 0) + 0.0001))
	if safeStacks <= 0 then
		return 0
	end

	local elapsed = safeNumber(timeSinceDamage, 0)
	local inCombatBonus = math.max(0, safeNumber(basePerStack, 0))
	local outOfCombatBonus = math.max(0, safeNumber(outOfCombatPerStack, 0))
	local delay = math.max(0, safeNumber(outOfCombatDelay, 0))
	local perStack = if elapsed >= delay then outOfCombatBonus else inCombatBonus
	return perStack * safeStacks
end

function RegenMath.getCurrentRegenPerSecond(
	level: number,
	passiveEffects: any,
	timeSinceDamage: number,
	options: any?
): number
	local balance = if typeof(options) == "table" and options.playerBalance ~= nil then options.playerBalance else PlayerBalance
	local safeLevel = math.max(1, math.floor(safeNumber(level, 1)))
	local elapsed = safeNumber(timeSinceDamage, 0)
	local regenDelay = RegenMath.getEffectiveRegenDelay(passiveEffects, balance)
	local rampMultiplier = RegenMath.getRegenRampMultiplier(elapsed, regenDelay)
	if rampMultiplier <= 0 then
		return 0
	end

	local regenMult = 1.0
	local regenFlat = 0
	if typeof(passiveEffects) == "table" then
		regenMult = math.max(0, safeNumber(passiveEffects.regenMultiplier, 1.0))
		regenFlat = safeNumber(passiveEffects.regenFlatBonus, 0)
	end

	local coilStacks = 0
	local coilBasePerStack = 0
	local coilOutOfCombatPerStack = 0
	local coilOutOfCombatDelay = 0
	if typeof(options) == "table" then
		coilStacks = safeNumber(options.coilStacks, 0)
		coilBasePerStack = safeNumber(options.coilBasePerStack, 0)
		coilOutOfCombatPerStack = safeNumber(options.coilOutOfCombatPerStack, 0)
		coilOutOfCombatDelay = safeNumber(options.coilOutOfCombatDelay, 0)
	end

	local baseRegen = CombatScaling.getBaseRegenAtLevel(safeLevel, balance)
	local coilBonus = RegenMath.getRegenerationCoilFlatBonus(
		coilStacks,
		elapsed,
		coilBasePerStack,
		coilOutOfCombatPerStack,
		coilOutOfCombatDelay
	)
	local fullRegenPerSecond = (baseRegen * regenMult) + regenFlat + coilBonus
	if fullRegenPerSecond <= 0 then
		return 0
	end

	return fullRegenPerSecond * rampMultiplier
end

return RegenMath
