--!strict
-- ItemBalance - Configuration for EXP orbs and leveling system

return {
	-- Spawn Settings
	SpawnEnabled = true,
	PowerupSpawnEnabled = true,  -- Enable powerup spawning
	
	-- Ambient exp spawn rate scaling (over game time)
	ExpPerSecondScaling = {
		StartValue = 0.2,
		EndValue = 25,
		Duration = 3500, -- 10 minutes to reach max
		EasingStyle = "Linear"
	},
	MinSpawnRadius = 60,  -- Min distance from player
	MaxSpawnRadius = 120,  -- Max distance from player
	MaxOrbs = 325,  -- Maximum orbs 
	OrbLifetime = 250.0,  -- Orbs despawn after 250s if not collected
	OrbHeightOffset = 2.5,  -- 2 studs above ground
	
	-- Orb Type Definitions (color and exp value - shared by ambient and enemy drops)
	OrbTypes = {
		Blue = {
			expAmount = 10,
			color = Color3.fromRGB(100, 150, 255),  -- Light blue
		},
		Orange = {
			expAmount = 30,
			color = Color3.fromRGB(255, 165, 0),  -- Orange
		},
		Purple = {
			expAmount = 100,
			color = Color3.fromRGB(180, 100, 255),  -- Purple
		},
		Red = {  -- For exp-sink orbs only
			expAmount = 0,  -- Dynamic (accumulates voided exp)
			color = Color3.fromRGB(255, 60, 60),  -- Red
		},
	},
	
	-- Orb type list for iteration
	OrbTypesList = {"Blue", "Orange", "Purple"},
	
	-- Ambient Spawn Weights (for ExpOrbSpawner)
	AmbientSpawnWeights = {
		Blue = 70,    -- 70%
		Orange = 25,  -- 25%
		Purple = 5,   -- 5%
	},
	
	-- Enemy Death Drop Settings
	EnemyDrops = {
		Enabled = true,
		BaseExpMultiplier = 1.3,  -- Baseline multiplier for all drops
		HPScaling = 1.005,  -- Every 100 HP = 1.005x exp (compound: (1.005)^(HP/100))
		
		-- Drop weights (separate from ambient)
		DropWeights = {
			Blue = 60,    -- 60%
			Orange = 30,  -- 30%
			Purple = 10,  -- 10%
		},
	},
	
	-- Exp-Sink (Red Orb) Settings
	ExpSink = {
		Enabled = true,
		SinkCooldown = 3.0,  -- 3s cooldown between red orb creations
		SinkName = "RedExpSink",
		Scale = 1.5,  -- Red orb scale multiplier
		TeleportEnabled = true,
		InitialTeleportDelay = 60,  -- Wait 60s before first teleport
		TeleportInterval = 30,  -- Teleport every 30s after initial delay
		TeleportRadius = 75,  -- Max teleport radius from player (studs)
		TeleportMinRadius = 175,  -- Spawn exactly at max radius edge (same as max = spawn at edge)
	},
	
	-- Leveling (Dynamic three-phase system)
	BaseExpRequired = 100,  -- Exp needed for level 2
	MaxLevel = 1000,
	
	-- Three-phase progression (automatically scales with upgrade count)
	ProgressionPhases = {
		Phase1 = {
			name = "Fast (Linear)",
			ratio = 0.35,  -- First 35% of max upgrades
			expPerLevel = 90,  -- Linear: +100 exp per level
		},
		Phase2 = {
			name = "Medium (Gentle Exponential)",
			ratio = 0.45,  -- Next 45% of max upgrades
			scaling = 1.07,  -- 1.1x multiplier per level
		},
		Phase3 = {
			name = "Grindy (Quadratic)",
			ratio = 0.20,  -- Final 20% of max upgrades
			baseMultiplier = 1.5,  -- Quadratic scaling base
		},
	},
	
	-- Chunked Exp Gain (prevents level spam)
	EnableChunking = true,
	ChunkCount = 10,  -- Split large gains into 10 chunks
	ChunkInterval = 0.08,  -- 0.15s between chunks
	ChunkThreshold = 50,  -- Only chunk if gaining >=50 exp at once
	
	-- Spawn EXP Settings (orbs spawned around player on initial spawn)
	SpawnExps = {
		Enabled = true,
		
		-- Delay before spawning starter orbs (prevents white flash)
		SpawnDelay = 2,  -- Wait 0.5s after player joins before spawning orbs
		
		-- Number of orbs to spawn
		MinOrbs = 800,   -- Minimum orbs
		MaxOrbs = 900,  -- Maximum orbs (random between min/max)
		
		-- Spawn radius around player
		MinRadius = 25,  -- Minimum distance from player (studs)
		MaxRadius = 40,  -- Maximum distance from player (studs)
		
		-- Orb type weights (same format as AmbientSpawnWeights)
		SpawnWeights = {
			Blue = 80,    -- 80%
			Orange = 15,  -- 15%
			Purple = 5,   -- 5%
		},
		
		-- Ground detection
		UseGroundDetection = true,  -- Use raycasting to ensure orbs spawn on ground
		MaxSpawnAttempts = 3,  -- Max attempts to find valid ground per orb
	},
}
