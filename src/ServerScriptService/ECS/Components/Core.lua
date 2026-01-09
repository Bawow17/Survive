--!strict
-- Core ECS Components - Essential components for all entities (Server-only)
-- Based on: https://ukendio.github.io/jecs/api/jecs.html

local world = require(game.ServerScriptService.ECS.World)

-- Core components that all entities can use
local CoreComponents = {}

-- Position component - 3D position in world space
CoreComponents.Position = world:component()

-- Velocity component - 3D velocity for movement
CoreComponents.Velocity = world:component()

-- Lifetime component - Entity lifetime management
CoreComponents.Lifetime = world:component()

-- GridCell component - For spatial partitioning optimization
CoreComponents.GridCell = world:component()

-- ChildOf relationship component for spatial grid
CoreComponents.ChildOf = world:component()

-- Visual component - Visual representation data
CoreComponents.Visual = world:component()

-- Owner component - Entity ownership information
CoreComponents.Owner = world:component()

-- EntityType component - Type identification
CoreComponents.EntityType = world:component()

-- Collision component - physics/collision radius, flags
CoreComponents.Collision = world:component()

-- Damage component - amount/type
CoreComponents.Damage = world:component()

-- AttackCooldown component - remaining/max
CoreComponents.AttackCooldown = world:component()

-- Experience component - amount on entity or pickup radius, etc.
CoreComponents.Experience = world:component()

-- Level component - level and related data
CoreComponents.Level = world:component()

-- ExpChunks component - Queued exp chunks for smooth gain (prevents level spam)
CoreComponents.ExpChunks = world:component()

-- SpawnTime component - Tracks game time when entity was spawned (for lifetime-based scaling)
CoreComponents.SpawnTime = world:component()

return CoreComponents
