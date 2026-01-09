--!strict
-- Enemy ECS Components - Components specific to enemy entities (Server-only)
-- Based on: https://devforum.roblox.com/t/how-do-i-lower-my-recv-td-game-enemy-system/2772669/9

local world = require(game.ServerScriptService.ECS.World)

-- Enemy-specific components
local EnemyComponents = {}

-- Health component - Enemy health and damage
EnemyComponents.Health = world:component()

-- AI component - AI behavior and state
EnemyComponents.AI = world:component()

-- Combat component - Combat-related data
EnemyComponents.Combat = world:component()

-- Target component - Targeting information
EnemyComponents.Target = world:component()

-- Movement component - Movement-specific data
EnemyComponents.Movement = world:component()

-- Repulsion component - Enemy separation and anti-stacking
EnemyComponents.Repulsion = world:component()

-- FacingDirection component - Direction the enemy should face (independent of movement)
EnemyComponents.FacingDirection = world:component()

-- ChargerState component - State machine for Charger enemies
EnemyComponents.ChargerState = world:component()

-- PathfindingState component - Tracks pathfinding mode and obstacle detection
EnemyComponents.PathfindingState = world:component()

-- EnemyPausedTime component - Tracks total time enemy has been paused (for lifetime scaling)
EnemyComponents.EnemyPausedTime = world:component()

return EnemyComponents
