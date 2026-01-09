--!strict
-- Projectile ECS Components - Components specific to projectile entities (Server-only)
-- Based on: https://ukendio.github.io/jecs/api/jecs.html

local world = require(game.ServerScriptService.ECS.World)
local CoreComponents = require(game.ServerScriptService.ECS.Components.Core)

-- Projectile-specific components
local ProjectileComponents = {}

-- Marker component to identify projectile entities in queries
ProjectileComponents.Projectile = world:component()

-- ProjectileData component - detailed projectile stats/state
ProjectileComponents.ProjectileData = world:component()

-- Reuse shared damage component defined in Core
ProjectileComponents.Damage = CoreComponents.Damage

-- Homing component - Homing behavior data
ProjectileComponents.Homing = world:component()

-- HitTargets component - Track entities already hit by this projectile (for homing re-targeting)
ProjectileComponents.HitTargets = world:component()

-- Piercing component - Piercing behavior data
ProjectileComponents.Piercing = world:component()

-- Explosive component - Explosion data
ProjectileComponents.Explosive = world:component()

-- StatusEffect component - Status effect data
ProjectileComponents.StatusEffect = world:component()

-- ProjectileOrbit component - Makes projectiles orbit around their owner
ProjectileComponents.ProjectileOrbit = world:component()

return ProjectileComponents
