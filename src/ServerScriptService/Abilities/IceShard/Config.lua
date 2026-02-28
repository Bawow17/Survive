--!strict
-- Ice Shard Ability Configuration (Unified)
-- Starting manual-cast ice shard ability.

return {
	-- Display name (shown in UI)
	Name = "Ice Shard",

	-- UI color (shown in upgrade selection)
	color = Color3.fromRGB(100, 200, 255),

	-- Progression settings
	StartWith = true,
	Unlockable = false,

	-- Client-visible projectile path; source model is explicitly cloned from the moved asset.
	modelPath = "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Special.IceShard.IceShardModel",
	replicationSourcePath = "ServerStorage.ContentDrawer.PlayerAbilities.Ice.Special.IceShard.IceShardModel",

	-- Core stats
	damageCoefficient = 8.0,
	procCoefficient = 1.0,
	projectileSpeed = 214.5,
	penetration = 0,
	duration = 15,
	cooldown = 3.0,
	windup = 0.11,

	-- Targeting configuration
	-- 0 = random direction
	-- 1 = random X/Z but track Y
	-- 2 = direct targeting with prediction
	-- 3 = homing
	targetingMode = 2,
	targetingRange = 10000,
	targetingAngle = math.rad(45),
	StayHorizontal = true,
	AlwaysStayHorizontal = false,
	StickToPlayer = false,

	-- Upgrade stat whitelist
	upgradeStatWhitelist = {
		damage = true,
		projectileSpeed = true,
		cooldownReduction = true,
		projectileCount = true,
	},

	-- Spawn configuration
	spawnOffset = Vector3.new(0, 0, 0),
	scale = 1,

	-- Multi-shot configuration
	projectileCount = 1,
	shotAmount = 1,
	pulseInterval = 0.1,
	spreadAngleEven = math.rad(15),
	spreadAngleOdd = math.rad(30),

	-- Ice Shard behavior configuration
	splitCount = 6,
	splitDamageMultiplier = 1.25,
	splitProcCoefficient = 1.0,
	splitScaleMultiplier = 0.55,
	splitMaxSpreadDeg = 70,
	lesserFrostStacksPerHit = 1,
	lesserFrostDuration = 7.0,

	-- Animation configuration (server-authoritative metadata)
	animations = {
		-- Optional server-side source path used to resolve animation IDs automatically.
		-- Supports Animation instances or containers with Animation descendants.
		sourcePath = "ServerStorage.ContentDrawer.PlayerAbilities.Ice.Special.IceShard.IceShard",
		animationIds = {
			first = "",
			loop = "",
			last = "",
		},
		loopFrame = 27,
		totalFrames = 50,
		duration = 0.833,
		animationPriority = Enum.AnimationPriority.Action,
		anticipation = 0.11,
	},
}
