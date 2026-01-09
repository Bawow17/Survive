--!strict
-- PowerupCollectionSystem - Handles collecting powerups when players get near them

local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)

local PowerupCollectionSystem = {}

local world: any
local Components: any
local DirtyService: any
local ECSWorldService: any
local PowerupEffectSystem: any  -- Will be set after PowerupEffectSystem is loaded

local Position: any
local PowerupData: any
local EntityTypeComponent: any
local PlayerStats: any

-- Cached queries
local powerupQuery: any
local playerQuery: any

function PowerupCollectionSystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService
	
	Position = Components.Position
	PowerupData = Components.PowerupData
	EntityTypeComponent = Components.EntityType
	PlayerStats = Components.PlayerStats
	
	-- Create cached queries
	powerupQuery = world:query(Components.Position, Components.PowerupData, Components.EntityType):cached()
	playerQuery = world:query(Components.Position, Components.PlayerStats):cached()
end

-- Set PowerupEffectSystem reference after it's initialized
function PowerupCollectionSystem.setPowerupEffectSystem(powerupEffectSystemRef: any)
	PowerupEffectSystem = powerupEffectSystemRef
end

-- Collect a powerup
local function collectPowerup(playerEntity: number, powerupEntity: number, powerupType: string)
	if not PowerupEffectSystem then
		warn("[PowerupCollectionSystem] PowerupEffectSystem not initialized yet!")
		return
	end
	
	-- Apply powerup effect to player
	PowerupEffectSystem.applyPowerup(playerEntity, powerupType)
	
	-- Mark powerup as collected (prevents double collection)
	local powerupData = world:get(powerupEntity, PowerupData)
	if powerupData then
		powerupData.collected = true
		DirtyService.setIfChanged(world, powerupEntity, PowerupData, powerupData, "PowerupData")
	end
	
	-- Destroy the powerup entity
	ECSWorldService.DestroyEntity(powerupEntity)
end

function PowerupCollectionSystem.step(dt: number)
	if not world or not PowerupEffectSystem then
		return
	end
	
	-- Check each player against each powerup
	for playerEntity, playerPos, playerStats in playerQuery do
		-- Get pickup range multiplier from player (Explorer passive)
		local pickupRangeMult = 1.0
		if playerStats and playerStats.player then
			pickupRangeMult = playerStats.player:GetAttribute("PickupRangeMultiplier") or 1.0
		end
		
		local collectionRadius = PlayerBalance.BasePickupRange * pickupRangeMult
		local collectionRadiusSq = collectionRadius * collectionRadius
		if not playerStats or not playerStats.player or not playerStats.player.Parent then
			continue
		end
		
		for powerupEntity, powerupPos, powerupData, powerupEntityType in powerupQuery do
			-- Skip if not a powerup or already collected
			if powerupEntityType.type ~= "Powerup" or (powerupData and powerupData.collected) then
				continue
			end
			
			-- MULTIPLAYER: Check ownership - can't collect other players' Health powerups
			if powerupData and powerupData.ownerId and powerupData.ownerId ~= playerEntity then
				continue
			end
			
			-- Calculate distance squared (avoid sqrt for performance)
			local dx = playerPos.x - powerupPos.x
			local dy = playerPos.y - powerupPos.y
			local dz = playerPos.z - powerupPos.z
			local distSq = dx * dx + dy * dy + dz * dz
			
			-- Check if within collection radius
			if distSq <= collectionRadiusSq then
				local powerupType = powerupData and powerupData.powerupType or "Nuke"
				collectPowerup(playerEntity, powerupEntity, powerupType)
			end
		end
	end
end

return PowerupCollectionSystem

