--!strict
-- Charger enemy balance configuration
-- Glass cannon enemy with high-speed dash attacks

local ChargerBalance = {}

-- Basic identification
ChargerBalance.Name = "Charger"
ChargerBalance.modelPath = "game.ServerStorage.ContentDrawer.Enemies.Mobs.Charger"

-- Base stats (affected by global scaling)
ChargerBalance.baseHealth = 55 -- Glass cannon: lower than Zombie
ChargerBalance.baseDamage = 15 -- Only dealt during dash
ChargerBalance.baseSpeed = 20 -- High base movement speed

-- AI behavior identifier
ChargerBalance.behavior = "Charger"

-- Attack settings
-- Note: Attack range is now automatically calculated from the Charger model's "Attackbox" part
-- This value is kept only as a fallback if no Attackbox is found
ChargerBalance.attackRange = 3.5 -- Fallback collision radius (only used if Attackbox missing)
ChargerBalance.attackCooldown = 0.2 -- Not used for Charger (uses dash cooldown instead)

-- Dash mechanic settings
ChargerBalance.dashTriggerRange = 35 -- Distance at which Charger enters dash range
ChargerBalance.windupTime = 0.8 -- Charge-up time before dash
ChargerBalance.directionLockDelay = 0.55 -- Time into windup when direction locks (0.55s of 0.8s windup)
ChargerBalance.dashSpeed = 60 -- Speed during dash (very fast)
ChargerBalance.dashDuration = 0.85 -- Maximum dash duration
ChargerBalance.dashOvershoot = 25 -- Distance to dash past the player
ChargerBalance.endlagTime = 0.8 -- Time stuck in place after dash
ChargerBalance.dashCooldown = 5.5 -- Cooldown before next dash can start

-- Movement penalties
ChargerBalance.cooldownSpeedMult = 0.6 -- Movement speed multiplier during cooldown (70% speed)

-- Positioning behavior
ChargerBalance.preferredRange = 26 -- Standoff distance before initiating dash
ChargerBalance.preferredJitter = 5 -- Randomization for preferred range (±5 studs)

return ChargerBalance

