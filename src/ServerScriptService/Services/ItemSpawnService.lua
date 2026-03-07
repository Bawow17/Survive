--!strict
-- ItemSpawnService - transient animated launch effects before a real pickup is created.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ItemSpawnService = {}

type SpawnRecord = {
	id: number,
	itemId: string,
	origin: Vector3,
	landingPosition: Vector3,
	auraAttachmentOffset: Vector3,
	spawnedAt: number,
	landAt: number,
	despawnAt: number,
	launchDuration: number,
	lingerDuration: number,
	ownerEntity: number?,
	recipients: {[Player]: boolean},
	pickupFactory: ((Vector3) -> number?)?,
	landed: boolean,
}

local world: any
local Components: any

local Position: any
local PlayerStats: any
local playerQuery: any

local activeSpawns: {[number]: SpawnRecord} = {}
local spawnIdCounter = 0
local refreshAccumulator = 0
local rng = Random.new()

local itemSpawnRemotesFolder: Folder
local ItemSpawnsSpawnBatch: RemoteEvent
local ItemSpawnsDespawnBatch: RemoteEvent

local DEFAULT_LAUNCH_DURATION = 1.0
local DEFAULT_LINGER_DURATION = 0.1
local DEFAULT_LANDING_SEARCH_RADIUS = 10.0
local MIN_LANDING_DISTANCE = 5.0
local LANDING_SAMPLE_COUNT = 12
local SEND_RADIUS = 200 -- Keep in sync with PickupService.SPAWN_SEND_RADIUS.
local SEND_RADIUS_SQ = SEND_RADIUS * SEND_RADIUS
local REFRESH_INTERVAL = 0.1
local COMMON_ITEM_AURA_PATH = "ReplicatedStorage.ContentDrawer.ItemModels.VFX.CommonItemAura"

local function isPlayerValid(playerStats: any): boolean
	return playerStats and playerStats.player and playerStats.player.Parent == Players
end

local function sendSpawnBatch(player: Player, payloads: {any})
	if #payloads <= 0 then
		return
	end
	ItemSpawnsSpawnBatch:FireClient(player, payloads)
end

local function sendDespawnBatch(player: Player, ids: {number})
	if #ids <= 0 then
		return
	end
	ItemSpawnsDespawnBatch:FireClient(player, ids)
end

local function buildSpawnPayload(record: SpawnRecord): {[string]: any}
	return {
		id = record.id,
		itemId = record.itemId,
		origin = record.origin,
		landingPos = record.landingPosition,
		auraAttachmentOffset = record.auraAttachmentOffset,
		spawnedAt = record.spawnedAt,
		landAt = record.landAt,
		despawnAt = record.despawnAt,
		launchDuration = record.launchDuration,
		lingerDuration = record.lingerDuration,
		vfxPath = COMMON_ITEM_AURA_PATH,
	}
end

local function ensureRemotes()
	local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	local folder = remotesFolder:FindFirstChild("ItemSpawns")
	if folder and not folder:IsA("Folder") then
		folder:Destroy()
		folder = nil
	end
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ItemSpawns"
		folder.Parent = remotesFolder
	end
	itemSpawnRemotesFolder = folder

	local spawnRemote = itemSpawnRemotesFolder:FindFirstChild("ItemSpawnsSpawnBatch")
	if spawnRemote and not spawnRemote:IsA("RemoteEvent") then
		spawnRemote:Destroy()
		spawnRemote = nil
	end
	if not spawnRemote then
		spawnRemote = Instance.new("RemoteEvent")
		spawnRemote.Name = "ItemSpawnsSpawnBatch"
		spawnRemote.Parent = itemSpawnRemotesFolder
	end
	ItemSpawnsSpawnBatch = spawnRemote

	local despawnRemote = itemSpawnRemotesFolder:FindFirstChild("ItemSpawnsDespawnBatch")
	if despawnRemote and not despawnRemote:IsA("RemoteEvent") then
		despawnRemote:Destroy()
		despawnRemote = nil
	end
	if not despawnRemote then
		despawnRemote = Instance.new("RemoteEvent")
		despawnRemote.Name = "ItemSpawnsDespawnBatch"
		despawnRemote.Parent = itemSpawnRemotesFolder
	end
	ItemSpawnsDespawnBatch = despawnRemote
end

local function sendSpawnToPlayer(record: SpawnRecord, player: Player)
	if not player or player.Parent ~= Players then
		return
	end
	if record.recipients[player] then
		return
	end
	record.recipients[player] = true
	sendSpawnBatch(player, { buildSpawnPayload(record) })
end

local function sendSpawnToNearbyPlayers(record: SpawnRecord)
	if not playerQuery then
		return
	end

	for _, pos, playerStats in playerQuery do
		if not isPlayerValid(playerStats) then
			continue
		end

		local playerPos = Vector3.new(pos.x, pos.y, pos.z)
		local delta = record.origin - playerPos
		local distSq = (delta.X * delta.X) + (delta.Y * delta.Y) + (delta.Z * delta.Z)
		if distSq <= SEND_RADIUS_SQ then
			sendSpawnToPlayer(record, playerStats.player)
		end
	end
end

local function cleanupRecord(record: SpawnRecord)
	activeSpawns[record.id] = nil

	local despawnIds = { record.id }
	for player in pairs(record.recipients) do
		if player and player.Parent == Players then
			sendDespawnBatch(player, despawnIds)
		end
	end
end

local function buildRaycastParams(ignoreInstance: Instance?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	if ignoreInstance then
		params.FilterDescendantsInstances = { ignoreInstance }
	end
	return params
end

local function collectGroundHit(
	results: {Vector3},
	basePosition: Vector3,
	lift: number,
	raycastParams: RaycastParams
)
	local castOrigin = basePosition + Vector3.new(0, 6, 0)
	local castDirection = Vector3.new(0, -16, 0)
	local result = Workspace:Raycast(castOrigin, castDirection, raycastParams)
	if result then
		table.insert(results, result.Position + Vector3.new(0, lift, 0))
	end
end

local function resolveLandingPosition(
	originPosition: Vector3,
	searchRadius: number,
	ignoreInstance: Instance?,
	lift: number
): Vector3
	local raycastParams = buildRaycastParams(ignoreInstance)
	local outerCandidates = {}
	local innerCandidates = {}
	local outerRadius = math.max(searchRadius, 0)
	local innerRadius = math.min(MIN_LANDING_DISTANCE, outerRadius)

	for _ = 1, LANDING_SAMPLE_COUNT do
		local angle = rng:NextNumber() * math.pi * 2
		if outerRadius > innerRadius then
			local distance = innerRadius + (rng:NextNumber() * (outerRadius - innerRadius))
			local offset = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
			collectGroundHit(outerCandidates, originPosition + offset, lift, raycastParams)
		else
			local distance = math.sqrt(rng:NextNumber()) * outerRadius
			local offset = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
			collectGroundHit(outerCandidates, originPosition + offset, lift, raycastParams)
		end
	end

	if #outerCandidates > 0 then
		return outerCandidates[rng:NextInteger(1, #outerCandidates)]
	end

	if innerRadius > 0 and outerRadius > innerRadius then
		for _ = 1, LANDING_SAMPLE_COUNT do
			local angle = rng:NextNumber() * math.pi * 2
			local distance = math.sqrt(rng:NextNumber()) * innerRadius
			local offset = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
			collectGroundHit(innerCandidates, originPosition + offset, lift, raycastParams)
		end
	end

	if #innerCandidates > 0 then
		return innerCandidates[rng:NextInteger(1, #innerCandidates)]
	end

	local fallbackCandidates = {}
	collectGroundHit(fallbackCandidates, originPosition, lift, raycastParams)
	if #fallbackCandidates > 0 then
		return fallbackCandidates[#fallbackCandidates]
	end

	return originPosition + Vector3.new(0, lift, 0)
end

function ItemSpawnService.init(worldRef: any, components: any)
	world = worldRef
	Components = components

	Position = Components.Position
	PlayerStats = Components.PlayerStats
	playerQuery = world:query(Components.Position, Components.PlayerStats):cached()

	ensureRemotes()
end

function ItemSpawnService.spawnAnimatedItemDrop(request: {[string]: any}): (boolean, string, number?)
	if typeof(request) ~= "table" then
		return false, "Invalid spawn request", nil
	end

	local itemId = request.itemId
	if typeof(itemId) ~= "string" or itemId == "" then
		return false, "Missing item id", nil
	end

	local originPosition = request.originPosition
	if typeof(originPosition) ~= "Vector3" then
		return false, "Missing origin position", nil
	end

	local pickupFactory = request.pickupFactory
	if typeof(pickupFactory) ~= "function" then
		return false, "Missing pickup factory", nil
	end

	local launchDuration = request.launchDuration
	if typeof(launchDuration) ~= "number" or launchDuration <= 0 then
		launchDuration = DEFAULT_LAUNCH_DURATION
	end

	local lingerDuration = request.lingerDuration
	if typeof(lingerDuration) ~= "number" or lingerDuration < 0 then
		lingerDuration = DEFAULT_LINGER_DURATION
	end

	local landingSearchRadius = request.landingSearchRadius
	if typeof(landingSearchRadius) ~= "number" or landingSearchRadius < 0 then
		landingSearchRadius = DEFAULT_LANDING_SEARCH_RADIUS
	end

	local landingLift = request.landingLift
	if typeof(landingLift) ~= "number" or landingLift < 0 then
		landingLift = 0
	end

	local auraAttachmentOffset = request.auraAttachmentOffset
	if typeof(auraAttachmentOffset) ~= "Vector3" then
		auraAttachmentOffset = Vector3.zero
	end

	local ignoreInstance = if typeof(request.ignoreInstance) == "Instance"
		then request.ignoreInstance
		else nil

	local now = Workspace:GetServerTimeNow()
	local landingPosition = resolveLandingPosition(
		originPosition,
		landingSearchRadius,
		ignoreInstance,
		landingLift
	)

	spawnIdCounter += 1
	local record: SpawnRecord = {
		id = spawnIdCounter,
		itemId = itemId,
		origin = originPosition,
		landingPosition = landingPosition,
		auraAttachmentOffset = auraAttachmentOffset,
		spawnedAt = now,
		landAt = now + launchDuration,
		despawnAt = now + launchDuration + lingerDuration,
		launchDuration = launchDuration,
		lingerDuration = lingerDuration,
		ownerEntity = if typeof(request.ownerEntity) == "number" then request.ownerEntity else nil,
		recipients = {},
		pickupFactory = pickupFactory,
		landed = false,
	}

	activeSpawns[record.id] = record
	sendSpawnToNearbyPlayers(record)

	return true, "Spawned animated item drop", record.id
end

function ItemSpawnService.step(dt: number)
	if not world then
		return
	end

	local now = Workspace:GetServerTimeNow()
	local expiredIds = {}

	for effectId, record in pairs(activeSpawns) do
		if not record.landed and now >= record.landAt then
			record.landed = true

			if record.pickupFactory then
				local ok, err = pcall(record.pickupFactory, record.landingPosition)
				if not ok then
					warn(string.format(
						"[ItemSpawnService] pickupFactory failed for item '%s': %s",
						record.itemId,
						tostring(err)
					))
				end
			end
		end

		if now >= record.despawnAt then
			table.insert(expiredIds, effectId)
		end
	end

	for _, effectId in ipairs(expiredIds) do
		local record = activeSpawns[effectId]
		if record then
			cleanupRecord(record)
		end
	end

	refreshAccumulator += dt
	if refreshAccumulator < REFRESH_INTERVAL then
		return
	end
	refreshAccumulator = 0

	for _, record in pairs(activeSpawns) do
		sendSpawnToNearbyPlayers(record)
	end
end

return ItemSpawnService
