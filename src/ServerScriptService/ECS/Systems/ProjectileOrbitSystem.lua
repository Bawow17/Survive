--!strict
-- ProjectileOrbitSystem - Makes projectiles orbit around their owner (e.g., Fire Storm fireballs)
-- Updates projectile position and velocity to maintain circular orbit
-- Based on JECS patterns: https://ukendio.github.io/jecs/

local ProjectileOrbitSystem = {}

local world: any
local Components: any
local DirtyService: any

-- Component references
local Position: any
local Velocity: any
local ProjectileOrbit: any
local FacingDirection: any
local EntityType: any

-- Cached query for performance
local orbitQuery: any

-- Helper: Convert table to Vector3
local function tableToVector(data: any): Vector3?
	if typeof(data) == "table" then
		local x = data.x or data.X
		local y = data.y or data.Y
		local z = data.z or data.Z
		if x and y and z then
			return Vector3.new(x, y, z)
		end
	end
	return nil
end

-- Helper: Convert Vector3 to table
local function vectorToTable(vec: Vector3): {x: number, y: number, z: number}
	return {x = vec.X, y = vec.Y, z = vec.Z}
end

-- Initialize the system
function ProjectileOrbitSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	-- Get component references
	Position = Components.Position
	Velocity = Components.Velocity
	ProjectileOrbit = Components.ProjectileOrbit
	FacingDirection = Components.FacingDirection
	EntityType = Components.EntityType
	
	-- Create cached query for orbiting projectiles
	orbitQuery = world:query(ProjectileOrbit, Position, Velocity):cached()
end

-- Step function (called every frame)
function ProjectileOrbitSystem.step(dt: number)
	if not world then
		return
	end
	
	-- Update all orbiting projectiles
	for projectileEntity, orbitData, projectilePos, projectileVel in orbitQuery do
		-- Get owner position
		local ownerEntity = orbitData.ownerEntity
		if not ownerEntity or not world:contains(ownerEntity) then
			-- Owner no longer exists, remove orbit component
			world:remove(projectileEntity, ProjectileOrbit)
			continue
		end
		
		local ownerPos = world:get(ownerEntity, Position)
		if not ownerPos then
			continue
		end
		
		local ownerPosition = tableToVector(ownerPos)
		if not ownerPosition then
			continue
		end
		
		-- Update orbit angle based on orbit speed
		local currentAngle = orbitData.currentAngle or 0
		local orbitSpeed = orbitData.orbitSpeed or 120  -- Degrees per second
		local orbitRadius = orbitData.orbitRadius or 15
		
		-- Increment angle (convert degrees to radians)
		local angleIncrement = math.rad(orbitSpeed) * dt
		currentAngle = currentAngle + angleIncrement
		
		-- Wrap angle to 0-2π range
		if currentAngle > math.pi * 2 then
			currentAngle = currentAngle - math.pi * 2
		end
		
		-- Calculate new orbit position
		local offsetX = math.cos(currentAngle) * orbitRadius
		local offsetZ = math.sin(currentAngle) * orbitRadius
		local newPosition = ownerPosition + Vector3.new(offsetX, 0, offsetZ)
		
		-- Calculate tangent direction (perpendicular to radius, clockwise)
		local tangentDirection = Vector3.new(-math.sin(currentAngle), 0, math.cos(currentAngle)).Unit
		
		-- Update projectile position (orbit system controls position directly)
		DirtyService.setIfChanged(world, projectileEntity, Position, vectorToTable(newPosition), "Position")
		
		-- Keep velocity at zero so MovementSystem doesn't interfere
		DirtyService.setIfChanged(world, projectileEntity, Velocity, {x = 0, y = 0, z = 0}, "Velocity")
		
		-- Update facing direction to match tangent (so projectile points in orbit direction)
		DirtyService.setIfChanged(world, projectileEntity, FacingDirection, vectorToTable(tangentDirection), "FacingDirection")
		
		-- Update orbit data with new angle
		orbitData.currentAngle = currentAngle
		DirtyService.setIfChanged(world, projectileEntity, ProjectileOrbit, orbitData, "ProjectileOrbit")
	end
end

return ProjectileOrbitSystem

