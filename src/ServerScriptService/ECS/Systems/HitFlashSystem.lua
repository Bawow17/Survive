--!strict
-- HitFlashSystem - Manages hit flash timers and cleanup
-- Removes expired hit flash components

local HitFlashSystem = {}

local world: any
local Components: any

-- Component references
local HitFlash: any

-- Cached query for performance
local flashQuery: any

function HitFlashSystem.init(worldRef: any, components: any)
	world = worldRef
	Components = components
	
	HitFlash = Components.HitFlash
	
	-- Create cached query for performance (JECS best practice)
	flashQuery = world:query(HitFlash):cached()
end

function HitFlashSystem.step(_dt: number)
	if not world then
		return
	end
	
	local currentTime = tick()
	
	-- Clean up expired hit flashes using cached query
	for entity, flash in flashQuery do
		if flash.endTime and currentTime >= flash.endTime then
			world:remove(entity, HitFlash)
		end
	end
end

return HitFlashSystem
