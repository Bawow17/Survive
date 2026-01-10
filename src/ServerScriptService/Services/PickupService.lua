--!strict
-- PickupService - Server-side pickup records + replication (exp orbs and red sinks)
-- Replaces ExpOrb entity replication with spawn/despawn batches only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemBalance = require(game.ServerScriptService.Balance.ItemBalance)
local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
local GameStateManager = require(game.ServerScriptService.ECS.Systems.GameStateManager)

local PickupService = {}

type PickupRecord = {
	id: number,
	kind: string,
	position: Vector3,
	value: number,
	spawnedAt: number,
	expiresAt: number,
	ownerEntity: number?,
	isSink: boolean?,
	claimed: boolean?,
	recipients: {[Player]: boolean},
}

local world: any
local Components: any
local ExpSystem: any
local ExpSinkSystem: any
local getPlayerEntityFromPlayer: ((Player) -> number?)?

local Position: any
local PlayerStats: any
local MagnetSession: any
local playerQuery: any

local pickups: {[number]: PickupRecord} = {}
local pickupIdCounter = 0

local gridCells: {[string]: {[number]: boolean}} = {}
local pickupCell: {[number]: string} = {}
local knownByPlayer: {[Player]: {[number]: boolean}} = setmetatable({}, { __mode = "k" })

local remotesFolder: Instance
local pickupRemotesFolder: Instance
local PickupsSpawnBatch: RemoteEvent
local PickupsDespawnBatch: RemoteEvent
local PickupsValueUpdate: RemoteEvent
local PickupRequest: RemoteEvent

local GRID_SIZE = 8
local MERGE_DISTANCE = 6
local MERGE_DISTANCE_SQ = MERGE_DISTANCE * MERGE_DISTANCE
local MERGE_TIME_WINDOW = 0.35

local SPAWN_SEND_RADIUS = 200
local DESPAWN_SEND_RADIUS = 240
local REFRESH_INTERVAL = 0.5

local REQUEST_DISTANCE_BUFFER = 3
local MAGNET_RADIUS_MULTIPLIER = 6

local function ensurePlayerKnown(player: Player): {[number]: boolean}
	local known = knownByPlayer[player]
	if not known then
		known = {}
		knownByPlayer[player] = known
	end
	return known
end

local function gridKey(cellX: number, cellZ: number): string
	return string.format("%d,%d", cellX, cellZ)
end

local function positionToCell(position: Vector3): (number, number)
	return math.floor(position.X / GRID_SIZE), math.floor(position.Z / GRID_SIZE)
end

local function addToGrid(pickupId: number, position: Vector3)
	local cellX, cellZ = positionToCell(position)
	local key = gridKey(cellX, cellZ)
	local cell = gridCells[key]
	if not cell then
		cell = {}
		gridCells[key] = cell
	end
	cell[pickupId] = true
	pickupCell[pickupId] = key
end

local function removeFromGrid(pickupId: number)
	local key = pickupCell[pickupId]
	if not key then
		return
	end
	local cell = gridCells[key]
	if cell then
		cell[pickupId] = nil
		if not next(cell) then
			gridCells[key] = nil
		end
	end
	pickupCell[pickupId] = nil
end

local function buildSpawnPayload(record: PickupRecord): {[string]: any}
	return {
		id = record.id,
		kind = record.kind,
		pos = record.position,
		value = record.value,
		expiresAt = record.expiresAt,
		isSink = record.isSink == true,
	}
end

local function sendSpawnBatch(player: Player, payloads: {any})
	if #payloads == 0 then
		return
	end
	PickupsSpawnBatch:FireClient(player, payloads)
end

local function sendDespawnBatch(player: Player, ids: {number})
	if #ids == 0 then
		return
	end
	PickupsDespawnBatch:FireClient(player, ids)
end

local function sendValueUpdate(record: PickupRecord)
	if not record.recipients or not next(record.recipients) then
		return
	end
	local update = {
		{ id = record.id, value = record.value },
	}
	for player in pairs(record.recipients) do
		if player and player.Parent == Players then
			PickupsValueUpdate:FireClient(player, update)
		end
	end
end

local function isPlayerValid(playerStats: any): boolean
	return playerStats and playerStats.player and playerStats.player.Parent == Players
end

local function shouldSendToPlayer(record: PickupRecord, playerEntity: number): boolean
	if record.ownerEntity and record.ownerEntity ~= playerEntity then
		return false
	end
	return true
end

local function getPlayerPosition(playerEntity: number): Vector3?
	if not world then
		return nil
	end
	local pos = world:get(playerEntity, Position)
	if not pos then
		return nil
	end
	return Vector3.new(pos.x, pos.y, pos.z)
end

local function isMagnetActive(playerEntity: number): boolean
	if not world then
		return false
	end
	local session = world:get(playerEntity, MagnetSession)
	if not session then
		return false
	end
	local now = GameTimeSystem.getGameTime()
	return session.endTime and session.endTime > now
end

local function buildPickupRadius(player: Player): (number, number)
	local pickupRangeMult = player:GetAttribute("PickupRangeMultiplier") or 1.0
	local baseRadius = PlayerBalance.BasePickupRange * pickupRangeMult
	local magnetRadius = baseRadius * MAGNET_RADIUS_MULTIPLIER
	return baseRadius, magnetRadius
end

local function findMergeTarget(kind: string, ownerEntity: number?, position: Vector3, now: number): PickupRecord?
	local cellX, cellZ = positionToCell(position)
	for dx = -1, 1 do
		for dz = -1, 1 do
			local key = gridKey(cellX + dx, cellZ + dz)
			local cell = gridCells[key]
			if cell then
				for pickupId in pairs(cell) do
					local record = pickups[pickupId]
					if record and not record.claimed then
						if record.kind == kind and record.ownerEntity == ownerEntity then
							if (now - record.spawnedAt) <= MERGE_TIME_WINDOW then
								local delta = record.position - position
								if (delta.X * delta.X + delta.Z * delta.Z) <= MERGE_DISTANCE_SQ then
									return record
								end
							end
						end
					end
				end
			end
		end
	end
	return nil
end

local function isPlayerInGame(player: Player): boolean
	if not GameStateManager or not GameStateManager.isPlayerInGame then
		return true
	end
	return GameStateManager.isPlayerInGame(player)
end

local function gatherPickupsNear(position: Vector3, radius: number, playerEntity: number): {PickupRecord}
	local results = {}
	local cellRadius = math.ceil(radius / GRID_SIZE)
	local baseX, baseZ = positionToCell(position)
	local radiusSq = radius * radius

	for dx = -cellRadius, cellRadius do
		for dz = -cellRadius, cellRadius do
			local key = gridKey(baseX + dx, baseZ + dz)
			local cell = gridCells[key]
			if cell then
				for pickupId in pairs(cell) do
					local record = pickups[pickupId]
					if record and not record.claimed then
						if shouldSendToPlayer(record, playerEntity) then
							local delta = record.position - position
							local distSq = delta.X * delta.X + delta.Z * delta.Z + delta.Y * delta.Y
							if distSq <= radiusSq then
								table.insert(results, record)
							end
						end
					end
				end
			end
		end
	end

	return results
end

local function flushVisibilityForPlayer(player: Player, playerEntity: number, playerPos: Vector3)
	local known = ensurePlayerKnown(player)
	local spawnPayloads = {}
	local despawnIds = {}

	local nearby = gatherPickupsNear(playerPos, SPAWN_SEND_RADIUS, playerEntity)
	for _, record in ipairs(nearby) do
		if not known[record.id] then
			known[record.id] = true
			record.recipients[player] = true
			table.insert(spawnPayloads, buildSpawnPayload(record))
		end
	end

	-- Despawn pickups that are far away to keep client maps small.
	local despawnRadiusSq = DESPAWN_SEND_RADIUS * DESPAWN_SEND_RADIUS
	for pickupId in pairs(known) do
		local record = pickups[pickupId]
		if not record or record.claimed then
			known[pickupId] = nil
		else
			local delta = record.position - playerPos
			local distSq = delta.X * delta.X + delta.Z * delta.Z + delta.Y * delta.Y
			if distSq > despawnRadiusSq or not shouldSendToPlayer(record, playerEntity) then
				known[pickupId] = nil
				record.recipients[player] = nil
				table.insert(despawnIds, pickupId)
			end
		end
	end

	sendSpawnBatch(player, spawnPayloads)
	sendDespawnBatch(player, despawnIds)
end

local function despawnPickupInternal(record: PickupRecord)
	removeFromGrid(record.id)
	pickups[record.id] = nil

	if record.recipients and next(record.recipients) then
		local perPlayer = {}
		for player in pairs(record.recipients) do
			if player and player.Parent == Players then
				local list = perPlayer[player]
				if not list then
					list = {}
					perPlayer[player] = list
				end
				table.insert(list, record.id)
			end
		end
		for player, list in pairs(perPlayer) do
			sendDespawnBatch(player, list)
			local known = knownByPlayer[player]
			if known then
				for _, pickupId in ipairs(list) do
					known[pickupId] = nil
				end
			end
		end
	end
end

function PickupService.init(worldRef: any, components: any, expSystemRef: any, getEntityFromPlayer: (Player) -> number?)
	world = worldRef
	Components = components
	ExpSystem = expSystemRef
	getPlayerEntityFromPlayer = getEntityFromPlayer

	Position = Components.Position
	PlayerStats = Components.PlayerStats
	MagnetSession = Components.MagnetSession

	playerQuery = world:query(Components.Position, Components.PlayerStats):cached()

	remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	pickupRemotesFolder = remotesFolder:FindFirstChild("Pickups") or Instance.new("Folder")
	pickupRemotesFolder.Name = "Pickups"
	pickupRemotesFolder.Parent = remotesFolder

	PickupsSpawnBatch = pickupRemotesFolder:FindFirstChild("PickupsSpawnBatch") :: RemoteEvent
	if not PickupsSpawnBatch then
		PickupsSpawnBatch = Instance.new("RemoteEvent")
		PickupsSpawnBatch.Name = "PickupsSpawnBatch"
		PickupsSpawnBatch.Parent = pickupRemotesFolder
	end

	PickupsDespawnBatch = pickupRemotesFolder:FindFirstChild("PickupsDespawnBatch") :: RemoteEvent
	if not PickupsDespawnBatch then
		PickupsDespawnBatch = Instance.new("RemoteEvent")
		PickupsDespawnBatch.Name = "PickupsDespawnBatch"
		PickupsDespawnBatch.Parent = pickupRemotesFolder
	end

	PickupsValueUpdate = pickupRemotesFolder:FindFirstChild("PickupsValueUpdate") :: RemoteEvent
	if not PickupsValueUpdate then
		PickupsValueUpdate = Instance.new("RemoteEvent")
		PickupsValueUpdate.Name = "PickupsValueUpdate"
		PickupsValueUpdate.Parent = pickupRemotesFolder
	end

	PickupRequest = pickupRemotesFolder:FindFirstChild("PickupRequest") :: RemoteEvent
	if not PickupRequest then
		PickupRequest = Instance.new("RemoteEvent")
		PickupRequest.Name = "PickupRequest"
		PickupRequest.Parent = pickupRemotesFolder
	end

	PickupRequest.OnServerEvent:Connect(function(player: Player, pickupId: number)
		if typeof(pickupId) ~= "number" then
			return
		end
		if not getPlayerEntityFromPlayer then
			return
		end
		local playerEntity = getPlayerEntityFromPlayer(player)
		if not playerEntity then
			return
		end
		local record = pickups[pickupId]
		if not record or record.claimed then
			return
		end
		if record.expiresAt <= GameTimeSystem.getGameTime() then
			despawnPickupInternal(record)
			return
		end
		if record.ownerEntity and record.ownerEntity ~= playerEntity then
			return
		end

		local playerPos = getPlayerPosition(playerEntity)
		if not playerPos then
			return
		end

		local baseRadius, magnetRadius = buildPickupRadius(player)
		local allowedRadius = baseRadius
		if not record.isSink and isMagnetActive(playerEntity) then
			allowedRadius = math.max(allowedRadius, magnetRadius)
		end
		allowedRadius = allowedRadius + REQUEST_DISTANCE_BUFFER
		local allowedSq = allowedRadius * allowedRadius

		local delta = record.position - playerPos
		local distSq = delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z
		if distSq > allowedSq then
			return
		end

		record.claimed = true

		if ExpSystem then
			local expMult = player:GetAttribute("ExpMultiplier") or 1.0
			local finalValue = math.floor(record.value * expMult)
			if finalValue > 0 then
				ExpSystem.addExperience(playerEntity, finalValue)
			end
		end

		if record.isSink and ExpSinkSystem and ExpSinkSystem.onSinkCollected then
			ExpSinkSystem.onSinkCollected(record.id, playerEntity)
		end

		despawnPickupInternal(record)
	end)
end

function PickupService.setExpSinkSystem(expSinkSystemRef: any)
	ExpSinkSystem = expSinkSystemRef
end

function PickupService.spawnPickup(position: Vector3, value: number, kind: string, ownerEntity: number?, lifetime: number?, opts: {[string]: any}?): number?
	if not position or typeof(position) ~= "Vector3" then
		return nil
	end

	local now = GameTimeSystem.getGameTime()
	local expireAt = now + (lifetime or ItemBalance.OrbLifetime)
	local isSink = opts and opts.isSink
	local allowMerge = not isSink and (opts and opts.allowMerge ~= false or opts == nil)

	if allowMerge then
		local mergeTarget = findMergeTarget(kind, ownerEntity, position, now)
		if mergeTarget then
			mergeTarget.value = mergeTarget.value + value
			mergeTarget.expiresAt = math.max(mergeTarget.expiresAt, expireAt)
			sendValueUpdate(mergeTarget)
			return mergeTarget.id
		end
	end

	pickupIdCounter += 1
	local pickupId = pickupIdCounter
	local record: PickupRecord = {
		id = pickupId,
		kind = kind,
		position = position,
		value = value,
		spawnedAt = now,
		expiresAt = expireAt,
		ownerEntity = ownerEntity,
		isSink = isSink == true,
		recipients = {},
	}
	pickups[pickupId] = record
	addToGrid(pickupId, position)

	for playerEntity, pos, playerStats in playerQuery do
		if isPlayerValid(playerStats) then
			local player = playerStats.player
			if not isPlayerInGame(player) then
				continue
			end
			if shouldSendToPlayer(record, playerEntity) then
				local playerPos = Vector3.new(pos.x, pos.y, pos.z)
				local delta = record.position - playerPos
				local distSq = delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z
				if distSq <= SPAWN_SEND_RADIUS * SPAWN_SEND_RADIUS then
					local known = ensurePlayerKnown(player)
					if not known[record.id] then
						known[record.id] = true
						record.recipients[player] = true
						sendSpawnBatch(player, { buildSpawnPayload(record) })
					end
				end
			end
		end
	end

	return pickupId
end

function PickupService.spawnExpPickup(orbType: string, position: Vector3, ownerEntity: number?, overrideValue: number?): number?
	local orbConfig = ItemBalance.OrbTypes[orbType]
	if not orbConfig then
		orbConfig = ItemBalance.OrbTypes.Blue
	end
	local value = overrideValue or orbConfig.expAmount
	local kind = "exp" .. orbType
	return PickupService.spawnPickup(position, value, kind, ownerEntity, ItemBalance.OrbLifetime, {
		isSink = orbType == "Red",
	})
end

function PickupService.updatePickupValue(pickupId: number, newValue: number)
	local record = pickups[pickupId]
	if not record or record.claimed then
		return
	end
	record.value = newValue
	sendValueUpdate(record)
end

function PickupService.getPickupValue(pickupId: number): number?
	local record = pickups[pickupId]
	return record and record.value or nil
end

function PickupService.despawnPickup(pickupId: number)
	local record = pickups[pickupId]
	if not record then
		return
	end
	despawnPickupInternal(record)
	if record.isSink and ExpSinkSystem and ExpSinkSystem.onSinkRemoved then
		ExpSinkSystem.onSinkRemoved(pickupId)
	end
end

function PickupService.countNonSinkPickupsForOwner(ownerEntity: number): number
	local count = 0
	for _, record in pairs(pickups) do
		if record.ownerEntity == ownerEntity and not record.isSink and not record.claimed then
			count += 1
		end
	end
	return count
end

function PickupService.cleanupPlayer(player: Player, playerEntity: number?)
	if player then
		knownByPlayer[player] = nil
	end
	local toDespawn = {}
	for _, record in pairs(pickups) do
		if record.recipients then
			record.recipients[player] = nil
		end
		if playerEntity and record.ownerEntity == playerEntity then
			table.insert(toDespawn, record.id)
		end
	end
	for _, pickupId in ipairs(toDespawn) do
		PickupService.despawnPickup(pickupId)
	end
end

local refreshAccumulator = 0

function PickupService.step(dt: number)
	if not world then
		return
	end

	local now = GameTimeSystem.getGameTime()
	local expiredIds = {}
	for pickupId, record in pairs(pickups) do
		if record.expiresAt <= now and not record.claimed then
			table.insert(expiredIds, pickupId)
		end
	end
	for _, pickupId in ipairs(expiredIds) do
		local record = pickups[pickupId]
		if record then
			despawnPickupInternal(record)
			if record.isSink and ExpSinkSystem and ExpSinkSystem.onSinkRemoved then
				ExpSinkSystem.onSinkRemoved(record.id)
			end
		end
	end

	refreshAccumulator += dt
	if refreshAccumulator < REFRESH_INTERVAL then
		return
	end
	refreshAccumulator = 0

	for playerEntity, pos, playerStats in playerQuery do
		if isPlayerValid(playerStats) then
			local player = playerStats.player
			if not isPlayerInGame(player) then
				continue
			end
			local playerPos = Vector3.new(pos.x, pos.y, pos.z)
			flushVisibilityForPlayer(player, playerEntity, playerPos)
		end
	end
end

return PickupService
