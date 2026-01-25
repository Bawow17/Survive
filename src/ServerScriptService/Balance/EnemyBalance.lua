--!strict
-- Enemy-specific balance settings

local EnemyBalance = {}

EnemyBalance.HealthMultiplier = 10.0
EnemyBalance.DamageMultiplier = 0.7

-- Enemy spawning settings (with time-based scaling)
EnemyBalance.MaxEnemies = 275 -- Maximum number of enemies allowed at once

-- Enemy type spawn weights (must sum to 1.0 or will be normalized)
EnemyBalance.SpawnWeights = {
	Zombie = 0.75,
	Charger = 0.25
}

-- Enemy spawn rate scaling (over game time)
EnemyBalance.EnemiesPerSecondScaling = {
	StartValue = 2.5,
	EndValue = 20,
	Duration = 1200, -- 10 minutes to reach max
	EasingStyle = "Linear"
}

-- Multiplayer enemy scaling (Phase 0.6)
EnemyBalance.Multiplayer = {
	-- Scale enemies per player (1.0 = 1x base rate per player, 0.75 = 75% per player)
	-- Example: 4 players at 1.0 = 4x total spawn rate
	-- Example: 4 players at 0.75 = 3x total spawn rate
	EnemiesPerPlayer = 0.9,
	
	-- Health scaling per player (+66% health per additional player)
	-- Formula: Health = Base * (1 + HealthPerPlayer * (playerCount - 1))
	-- Example: 2 players = 1.66x health, 3 players = 2.32x health
	HealthPerPlayer = 0.66,
}

-- Global enemy move speed scaling (over game time)
EnemyBalance.GlobalMoveSpeedScaling = {
	StartValue = 1.0,
	EndValue = 2.4,
	Duration = 3500, -- 10 minutes to reach max
	EasingStyle = "Linear"
}

-- Global enemy health scaling (over game time)
EnemyBalance.GlobalHealthScaling = {
	StartValue = 1,
	EndValue = 15,
	Duration = 4500, -- 50 minutes to reach max
	EasingStyle = "Linear"
}

-- Per-enemy lifetime move speed scaling (individual enemy age)
EnemyBalance.LifetimeMoveSpeedScaling = {
	StartValue = 1.0,
	EndValue = 2.2,
	Duration = 180, -- 2 minutes max per enemy
	EasingStyle = "InQuad" -- Quadratic easing inward (accelerating)
}
EnemyBalance.InitialSpawnDelay = 1	 -- Seconds to wait before first enemy spawn
EnemyBalance.MinSpawnRadius = 90 -- Minimum distance from player to spawn enemies
EnemyBalance.MaxSpawnRadius = 170 -- Maximum distance from player to spawn enemies

-- Spawn density control (prevents clustering)
EnemyBalance.SpawnDensityCheck = {
	Enabled = true,
	MaxEnemiesInRadius = 2,  -- Reject spawn if >= 3 enemies nearby
	CheckRadius = 40,  -- Check within 20 studs
	MaxAttempts = 5,  -- Try up to 3 different positions
}

-- Sector-based spawning (distributes enemies evenly around player)
EnemyBalance.SectorSpawning = {
	Enabled = true,
	SectorCount = 8,  -- Divide spawn ring into 8 sectors (45° each)
	AttemptsPerSector = 5,  -- Try 3 positions within chosen sector
}

-- Enemy combat settings
-- Note: Attack range is automatically calculated based on each enemy's "Attackbox" part size
-- Each enemy model must contain:
--   "Hitbox" part = for receiving damage from projectiles (only this part can be hit)
--   "Attackbox" part = for dealing damage to players (determines attack range)
-- Attack cooldown is hardcoded to 0.2 seconds between attacks

-- Enemy repulsion settings (Minecraft-like separation)
EnemyBalance.RepulsionRadius = 18 -- Default separation radius in studs
EnemyBalance.RepulsionStrength = 13 -- Default separation force strength
EnemyBalance.EnableRepulsion = true -- Enable/disable repulsion system
EnemyBalance.MaxRepulsionForce = 15.0 -- Maximum repulsion force to prevent excessive pushing
EnemyBalance.MinSeparationDistance = 0.5 -- Minimum distance before applying repulsion
EnemyBalance.CrowdRepulsionMultiplier = 0.086 -- How much to increase repulsion per extra enemy in crowd (0.6/7 = 0.086 to reach 1.6x at 10 enemies)
EnemyBalance.CrowdRepulsionThreshold = 3 -- Number of nearby enemies before crowd scaling kicks in
EnemyBalance.MaxCrowdMultiplier = 1.6 -- Maximum crowd repulsion multiplier (32 max strength: 20 * 1.6 = 32)

-- Inner crowd stability settings
EnemyBalance.InnerCrowdThreshold = 8 -- Number of nearby enemies to be considered "inner crowd"
EnemyBalance.InnerCrowdDampening = 0.6 -- Reduce repulsion force for heavily crowded enemies (0.0-1.0)
EnemyBalance.ForceSmoothing = 0.7 -- How much to blend with previous frame's force (0.0-1.0)
EnemyBalance.MaxVelocityChange = 12.0 -- Maximum velocity change per frame to prevent jumping

return EnemyBalance

