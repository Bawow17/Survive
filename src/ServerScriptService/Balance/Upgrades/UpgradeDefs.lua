--!strict
-- UpgradeDefs - Centralized config for the new rarity-based upgrade system

local UpgradeDefs = {}

UpgradeDefs.Rarities = {
	Common = {
		id = "Common",
		weight = 0.5625, -- remainder after rare/epic/legendary at base luck
		budget = 0.08,
		powerWeight = 1.0,
		scale = 0.35,
		color = Color3.fromRGB(235, 235, 235),
		minStats = 1,
		maxStats = 1,
	},
	Rare = {
		id = "Rare",
		weight = 0.40,
		budget = 0.125,
		powerWeight = 1.35,
		scale = 0.55,
		color = Color3.fromRGB(110, 170, 255),
		minStats = 1,
		maxStats = 2,
	},
	Epic = {
		id = "Epic",
		weight = 0.035, -- base epic chance at 100% luck
		budget = 0.275,
		powerWeight = 1.8,
		scale = 0.8,
		color = Color3.fromRGB(200, 120, 255),
		minStats = 2,
		maxStats = 3,
	},
	Legendary = {
		id = "Legendary",
		weight = 0.0025, -- base legendary chance at 100% luck
		budget = 0.45,
		powerWeight = 2.5,
		scale = 1.0,
		color = Color3.fromRGB(255, 190, 80),
		minStats = 3,
		maxStats = 3,
	},
}

UpgradeDefs.Luck = {
	maxEpicMultiplier = math.huge,
	maxLegendaryMultiplier = math.huge,
}

UpgradeDefs.RarityScales = {
	Common = 0.35,
	Rare = 0.55,
	Epic = 0.8,
	Legendary = 1.0,
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
		baseValue = 0.30,
		max = 0.30,
		weight = 1.0,
		effect = "increase",
		kind = "percent",
	},
	projectileSpeed = {
		id = "projectileSpeed",
		display = "Projectile Speed",
		field = "projectileSpeed",
		baseValue = 0.20,
		max = 0.20,
		weight = 1.0,
		effect = "increase",
		kind = "percent",
	},
	cooldownReduction = {
		id = "cooldownReduction",
		display = "Cooldown Reduction",
		field = "cooldown",
		baseValue = 0.15,
		max = 0.15,
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
		rarityValues = {
			Epic = 1,
			Legendary = 2,
		},
		minRarity = "Epic",
		kind = "count",
	},
	abilitySize = {
		id = "abilitySize",
		display = "Ability Size",
		field = "scale",
		baseValue = 0.40,
		max = 0.40,
		weight = 0.8,
		effect = "increase",
		kind = "percent",
	},
	abilityDuration = {
		id = "abilityDuration",
		display = "Ability Duration",
		field = "duration",
		baseValue = 0.40,
		max = 0.40,
		weight = 0.8,
		effect = "increase",
		kind = "percent",
	},
}

UpgradeDefs.PassiveStats = {
	damage = {
		id = "damage",
		display = "Damage",
		field = "damageMultiplier",
		baseValue = 0.20,
		max = 0.20,
		weight = 1.0,
		effect = "increase",
	},
	critChance = {
		id = "critChance",
		display = "Crit Chance",
		field = "critChance",
		baseValue = 0.06,
		max = 0.06,
		weight = 1.2,
		effect = "increase",
	},
	critDamage = {
		id = "critDamage",
		display = "Crit Damage",
		field = "critDamage",
		baseValue = 0.25,
		max = 0.25,
		weight = 1.0,
		effect = "increase",
	},
	projectileCount = {
		id = "projectileCount",
		display = "Projectile Count",
		field = "projectileCount",
		weight = 0.4,
		rarityValues = {
			Epic = 1,
			Legendary = 2,
		},
		minRarity = "Epic",
		kind = "count",
	},
	healthFlat = {
		id = "healthFlat",
		display = "Max Health",
		field = "healthFlatBonus",
		baseValue = 150,
		max = 150,
		weight = 1.0,
		effect = "increase",
		kind = "flat",
		hidden = true, -- rolled via combined Health upgrade
	},
	armor = {
		id = "armor",
		display = "Armor",
		field = "armorReduction",
		baseValue = 0.15,
		max = 0.15,
		weight = 1.2,
		effect = "increase",
		softCap = 0.35,
		hidden = true, -- rolled via combined Health upgrade
	},
	healthArmor = {
		id = "healthArmor",
		display = "Health",
		kind = "paired",
		subStats = {"healthFlat", "armor"},
		weight = 1.0,
	},
	lifesteal = {
		id = "lifesteal",
		display = "Lifesteal",
		field = "lifesteal",
		baseValue = 0.10,
		max = 0.10,
		weight = 1.0,
		effect = "increase",
		hidden = true, -- rolled via Vampiric upgrade
	},
	regenFlat = {
		id = "regenFlat",
		display = "Regen",
		field = "regenFlatBonus",
		baseValue = 25,
		min = 0,
		max = 25,
		weight = 1.0,
		effect = "increase",
		kind = "flat",
		delayMin = 0.01,
		delayMax = 0.08,
		hidden = true, -- rolled via Vampiric upgrade
	},
	vampiric = {
		id = "vampiric",
		display = "Vampiric",
		kind = "paired",
		subStats = {"lifesteal", "regenFlat"},
		weight = 0.2, -- 5x rarer than other passives
		minRarity = "Epic",
	},
	abilitySize = {
		id = "abilitySize",
		display = "Ability Size",
		field = "sizeMultiplier",
		baseValue = 0.30,
		max = 0.30,
		weight = 1.0,
		effect = "increase",
	},
	cooldownReduction = {
		id = "cooldownReduction",
		display = "Cooldown Reduction",
		field = "cooldownMultiplier",
		baseValue = 0.12,
		max = 0.12,
		weight = 1.2,
		effect = "reduce",
		softCap = UpgradeDefs.SoftCaps.dangerousCap,
	},
	abilityDuration = {
		id = "abilityDuration",
		display = "Ability Duration",
		field = "durationMultiplier",
		baseValue = 0.30,
		max = 0.30,
		weight = 1.0,
		effect = "increase",
	},
	penetration = {
		id = "penetration",
		display = "Penetration",
		field = "penetrationBonus",
		weight = 1.1,
		rarityValues = {
			Epic = 1,
			Legendary = 2,
		},
		minRarity = "Epic",
		kind = "count",
	},
	moveSpeed = {
		id = "moveSpeed",
		display = "Movement Speed",
		field = "moveSpeedMultiplier",
		baseValue = 0.15,
		max = 0.15,
		weight = 1.0,
		effect = "increase",
	},
	mobilityCooldown = {
		id = "mobilityCooldown",
		display = "Movement Cooldowns",
		field = "mobilityCooldownMultiplier",
		baseValue = 0.20,
		max = 0.20,
		weight = 1.2,
		effect = "reduce",
		softCap = UpgradeDefs.SoftCaps.dangerousCap,
	},
	dashDistance = {
		id = "dashDistance",
		display = "Movement Power",
		field = "mobilityDistanceMultiplier",
		baseValue = 0.15,
		max = 0.15,
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
		baseValue = 0.75,
		max = 0.75,
		weight = 1.0,
		effect = "increase",
	},
	expGain = {
		id = "expGain",
		display = "Exp Gain",
		field = "expMultiplier",
		baseValue = 0.95,
		max = 0.95,
		weight = 1.0,
		effect = "increase",
	},
	pickupRange = {
		id = "pickupRange",
		display = "Pickup Range",
		field = "pickupRangeMultiplier",
		baseValue = 0.40,
		max = 0.40,
		weight = 1.0,
		effect = "increase",
		hidden = true, -- driven by Exp Gain upgrade
	},
}

return UpgradeDefs
