--!strict
-- [Ability Name] Configuration Template (Unified)
-- Copy this file to create a new ability's configuration
-- 1. Copy this entire _Templates folder
-- 2. Rename folder to your ability name (e.g., "Fireball")
-- 3. Rename this file to "Config.lua"
-- 4. Update the values below

return {
	-- Display name (shown in UI, can have spaces and capitals)
	Name = "Your Ability Name",
	
	-- Progression settings
	StartWith = false, -- Set to true if player should start with this ability
	Unlockable = true, -- Set to false if ability is locked behind specific requirements (quest, achievement, etc.)
	
	-- Model path in ReplicatedStorage (REQUIRED)
	-- Format: "ReplicatedStorage.ContentDrawer.Attacks.Abilties.YourAbility.YourAbility"
	modelPath = "ReplicatedStorage.ContentDrawer.Attacks.Abilties.YourAbility.YourAbility",
	
	-- Core stats
	damage = 25, -- Base damage per hit
	projectileSpeed = 100, -- Movement speed in studs per second
	penetration = 0, -- Number of enemies projectile can pierce (0 = destroy on first hit)
	duration = 1.5, -- Maximum lifetime in seconds
	cooldown = 1.2, -- Cooldown between casts in seconds
	
	-- Targeting configuration
	-- 0 = random direction
	-- 1 = random X/Z but track Y coordinate
	-- 2 = direct targeting with velocity prediction
	-- 3 = homing (uses velocity steering to track targets)
	targetingMode = 2,
	targetingRange = 500, -- Maximum range to search for targets
	targetingAngle = math.rad(45), -- Maximum angle deviation (in radians)
	StayHorizontal = false, -- Keep projectiles horizontal when player is grounded
	AlwaysStayHorizontal = false, -- Lock Y-axis to spawn height (works even when airborne, overrides StayHorizontal)
	StickToPlayer = false, -- Projectile follows player movement in all axes X/Y/Z (overrides AlwaysStayHorizontal)
	
	-- Homing configuration (only used when targetingMode = 3)
	homingStrength = 180, -- Turn speed in degrees per second
	homingDistance = 100, -- Distance for target acquisition in studs
	homingMaxAngle = 90, -- Max turn angle in degrees (prevents 180° reversals)
	
	-- Spawn configuration
	spawnOffset = Vector3.new(0, 0, 0), -- Offset from player position when spawning
	scale = 1, -- Visual scale multiplier
	
	-- Multi-shot configuration
	projectileCount = 1, -- Number of projectiles per cast (fired sequentially)
	shotAmount = 1, -- Number of projectiles per shot (shotgun spread)
	pulseInterval = 0.08, -- Time between sequential projectiles (seconds)
	spreadAngleEven = math.rad(10), -- Spread angle when shotAmount is even (in radians)
	spreadAngleOdd = math.rad(10), -- Spread angle when shotAmount is odd (in radians)
	
	-- Animation configuration (Server-Only - Asset IDs)
	-- Fill in animation IDs after creating animations
	animations = {
		animationIds = {
			first = "",   -- Initial cast animation (leave empty until created)
			loop = "",    -- Looping animation (alternates with last)
			last = "",    -- Looping animation (alternates with loop)
		},
		loopFrame = 27,  -- Frame at which to stop and restart for loops (adjust based on your animation)
		totalFrames = 50,  -- Total frames at 60fps (adjust based on your animation)
		duration = 0.833,  -- Duration in seconds (totalFrames/60)
		animationPriority = Enum.AnimationPriority.Action,  -- Overrides walking
		anticipation = 0.2,  -- Delay before first projectile spawns (animation wind-up time)
	},
}
