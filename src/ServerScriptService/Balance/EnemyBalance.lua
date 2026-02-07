--!strict
-- Enemy-specific balance settings

local EnemyBalance = {}

EnemyBalance.HealthMultiplier = 1
EnemyBalance.DamageMultiplier = 1

-- Enemy spawning settings (adaptive, per-player)
EnemyBalance.MaxEnemies = 190 -- Global cap

-- Global difficulty coefficient (RoR2-style, Normal)
EnemyBalance.DifficultyCoeff = {
	EnemyDifficulty = 1.0,
	RateMult = 1.8,
}

-- Difficulty coefficient -> enemy scaling exponents (modest)
EnemyBalance.DifficultyScaling = {
	SpawnExponent = 1.8,
	HealthExponent = 5.0,
	DamageExponent = 0.65,
	SpeedExponent = 0.85,
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

-- Per-player pressure correction (small, clamped)
EnemyBalance.PressureCorrection = {
	SpawnClamp = 0.20, -- ±15%
	StatClamp = 0.12, -- ±10% for HP/Dmg/Speed
	ChangeThreshold = 0.02,
	ChangeCooldown = 8.0, -- seconds
}

EnemyBalance.Pressure = {
	Tau = 30, -- fallback if TauEarly/TauLate are not set
	TauEarly = 75, -- seconds (slow catch-up early)
	TauLate = 8, -- seconds (faster catch-up later)
	TauRampMinutes = 60, -- minutes to ramp TauEarly -> TauLate
	UpdateInterval = 0.5, -- seconds between pressure updates
}

-- Raw stat-driven scaling (passives + ability stats, excluding temporary buffs)
EnemyBalance.RawStatScaling = {
	Enabled = true,
	AbilityWeight = 0.85, -- abilities contribute at 45% of general stats
	General = {
		-- Player offense -> Enemy health/spawn
		Health = { Damage = 1.5, Cooldown = 0.8, ProjectileCount = 0.8, Penetration = 0.8, Size = 0.5, Duration = 0.5 },
		-- Player defense -> Enemy damage (low impact)
		Damage = { Health = 0.25, Armor = 0.4, Regen = 0.1, Lifesteal = 0.15 },
		-- Player mobility -> Enemy speed (low impact)
		Speed = { MoveSpeed = 0.6, MobilityDistance = 0.4 },
	},
	Ability = {
		Health = { Damage = 0.9, Cooldown = 0.4, ProjectileCount = 0.6, ShotAmount = 0.6, Penetration = 0.25, Size = 0.2, Duration = 0.2 },
		Spawn = { Damage = 0.35, Cooldown = 0.5, ProjectileCount = 0.3, ShotAmount = 0.3, Penetration = 0.15, Size = 0.2, Duration = 0.2 },
	},
}

-- PlayerScaling removed: scaling is now driven only by raw stats + time.


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

-- Base spawn rate per player (adaptive system scales from this)
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
