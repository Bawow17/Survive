--!strict
-- ExpSinkSystem - Manages red orb exp-sink when MaxOrbs cap is reached
-- Uses PickupService (spawn/despawn-only) instead of ExpOrb entities.

local ItemBalance = require(game.ServerScriptService.Balance.ItemBalance)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
local PauseSystem = require(game.ServerScriptService.ECS.Systems.PauseSystem)

local ExpSinkSystem = {}

local world: any
local Components: any
local PickupService: any

local Position: any

-- MULTIPLAYER: Per-player sink tracking
local playerSinks: {[number]: {
	sinkPickupId: number?,
	lastSinkCreatedAt: number,
	pendingBufferedExp: number,
	sinkCreationTime: number?,
	lastTeleportTime: number?,
}} = {}

local function getPlayerSinkData(playerEntity: number)
	if not playerSinks[playerEntity] then
		playerSinks[playerEntity] = {
			sinkPickupId = nil,
			lastSinkCreatedAt = 0,
			pendingBufferedExp = 0,
			sinkCreationTime = nil,
			lastTeleportTime = nil,
		}
	end
	return playerSinks[playerEntity]
end

function ExpSinkSystem.init(worldRef: any, components: any, pickupService: any)
	world = worldRef
	Components = components
	PickupService = pickupService

	Position = Components.Position
end

-- MULTIPLAYER: Count non-sink pickups for a specific player
function ExpSinkSystem.countPlayerOrbs(playerEntity: number): number
	if not PickupService then
		return 0
	end
	return PickupService.countNonSinkPickupsForOwner(playerEntity)
end

function ExpSinkSystem.shouldAbsorb(playerEntity: number): boolean
	if not ItemBalance.ExpSink.Enabled or not playerEntity then
		return false
	end
	local orbCount = ExpSinkSystem.countPlayerOrbs(playerEntity)
	return orbCount >= ItemBalance.MaxOrbs
end

local function spawnRedPickup(expAmount: number, playerEntity: number): number?
	if not world or not PickupService then
		return nil
	end

	local playerPos = world:get(playerEntity, Position)
	if not playerPos then
		return nil
	end

	local sinkData = getPlayerSinkData(playerEntity)

	local angle = math.random() * math.pi * 2
	local distance = ItemBalance.ExpSink.TeleportRadius
	local offsetX = math.cos(angle) * distance
	local offsetZ = math.sin(angle) * distance

	local spawnPos = Vector3.new(
		playerPos.x + offsetX,
		playerPos.y + (ItemBalance.OrbHeightOffset or 2.0) + 1.0,
		playerPos.z + offsetZ
	)

	local totalExp = expAmount + sinkData.pendingBufferedExp
	sinkData.pendingBufferedExp = 0

	local pickupId = PickupService.spawnExpPickup("Red", spawnPos, playerEntity, totalExp)
	if not pickupId then
		return nil
	end

	local now = GameTimeSystem.getGameTime()
	sinkData.sinkPickupId = pickupId
	sinkData.sinkCreationTime = now
	sinkData.lastTeleportTime = nil

	return pickupId
end

function ExpSinkSystem.depositExp(amount: number, playerEntity: number)
	if not ItemBalance.ExpSink.Enabled or not playerEntity or not PickupService then
		return
	end

	local sinkData = getPlayerSinkData(playerEntity)
	local now = GameTimeSystem.getGameTime()

	if sinkData.sinkPickupId then
		local currentValue = PickupService.getPickupValue(sinkData.sinkPickupId)
		if currentValue ~= nil then
			PickupService.updatePickupValue(sinkData.sinkPickupId, currentValue + amount)
			return
		end
		sinkData.sinkPickupId = nil
	end

	local cooldownActive = (now - sinkData.lastSinkCreatedAt) < ItemBalance.ExpSink.SinkCooldown
	if cooldownActive then
		sinkData.pendingBufferedExp = sinkData.pendingBufferedExp + amount
		return
	end

	local newSink = spawnRedPickup(amount, playerEntity)
	if newSink then
		sinkData.lastSinkCreatedAt = now
	else
		sinkData.pendingBufferedExp = sinkData.pendingBufferedExp + amount
	end
end

function ExpSinkSystem.onSinkCollected(pickupId: number, playerEntity: number?)
	local now = GameTimeSystem.getGameTime()

	if playerEntity then
		local sinkData = playerSinks[playerEntity]
		if sinkData and sinkData.sinkPickupId == pickupId then
			sinkData.sinkPickupId = nil
			sinkData.lastSinkCreatedAt = now
			sinkData.sinkCreationTime = nil
			sinkData.lastTeleportTime = nil
			return
		end
	end

	for _, sinkData in pairs(playerSinks) do
		if sinkData.sinkPickupId == pickupId then
			sinkData.sinkPickupId = nil
			sinkData.lastSinkCreatedAt = now
			sinkData.sinkCreationTime = nil
			sinkData.lastTeleportTime = nil
			return
		end
	end
end

function ExpSinkSystem.onSinkRemoved(pickupId: number)
	for _, sinkData in pairs(playerSinks) do
		if sinkData.sinkPickupId == pickupId then
			sinkData.sinkPickupId = nil
			sinkData.sinkCreationTime = nil
			sinkData.lastTeleportTime = nil
			return
		end
	end
end

function ExpSinkSystem.cleanupEntity(entity: number)
	playerSinks[entity] = nil
end

local function teleportSinkToPlayer(playerEntity: number): boolean
	if not world or not PickupService then
		return false
	end

	local sinkData = getPlayerSinkData(playerEntity)
	if not sinkData.sinkPickupId then
		return false
	end

	local playerPos = world:get(playerEntity, Position)
	if not playerPos then
		return false
	end

	local currentValue = PickupService.getPickupValue(sinkData.sinkPickupId)
	if currentValue == nil then
		sinkData.sinkPickupId = nil
		return false
	end

	local angle = math.random() * math.pi * 2
	local distance = ItemBalance.ExpSink.TeleportRadius
	local offsetX = math.cos(angle) * distance
	local offsetZ = math.sin(angle) * distance

	local newPos = Vector3.new(
		playerPos.x + offsetX,
		playerPos.y + (ItemBalance.OrbHeightOffset or 2.0) + 1.0,
		playerPos.z + offsetZ
	)

	PickupService.despawnPickup(sinkData.sinkPickupId)
	local newId = PickupService.spawnExpPickup("Red", newPos, playerEntity, currentValue)
	if not newId then
		sinkData.sinkPickupId = nil
		return false
	end

	local now = GameTimeSystem.getGameTime()
	sinkData.sinkPickupId = newId
	sinkData.lastTeleportTime = now
	if not sinkData.sinkCreationTime then
		sinkData.sinkCreationTime = now
	end

	return true
end

function ExpSinkSystem.step(dt: number)
	if not ItemBalance.ExpSink.Enabled or not ItemBalance.ExpSink.TeleportEnabled then
		return
	end

	if PauseSystem.isPaused() then
		return
	end

	local now = GameTimeSystem.getGameTime()

	for playerEntity, sinkData in pairs(playerSinks) do
		if not sinkData.sinkPickupId then
			continue
		end

		if not sinkData.sinkCreationTime then
			sinkData.sinkCreationTime = now
			sinkData.lastTeleportTime = nil
		end

		if now - sinkData.sinkCreationTime < ItemBalance.ExpSink.InitialTeleportDelay then
			continue
		end

		if not sinkData.lastTeleportTime then
			teleportSinkToPlayer(playerEntity)
		elseif now - sinkData.lastTeleportTime >= ItemBalance.ExpSink.TeleportInterval then
			teleportSinkToPlayer(playerEntity)
		end
	end
end

return ExpSinkSystem
