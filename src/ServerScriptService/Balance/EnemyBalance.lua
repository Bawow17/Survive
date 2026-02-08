--!strict
-- Enemy-specific balance settings

local EnemyBalance = {}

EnemyBalance.HealthMultiplier = 1
EnemyBalance.DamageMultiplier = 1

-- Enemy spawning settings (time/player-count coefficient only)
EnemyBalance.MaxEnemies = 190 -- Global cap

-- Global difficulty coefficient (RoR2-style, Normal)
EnemyBalance.DifficultyCoeff = {
	EnemyDifficulty = 1.0,
	RateMult = 1.8,
}

-- Difficulty coefficient -> enemy scaling exponents (modest)
EnemyBalance.DifficultyScaling = {
	SpawnExponent = 1.8,
	HealthExponent = 4.0,
	DamageExponent = 0.65,
	SpeedExponent = 0.65,
}

-- Dynamic scaling correction clamp (player stats vs expected power by time).
-- Hard-limited to +/-12% in EnemySpawner even if these values are increased.
EnemyBalance.ScalingCorrection = {
	Enabled = true,
	SpawnClamp = 0.12,
	StatClamp = 0.12,
	SmoothingAlpha = 0.35,
	Weights = {
		Spawn = 1.0,
		Health = 1.0,
		Damage = 1.0,
		Speed = 1.0,
	},
	TimeExpectation = {
		EarlyMinutes = 20,
		EarlyPerMinute = 0.03,
		LatePerMinute = 0.015,
	},
}

-- Super/Elite tier settings (rarer, stronger)
EnemyBalance.SuperElite = {
	StartMinutes = 0,
	MidMinutes = 25,
	LateMinutes = 50,

	SuperOdds = { start = 0.01, mid = 0.03, late = 0.06 },
	EliteOdds = { start = 0.0015, mid = 0.005, late = 0.01 },

	SpawnScale = 1.0,

	SuperMult = { health = 6.1, damage = 1.25, speed = 1.15, size = 4.0 },
	EliteMult = { health = 11.4, damage = 1.6, speed = 0.9, size = 7.5 },

	SuperExpMult = 2.0,
	EliteExpMult = 3.0,
	SuperDropCount = 5,
	EliteDropCount = 7,
	SuperOrbWeights = { Purple = 70, Orange = 30 },
	EliteOrbType = "Purple",
}

EnemyBalance.SpawnBudget = {
	MaxSpawnsPerSecond = 14, -- Global spawn budget (all players)
	MaxSpawnsPerTick = 16, -- Safety cap per step
}

EnemyBalance.SpawnPlacement = {
	Samples = 10, -- candidate points around owner
	DesiredRadius = 150, -- preferred distance to owner
	AvoidOtherPlayersRadius = 60,
	WeightOwner = 1.0,
	WeightOthers = 4.0,
	WeightDensity = 0.4,
	DensityRadius = 30,
}

EnemyBalance.Aggro = {
	SwitchCooldown = 1.2, -- seconds between target switches
	ThreatTau = 4.0, -- seconds for threat decay
	ThreatMargin = 0.2, -- candidate threat must exceed current by this margin
	MinDamageFractionToSwitch = 0.30, -- 30% of max HP
}

-- Enemy type spawn weights (must sum to 1.0 or will be normalized)
EnemyBalance.SpawnWeights = {
	Zombie = 0.75,
	Charger = 0.25
}

-- Base spawn rate per player (scaled by global difficulty coefficient)
EnemyBalance.BaseSpawnRatePerPlayer = 1.4

EnemyBalance.InitialSpawnDelay = 3	 -- Seconds to wait before first enemy spawn
EnemyBalance.MinSpawnRadius = 130 -- Minimum distance from player to spawn enemies
EnemyBalance.MaxSpawnRadius = 240 -- Maximum distance from player to spawn enemies

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
	SectorCount = 8,  -- Divide spawn ring into 8 sectors (45 deg each)
	AttemptsPerSector = 5,  -- Try 3 positions within chosen sector
}

-- Enemy combat settings
-- Note: Attack range is automatically calculated based on each enemy's "Attackbox" part size
-- Each enemy model must contain:
--   "Hitbox" part = for receiving damage from projectiles (only this part can be hit)
--   "Attackbox" part = for dealing damage to players (determines attack range)
-- Attack cooldown comes from each enemy type balance (for example Zombie attackCooldown = 0.7)

-- Enemy repulsion settings (Minecraft-like separation)
EnemyBalance.RepulsionRadius = 18 -- Default separation radius in studs
EnemyBalance.RepulsionStrength = 13 -- Default separation force strength
EnemyBalance.EnableRepulsion = true -- Enable/disable repulsion system
EnemyBalance.MaxRepulsionForce = 15.0 -- Maximum repulsion force to prevent excessive pushing
EnemyBalance.MinSeparationDistance = 0.5 -- Minimum distance before applying repulsion
EnemyBalance.CrowdRepulsionMultiplier = 0.086 -- How much to increase repulsion per extra enemy in crowd (0.6/7 = 0.086 to reach 1.6x at 10 enemies)
EnemyBalance.CrowdRepulsionThreshold = 3 -- Number of nearby enemies before crowd scaling kicks in
EnemyBalance.MaxCrowdMultiplier = 1.6 -- Maximum crowd repulsion multiplier (32 max strength: 20 * 1.6 = 32)

-- Movement system tuning (clamp as backup only)
EnemyBalance.Movement = {
	MaxStep = 1/30, -- Max dt per movement substep (seconds)
	MaxSubsteps = 4, -- Cap substeps per frame
	ClampBackupMultiplier = 3.0, -- Higher = clamp only on extreme spikes
}

-- Inner crowd stability settings
EnemyBalance.InnerCrowdThreshold = 8 -- Number of nearby enemies to be considered "inner crowd"
EnemyBalance.InnerCrowdDampening = 0.6 -- Reduce repulsion force for heavily crowded enemies (0.0-1.0)
EnemyBalance.ForceSmoothing = 0.7 -- How much to blend with previous frame's force (0.0-1.0)
EnemyBalance.MaxVelocityChange = 12.0 -- Maximum velocity change per frame to prevent jumping

return EnemyBalance
