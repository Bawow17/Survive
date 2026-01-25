--!strict
-- EnemySlowSystem - Handles enemy slow debuffs (duration + multiplier)

local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)

local EnemySlowSystem = {}

local world: any
local Components: any
local DirtyService: any

local EnemySlow: any
local Health: any

local slowQuery: any

function EnemySlowSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService

	EnemySlow = Components.EnemySlow
	Health = Components.Health

	slowQuery = world:query(EnemySlow, Health):cached()
end

function EnemySlowSystem.applySlow(enemyEntity: number, duration: number, multiplier: number, impaleModelPath: string?): boolean
	if not world or not enemyEntity then
		return false
	end
	local now = GameTimeSystem.getGameTime()
	local clampedMultiplier = math.clamp(multiplier or 1.0, 0, 1)
	local slowData = {
		startTime = now,
		endTime = now + math.max(duration or 0, 0),
		duration = duration or 0,
		multiplier = clampedMultiplier,
		impaleModelPath = impaleModelPath,
	}
	DirtyService.setIfChanged(world, enemyEntity, EnemySlow, slowData, "EnemySlow")
	return true
end

function EnemySlowSystem.getSlowMultiplier(enemyEntity: number): number
	if not world then
		return 1.0
	end
	local slow = world:get(enemyEntity, EnemySlow)
	if not slow then
		return 1.0
	end
	local now = GameTimeSystem.getGameTime()
	if slow.endTime and slow.endTime <= now then
		return 1.0
	end
	return slow.multiplier or 1.0
end

function EnemySlowSystem.step(_dt: number)
	if not world then
		return
	end
	local now = GameTimeSystem.getGameTime()
	for entity, slow, health in slowQuery do
		if health and health.current and health.current <= 0 then
			world:remove(entity, EnemySlow)
			continue
		end
		if slow and slow.endTime and slow.endTime <= now then
			world:remove(entity, EnemySlow)
		end
	end
end

return EnemySlowSystem
