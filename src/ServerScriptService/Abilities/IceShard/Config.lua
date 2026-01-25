--!strict
-- Ice Shard Ability Configuration (Unified)
-- Combines gameplay balance, animation settings, and asset IDs

return {
	-- Display name (shown in UI)
	Name = "Ice Shard",
	
	-- UI color (shown in upgrade selection)
	color = Color3.fromRGB(100, 200, 255), -- Light blue
	
	-- Progression settings
	StartWith = false, -- Player starts with this ability
	Unlockable = true, -- Can appear in random upgrade options
	
	-- Model path in ReplicatedStorage
	modelPath = "ReplicatedStorage.ContentDrawer.Attacks.Abilties.IceShard.IceShard",
	
	-- Core stats
	damage = 150,
	projectileSpeed = 175, -- studs per second
	penetration = 3, -- amount of enemies it can hit before destroying (0 = destroy on first hit)
	duration = 0.7, -- lifetime of the projectile in seconds
	cooldown = 1.6, -- cooldown in seconds between casts
	
	-- Targeting configuration
	-- 0 = random direction
	-- 1 = random X/Z but track Y
	-- 2 = direct targeting with prediction
	-- 3 = homing (fallback to 2)
	targetingMode = 3,
	targetingRange = 10000, -- maximum range for targeting enemies
	targetingAngle = math.rad(45), -- maximum angle deviation for targeting
	StayHorizontal = true, -- Keep projectiles horizontal when player is grounded
	AlwaysStayHorizontal = false, -- Lock Y-axis to spawn height (works even when airborne, overrides StayHorizontal)
	StickToPlayer = false, -- Projectile follows player movement in all axes X/Y/Z (overrides AlwaysStayHorizontal)
	
	-- Homing configuration (only used when targetingMode = 3)
	homingStrength = 100, -- Turn speed in degrees per second
	homingDistance = 300, -- Distance for target acquisition in studs
	homingMaxAngle = 180, -- Max turn angle in degrees (prevents 180° reversals)
	
	-- Spawn configuration
	spawnOffset = Vector3.new(0, 0, 0), -- offset from player position
	scale = 1, -- visual scale multiplier
	
	-- Multi-shot configuration
	projectileCount = 1, -- amount of projectiles shot in one cast (after one another)
	shotAmount = 1, -- amount of projectiles shot PER projectile (shotgun spread)
	pulseInterval = 0.08, -- interval between each projectile count
	spreadAngleEven = math.rad(15), -- spread angle when shotAmount is even
	spreadAngleOdd = math.rad(30), -- spread angle when shotAmount is odd
	
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
