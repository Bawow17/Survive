--!strict

local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local IceTracerConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.IceTracer)

local MobilityLoadoutService = {}

local world: any
local Components: any
local DirtyService: any

local function replicateIceTracerAssets()
	if ModelReplicationService.replicateIceUtilityAssets() then
		return
	end

	warn("[MobilityLoadoutService] Ice utility asset replication did not complete successfully")
end

function MobilityLoadoutService.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	replicateIceTracerAssets()
end

function MobilityLoadoutService.equipStarterMobility(playerEntity: number)
	if not world or not Components or not DirtyService then
		return false
	end

	local mobilityData = {
		equippedMobility = "IceTracer",
		distance = IceTracerConfig.distance,
		cooldown = IceTracerConfig.cooldown,
		duration = IceTracerConfig.duration,
		iceTracerPathPath = IceTracerConfig.iceTracerPathModelPath and ("ReplicatedStorage." .. IceTracerConfig.iceTracerPathModelPath) or nil,
		iceTracerBeam1Path = IceTracerConfig.iceTracerBeam1ModelPath and ("ReplicatedStorage." .. IceTracerConfig.iceTracerBeam1ModelPath) or nil,
		iceTracerBeam2Path = IceTracerConfig.iceTracerBeam2ModelPath and ("ReplicatedStorage." .. IceTracerConfig.iceTracerBeam2ModelPath) or nil,
		iceTracerAnimationPath = IceTracerConfig.iceTracerAnimationModelPath and ("ReplicatedStorage." .. IceTracerConfig.iceTracerAnimationModelPath) or nil,
		iceTracerPathSpacing = IceTracerConfig.pathSpacing,
		iceTracerRampFrames = IceTracerConfig.rampFrames,
		iceTracerTotalFrames = IceTracerConfig.totalFrames,
		iceTracerLookAheadDistance = IceTracerConfig.lookAheadDistance,
		iceTracerPartLifetime = IceTracerConfig.pathPartLifetime,
	}

	DirtyService.setIfChanged(world, playerEntity, Components.MobilityData, mobilityData, "MobilityData")
	DirtyService.setIfChanged(world, playerEntity, Components.MobilityCooldown, { lastUsedTime = 0 }, "MobilityCooldown")
	return true
end

return MobilityLoadoutService
