--!strict
-- Combat ECS Components - Components for hit feedback, knockback, and death animations
-- Based on: https://ukendio.github.io/jecs/api/jecs.html

local world = require(game.ServerScriptService.ECS.World)

-- Combat-specific components
local CombatComponents = {}

-- HitFlash component - tracks when an enemy should show hit feedback
-- Data: { endTime: number, hitCount: number }
CombatComponents.HitFlash = world:component()

-- Knockback component - applies knockback velocity and stun
-- Data: { velocity: Vector3, endTime: number, stunned: boolean }
CombatComponents.Knockback = world:component()

-- DeathAnimation component - marks entity for death fade animation
-- Data: { startTime: number, duration: number, flashEndTime: number }
CombatComponents.DeathAnimation = world:component()

return CombatComponents
