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
			-- Apply knockback velocity to position
			local kbVel = knockback.velocity
			if kbVel then
				local newPos = {
					x = position.x + kbVel.x * dt,
					y = position.y + kbVel.y * dt,
					z = position.z + kbVel.z * dt
				}
				
				DirtyService.setIfChanged(world, entity, Position, newPos, "Position")
				
				-- Also set velocity component if it exists (for smooth movement)
				local velocityComponent = world:get(entity, Velocity)
				if velocityComponent then
					DirtyService.setIfChanged(world, entity, Velocity, kbVel, "Velocity")
				end
			end
		end
	end
end

return KnockbackSystem
