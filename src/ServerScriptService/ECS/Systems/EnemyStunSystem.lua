--!strict
-- EnemyStunSystem - Applies timed stun debuffs that fully disable enemy movement and attacks

local EnemyStunSystem = {}

local world: any
local Components: any
local DirtyService: any

local EnemyStun: any
local EntityType: any
local Health: any

local stunQuery: any

function EnemyStunSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService

	EnemyStun = Components.EnemyStun
	EntityType = Components.EntityType
	Health = Components.Health

	stunQuery = world:query(EnemyStun, Health):cached()
end

function EnemyStunSystem.applyStun(enemyEntity: number, duration: number, statusId: string?): boolean
	if not world or not EnemyStun or typeof(enemyEntity) ~= "number" then
		return false
	end

	local entityType = EntityType and world:get(enemyEntity, EntityType)
	if not entityType or entityType.type ~= "Enemy" then
		return false
	end
	local health = Health and world:get(enemyEntity, Health)
	if health and typeof(health.current) == "number" and health.current <= 0 then
		return false
	end

	local stunDuration = math.max(duration or 0, 0)
	if stunDuration <= 0 then
		return false
	end

	local now = tick()
	DirtyService.setIfChanged(world, enemyEntity, EnemyStun, {
		statusId = statusId or "Stun",
		startTime = now,
		endTime = now + stunDuration,
	}, "EnemyStun")

	return true
end

function EnemyStunSystem.isStunned(enemyEntity: number, now: number?): boolean
	if not world or not EnemyStun or typeof(enemyEntity) ~= "number" then
		return false
	end

	local stunData = world:get(enemyEntity, EnemyStun)
	if not stunData then
		return false
	end

	local currentTime = typeof(now) == "number" and now or tick()
	return (stunData.endTime or 0) > currentTime
end

function EnemyStunSystem.step(_dt: number)
	if not world or not stunQuery then
		return
	end

	local now = tick()
	for entity, stunData, health in stunQuery do
		if health and typeof(health.current) == "number" and health.current <= 0 then
			world:remove(entity, EnemyStun)
			continue
		end

		if stunData and (stunData.endTime or 0) <= now then
			world:remove(entity, EnemyStun)
		end
	end
end

return EnemyStunSystem
