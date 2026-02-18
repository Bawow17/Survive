--!strict
-- ExpOrbSpawner - disabled for kill-only XP mode

local ExpOrbSpawner = {}

local spawnEnabled = true

function ExpOrbSpawner.init(_worldRef: any, _components: any, _ecsWorldService: any, _expSinkSystem: any, _pickupService: any)
	-- Intentionally disabled.
end

function ExpOrbSpawner.setExpSinkSystem(_expSinkSystem: any)
	-- Intentionally disabled.
end

function ExpOrbSpawner.setEnabled(enabled: boolean)
	spawnEnabled = enabled
end

function ExpOrbSpawner.step(_dt: number)
	if not spawnEnabled then
		return
	end
	-- Intentionally disabled.
end

return ExpOrbSpawner
