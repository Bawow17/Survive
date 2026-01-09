--!strict
-- Ability ECS Components - Components specific to player abilities (Server-only)
-- Based on: https://ukendio.github.io/jecs/api/jecs.html

local world = require(game.ServerScriptService.ECS.World)

-- Ability-specific components
local AbilityComponents = {}

-- Marker component to identify entities that have abilities
AbilityComponents.Ability = world:component()

-- AbilityData component - stores ability configuration and runtime state
AbilityComponents.AbilityData = world:component()

-- AbilityCooldown component - tracks cooldown timers for abilities
AbilityComponents.AbilityCooldown = world:component()

-- AbilityTargeting component - stores targeting information
AbilityComponents.AbilityTargeting = world:component()

-- AbilityPulse component - tracks multi-shot pulse timing
AbilityComponents.AbilityPulse = world:component()

-- AfterimageClones component - tracks clone entities for Afterimages attribute
AbilityComponents.AfterimageClones = world:component()

return AbilityComponents
