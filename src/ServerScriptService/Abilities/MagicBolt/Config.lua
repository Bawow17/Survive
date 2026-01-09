--!strict
-- Magic Bolt Ability Configuration (Unified)
-- Combines gameplay balance, animation settings, and asset IDs

return {
	-- Display name (shown in UI)
	Name = "Magic Bolt",
	
	-- UI color (shown in upgrade selection)
	color = Color3.fromRGB(0, 60, 150), -- Dark blue
	
	-- Progression settings
	StartWith = true, -- Player starts with this ability
	Unlockable = false, -- Can appear in random upgrade options (false since player already has it)
	
	-- Model path in ReplicatedStorage
	modelPath = "ReplicatedStorage.ContentDrawer.Attacks.Abilties.MagicBolt.MagicBolt",
	
	-- Core stats
	damage = 90,
	projectileSpeed = 100, -- studs per second
	penetration = 3, -- amount of enemies it can hit before destroying (0 = destroy on first hit)
	duration = 1.5, -- lifetime of the projectile in seconds
	cooldown = 0.01, -- cooldown in seconds between casts
	
	-- Targeting configuration
	-- 0 = random direction
	-- 1 = random X/Z but track Y
	-- 2 = direct targeting with prediction
	-- 3 = homing 
	targetingMode = 2,
	targetingRange = 500, -- maximum range for targeting enemies
	targetingAngle = math.rad(45), -- maximum angle deviation for targeting
	StayHorizontal = true, -- Keep projectiles horizontal when player is grounded
	AlwaysStayHorizontal = false, -- Lock Y-axis to spawn height (works even when airborne, overrides StayHorizontal)
	StickToPlayer = false, -- Projectile follows player movement in all axes X/Y/Z (overrides AlwaysStayHorizontal)
	
	-- Homing configuration (only used when targetingMode = 3)
	homingStrength = 250, -- Turn speed in degrees per second
	homingDistance = 100, -- Distance for target acquisition in studs
	homingMaxAngle = 200, -- Max turn angle in degrees (prevents 180° reversals)
	
	-- Spawn configuration
	spawnOffset = Vector3.new(0, 0, 0), -- offset from player position
	scale = 1, -- visual scale multiplier
	
	-- Multi-shot configuration
	projectileCount = 1, -- amount of projectiles shot in one cast (after one another)
	shotAmount = 5, -- amount of projectiles shot PER projectile (shotgun spread)
	pulseInterval = 0.08, -- interval between each projectile count
	spreadAngleEven = math.rad(15), -- spread angle when shotAmount is even
	spreadAngleOdd = math.rad(30), -- spread angle when shotAmount is odd
	
	-- Animation configuration (Server-Only - Asset IDs)
	animations = {
		animationIds = {
			first = "rbxassetid://77657526317110",   -- Initial cast animation
			loop = "rbxassetid://136991117772395",    -- Looping animation (alternates with last)
			last = "rbxassetid://135450356946547",    -- Looping animation (alternates with loop)
		},
		loopFrame = 27,  -- Frame at which to stop and restart for loops
		totalFrames = 50,  -- Total frames at 60fps
		duration = 0.833,  -- Duration in seconds (50/60)
		animationPriority = Enum.AnimationPriority.Action,  -- Overrides walking
		anticipation = 0.2,  -- Delay before first projectile spawns (animation wind-up time)
	},
}

