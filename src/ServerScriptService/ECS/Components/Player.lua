--!strict
-- Player ECS Components - Components specific to player entities (Server-only)
-- Based on: https://ukendio.github.io/jecs/api/jecs.html

local world = require(game.ServerScriptService.ECS.World)
local CoreComponents = require(game.ServerScriptService.ECS.Components.Core)

-- Player-specific components
local PlayerComponents = {}

-- PlayerStats component - Player statistics
PlayerComponents.PlayerStats = world:component()

-- Level component - reuse shared component
PlayerComponents.Level = CoreComponents.Level

-- Experience component - reuse shared component
PlayerComponents.Experience = CoreComponents.Experience

-- Spell component - Spell casting data
PlayerComponents.Spell = world:component()

-- Cooldown component - Cooldown tracking
PlayerComponents.Cooldown = world:component()

-- Upgrades component - Tracks player upgrade progress (ability and passive levels)
PlayerComponents.Upgrades = world:component()

-- AttributeSelections component - Tracks selected attributes per ability
PlayerComponents.AttributeSelections = world:component()

-- PassiveEffects component - Stores computed passive effect multipliers
PlayerComponents.PassiveEffects = world:component()

-- StatusEffects component - Tracks timed buffs (invincibility, speed boosts)
PlayerComponents.StatusEffects = world:component()

-- Overheal component - Temporary health that decays over time
PlayerComponents.Overheal = world:component()

-- BuffState component - Stacking temporary buffs (damage, cooldown)
PlayerComponents.BuffState = world:component()

-- MagnetSession component - Tracks active magnet sessions for auto-tagging new orbs
PlayerComponents.MagnetSession = world:component()

-- AbilityDamageStats component - Tracks total damage dealt by each ability (session-persistent)
PlayerComponents.AbilityDamageStats = world:component()

-- Mobility system components
-- MobilityData component - Tracks which mobility ability is equipped
PlayerComponents.MobilityData = world:component()

-- MobilityCooldown component - Tracks last usage time for cooldown validation
PlayerComponents.MobilityCooldown = world:component()

-- HealthRegen component - Tracks health regeneration state
PlayerComponents.HealthRegen = world:component()

-- PlayerPauseState component - Per-player pause state (for individual pause mode)
PlayerComponents.PlayerPauseState = world:component()

-- PendingLevelUps component - Queue of level ups when gaining multiple levels at once
PlayerComponents.PendingLevelUps = world:component()

return PlayerComponents
