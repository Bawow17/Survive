--!strict

local GlacialPathConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.GlacialPath)

local MobilityLoadoutService = {}

local world: any
local Components: any
local DirtyService: any

function MobilityLoadoutService.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
end

function MobilityLoadoutService.equipStarterMobility(playerEntity: number)
	if not world or not Components or not DirtyService then
		return false
	end

	local mobilityData = {
		equippedMobility = "GlacialPath",
		distance = GlacialPathConfig.distance,
		cooldown = GlacialPathConfig.cooldown,
		duration = GlacialPathConfig.duration,
		glacialPathPathPath = GlacialPathConfig.glacialPathPathModelPath and ("ReplicatedStorage." .. GlacialPathConfig.glacialPathPathModelPath) or nil,
		glacialPathBeam1Path = GlacialPathConfig.glacialPathBeam1ModelPath and ("ReplicatedStorage." .. GlacialPathConfig.glacialPathBeam1ModelPath) or nil,
		glacialPathBeam2Path = GlacialPathConfig.glacialPathBeam2ModelPath and ("ReplicatedStorage." .. GlacialPathConfig.glacialPathBeam2ModelPath) or nil,
		glacialPathAnimationPath = GlacialPathConfig.glacialPathAnimationModelPath and ("ReplicatedStorage." .. GlacialPathConfig.glacialPathAnimationModelPath) or nil,
		glacialPathPathSpacing = GlacialPathConfig.pathSpacing,
		glacialPathRampFrames = GlacialPathConfig.rampFrames,
		glacialPathTotalFrames = GlacialPathConfig.totalFrames,
		glacialPathLookAheadDistance = GlacialPathConfig.lookAheadDistance,
		glacialPathPartLifetime = GlacialPathConfig.pathPartLifetime,
	}

	DirtyService.setIfChanged(world, playerEntity, Components.MobilityData, mobilityData, "MobilityData")
	DirtyService.setIfChanged(world, playerEntity, Components.MobilityCooldown, { lastUsedTime = 0 }, "MobilityCooldown")
	return true
end

return MobilityLoadoutService
