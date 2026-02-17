--!strict
-- FacingResolver - shared horizontal facing resolution for server/client parity.

local FacingResolver = {}

local EPSILON = 1e-4

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function toHorizontalUnit(x: any, z: any): Vector3?
	if not isFiniteNumber(x) or not isFiniteNumber(z) then
		return nil
	end
	local vec = Vector3.new(x, 0, z)
	if vec.Magnitude <= EPSILON then
		return nil
	end
	return vec.Unit
end

function FacingResolver.getHorizontalUnitFromFacing(facingData: any): Vector3?
	if typeof(facingData) == "Vector3" then
		return toHorizontalUnit(facingData.X, facingData.Z)
	end
	if typeof(facingData) ~= "table" then
		return nil
	end
	local x = facingData.x or facingData.X
	local z = facingData.z or facingData.Z
	return toHorizontalUnit(x, z)
end

function FacingResolver.getHorizontalUnitFromVelocity(velocityData: any): Vector3?
	if typeof(velocityData) == "Vector3" then
		return toHorizontalUnit(velocityData.X, velocityData.Z)
	end
	if typeof(velocityData) ~= "table" then
		return nil
	end
	local x = velocityData.x or velocityData.X
	local z = velocityData.z or velocityData.Z
	return toHorizontalUnit(x, z)
end

function FacingResolver.resolveEnemyFacing(
	facingData: any,
	desiredVelocityData: any,
	velocityData: any,
	fallbackLook: Vector3?
): Vector3
	local facingDir = FacingResolver.getHorizontalUnitFromFacing(facingData)
	if facingDir then
		return facingDir
	end

	local desiredDir = FacingResolver.getHorizontalUnitFromVelocity(desiredVelocityData)
	if desiredDir then
		return desiredDir
	end

	local velocityDir = FacingResolver.getHorizontalUnitFromVelocity(velocityData)
	if velocityDir then
		return velocityDir
	end

	local fallbackDir = FacingResolver.getHorizontalUnitFromVelocity(fallbackLook)
	if fallbackDir then
		return fallbackDir
	end

	return Vector3.new(0, 0, 1)
end

return FacingResolver
