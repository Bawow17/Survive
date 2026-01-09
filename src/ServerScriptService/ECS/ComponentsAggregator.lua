--!strict
-- ECS Components - Server-side component definitions
-- Exports all component types for use across server systems

-- Import all component modules
local CoreComponents = require(game.ServerScriptService.ECS.Components.Core)
local EnemyComponents = require(game.ServerScriptService.ECS.Components.Enemy)
local ProjectileComponents = require(game.ServerScriptService.ECS.Components.Projectile)
local ItemComponents = require(game.ServerScriptService.ECS.Components.Item)
local PlayerComponents = require(game.ServerScriptService.ECS.Components.Player)
local AbilityComponents = require(game.ServerScriptService.ECS.Components.Ability)
local CombatComponents = require(game.ServerScriptService.ECS.Components.Combat)

-- Combine all components into a single export
local Components = {}

-- Core components
for key, value in pairs(CoreComponents) do
	Components[key] = value
end

-- Enemy components
for key, value in pairs(EnemyComponents) do
	Components[key] = value
end

-- Projectile components
for key, value in pairs(ProjectileComponents) do
	Components[key] = value
end

-- Item components
for key, value in pairs(ItemComponents) do
	Components[key] = value
end

-- Player components
for key, value in pairs(PlayerComponents) do
	Components[key] = value
end

-- Ability components
for key, value in pairs(AbilityComponents) do
	Components[key] = value
end

-- Combat components
for key, value in pairs(CombatComponents) do
	Components[key] = value
end

return Components