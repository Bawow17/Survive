--!strict
-- IceShard Attribute Definitions
-- Powerful transformations available at levels 10/20/30/40/50
-- Only available when IceShard is at maximum upgrade level

return {
	FrozenPetals = {
		id = "FrozenPetals",
		name = "Frozen Petals",
		desc = "Replace your ice shards with small frozen petals which chase down enemies and repel nearby enemies.",
		color = Color3.fromRGB(255, 105, 180),
		special = {
			petalCount = 2,
			petalMaxRange = 100,
			petalSpeedMultiplier = 1.3,
			petalHitCooldown = 0.2,
			petalDamageMultiplier = 2.0,
			petalRadiusMultiplier = 2.0,
			petalHomingStrength = 1440, -- very fast turning
			petalHomingMaxAngle = 360,
			petalLifetime = 999999,
			repelInterval = 3.0,
			repelDamage = 100,
			repelKnockbackDistance = 10,
		},
	},

	ImpalingFrost = {
		id = "ImpalingFrost",
		name = "Impaling Frost",
		desc = "Ice shard projectiles impale enemies slowing them for the duration.",
		color = Color3.fromRGB(170, 80, 255),
		special = {
			slowDuration = 5.0,
			slowMultiplier = 0.6,
			impaleModelPath = "ReplicatedStorage.ContentDrawer.Attacks.Abilties.IceShard.IceShard",
		},
	},

	CrystalShards = {
		id = "CrystalShards",
		name = "Crystal Shards",
		desc = "Enhances ice shards with extreme speed, shattering and multiplying with each enemy hit.",
		color = Color3.fromRGB(0, 180, 180),
		special = {
			splitDamageMultiplier = 0.7,
			splitScaleMultiplier = 0.5,
			maxSpreadDegrees = 180,
		},
	},
}
