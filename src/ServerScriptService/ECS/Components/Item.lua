--!strict
-- Item ECS Components - Components specific to item entities (Server-only)
-- Based on: https://ukendio.github.io/jecs/api/jecs.html

local world = require(game.ServerScriptService.ECS.World)

-- Item-specific components
local ItemComponents = {}

-- ItemData component - Item type and properties
ItemComponents.ItemData = world:component()

-- Pickup component - Pickup behavior data
ItemComponents.Pickup = world:component()

-- Rarity component - Item rarity and effects
ItemComponents.Rarity = world:component()

-- Magnetic component - Magnetic attraction data
ItemComponents.Magnetic = world:component()

-- Bounce component - Bounce physics data
ItemComponents.Bounce = world:component()

-- PowerupData component - Powerup type and collected state
ItemComponents.PowerupData = world:component()

-- MagnetPull component - Magnet pull state for exp orbs
ItemComponents.MagnetPull = world:component()

return ItemComponents
