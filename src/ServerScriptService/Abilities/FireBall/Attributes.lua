--!strict
-- FireBall Attribute Definitions
-- Powerful transformations available at levels 15/30/45/60
-- Only available when FireBall is at maximum upgrade level

return {
	FireStorm = {
		id = "FireStorm",
		name = "Fire Storm",
		desc = "Fireballs orbit around you, exploding on contact",
		color = Color3.fromRGB(0, 100, 255), -- Blue
		stats = {
			scale = "55%",  -- 35% projectile size
			cooldown = "+5%",  
			damage = "67%",  -- Reduce damage by 33%
			explosionDamage = "33%",  -- 33% explosion damage
			explosionScale = "45%",  -- NEW: 35% explosion size (matches projectile)
			projectileCount = "50%",  -- Half projectile count
		},
		special = {
			orbitRadius = 50,  -- Base orbit radius in studs
			orbitRadiusVariance = 20,  -- +/- variance for random orbit radius
			orbitSpeed = 20,  -- Degrees per second
		},
	},
	
	TheBigOne = {
		id = "TheBigOne",
		name = "The Big One",
		desc = "Combines all fireballs into one massive projectile",
		color = Color3.fromRGB(200, 50, 0), -- Dark orange/reddish
		stats = {
			-- Dynamic scaling (size, duration, penetration) handled in System.lua
			cooldown = "*2",
		},
	},
	
	CannonFire = {
		id = "CannonFire",
		name = "Cannon Fire",
		desc = "Smaller, faster fireballs with double damage",
		color = Color3.fromRGB(150, 150, 150), -- Grey
		stats = {
			scale = "33.33%",  -- 1/3 size
			projectileSpeed = "*3",
			damage = "*2",
			explosionDamage = "*2",
			targetingMode = 2,
			projectileCount = "+2",  -- Add 2 more projectiles
			shotAmount = "+2",  -- Add shotgun spread
			pulseInterval = 0.25,  -- 0.25s between bursts
			cooldown = "*2.5",  -- 2.5x cooldown
		},
	},
}

