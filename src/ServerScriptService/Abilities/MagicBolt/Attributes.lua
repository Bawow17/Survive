--!strict
-- Magic Bolt Attributes
-- Powerful transformations available at levels 15/30/45/60
-- Only available when Magic Bolt is at maximum upgrade level

return {
	ChainCasting = {
		id = "ChainCasting",
		name = "Chain Casting",
		desc = "Higher attack speed, more projectiles",
		color = Color3.fromRGB(255, 255, 0),  -- Yellow
		stats = {
			projectileCount = "+3",  -- Add 3 more projectiles
			cooldown = "-20%",       -- 20% faster cooldown
			pulseInterval = 0.11,    -- Set to 0.11s for continuous firing
		},
	},
	
	FireAtWill = {
		id = "FireAtWill",
		name = "Fire at Will",
		desc = "Massive projectile count, random targeting, more damage",
		color = Color3.fromRGB(255, 0, 0),  -- Red
		stats = {
			projectileCount = "*7",  -- Multiply projectile count by 7
			damage = "+30%",         -- 30% more damage
			targetingMode = 1,       -- Change to random X/Z, track Y
			pulseInterval = 0.02,    -- Very fast firing (0.02s between shots)
			cooldown = "*2.5",       -- Multiply cooldown by 2.5x
		},
	},
	
	Afterimages = {
		id = "Afterimages",
		name = "Afterimages",
		desc = "Summon clones that shoot for you, homing projectiles",
		color = Color3.fromHSV(0.800189, 0.709677, 0.972549),  -- Purple
		stats = {
			cooldown = "*2.5",       -- Multiply cooldown by 2.5x (balanced for 3 clones)
			targetingMode = 3,       -- Homing projectiles
		},
		special = {
			replacesPlayer = true,          -- Player doesn't shoot, clones do
			cloneCount = 3,                  -- Spawn 3 clones
			cloneTransparency = 0.5,         -- 50% transparent clones
			cloneTriangleSideLength = 30,    -- 30-stud equilateral triangle
		},
	},
}

