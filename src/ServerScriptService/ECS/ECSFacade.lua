--!strict
-- Server-side ECS Facade
-- Provides unified access to ECS components for server systems

local World = require(game.ServerScriptService.ECS.World)
local Components = require(game.ServerScriptService.ECS.ComponentsAggregator)

-- ECS facade for server systems
local ECS = {
	World = World,
	Components = Components,
}

return ECS