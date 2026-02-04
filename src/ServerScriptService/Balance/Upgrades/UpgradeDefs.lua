--!strict
-- UpgradeDefs - Centralized config for the new rarity-based upgrade system

local UpgradeDefs = {}

UpgradeDefs.Rarities = {
	Common = {
		id = "Common",
		weight = 0.55,
		budget = 0.08,
		powerWeight = 1.0,
		color = Color3.fromRGB(235, 235, 235),
		minStats = 1,
		maxStats = 1,
		minRollT = 0.0,
	},
	Rare = {
		id = "Rare",
		weight = 0.30,
		budget = 0.125,
		powerWeight = 1.35,
		color = Color3.fromRGB(110, 170, 255),
		minStats = 1,
		maxStats = 2,
		minRollT = 0.1,
	},
	Epic = {
		id = "Epic",
		weight = 0.0683333, -- tuned for ~13.67% epic at base luck (epic mult = 2.0)
		budget = 0.275,
		powerWeight = 1.8,
		color = Color3.fromRGB(200, 120, 255),
		minStats = 2,
		maxStats = 3,
		minRollT = 0.2,
	},
	Legendary = {
		id = "Legendary",
		weight = 0.0066667, -- ~1 legendary per 75 cards at base luck (after luck scaling)
		budget = 0.45,
		powerWeight = 2.5,
		color = Color3.fromRGB(255, 190, 80),
		minStats = 3,
		maxStats = 3,
		minRollT = 0.3,
	},
}

UpgradeDefs.Luck = {
	minCommonWeight = 0.15,
	maxEpicMultiplier = 2.0,
	maxLegendaryMultiplier = 2.0,
}

-- Ability-only: how many stats can roll per upgrade by rarity.
-- Legendary must be an even 1/3 chance each (1, 2, or 3 stats).
UpgradeDefs.AbilityStatCountWeights = {
	Common = { [1] = 1.0, [2] = 0.0, [3] = 0.0 },
	Rare = { [1] = 0.75, [2] = 0.22, [3] = 0.03 },
	Epic = { [1] = 0.2, [2] = 0.6, [3] = 0.2 },
	Legendary = { [1] = 1.0, [2] = 1.0, [3] = 1.0 }, -- equal weight; handled specially in UpgradeSystem
}

UpgradeDefs.SoftCaps = {
	dangerousCap = 0.50,
	countMaxMultiplier = 5.0,
	curveK = 1.6,
	mobilityDistanceCap = 0.30,
	mobilityDistanceCurveK = 2.6,
}

UpgradeDefs.AbilityStats = {
	damage = {
		id = "damage",
		display = "Damage",
		field = "damage",
		min = 0.0625,
		max = 0.25,
		weight = 1.0,
		effect = "increase",
		kind = "percent",
	},
	projectileSpeed = {
		id = "projectileSpeed",
		display = "Projectile Speed",
		field = "projectileSpeed",
		min = 0.0425,
		max = 0.17,
		weight = 1.0,
		effect = "increase",
		kind = "percent",
	},
	cooldownReduction = {
		id = "cooldownReduction",
		display = "Cooldown Reduction",
		field = "cooldown",
		min = 0.0425,
		max = 0.17,
		weight = 1.2,
		effect = "reduce",
		kind = "percent",
		softCap = UpgradeDefs.SoftCaps.dangerousCap,
	},
	projectileCount = {
		id = "projectileCount",
		display = "Projectile Count",
		field = "projectileCount",
		weight = 0.6,
		increment = 0.5,
		legendaryIncrement = 1.7,
		kind = "count",
	},
}

UpgradeDefs.PassiveStats = {
	damage = {
		id = "damage",
		display = "Damage",
		field = "damageMultiplier",
		min = 0.0425,
		max = 0.17,
		weight = 1.0,
		effect = "increase",
	},
	critChance = {
		id = "critChance",
		display = "Crit Chance",
		field = "critChance",
		min = 0.025,
		max = 0.085,
		weight = 1.2,
		effect = "increase",
		hardCap = true,
		rarityMax = {
			Common = 0.04,
			Rare = 0.055,
			Epic = 0.07,
			Legendary = 0.085,
		},
		softCap = UpgradeDefs.SoftCaps.dangerousCap,
	},
	critDamage = {
		id = "critDamage",
		display = "Crit Damage",
		field = "critDamage",
		min = 0.075,
		max = 0.30,
		weight = 1.0,
		effect = "increase",
	},
	projectileCount = {
		id = "projectileCount",
		display = "Projectile Count",
		field = "projectileCount",
		weight = 0.4,
		increment = 0.3,
		legendaryIncrement = 1.0,
		kind = "count",
	},
	health = {
		id = "health",
		display = "Max Health",
		field = "healthMultiplier",
		min = 0.15,
		max = 0.60,
		weight = 1.0,
		effect = "increase",
		hidden = true, -- rolled via combined Health & Regen upgrade
	},
	regen = {
		id = "regen",
		display = "Regen",
		field = "regenMultiplier",
		min = 0.30,
		max = 1.20,
		weight = 1.0,
		effect = "increase",
		delayMin = 0.01, -- 1% faster regen delay per roll (min)
		delayMax = 0.08, -- 8% faster regen delay per roll (max)
		hidden = true, -- rolled via combined Health & Regen upgrade
	},
	healthRegen = {
		id = "healthRegen",
		display = "Health & Regen",
		kind = "paired",
		subStats = {"health", "regen", "armor"},
		weight = 1.0,
	},
	armor = {
		id = "armor",
		display = "Armor",
		field = "armorReduction",
		min = 0.02,
		max = 0.08,
		weight = 1.2,
		effect = "increase",
		softCap = 0.35,
		hidden = true, -- rolled via combined Health/Regen/Armor upgrade
	},
	lifesteal = {
		id = "lifesteal",
		display = "Lifesteal",
		field = "lifesteal",
		min = 0.0001,
		max = 0.0005,
		weight = 0.4,
		rollWeight = 1000,
		effect = "increase",
	},
	abilitySize = {
		id = "abilitySize",
		display = "Ability Size",
		field = "sizeMultiplier",
		min = 0.075,
		max = 0.30,
		weight = 1.0,
		effect = "increase",
	},
	cooldownReduction = {
		id = "cooldownReduction",
		display = "Cooldown Reduction",
		field = "cooldownMultiplier",
		min = 0.0425,
		max = 0.17,
		weight = 1.2,
		effect = "reduce",
		softCap = UpgradeDefs.SoftCaps.dangerousCap,
	},
	abilityDuration = {
		id = "abilityDuration",
		display = "Ability Duration",
		field = "durationMultiplier",
		min = 0.075,
		max = 0.30,
		weight = 1.0,
		effect = "increase",
	},
	penetration = {
		id = "penetration",
		display = "Penetration",
		field = "penetrationMultiplier",
		min = 0.125,
		max = 0.50,
		weight = 1.1,
		effect = "increase",
	},
	moveSpeed = {
		id = "moveSpeed",
		display = "Movement Speed",
		field = "moveSpeedMultiplier",
		min = 0.0425,
		max = 0.17,
		weight = 1.0,
		effect = "increase",
		softCap = UpgradeDefs.SoftCaps.dangerousCap,
	},
	mobilityCooldown = {
		id = "mobilityCooldown",
		display = "Movement Cooldowns",
		field = "mobilityCooldownMultiplier",
		min = 0.0425,
		max = 0.17,
		weight = 1.2,
		effect = "reduce",
		softCap = UpgradeDefs.SoftCaps.dangerousCap,
	},
	dashDistance = {
		id = "dashDistance",
		display = "Mobility Distance",
		field = "mobilityDistanceMultiplier",
		min = 0.03,
		max = 0.09,
		weight = 1.0,
		effect = "increase",
		softCap = UpgradeDefs.SoftCaps.mobilityDistanceCap,
		curveK = UpgradeDefs.SoftCaps.mobilityDistanceCurveK,
		hardCap = true,
	},
	luck = {
		id = "luck",
		display = "Luck",
		field = "luck",
		min = 0.075,
		max = 0.30,
		weight = 1.0,
		effect = "increase",
		softCap = UpgradeDefs.SoftCaps.dangerousCap,
	},
	expGain = {
		id = "expGain",
		display = "Exp Gain",
		field = "expMultiplier",
		min = 0.125,
		max = 0.50,
		weight = 1.0,
		effect = "increase",
	},
	pickupRange = {
		id = "pickupRange",
		display = "Pickup Range",
		field = "pickupRangeMultiplier",
		min = 0.125,
		max = 0.50,
		weight = 1.0,
		effect = "increase",
		hidden = true, -- driven by Exp Gain upgrade
	},
}

return UpgradeDefs
