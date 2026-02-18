--!strict
-- Zombie Enemy Balance Configuration
-- All base stats and settings for the Zombie enemy type

return {
	-- Display name
	Name = "Zombie",
	
	-- Model path in ReplicatedStorage
	modelPath = "ReplicatedStorage.ContentDrawer.Enemies.Mobs.Zombie",
	
	-- Base stats (before multipliers and scaling)
	-- RoR2-like baseline (Lemurian/Beetle-range):
	baseHealth = 95,
	baseDamage = 14,
	baseSpeed = 11,
	
	-- AI behavior
	behavior = "Melee",
	attackRange = 4,  -- Default if attackbox not found in model
	attackCooldown = 0.7,
}
