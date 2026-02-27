--!strict

local PlayerBalance = require(script.Parent.PlayerBalance)

local CombatScaling = {}

local function safeNumber(value: any, fallback: number): number
	if typeof(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return fallback
end

function CombatScaling.getLevelScalar(level: number, perLevel: number): number
	local safeLevel = math.max(1, math.floor(safeNumber(level, 1)))
	local safePerLevel = math.max(0, safeNumber(perLevel, 0))
	return 1 + (safePerLevel * math.max(safeLevel - 1, 0))
end

function CombatScaling.getBaseDamageAtLevel(level: number, balance: any?): number
	local cfg = balance or PlayerBalance
	local scaling = cfg.LevelScaling or {}
	local baseDamage = math.max(0, safeNumber(cfg.BaseDamage, 12))
	local scalar = CombatScaling.getLevelScalar(level, safeNumber(scaling.damagePerLevel, 0.20))
	return baseDamage * scalar
end

function CombatScaling.getBaseMaxHealthAtLevel(level: number, balance: any?): number
	local cfg = balance or PlayerBalance
	local scaling = cfg.LevelScaling or {}
	local baseHealth = math.max(1, safeNumber(cfg.BaseMaxHealth, 100))
	local scalar = CombatScaling.getLevelScalar(level, safeNumber(scaling.maxHealthPerLevel, 0.30))
	return baseHealth * scalar
end

function CombatScaling.getBaseRegenAtLevel(level: number, balance: any?): number
	local cfg = balance or PlayerBalance
	local scaling = cfg.LevelScaling or {}
	local baseRegen = math.max(0, safeNumber(cfg.HealthRegenRate, 1.0))
	local scalar = CombatScaling.getLevelScalar(level, safeNumber(scaling.regenPerLevel, 0.20))
	return baseRegen * scalar
end

return CombatScaling
