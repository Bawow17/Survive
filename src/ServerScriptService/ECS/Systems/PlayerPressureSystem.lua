--!strict
-- PlayerPressureSystem (legacy)
-- Adaptive player-stat pressure scaling has been removed.
-- Keep this module as a no-op shim so legacy requires do not break.

local PlayerPressureSystem = {}

function PlayerPressureSystem.init(_worldRef: any, _components: any, _dirtyService: any)
	return
end

function PlayerPressureSystem.step(_dt: number)
	return
end

return PlayerPressureSystem
