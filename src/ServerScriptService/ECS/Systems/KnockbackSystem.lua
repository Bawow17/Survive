--!strict
-- KnockbackSystem - Applies knockback physics and manages stun duration
-- Handles knockback velocity application and cleanup

local KnockbackSystem = {}

local world: any
local Components: any
local DirtyService: any

-- Component references
local Knockback: any
local Position: any
local Velocity: any

-- Cached query for performance
local knockbackQuery: any

function KnockbackSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	Knockback = Components.Knockback
	Position = Components.Position
	Velocity = Components.Velocity
	
	-- Create cached query for performance (JECS best practice)
	knockbackQuery = world:query(Knockback, Position):cached()
end

function KnockbackSystem.step(dt: number)
	if not world then
		return
	end
	
	local currentTime = tick()
	
	-- Apply knockback to entities using cached query
	for entity, knockback, position in knockbackQuery do
		-- Check if knockback expired
		if currentTime >= knockback.endTime then
			-- Remove knockback component (resumes normal AI)
			world:remove(entity, Knockback)
		else
			-- Movement handled by MovementSystem (uses Knockback component velocity as external)
			-- No direct position/velocity writes here to avoid double integration.
		end
	end
end

return KnockbackSystem
