--!strict
-- Refractions Ability Configuration

return {
	-- Display name (shown in UI)
	Name = "Refractions",
	
	-- UI color (shown in upgrade selection)
	color = Color3.fromRGB(120, 220, 255),
	
	-- Progression settings
	StartWith = false,
	Unlockable = true,
	
	-- Model path in ReplicatedStorage
	modelPath = "ReplicatedStorage.ContentDrawer.Attacks.Abilties.Refractions.Refractions",
	
	-- Core stats
	damage = 60,
	projectileSpeed = 0, -- Beam is stationary relative to player
	penetration = 9999, -- Infinite penetration
	duration = 0.5,
	cooldown = 1.7,
	
	-- Targeting configuration
	targetingMode = 2,
	targetingRange = 10000,
	targetingAngle = math.rad(180),
	StayHorizontal = true,
	AlwaysStayHorizontal = false,
	StickToPlayer = true,
	upgradeStatBlacklist = {
		projectileSpeed = true,
		shotAmount = true,
	},
	
	-- Spawn configuration
	spawnOffset = Vector3.new(0, 0, 0),
	scale = 1,
	
	-- Multi-shot configuration
	projectileCount = 1,
	shotAmount = 2,
	pulseInterval = 0.1,
	spreadAngleEven = math.rad(0),
	spreadAngleOdd = math.rad(0),
	
	-- Hit cadence for beam ticks
	hitCooldown = 0.2,
}
