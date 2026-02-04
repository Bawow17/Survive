--!strict
-- Enemy-specific balance settings

local EnemyBalance = {}

EnemyBalance.HealthMultiplier = 1
EnemyBalance.DamageMultiplier = 1

-- Enemy spawning settings (adaptive, per-player)
EnemyBalance.MaxEnemies = 190 -- Global cap

-- Player power → pressure smoothing (adaptive scaling)
EnemyBalance.PlayerPower = {
	-- Legacy upgrade-level weighting removed; scaling is now raw-stat driven.
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
		Health = { Damage = 1.5, Cooldown = 0.25, ProjectileCount = 0.1, Penetration = 0.15, Size = 0.1, Duration = 0.1 },
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

-- Optional time-based scaling (works alongside player power scaling)
EnemyBalance.TimeScaling = {
	Enabled = true,
	EarlyMinutes = 20, 
	PostMinutes = 65, -- post scaling starts here
	PostRamp = 15, -- minutes to ramp post scaling
	Health = { EarlyScale = 0.15, PostScale = 0.4, PostGrowth = 0.6, PostExponent = 1.1 },
	Damage = { EarlyScale = 0.05, PostScale = 0.15, PostGrowth = 0.2, PostExponent = 1.0 },
	Speed = { EarlyScale = 0.05, PostScale = 0.1, PostGrowth = 0.15, PostExponent = 1.0 },
	Spawn = { EarlyScale = 0.1, PostScale = 0.2, PostGrowth = 0.2, PostExponent = 1.0 },
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

-- Base spawn rate per player (adaptive system scales from this)
EnemyBalance.BaseSpawnRatePerPlayer = 1.4

-- Multiplayer enemy scaling (Phase 0.6)
EnemyBalance.Multiplayer = {
	-- Scale enemies per player (1.0 = 1x base rate per player, 0.75 = 75% per player)
	-- Example: 4 players at 1.0 = 4x total spawn rate
	-- Example: 4 players at 0.75 = 3x total spawn rate
	EnemiesPerPlayer = 0.9, -- deprecated (adaptive system handles)
	
	-- Health scaling per player (+66% health per additional player)
	-- Formula: Health = Base * (1 + HealthPerPlayer * (playerCount - 1))
	-- Example: 2 players = 1.66x health, 3 players = 2.32x health
	HealthPerPlayer = 0.66, -- deprecated (adaptive system handles)
}

-- Legacy time-based scaling (deprecated, kept for reference)
EnemyBalance.GlobalMoveSpeedScaling = EnemyBalance.GlobalMoveSpeedScaling or nil
EnemyBalance.GlobalHealthScaling = EnemyBalance.GlobalHealthScaling or nil
EnemyBalance.LifetimeMoveSpeedScaling = EnemyBalance.LifetimeMoveSpeedScaling or nil
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
