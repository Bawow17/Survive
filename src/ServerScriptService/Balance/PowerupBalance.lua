--!strict
-- PowerupBalance - Configuration for powerup items

return {
	-- Powerup Types
	PowerupTypes = {
		Nuke = {
			modelPath = "ServerStorage.ContentDrawer.ItemModels.Powerups.Nuke",
			displayName = "Nuke",
			nukeDuration = 3.0,  -- Anti-spawn period
			restoreDuration = 15.0,  -- Gradual spawn rate restoration
			highlightColor = Color3.fromRGB(30, 30, 30),  -- Dark gray (pure black is hard to see)
		},
		Magnet = {
			modelPath = "ServerStorage.ContentDrawer.ItemModels.Powerups.Magnet",
			displayName = "Magnet",
			pullDuration = 3.0,
			highlightColor = Color3.fromRGB(255, 255, 0),  -- Yellow
		},
		Health = {
			modelPath = "ServerStorage.ContentDrawer.ItemModels.Powerups.Health",
			displayName = "Health",
			healPercent = 0.45,  -- 45% of max HP
			overhealAmount = 0,  -- No base overheal (can be added later)
			highlightColor = Color3.fromRGB(0, 255, 0),  -- Green
		},
		Cloak = {
			modelPath = "ServerStorage.ContentDrawer.ItemModels.Powerups.Cloak",
			displayName = "Cloak",
			duration = 7.0,
			speedBoost = 1.3,  -- 30% speed boost
			highlightColor = Color3.fromRGB(255, 255, 255),  -- White
			characterTransparency = 0.5,
		},
		ArcaneRune = {
			modelPath = "ServerStorage.ContentDrawer.ItemModels.Powerups.ArcaneRune",
			displayName = "Arcane Rune",
			duration = 15.0,
			damageMult = 3.0,
			cooldownMult = 0.33,  -- 3x cooldown reduction (divide by 3)
			homingMult = 1.75,  -- 1.75x homing strength, distance, and max angle
			penetrationMult = 3,  -- Triple penetration
			durationMult = 2,  -- Double projectile/effect duration
			projectileSpeedMult = 1.23,  -- 1.5x projectile speed
			highlightColor = Color3.fromRGB(0, 100, 255),  -- Blue
		},
	},
	
	-- Spawn chances
	AmbientPowerupChance = 0.0053,  -- chance to spawn powerup instead of exp
	EnemyDropPowerupChance = 0.008,  -- chance enemy drops powerup
	
	-- Powerup type weights (equal distribution)
	PowerupWeights = {
		Nuke = 1,
		Magnet = 3,
		Health = 4,
		Cloak = 2,
		ArcaneRune = 1,
	},
	
	-- Powerup type list for iteration
	PowerupTypesList = {"Nuke", "Magnet", "Health", "Cloak", "ArcaneRune"},
	
	-- Visual Settings
	PowerupScale = 1.7,  -- Scale multiplier for all powerup models (1.5 = 1.5x larger)
	
	-- Lifetime
	PowerupLifetime = 45.0,  -- Despawn after 45s
	PowerupHeightOffset = 2.0,  -- 2 studs above ground
	
	-- Overheal
	OverhealDecayRate = 1.0,  -- 1 HP/s
	
	-- Highlight fade (10 chunks over 0.5s)
	HighlightFadeChunks = 10,
	HighlightFadeDuration = 0.5,
	
	-- Display names
	InvincibilityDisplayName = "Invincibility",
}

