--!strict
-- Shield Bash Mobility Ability Configuration
-- Upgraded dash with combat abilities - damages and knocks back enemies

return {
	id = "ShieldBash",
	displayName = "Shield Bash",
	description = "Powerful dash that damages enemies, negates damage, and grants overshield. (5% max HP per enemy hit)",
	
	-- UI color (shown in upgrade selection)
	color = Color3.fromRGB(180, 80, 0), -- Dark orange
	
	-- Movement (user will balance these stats)
	distance = 185,  -- studs (affected by Haste passive)
	duration = 0.55,  -- seconds for dash movement
	
	-- Timing
	cooldown = 4.0,  -- seconds (affected by Fast Casting)
	
	-- Combat
	damage = 250,  -- damage per enemy hit
	knockbackDistance = 50,  -- studs
	preDashInvincibility = 0.45,  -- seconds of invincibility BEFORE dash (lag protection)
	invincibilityPerHit = 0.25,  -- seconds of invincibility per enemy hit (stacks)
	overshieldPerHit = 0.05,  -- 5% of max health as overshield per enemy hit (stacks)
	
	-- Visual
	afterimageCount = 6,
	afterimageDuration = 0.2,  -- fade duration in seconds
	afterimageInterval = 0.018,  -- spawn interval in seconds
	afterimageModelPath = "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.BashShield.Afterimage",
	
	-- Model path (Shield model with Hitbox)
	shieldModelPath = "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.BashShield.Shield",
	
	-- Unlock
	minLevel = 15,  -- Available as upgrade at level 
	category = "mobility",
}

