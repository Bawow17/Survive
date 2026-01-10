--!strict
-- SyncSystem - packages dirty component state and dispatches to clients

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfilingConfig = require(ReplicatedStorage.Shared.ProfilingConfig)
local Prof = ProfilingConfig.ENABLED and require(ReplicatedStorage.Shared.ProfilingServer) or require(ReplicatedStorage.Shared.ProfilingStub)
local PROFILING_ENABLED = ProfilingConfig.ENABLED

local function profInc(name: string, amount: number?)
	if PROFILING_ENABLED then
		Prof.incCounter(name, amount)
	end
end

local function profGauge(name: string, value: number)
	if PROFILING_ENABLED then
		Prof.gauge(name, value)
	end
end

local function safeJsonSize(payload: any): number?
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, payload)
	if ok and type(encoded) == "string" then
		return #encoded
	end
	return nil
end

local SyncSystem = {}

local world
local DirtyService
local Components
local Remotes
local UnreliableUpdateRemote
local options

local getPlayerFromEntity: (number) -> Player? = function()
	return nil
end

local syncInterval = 0.05  -- PERFORMANCE FIX: 20 FPS sync rate (was 30 FPS) - reduces network load
local accumulator = 0

-- Garbage collection management
local gcAccumulator = 0
local GC_INTERVAL = 5.0 -- Force GC every 5 seconds

-- Memory optimization settings
local MAX_SHARED_ENTRIES_PER_COMPONENT = 500 -- Limit shared catalog size

-- PERFORMANCE FIX: Batch size limits to prevent overwhelming network
local MAX_UPDATES_PER_BATCH = 10000 -- Removed projectile limit cap (was 200) - allows unlimited projectiles
local MAX_DESPAWNS_PER_BATCH = 5000 -- Removed despawn limit cap (was 100)

-- AOI / relevancy tuning
local AOI_GRID_SIZE = 80
local AOI_NEAR_RADIUS = 140
local AOI_MID_RADIUS = 280
local AOI_MID_UPDATE_INTERVAL_TICKS = 3
local MAX_SPAWNS_PER_TICK_PER_PLAYER = 200
local MAX_UPDATES_PER_TICK_PER_PLAYER = 1500
local AOI_BAND_HYSTERESIS = 20

-- Transform update gating
local TRANSFORM_POS_EPS = 0.05
local TRANSFORM_VEL_EPS = 0.05
local TRANSFORM_FACING_EPS = 0.02
local NEAR_UPDATE_HZ = 12
local MID_UPDATE_HZ = 5
local FAR_UPDATE_HZ = 0
local USE_UNRELIABLE_TRANSFORMS = false
local ENEMY_POS_QUANTIZE = 0.1
local ENEMY_VEL_QUANTIZE = 0.1
local ENEMY_FACING_QUANTIZE = 0.05

local AOI_NEAR_RADIUS_SQ = AOI_NEAR_RADIUS * AOI_NEAR_RADIUS
local AOI_MID_RADIUS_SQ = AOI_MID_RADIUS * AOI_MID_RADIUS
local AOI_NEAR_ENTER_SQ = math.max(AOI_NEAR_RADIUS - AOI_BAND_HYSTERESIS, 0) ^ 2
local AOI_NEAR_EXIT_SQ = (AOI_NEAR_RADIUS + AOI_BAND_HYSTERESIS) ^ 2
local AOI_MID_ENTER_SQ = math.max(AOI_MID_RADIUS - AOI_BAND_HYSTERESIS, 0) ^ 2
local AOI_MID_EXIT_SQ = (AOI_MID_RADIUS + AOI_BAND_HYSTERESIS) ^ 2

local TRANSFORM_POS_EPS_SQ = TRANSFORM_POS_EPS * TRANSFORM_POS_EPS
local TRANSFORM_VEL_EPS_SQ = TRANSFORM_VEL_EPS * TRANSFORM_VEL_EPS
local TRANSFORM_FACING_EPS_SQ = TRANSFORM_FACING_EPS * TRANSFORM_FACING_EPS
local NEAR_UPDATE_TICKS = math.max(1, math.floor((1 / NEAR_UPDATE_HZ) / syncInterval + 0.5))
local MID_UPDATE_TICKS = math.max(1, math.floor((1 / MID_UPDATE_HZ) / syncInterval + 0.5))
local FAR_UPDATE_TICKS = FAR_UPDATE_HZ > 0 and math.max(1, math.floor((1 / FAR_UPDATE_HZ) / syncInterval + 0.5)) or math.huge
local NIL_HELPER_LOG_INTERVAL = 2

local AOI_TRACKED_TYPES = {
	Enemy = true,
	Projectile = true,
	ExpOrb = true,
	Powerup = true,
	AfterimageClone = true,
}

local componentLookup: {[string]: any} = {}
local pendingDespawn: {[number]: boolean} = {}
local entityRecipients: {[number]: {[any]: boolean}} = {}

-- PERFORMANCE FIX: Cached query to avoid creating new query every frame (CRITICAL!)
local playerPositionQuery: any

type AoiGridRecord = {
	entities: {number},
	indexLookup: {[number]: number},
	count: number,
}

type PlayerAoiState = {
	nearSet: {[number]: boolean},
	midSet: {[number]: boolean},
	bandByEntity: {[number]: string},
	spawnQueue: {number},
	spawnQueueSet: {[number]: string},
	updateQueue: {[number]: {[string]: boolean}},
	spawnScheduled: {[number]: boolean},
	lastTransformByEntity: {[number]: {px: number, py: number, pz: number, vx: number, vy: number, vz: number, fx: number, fy: number, fz: number}},
	lastTransformTick: {[number]: number},
}

local aoiGrid: {[string]: AoiGridRecord} = {}
local aoiEntityCell: {[number]: {cellKey: string, index: number}} = {}
local aoiTrackedCount = 0
local playerAoiState: {[Player]: PlayerAoiState} = setmetatable({}, { __mode = "k" })
local tickCounter = 0
local lastNilHelperLog = 0

local shareableComponents = {
	EntityType = true,
	-- AI = true,  -- REMOVED: AI state changes frequently (Charger numeric states, Zombie targeting) - causes corruption
	-- Visual = true,  -- REMOVED: Visual can change (red orb teleportation, scale upgrades) - must be sent per-entity
	-- ItemData = true,  -- REMOVED: ItemData should NOT be shared (causes color bleeding due to catalog corruption)
	AbilityData = true,
	PowerupData = true,  -- Powerup data is static per type
}

-- Immutable components that can be passed by reference (no cloning needed)
-- These components are read-only on the client and never modified
local immutableComponents = {
	EntityType = true,
	-- AI = true,  -- REMOVED: AI state changes frequently (causes stale data issues)
	-- Visual = true,  -- REMOVED: Visual can change (scale upgrades for projectiles!)
	-- ItemData = true,  -- REMOVED: ItemData can change (red orb conversion!)
	AbilityData = true,
	Ability = true,
	ProjectileData = true,  -- Read-only projectile configuration
	Damage = true,  -- Read-only damage value
	AbilityDamageStats = true,  -- Read-only ability damage tracking (client only reads for animation priority)
}

local initialComponents = {
	Position = true,
	Velocity = true,
	EntityType = true,
	Visual = true,
	ItemData = true,
	ProjectileData = true,
	PowerupData = true,
	FacingDirection = true,
	Health = true,
	Target = true,
	Ability = true,
	AbilityData = true,
	AbilityCooldown = true,
	AbilityPulse = true,
	HitFlash = true,
	Knockback = true,
	DeathAnimation = true,
	MobilityData = true,
	MobilityCooldown = true,
	PassiveEffects = true,  -- Need for mobility multipliers on client
}

local EXP_ORB_ALLOWED_UPDATES = {
	ItemData = true,
	Visual = true,
	MagnetPull = true,
	HitFlash = true,
	DeathAnimation = true,
}

-- Component tracking (legacy - all components now sync every frame)
local criticalComponents = {
	HitFlash = true,
	Knockback = true,
	DeathAnimation = true,
	Position = true,
	Velocity = true,
}

local sharedCatalog: {[string]: {
	byKey: {[string]: number},
	byId: {[number]: any},
	nextId: number,
}} = {}

local playerSharedKnown = setmetatable({}, { __mode = "k" })
local playerKnownEntities: {[Player]: {[number]: boolean}} = setmetatable({}, { __mode = "k" })

Players.PlayerRemoving:Connect(function(player)
	playerSharedKnown[player] = nil
	playerKnownEntities[player] = nil
	playerAoiState[player] = nil
end)

local function ensurePlayerKnownEntities(player: Player): {[number]: boolean}
	local known = playerKnownEntities[player]
	if not known then
		known = {}
		playerKnownEntities[player] = known
	end
	return known
end

local function initSharedCatalog()
	for componentName in pairs(shareableComponents) do
		sharedCatalog[componentName] = {
			byKey = {},
			byId = {},
			nextId = 1,
		}
	end
end

initSharedCatalog()

local function cloneTable(value: any): any
	if typeof(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, item in pairs(value) do
		if typeof(item) == "table" then
			copy[key] = cloneTable(item)
		else
			copy[key] = item
		end
	end
	return copy
end

local function ensurePlayerSharedState(player: Player)
	local state = playerSharedKnown[player]
	if not state then
		state = {}
		for componentName in pairs(shareableComponents) do
			state[componentName] = {}
		end
		playerSharedKnown[player] = state
	end
	return state
end

local function ensurePlayerPayload(map: {[any]: {updates: {any}?, resyncs: {any}?, shared: {[string]: {[number]: any}}?, despawns: {number}?, projectiles: {{number}}?, enemies: {{number}}?, entities: {[number]: any}?, projectileSpawns: {any}?, orbSpawns: {any}?}}, player: Player)
	local entry = map[player]
	if not entry then
		entry = {}
		map[player] = entry
	end
	if not entry.updates then
		entry.updates = {}
	end
	if not entry.shared then
		entry.shared = {}
	end
	if not entry.despawns then
		entry.despawns = {}
	end
	return entry
end

-- Object pooling with proper limits and safety
local recipientPool = {}
local MAX_RECIPIENT_POOL_SIZE = 20 -- Reasonable pool size limit
local function getRecipientTable()
	return table.remove(recipientPool) or {}
end
local function returnRecipientTable(recipientTable)
	table.clear(recipientTable)
	-- Only add to pool if it's not full
	if #recipientPool < MAX_RECIPIENT_POOL_SIZE then
		table.insert(recipientPool, recipientTable)
	end
	-- If pool is full, let the table be garbage collected
end

local shouldIncludeEntityForPlayer: (number, Player?) -> boolean
local attachSharedForPlayer: (Player, {shared: {[string]: {[number]: any}}?}, {[string]: {id: number, value: any}}?) -> ()
local buildComponentPayload: (number, {[string]: boolean}) -> ({[string]: any}, {[string]: {id: number, value: any}})
local getVectorComponents: (any) -> (number?, number?, number?)

local function copyRecipients(source: {[any]: boolean}): {[any]: boolean}
	local copy = getRecipientTable()
	for player in pairs(source) do
		copy[player] = true
	end
	return copy
end

local function isAoiTrackedType(entityType: any): boolean
	if not entityType then
		return false
	end
	return AOI_TRACKED_TYPES[entityType.type] == true
end

local function aoiWorldToCell(position: {x: number, y: number, z: number}): (number, number)
	return math.floor(position.x / AOI_GRID_SIZE), math.floor(position.z / AOI_GRID_SIZE)
end

local function aoiCellKey(cellX: number, cellZ: number): string
	return string.format("%d,%d", cellX, cellZ)
end

local function addToAoiGrid(entity: number, position: {x: number, y: number, z: number})
	local cellX, cellZ = aoiWorldToCell(position)
	local key = aoiCellKey(cellX, cellZ)
	local record = aoiGrid[key]
	if not record then
		record = {
			entities = {},
			indexLookup = {},
			count = 0,
		}
		aoiGrid[key] = record
	end

	record.count += 1
	record.entities[record.count] = entity
	record.indexLookup[entity] = record.count
	aoiEntityCell[entity] = {
		cellKey = key,
		index = record.count,
	}
	aoiTrackedCount += 1
end

local function removeFromAoiGrid(entity: number)
	local mapping = aoiEntityCell[entity]
	if not mapping then
		return
	end
	aoiEntityCell[entity] = nil

	local record = aoiGrid[mapping.cellKey]
	if not record then
		return
	end

	local index = mapping.index
	local lastIndex = record.count
	if lastIndex <= 0 then
		return
	end

	local lastEntity = record.entities[lastIndex]
	record.entities[lastIndex] = nil
	record.indexLookup[entity] = nil

	if index ~= lastIndex and lastEntity then
		record.entities[index] = lastEntity
		record.indexLookup[lastEntity] = index
		local lastMapping = aoiEntityCell[lastEntity]
		if lastMapping then
			lastMapping.index = index
		end
	else
		record.entities[index] = nil
	end

	record.count -= 1
	if record.count <= 0 then
		aoiGrid[mapping.cellKey] = nil
	end
	aoiTrackedCount = math.max(aoiTrackedCount - 1, 0)
end

local function updateAoiGrid(entity: number, position: {x: number, y: number, z: number})
	local cellX, cellZ = aoiWorldToCell(position)
	local key = aoiCellKey(cellX, cellZ)
	local mapping = aoiEntityCell[entity]
	if mapping and mapping.cellKey == key then
		return
	end
	if mapping then
		removeFromAoiGrid(entity)
	end
	addToAoiGrid(entity, position)
end

local function ensurePlayerAoiState(player: Player): PlayerAoiState
	local state = playerAoiState[player]
	if not state then
		state = {
			nearSet = {},
			midSet = {},
			bandByEntity = {},
			spawnQueue = {},
			spawnQueueSet = {},
			updateQueue = {},
			spawnScheduled = {},
			lastTransformByEntity = {},
			lastTransformTick = {},
		}
		playerAoiState[player] = state
	end
	return state
end

local function queueSpawn(state: PlayerAoiState, entity: number, zone: string)
	local existing = state.spawnQueueSet[entity]
	if existing == "near" then
		return
	end
	if existing == "mid" and zone == "near" then
		state.spawnQueueSet[entity] = "near"
		return
	end
	if existing then
		return
	end
	state.spawnQueueSet[entity] = zone
	table.insert(state.spawnQueue, entity)
end

local function removeSpawnFromQueue(state: PlayerAoiState, entity: number)
	if not state.spawnQueueSet[entity] then
		return
	end
	state.spawnQueueSet[entity] = nil
	local list = state.spawnQueue
	for i = 1, #list do
		if list[i] == entity then
			list[i] = list[#list]
			list[#list] = nil
			break
		end
	end
end

local function queueUpdate(state: PlayerAoiState, entity: number, flags: {[string]: boolean}): boolean
	local entry = state.updateQueue[entity]
	local isNew = false
	if not entry then
		entry = {}
		state.updateQueue[entity] = entry
		isNew = true
	end
	for componentName in pairs(flags) do
		entry[componentName] = true
	end
	return isNew
end

local function hasOnlyMovementComponents(flags: {[string]: boolean}): boolean
	for componentName in pairs(flags) do
		if componentName ~= "Position" and componentName ~= "Velocity" and componentName ~= "FacingDirection" then
			return false
		end
	end
	return true
end

local function roundToStep(value: number, step: number): number
	return math.floor(value / step + 0.5) * step
end

local function quantizeVector(value: any, step: number): any
	if typeof(value) ~= "table" then
		return value
	end
	local x = value.x or value.X
	local y = value.y or value.Y
	local z = value.z or value.Z
	if x == nil and y == nil and z == nil then
		return value
	end
	return {
		x = x ~= nil and roundToStep(x, step) or nil,
		y = y ~= nil and roundToStep(y, step) or nil,
		z = z ~= nil and roundToStep(z, step) or nil,
	}
end

local function filterFlagsForEntity(entityType: string?, flags: {[string]: boolean}): ({[string]: boolean}?, boolean)
	if entityType == "Projectile" then
		return nil, false
	end
	if entityType == "ExpOrb" then
		local filtered: {[string]: boolean}? = nil
		for componentName in pairs(flags) do
			if EXP_ORB_ALLOWED_UPDATES[componentName] then
				if not filtered then
					filtered = {}
				end
				filtered[componentName] = true
			end
		end
		if not filtered then
			return nil, false
		end
		return filtered, true
	end
	return flags, true
end

local function getUpdateIntervalTicks(band: string): number
	if band == "near" then
		return NEAR_UPDATE_TICKS
	elseif band == "mid" then
		return MID_UPDATE_TICKS
	else
		return FAR_UPDATE_TICKS
	end
end

getVectorComponents = function(value: any): (number?, number?, number?)
	if not value then
		return nil, nil, nil
	end
	return value.x or value.X, value.y or value.Y, value.z or value.Z
end

local function isTransformChangeSignificant(state: PlayerAoiState, entity: number, pos: any, vel: any, facing: any): boolean
	local last = state.lastTransformByEntity[entity]
	if not last then
		return true
	end

	if pos == nil and vel == nil and facing == nil then
		return true
	end

	local px, py, pz = getVectorComponents(pos)
	if px ~= nil and py ~= nil and pz ~= nil then
		local dx = px - last.px
		local dy = py - last.py
		local dz = pz - last.pz
		if (dx * dx + dy * dy + dz * dz) > TRANSFORM_POS_EPS_SQ then
			return true
		end
	end

	local vx, vy, vz = getVectorComponents(vel)
	if vx ~= nil and vy ~= nil and vz ~= nil then
		local dvx = vx - last.vx
		local dvy = vy - last.vy
		local dvz = vz - last.vz
		if (dvx * dvx + dvy * dvy + dvz * dvz) > TRANSFORM_VEL_EPS_SQ then
			return true
		end
	end

	local fx, fy, fz = getVectorComponents(facing)
	if fx ~= nil and fy ~= nil and fz ~= nil then
		local dfx = fx - last.fx
		local dfy = fy - last.fy
		local dfz = fz - last.fz
		if (dfx * dfx + dfy * dfy + dfz * dfz) > TRANSFORM_FACING_EPS_SQ then
			return true
		end
	end

	return false
end

local function recordLastTransform(state: PlayerAoiState, entity: number, pos: any, vel: any, facing: any)
	local px, py, pz = getVectorComponents(pos)
	local vx, vy, vz = getVectorComponents(vel)
	local fx, fy, fz = getVectorComponents(facing)
	state.lastTransformByEntity[entity] = {
		px = px or 0,
		py = py or 0,
		pz = pz or 0,
		vx = vx or 0,
		vy = vy or 0,
		vz = vz or 0,
		fx = fx or 0,
		fy = fy or 0,
		fz = fz or 0,
	}
	state.lastTransformTick[entity] = tickCounter
end

local function fillAoiSetsForPlayer(player: Player, playerPos: {x: number, y: number, z: number}, nearSet: {[number]: boolean}, midSet: {[number]: boolean}, bandByEntity: {[number]: string}): (number, number)
	local nearCount = 0
	local midCount = 0
	local cellRadius = math.ceil((AOI_MID_RADIUS + AOI_BAND_HYSTERESIS) / AOI_GRID_SIZE)
	local baseCellX, baseCellZ = aoiWorldToCell(playerPos)

	local px = playerPos.x
	local py = playerPos.y
	local pz = playerPos.z

	for dx = -cellRadius, cellRadius do
		for dz = -cellRadius, cellRadius do
			local key = aoiCellKey(baseCellX + dx, baseCellZ + dz)
			local record = aoiGrid[key]
			if record then
				for i = 1, record.count do
					local entity = record.entities[i]
					if entity and shouldIncludeEntityForPlayer(entity, player) then
						local pos = world:get(entity, componentLookup.Position)
						if pos then
							local dxp = pos.x - px
							local dyp = pos.y - py
							local dzp = pos.z - pz
							local distSq = dxp * dxp + dyp * dyp + dzp * dzp
							local prevBand = bandByEntity[entity]
							local band = "far"
							if prevBand == "near" then
								if distSq <= AOI_NEAR_EXIT_SQ then
									band = "near"
								end
							elseif prevBand == "mid" then
								if distSq <= AOI_MID_EXIT_SQ and distSq > AOI_NEAR_ENTER_SQ then
									band = "mid"
								elseif distSq <= AOI_NEAR_ENTER_SQ then
									band = "near"
								end
							end

							if band == "far" then
								if distSq <= AOI_NEAR_ENTER_SQ then
									band = "near"
								elseif distSq <= AOI_MID_ENTER_SQ then
									band = "mid"
								end
							end

							bandByEntity[entity] = band
							if band == "near" then
								nearSet[entity] = true
								nearCount += 1
							elseif band == "mid" then
								midSet[entity] = true
								midCount += 1
							end
						end
					end
				end
			end
		end
	end

	return nearCount, midCount
end

local function updateAoiGridFromDirty(dirty: {[number]: {[string]: boolean}})
	for entity, flags in pairs(dirty) do
		if flags.Position or flags.EntityType then
			local entityType = world:get(entity, componentLookup.EntityType)
			if isAoiTrackedType(entityType) then
				local pos = world:get(entity, componentLookup.Position)
				if pos then
					updateAoiGrid(entity, pos)
				end
			else
				removeFromAoiGrid(entity)
			end
		end
	end
end

local function buildInitialAoiGrid()
	if not world then
		return
	end
	local query = world:query(Components.Position, Components.EntityType)
	for entity, pos, entityType in query do
		if isAoiTrackedType(entityType) then
			updateAoiGrid(entity, pos)
		end
	end
end

local function getVectorTable(value: any): {[string]: number}?
	local x, y, z = getVectorComponents(value)
	if x == nil and y == nil and z == nil then
		return nil
	end
	return { x = x or 0, y = y or 0, z = z or 0 }
end

local function getLifetimeSeconds(value: any): number?
	if typeof(value) ~= "table" then
		return nil
	end
	return value.remaining or value.max
end

local function buildProjectileSpawn(entityId: number): {[string]: any}?
	local pos = world:get(entityId, componentLookup.Position)
	local vel = world:get(entityId, componentLookup.Velocity)
	if not pos or not vel then
		return nil
	end
	local entityTypeValue = world:get(entityId, componentLookup.EntityType)
	local projectileData = world:get(entityId, componentLookup.ProjectileData)
	local visual = world:get(entityId, componentLookup.Visual)
	local owner = componentLookup.Owner and world:get(entityId, componentLookup.Owner) or nil
	local ownerPlayer = owner and owner.player or nil
	local ownerUserId = ownerPlayer and ownerPlayer.UserId or nil
	local lifetime = world:get(entityId, componentLookup.Lifetime)
	local visualTypeId = (entityTypeValue and entityTypeValue.subtype) or (projectileData and projectileData.type)

	return {
		id = entityId,
		origin = getVectorTable(pos),
		velocity = getVectorTable(vel),
		spawnTime = tick(),
		lifetime = getLifetimeSeconds(lifetime),
		visualTypeId = visualTypeId,
		visualColor = visual and visual.color or nil,
		visualScale = visual and visual.scale or nil,
		ownerUserId = ownerUserId,
		ownerEntity = owner and owner.entity or nil,
	}
end

local function buildExpOrbSpawn(entityId: number): {[string]: any}?
	local pos = world:get(entityId, componentLookup.Position)
	if not pos then
		return nil
	end
	local itemData = world:get(entityId, componentLookup.ItemData)
	local visual = world:get(entityId, componentLookup.Visual)
	local lifetime = world:get(entityId, componentLookup.Lifetime)
	local magnetPull = world:get(entityId, componentLookup.MagnetPull)
	local seed = (itemData and itemData.uniqueId) or entityId

	return {
		id = entityId,
		origin = getVectorTable(pos),
		spawnTime = tick(),
		lifetime = getLifetimeSeconds(lifetime),
		seed = seed,
		itemColor = itemData and itemData.color or nil,
		isSink = itemData and itemData.isSink or nil,
		uniqueId = itemData and itemData.uniqueId or nil,
		ownerId = itemData and itemData.ownerId or nil,
		expAmount = itemData and itemData.expAmount or nil,
		visualScale = visual and visual.scale or nil,
		magnetPull = magnetPull and cloneTable(magnetPull) or nil,
	}
end

local function addSpawnForPlayer(player: Player, entry: {entities: {[number]: any}?, projectileSpawns: {any}?, orbSpawns: {any}?}, entityId: number): boolean
	local entityTypeValue = world:get(entityId, componentLookup.EntityType)
	local entityType = entityTypeValue and entityTypeValue.type
	if entityType == "Projectile" then
		local spawnData = buildProjectileSpawn(entityId)
		if spawnData then
			local list = entry.projectileSpawns
			if not list then
				list = {}
				entry.projectileSpawns = list
			end
			table.insert(list, spawnData)
			return true
		end
		return false
	end
	if entityType == "ExpOrb" then
		local spawnData = buildExpOrbSpawn(entityId)
		if spawnData then
			local list = entry.orbSpawns
			if not list then
				list = {}
				entry.orbSpawns = list
			end
			table.insert(list, spawnData)
			return true
		end
		return false
	end

	local spawnPayload, spawnShareInfo = buildComponentPayload(entityId, initialComponents)
	if spawnPayload and next(spawnPayload) then
		spawnPayload.id = entityId
		entry.entities = entry.entities or {}
		entry.entities[entityId] = spawnPayload
		attachSharedForPlayer(player, entry, spawnShareInfo)
		return true
	end
	return false
end

local function emitUpdateForPlayer(
	player: Player,
	entity: number,
	flags: {[string]: boolean},
	perPlayerPayload: {[any]: {updates: {any}?, resyncs: {any}?, shared: {[string]: {[number]: any}}?, despawns: {number}?, projectiles: {{number}}?, enemies: {{number}}?, entities: {[number]: any}?, projectileSpawns: {any}?, orbSpawns: {any}?}},
	projectileUpdates: {[Player]: {{number}}},
	enemyUpdates: {[Player]: {{number}}}
): boolean
	if buildComponentPayload == nil or attachSharedForPlayer == nil then
		if PROFILING_ENABLED then
			local now = tick()
			if now - lastNilHelperLog >= NIL_HELPER_LOG_INTERVAL then
				lastNilHelperLog = now
				warn(string.format(
					"[SyncSystem] emitUpdateForPlayer missing helper(s) buildComponentPayload=%s attachSharedForPlayer=%s entity=%s player=%s",
					tostring(buildComponentPayload),
					tostring(attachSharedForPlayer),
					tostring(entity),
					player and player.Name or "nil"
				))
			end
		end
		return false
	end

	local entityTypeValue = world:get(entity, componentLookup.EntityType)
	local entityType = entityTypeValue and entityTypeValue.type
	local isProjectile = entityType == "Projectile"
	local isEnemy = entityType == "Enemy"
	local filteredFlags, allowed = filterFlagsForEntity(entityType, flags)
	if not allowed then
		return false
	end
	flags = filteredFlags :: {[string]: boolean}

	if (isProjectile or isEnemy) and hasOnlyMovementComponents(flags) then
		local pos = world:get(entity, componentLookup.Position)
		local vel = world:get(entity, componentLookup.Velocity)
		if pos and vel then
			local px, py, pz = pos.x, pos.y, pos.z
			local vx, vy, vz = vel.x, vel.y, vel.z
			if isEnemy then
				px = roundToStep(px, ENEMY_POS_QUANTIZE)
				py = roundToStep(py, ENEMY_POS_QUANTIZE)
				pz = roundToStep(pz, ENEMY_POS_QUANTIZE)
				vx = roundToStep(vx, ENEMY_VEL_QUANTIZE)
				vy = roundToStep(vy, ENEMY_VEL_QUANTIZE)
				vz = roundToStep(vz, ENEMY_VEL_QUANTIZE)
			end
			local compactData = {
				entity,
				px, py, pz,
				vx, vy, vz,
			}
			if isProjectile then
				local list = projectileUpdates[player]
				if not list then
					list = {}
					projectileUpdates[player] = list
				end
				table.insert(list, compactData)
			else
				local list = enemyUpdates[player]
				if not list then
					list = {}
					enemyUpdates[player] = list
				end
				table.insert(list, compactData)
			end
			return true
		end
	end

	local payload, shareInfo = buildComponentPayload(entity, flags)
	if next(payload) then
		payload.id = entity
		local entry = ensurePlayerPayload(perPlayerPayload, player)
		attachSharedForPlayer(player, entry, shareInfo)
		table.insert(entry.updates, payload)
		return true
	end

	return false
end


local function getSharedDefinition(componentName: string, value: any)
	local catalog = sharedCatalog[componentName]
	if not catalog then
		return nil, nil
	end

	local encoded = HttpService:JSONEncode(value)
	local existingId = catalog.byKey[encoded]
	if existingId then
		return existingId, catalog.byId[existingId]
	end

	-- Memory optimization: Clean up old entries if catalog gets too large
	if catalog.nextId > MAX_SHARED_ENTRIES_PER_COMPONENT then
		-- Simple cleanup: just reset the catalog to prevent unlimited growth
		-- This is safer than trying to preserve entries, which could cause issues
		sharedCatalog[componentName] = { byKey = {}, byId = {}, nextId = 1 }
		catalog = sharedCatalog[componentName]
	end

	local id = catalog.nextId
	catalog.nextId += 1

	local storedValue = cloneTable(value)
	catalog.byKey[encoded] = id
	catalog.byId[id] = storedValue

	return id, storedValue
end

attachSharedForPlayer = function(player: Player, entry: {shared: {[string]: {[number]: any}}?}, shareInfo: {[string]: {id: number, value: any}}?)
	if not shareInfo or not next(shareInfo) then
		return
	end

	local sharedState = ensurePlayerSharedState(player)
	local sharedBuckets = entry.shared or {}
	entry.shared = sharedBuckets

	for componentName, info in pairs(shareInfo) do
		local known = sharedState[componentName]
		if not known then
			-- Initialize if not present (shouldn't happen, but safety check)
			known = {}
			sharedState[componentName] = known
		end
		
		-- Send shared component if player hasn't received this ID yet
		if not known[info.id] then
			known[info.id] = true
			local bucket = sharedBuckets[componentName]
			if not bucket then
				bucket = {}
				sharedBuckets[componentName] = bucket
			end
			bucket[info.id] = info.value
		end
	end
end

function shouldIncludeEntityForPlayer(entity: number, player: Player?)
	local entityTypeComponent = componentLookup.EntityType
	if not entityTypeComponent or not world then
		return true
	end

	local entityType = world:get(entity, entityTypeComponent)
	if not entityType then
		return true
	end

	-- MULTIPLAYER: All players see all enemies
	if entityType.type == "Enemy" then
		return true  -- Changed from per-player filtering to global visibility
	end
	
	-- MULTIPLAYER: Per-player items (exp orbs)
	if entityType.type == "ExpOrb" then
		local itemData = world:get(entity, componentLookup.ItemData)
		if itemData and itemData.ownerId then
			-- Per-player orb: only send to owner
			if not player then return false end
			local ownerPlayer = getPlayerFromEntity(itemData.ownerId)
			return ownerPlayer == player
		end
		-- No owner = global orb, visible to all
		return true
	end
	
	-- MULTIPLAYER: Per-player powerups (Health only)
	if entityType.type == "Powerup" then
		local powerupData = world:get(entity, componentLookup.PowerupData)
		if powerupData and powerupData.ownerId then
			-- Per-player powerup (Health): only send to owner
			if not player then return false end
			local ownerPlayer = getPlayerFromEntity(powerupData.ownerId)
			return ownerPlayer == player
		end
		-- No owner = global powerup, visible to all
		return true
	end
	
	-- MULTIPLAYER: Player entities (per-player components like MobilityData, PassiveEffects)
	if entityType.type == "Player" then
		if not player then return false end
		-- Each player only receives their own player entity updates
		local ownerPlayer = getPlayerFromEntity(entity)
		return ownerPlayer == player
	end

	return true
end

local function determineRecipients(entity: number)
	local recipients: {[any]: boolean} = {}

	if not world then
		return recipients
	end

	-- Filter recipients based on per-player ownership (same as initial sync)
	for _, player in ipairs(Players:GetPlayers()) do
		if shouldIncludeEntityForPlayer(entity, player) then
			recipients[player] = true
		end
	end

	return recipients
end

local function updateEntityRecipients(entity: number, recipients: {[any]: boolean}, perPlayerPayload: {[any]: {updates: {any}?, resyncs: {any}?, shared: {[string]: {[number]: any}}?, despawns: {number}?, projectiles: {{number}}?, enemies: {{number}}?, entities: {[number]: any}?, projectileSpawns: {any}?, orbSpawns: {any}?}})
	local previous = entityRecipients[entity]
	if previous then
		for player in pairs(previous) do
			if not recipients[player] then
				local entry = ensurePlayerPayload(perPlayerPayload, player)
				table.insert(entry.despawns, entity)
				profInc("despawnSentCount", 1)
				local known = ensurePlayerKnownEntities(player)
				if known[entity] then
					known[entity] = nil
					profInc("knownEntitiesRemoved", 1)
				end
			end
		end
		table.clear(previous)
		for player in pairs(recipients) do
			previous[player] = true
		end
	else
		entityRecipients[entity] = copyRecipients(recipients)
	end
end

buildComponentPayload = function(entity: number, flags: {[string]: boolean})
	local payload: {[string]: any} = {}
	local shareInfo: {[string]: {id: number, value: any}} = {}
	local entityTypeValue = componentLookup.EntityType and world:get(entity, componentLookup.EntityType)
	local isEnemy = entityTypeValue and entityTypeValue.type == "Enemy"

	for componentName in pairs(flags) do
		local component = componentLookup[componentName]
		if component then
			local value = world:get(entity, component)
			if value ~= nil then
				if isEnemy then
					if componentName == "Position" then
						value = quantizeVector(value, ENEMY_POS_QUANTIZE)
					elseif componentName == "Velocity" then
						value = quantizeVector(value, ENEMY_VEL_QUANTIZE)
					elseif componentName == "FacingDirection" then
						value = quantizeVector(value, ENEMY_FACING_QUANTIZE)
					end
				end
				if shareableComponents[componentName] and typeof(value) == "table" then
					local shareId, shareValue = getSharedDefinition(componentName, value)
					if shareId then
						payload[componentName] = shareId
						shareInfo[componentName] = { id = shareId, value = shareValue }
					else
						-- Check if component is immutable (can pass by reference)
						if immutableComponents[componentName] then
							payload[componentName] = value  -- No clone (optimization!)
						else
							payload[componentName] = cloneTable(value)
						end
					end
				else
					-- Check if component is immutable (can pass by reference)
					if immutableComponents[componentName] then
						payload[componentName] = value  -- No clone (optimization!)
					else
						payload[componentName] = cloneTable(value)
					end
				end
			end
		end
	end

	return payload, shareInfo
end

local function appendDespawns(perPlayerPayload: {[any]: {updates: {any}?, resyncs: {any}?, shared: {[string]: {[number]: any}}?, despawns: {number}?, projectiles: {{number}}?, enemies: {{number}}?, entities: {[number]: any}?, projectileSpawns: {any}?, orbSpawns: {any}?}})
	local activePlayers = Players:GetPlayers()
	-- PERFORMANCE FIX: Track despawns per player to enforce batch limits
	local playerDespawnCounts: {[Player]: number} = {}

	for entity in pairs(pendingDespawn) do
		local allQueued = true
		local hadKnown = false

		for _, player in ipairs(activePlayers) do
			if player and player.Parent == Players then
				local known = playerKnownEntities[player]
				if known and known[entity] then
					hadKnown = true
					local count = playerDespawnCounts[player] or 0
					if count < MAX_DESPAWNS_PER_BATCH then
						local entry = ensurePlayerPayload(perPlayerPayload, player)
						table.insert(entry.despawns, entity)
						playerDespawnCounts[player] = count + 1
						known[entity] = nil
						local state = playerAoiState[player]
						if state then
							state.bandByEntity[entity] = nil
							state.lastTransformByEntity[entity] = nil
							state.lastTransformTick[entity] = nil
						end
						profInc("knownEntitiesRemoved", 1)
						profInc("despawnSentCount", 1)
					else
						allQueued = false
					end
				end
			end
		end

		for _, state in pairs(playerAoiState) do
			if state.updateQueue[entity] then
				state.updateQueue[entity] = nil
			end
			removeSpawnFromQueue(state, entity)
		end

		if not hadKnown then
			pendingDespawn[entity] = nil
			if entityRecipients[entity] then
				returnRecipientTable(entityRecipients[entity])
				entityRecipients[entity] = nil
			end
			removeFromAoiGrid(entity)
		elseif allQueued then
			pendingDespawn[entity] = nil
			if entityRecipients[entity] then
				returnRecipientTable(entityRecipients[entity])
				entityRecipients[entity] = nil
			end
			removeFromAoiGrid(entity)
		end
		-- If not queued due to batch limit, it will be tried again next frame
	end
end

function SyncSystem.init(worldRef: any, components: any, dirtyService: any, remotes: any, opts: any?)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	Remotes = remotes
	UnreliableUpdateRemote = remotes and remotes.EntityUpdateUnreliable or nil
	if not UnreliableUpdateRemote then
		local remoteRoot = ReplicatedStorage:FindFirstChild("RemoteEvents")
		local ecsRemotes = remoteRoot and remoteRoot:FindFirstChild("ECS")
		local candidate = ecsRemotes and ecsRemotes:FindFirstChild("EntityUpdateUnreliable")
		if candidate and candidate:IsA("UnreliableRemoteEvent") then
			UnreliableUpdateRemote = candidate
		end
	end
	options = opts or {}

	if options and options.getPlayerFromEntity then
		getPlayerFromEntity = options.getPlayerFromEntity
	end

	componentLookup = {
		Position = Components.Position,
		Velocity = Components.Velocity,
		EntityType = Components.EntityType,
		Health = Components.Health,
		Lifetime = Components.Lifetime,
		Visual = Components.Visual,
		Owner = Components.Owner,
		Projectile = Components.Projectile,
		ProjectileData = Components.ProjectileData,
		Damage = Components.Damage,
		Collision = Components.Collision,
		Target = Components.Target,
		AI = Components.AI,
		FacingDirection = Components.FacingDirection,
		ItemData = Components.ItemData,  -- Has ownerId for per-player orbs
		PlayerStats = Components.PlayerStats,
		AttackCooldown = Components.AttackCooldown,
		Experience = Components.Experience,
		Level = Components.Level,
		Ability = Components.Ability,
		AbilityData = Components.AbilityData,
		AbilityCooldown = Components.AbilityCooldown,
		AbilityPulse = Components.AbilityPulse,
		HitFlash = Components.HitFlash,
		Knockback = Components.Knockback,
		DeathAnimation = Components.DeathAnimation,
		PowerupData = Components.PowerupData,  -- Has ownerId for per-player Health powerups
		Overheal = Components.Overheal,
		BuffState = Components.BuffState,
		MagnetPull = Components.MagnetPull,
		AbilityDamageStats = Components.AbilityDamageStats,
		Homing = Components.Homing,  -- Homing projectile tracking data
		MobilityData = Components.MobilityData,  -- Equipped mobility ability
		MobilityCooldown = Components.MobilityCooldown,  -- Mobility cooldown tracking
		PassiveEffects = Components.PassiveEffects,  -- Passive multipliers (for mobility)
	}
	
	-- PERFORMANCE FIX: Cache player position query (CRITICAL for FPS!)
	playerPositionQuery = world:query(Components.Position, Components.PlayerStats):cached()

	buildInitialAoiGrid()
end

function SyncSystem.queueDespawn(entity: number)
	pendingDespawn[entity] = true
	removeFromAoiGrid(entity)
	
	-- Return recipient table to pool
	if entityRecipients[entity] then
		returnRecipientTable(entityRecipients[entity])
		entityRecipients[entity] = nil
	end
end

function SyncSystem.markForInitialSync(entity: number)
	-- Mark common components
	DirtyService.mark(entity, "Position")
	DirtyService.mark(entity, "Velocity")
	DirtyService.mark(entity, "EntityType")
	DirtyService.mark(entity, "Visual")
	
	-- Only mark entity-specific components if they exist
	if world:has(entity, componentLookup.Health) then
		DirtyService.mark(entity, "Health")
	end
	if world:has(entity, componentLookup.AbilityData) then
		DirtyService.mark(entity, "AbilityData")
	end
	if world:has(entity, componentLookup.AbilityCooldown) then
		DirtyService.mark(entity, "AbilityCooldown")
	end
	if world:has(entity, componentLookup.ItemData) then
		DirtyService.mark(entity, "ItemData")
	end
	if world:has(entity, componentLookup.Collision) then
		DirtyService.mark(entity, "Collision")
	end
	if world:has(entity, componentLookup.Lifetime) then
		DirtyService.mark(entity, "Lifetime")
	end
end

function SyncSystem.step(dt: number)
	accumulator += dt
	if accumulator < syncInterval then
		return
	end
	accumulator -= syncInterval
	tickCounter += 1
	
	-- Periodic garbage collection to prevent memory buildup
	gcAccumulator += dt
	if gcAccumulator >= GC_INTERVAL then
		gcAccumulator = 0
		-- Use gcinfo() to check memory and force collection if needed
		local memoryKB = gcinfo()
		if memoryKB > 1024 * 1024 then -- If over 1GB
			collectgarbage("collect")
		end
	end

	if not world then
		return
	end

	Prof.beginTimer("SyncSystem.PackSend")

	local dirty = DirtyService.consumeDirty()
	updateAoiGridFromDirty(dirty)
	local perPlayerPayload: {[any]: {updates: {any}?, resyncs: {any}?, shared: {[string]: {[number]: any}}?, despawns: {number}?, projectiles: {{number}}?, enemies: {{number}}?, entities: {[number]: any}?, projectileSpawns: {any}?, orbSpawns: {any}?}} = {}
	local perPlayerPayloadUnreliable: {[any]: {updates: {any}?, shared: {[string]: {[number]: any}}?, projectiles: {{number}}?, enemies: {{number}}?}} = {}
	local playerUpdateCounts: {[Player]: number} = {}
	local projectileUpdates: {[Player]: {{number}}} = {}
	local enemyUpdates: {[Player]: {{number}}} = {}
	local projectileUpdatesUnreliable: {[Player]: {{number}}} = {}
	local enemyUpdatesUnreliable: {[Player]: {{number}}} = {}
	local activePlayers = Players:GetPlayers()
	local canUseUnreliable = USE_UNRELIABLE_TRANSFORMS and UnreliableUpdateRemote ~= nil
	local spawnBudgetHitPlayers: {[Player]: boolean} = {}
	local updateBudgetHitPlayers: {[Player]: boolean} = {}

	for _, player in ipairs(activePlayers) do
		local state = ensurePlayerAoiState(player)
		table.clear(state.nearSet)
		table.clear(state.midSet)
		table.clear(state.spawnScheduled)
	end

	local maxNear = 0
	local maxMid = 0
	local maxFar = 0
	for _, playerPos, playerStats in playerPositionQuery do
		local player = playerStats and playerStats.player
		if player then
			local state = ensurePlayerAoiState(player)
			local nearCount, midCount = fillAoiSetsForPlayer(player, playerPos, state.nearSet, state.midSet, state.bandByEntity)
			if nearCount > maxNear then
				maxNear = nearCount
			end
			if midCount > maxMid then
				maxMid = midCount
			end
			local farCount = math.max(aoiTrackedCount - nearCount - midCount, 0)
			if farCount > maxFar then
				maxFar = farCount
			end
		end
	end

	profGauge("entitiesNearCount", maxNear)
	profGauge("entitiesMidCount", maxMid)
	profGauge("entitiesFarCount", maxFar)

	for _, player in ipairs(activePlayers) do
		local state = ensurePlayerAoiState(player)
		local known = ensurePlayerKnownEntities(player)
		local nearSet = state.nearSet
		local midSet = state.midSet

		local farDespawnCount = 0
		for entityId in pairs(known) do
			if not nearSet[entityId] and not midSet[entityId] then
				local entry = ensurePlayerPayload(perPlayerPayload, player)
				table.insert(entry.despawns, entityId)
				farDespawnCount += 1
				profInc("despawnsSentFar", 1)
				known[entityId] = nil
				profInc("knownEntitiesRemoved", 1)
				if entityRecipients[entityId] then
					entityRecipients[entityId][player] = nil
				end
				if state.updateQueue[entityId] then
					state.updateQueue[entityId] = nil
				end
				state.bandByEntity[entityId] = nil
				state.lastTransformByEntity[entityId] = nil
				state.lastTransformTick[entityId] = nil
				removeSpawnFromQueue(state, entityId)
			end
		end
		if farDespawnCount > 0 then
			profInc("despawnSentCount", farDespawnCount)
		end

		local spawnBudget = MAX_SPAWNS_PER_TICK_PER_PLAYER
		local spawnCount = 0
		local queueList = state.spawnQueue
		local i = 1
		while i <= #queueList and spawnCount < spawnBudget do
			local entityId = queueList[i]
			local zone = state.spawnQueueSet[entityId]
			local inNear = nearSet[entityId]
			local inMid = midSet[entityId]
			if not zone or (not inNear and not inMid) then
				state.spawnQueueSet[entityId] = nil
				queueList[i] = queueList[#queueList]
				queueList[#queueList] = nil
			elseif known[entityId] or state.spawnScheduled[entityId] then
				state.spawnQueueSet[entityId] = nil
				queueList[i] = queueList[#queueList]
				queueList[#queueList] = nil
			else
				if inNear then
					zone = "near"
					state.spawnQueueSet[entityId] = "near"
				end

				local spawnEntry = ensurePlayerPayload(perPlayerPayload, player)
				if addSpawnForPlayer(player, spawnEntry, entityId) then
					local recipients = entityRecipients[entityId]
					if not recipients then
						recipients = {}
						entityRecipients[entityId] = recipients
					end
					recipients[player] = true
					spawnCount += 1
					state.spawnScheduled[entityId] = true
					if zone == "near" then
						profInc("spawnsSentNear", 1)
					else
						profInc("spawnsSentMid", 1)
					end
					if state.updateQueue[entityId] then
						state.updateQueue[entityId] = nil
					end
				end

				state.spawnQueueSet[entityId] = nil
				queueList[i] = queueList[#queueList]
				queueList[#queueList] = nil
			end
		end

		for entityId in pairs(nearSet) do
			if not known[entityId] and not state.spawnScheduled[entityId] and not state.spawnQueueSet[entityId] then
				if spawnCount < spawnBudget then
					local spawnEntry = ensurePlayerPayload(perPlayerPayload, player)
					if addSpawnForPlayer(player, spawnEntry, entityId) then
						local recipients = entityRecipients[entityId]
						if not recipients then
							recipients = {}
							entityRecipients[entityId] = recipients
						end
						recipients[player] = true
						spawnCount += 1
						state.spawnScheduled[entityId] = true
						profInc("spawnsSentNear", 1)
						if state.updateQueue[entityId] then
							state.updateQueue[entityId] = nil
						end
					end
				else
					queueSpawn(state, entityId, "near")
					profInc("queuedSpawns", 1)
					if not spawnBudgetHitPlayers[player] then
						spawnBudgetHitPlayers[player] = true
						profInc("budgetHitCount", 1)
					end
				end
			end
		end

		for entityId in pairs(midSet) do
			if not nearSet[entityId] and not known[entityId] and not state.spawnScheduled[entityId] and not state.spawnQueueSet[entityId] then
				if spawnCount < spawnBudget then
					local spawnEntry = ensurePlayerPayload(perPlayerPayload, player)
					if addSpawnForPlayer(player, spawnEntry, entityId) then
						local recipients = entityRecipients[entityId]
						if not recipients then
							recipients = {}
							entityRecipients[entityId] = recipients
						end
						recipients[player] = true
						spawnCount += 1
						state.spawnScheduled[entityId] = true
						profInc("spawnsSentMid", 1)
						if state.updateQueue[entityId] then
							state.updateQueue[entityId] = nil
						end
					end
				else
					queueSpawn(state, entityId, "mid")
					profInc("queuedSpawns", 1)
					if not spawnBudgetHitPlayers[player] then
						spawnBudgetHitPlayers[player] = true
						profInc("budgetHitCount", 1)
					end
				end
			end
		end
	end

	for _, player in ipairs(activePlayers) do
		local state = playerAoiState[player]
		if state then
			local known = ensurePlayerKnownEntities(player)
			local updatesUsed = playerUpdateCounts[player] or 0
			for entityId, flags in pairs(state.updateQueue) do
				if updatesUsed >= MAX_UPDATES_PER_TICK_PER_PLAYER then
					if not updateBudgetHitPlayers[player] then
						updateBudgetHitPlayers[player] = true
						profInc("budgetHitCount", 1)
					end
					break
				end
				if not known[entityId] or state.spawnScheduled[entityId] then
					state.updateQueue[entityId] = nil
					continue
				end
				local entityTypeValue = world:get(entityId, componentLookup.EntityType)
				local entityType = entityTypeValue and entityTypeValue.type
				local filteredFlags, allowed = filterFlagsForEntity(entityType, flags)
				if not allowed then
					state.updateQueue[entityId] = nil
					continue
				end
				flags = filteredFlags :: {[string]: boolean}
				local zone = nil
				if state.nearSet[entityId] then
					zone = "near"
				elseif state.midSet[entityId] then
					zone = "mid"
				else
					if entityTypeValue and not isAoiTrackedType(entityTypeValue) and shouldIncludeEntityForPlayer(entityId, player) then
						zone = "near"
					end
				end
				if not zone then
					state.updateQueue[entityId] = nil
					continue
				end
				local isTransformOnly = hasOnlyMovementComponents(flags)
				local needsTransform = flags.Position or flags.Velocity or flags.FacingDirection
				local pos = needsTransform and world:get(entityId, componentLookup.Position) or nil
				local vel = needsTransform and world:get(entityId, componentLookup.Velocity) or nil
				local facing = needsTransform and world:get(entityId, componentLookup.FacingDirection) or nil

				if isTransformOnly then
					if not isTransformChangeSignificant(state, entityId, pos, vel, facing) then
						profInc("updatesSkippedNoChange", 1)
						state.updateQueue[entityId] = nil
						continue
					end
					local intervalTicks = getUpdateIntervalTicks(zone)
					local lastTick = state.lastTransformTick[entityId] or 0
					if (tickCounter - lastTick) < intervalTicks then
						profInc("updatesSkippedRateLimit", 1)
						continue
					end
				end

				local useUnreliable = canUseUnreliable and isTransformOnly
				local targetPayload = useUnreliable and perPlayerPayloadUnreliable or perPlayerPayload
				local targetProjectiles = useUnreliable and projectileUpdatesUnreliable or projectileUpdates
				local targetEnemies = useUnreliable and enemyUpdatesUnreliable or enemyUpdates

				if emitUpdateForPlayer(player, entityId, flags, targetPayload, targetProjectiles, targetEnemies) then
					updatesUsed += 1
					if zone == "near" then
						profInc("updatesSentNear", 1)
					else
						profInc("updatesSentMid", 1)
					end
					if isTransformOnly or needsTransform then
						recordLastTransform(state, entityId, pos, vel, facing)
					end
				end
				state.updateQueue[entityId] = nil
			end
			playerUpdateCounts[player] = updatesUsed
		end
	end

	for entity, flags in pairs(dirty) do
		local entityTypeValue = world:get(entity, componentLookup.EntityType)
		local entityType = entityTypeValue and entityTypeValue.type
		local filteredFlags, allowed = filterFlagsForEntity(entityType, flags)
		if not allowed then
			continue
		end
		flags = filteredFlags :: {[string]: boolean}
		local isProjectile = entityType == "Projectile"
		local isEnemy = entityType == "Enemy"
		local isAoiTracked = isAoiTrackedType(entityTypeValue)
		local canUseCompact = isEnemy and hasOnlyMovementComponents(flags)
		local isTransformOnly = hasOnlyMovementComponents(flags)
		local needsTransform = flags.Position or flags.Velocity or flags.FacingDirection
		local pos = needsTransform and world:get(entity, componentLookup.Position) or nil
		local vel = needsTransform and world:get(entity, componentLookup.Velocity) or nil
		local facing = needsTransform and world:get(entity, componentLookup.FacingDirection) or nil

		local compactData
		if canUseCompact then
			if pos and vel then
				local px = roundToStep(pos.x, ENEMY_POS_QUANTIZE)
				local py = roundToStep(pos.y, ENEMY_POS_QUANTIZE)
				local pz = roundToStep(pos.z, ENEMY_POS_QUANTIZE)
				local vx = roundToStep(vel.x, ENEMY_VEL_QUANTIZE)
				local vy = roundToStep(vel.y, ENEMY_VEL_QUANTIZE)
				local vz = roundToStep(vel.z, ENEMY_VEL_QUANTIZE)
				compactData = {
					entity,
					px, py, pz,
					vx, vy, vz,
				}
			end
		end

		local payload
		local shareInfo
		if not compactData then
			payload, shareInfo = buildComponentPayload(entity, flags)
			if next(payload) then
				payload.id = entity
			else
				payload = nil
			end
		end

		if not compactData and not payload then
			continue
		end

		for _, player in ipairs(activePlayers) do
			local state = playerAoiState[player]
			if not state then
				continue
			end

			local zone = nil
			if isAoiTracked then
				if state.nearSet[entity] then
					zone = "near"
				elseif state.midSet[entity] then
					zone = "mid"
				else
					continue
				end
			else
				if shouldIncludeEntityForPlayer(entity, player) then
					zone = "near"
				else
					continue
				end
			end

			local known = ensurePlayerKnownEntities(player)
			if not known[entity] or state.spawnScheduled[entity] then
				profInc("updatesSuppressedUnknownCount", 1)
				if not isAoiTracked and not state.spawnScheduled[entity] then
					local spawnEntry = ensurePlayerPayload(perPlayerPayload, player)
					if addSpawnForPlayer(player, spawnEntry, entity) then
						local recipients = entityRecipients[entity]
						if not recipients then
							recipients = {}
							entityRecipients[entity] = recipients
						end
						recipients[player] = true
						state.spawnScheduled[entity] = true
					end
				end
				continue
			end
			if isTransformOnly then
				if not isTransformChangeSignificant(state, entity, pos, vel, facing) then
					profInc("updatesSkippedNoChange", 1)
					continue
				end
				local intervalTicks = getUpdateIntervalTicks(zone)
				local lastTick = state.lastTransformTick[entity] or 0
				if (tickCounter - lastTick) < intervalTicks then
					profInc("updatesSkippedRateLimit", 1)
					if queueUpdate(state, entity, flags) then
						profInc("queuedUpdates", 1)
					end
					continue
				end
			end

			local updatesUsed = playerUpdateCounts[player] or 0
			if updatesUsed >= MAX_UPDATES_PER_TICK_PER_PLAYER then
				if queueUpdate(state, entity, flags) then
					profInc("queuedUpdates", 1)
				end
				if not updateBudgetHitPlayers[player] then
					updateBudgetHitPlayers[player] = true
					profInc("budgetHitCount", 1)
				end
				continue
			end

			local useUnreliable = canUseUnreliable and isTransformOnly
			local targetProjectiles = useUnreliable and projectileUpdatesUnreliable or projectileUpdates
			local targetEnemies = useUnreliable and enemyUpdatesUnreliable or enemyUpdates
			local targetPayload = useUnreliable and perPlayerPayloadUnreliable or perPlayerPayload

			if compactData then
				if isProjectile then
					local list = targetProjectiles[player]
					if not list then
						list = {}
						targetProjectiles[player] = list
					end
					table.insert(list, compactData)
				elseif isEnemy then
					local list = targetEnemies[player]
					if not list then
						list = {}
						targetEnemies[player] = list
					end
					table.insert(list, compactData)
				end
			else
				local entry = ensurePlayerPayload(targetPayload, player)
				attachSharedForPlayer(player, entry, shareInfo)
				table.insert(entry.updates, payload)
			end

			updatesUsed += 1
			playerUpdateCounts[player] = updatesUsed
			if zone == "near" then
				profInc("updatesSentNear", 1)
			else
				profInc("updatesSentMid", 1)
			end
			if isTransformOnly or needsTransform then
				recordLastTransform(state, entity, pos, vel, facing)
			end
		end
	end

	appendDespawns(perPlayerPayload)

	for player, compactProj in pairs(projectileUpdates) do
		local entry = ensurePlayerPayload(perPlayerPayload, player)
		entry.projectiles = compactProj
	end
	for player, compactEnem in pairs(enemyUpdates) do
		local entry = ensurePlayerPayload(perPlayerPayload, player)
		entry.enemies = compactEnem
	end
	for player, compactProj in pairs(projectileUpdatesUnreliable) do
		local entry = ensurePlayerPayload(perPlayerPayloadUnreliable, player)
		entry.projectiles = compactProj
	end
	for player, compactEnem in pairs(enemyUpdatesUnreliable) do
		local entry = ensurePlayerPayload(perPlayerPayloadUnreliable, player)
		entry.enemies = compactEnem
	end

	for player, entry in pairs(perPlayerPayload) do
		if not player or player.Parent ~= Players then
			playerSharedKnown[player] = nil
			continue
		end
		local spawnCount = 0
		local known = ensurePlayerKnownEntities(player)
		if entry.entities then
			for entityId, spawnPayload in pairs(entry.entities) do
				if known[entityId] then
					entry.entities[entityId] = nil
					local resyncs = entry.resyncs or {}
					entry.resyncs = resyncs
					table.insert(resyncs, spawnPayload)
					profInc("duplicateSpawnSuppressedCount", 1)
				else
					known[entityId] = true
					spawnCount += 1
					profInc("knownEntitiesAdded", 1)
				end
			end
			if next(entry.entities) == nil then
				entry.entities = nil
			end
		end
		if entry.projectileSpawns then
			local write = 1
			for _, spawnPayload in ipairs(entry.projectileSpawns) do
				local entityId = spawnPayload and spawnPayload.id
				if entityId and known[entityId] then
					profInc("duplicateSpawnSuppressedCount", 1)
				else
					if entityId then
						known[entityId] = true
						spawnCount += 1
						profInc("knownEntitiesAdded", 1)
					end
					entry.projectileSpawns[write] = spawnPayload
					write += 1
				end
			end
			for i = write, #entry.projectileSpawns do
				entry.projectileSpawns[i] = nil
			end
			if #entry.projectileSpawns == 0 then
				entry.projectileSpawns = nil
			end
		end
		if entry.orbSpawns then
			local write = 1
			for _, spawnPayload in ipairs(entry.orbSpawns) do
				local entityId = spawnPayload and spawnPayload.id
				if entityId and known[entityId] then
					profInc("duplicateSpawnSuppressedCount", 1)
				else
					if entityId then
						known[entityId] = true
						spawnCount += 1
						profInc("knownEntitiesAdded", 1)
					end
					entry.orbSpawns[write] = spawnPayload
					write += 1
				end
			end
			for i = write, #entry.orbSpawns do
				entry.orbSpawns[i] = nil
			end
			if #entry.orbSpawns == 0 then
				entry.orbSpawns = nil
			end
		end
		if spawnCount > 0 then
			profInc("spawnSentCount", spawnCount)
		end
		if entry.updates and #entry.updates == 0 then
			entry.updates = nil
		end
		if entry.resyncs and #entry.resyncs == 0 then
			entry.resyncs = nil
		end
		if entry.despawns and #entry.despawns == 0 then
			entry.despawns = nil
		end
		if entry.shared and next(entry.shared) == nil then
			entry.shared = nil
		end
		-- Clean up empty compact batches
		if entry.projectiles and #entry.projectiles == 0 then
			entry.projectiles = nil
		end
		if entry.enemies and #entry.enemies == 0 then
			entry.enemies = nil
		end
		if entry.updates or entry.resyncs or entry.despawns or entry.shared or entry.projectiles or entry.enemies or entry.entities or entry.projectileSpawns or entry.orbSpawns then
			local entitiesCount = 0
			local updatesCount = 0
			local spawnEntitiesCount = 0
			if entry.updates then
				entitiesCount += #entry.updates
				updatesCount += #entry.updates
			end
			if entry.resyncs then
				entitiesCount += #entry.resyncs
				updatesCount += #entry.resyncs
			end
			if entry.projectiles then
				entitiesCount += #entry.projectiles
				updatesCount += #entry.projectiles
			end
			if entry.enemies then
				entitiesCount += #entry.enemies
				updatesCount += #entry.enemies
			end
			if entry.despawns then
				entitiesCount += #entry.despawns
			end
			if entry.entities then
				for _ in pairs(entry.entities) do
					entitiesCount += 1
					spawnEntitiesCount += 1
				end
			end
			if entry.projectileSpawns then
				spawnEntitiesCount += #entry.projectileSpawns
				entitiesCount += #entry.projectileSpawns
			end
			if entry.orbSpawns then
				spawnEntitiesCount += #entry.orbSpawns
				entitiesCount += #entry.orbSpawns
			end

			if PROFILING_ENABLED then
				local payloadBytes = safeJsonSize(entry)
				if payloadBytes then
					Prof.incCounter("SyncSystem.BytesPerTickPlayer", payloadBytes)
				end
				if spawnEntitiesCount > 0 then
					local spawnBytes = safeJsonSize({
						shared = entry.shared,
						entities = entry.entities,
						projectileSpawns = entry.projectileSpawns,
						orbSpawns = entry.orbSpawns,
					})
					if spawnBytes then
						Prof.incCounter("bytesSentSpawns", spawnBytes)
					end
				end
				if updatesCount > 0 or (entry.despawns and #entry.despawns > 0) then
					local updateBytes = safeJsonSize({
						updates = entry.updates,
						resyncs = entry.resyncs,
						enemies = entry.enemies,
						projectiles = entry.projectiles,
						despawns = entry.despawns,
					})
					if updateBytes then
						Prof.incCounter("bytesSentUpdates", updateBytes)
						if updatesCount > 0 then
							Prof.gauge("avgBytesPerUpdate", math.floor(updateBytes / updatesCount))
						end
					end
				end
			end
			profInc("SyncSystem.EntitiesPerTickPlayer", entitiesCount)
			profInc("updatesSentCount", updatesCount)
			profInc("updatesSentReliable", updatesCount)

			Remotes.EntityUpdate:FireClient(player, entry)

			local knownCount = 0
			for _ in pairs(known) do
				knownCount += 1
			end
			profGauge("knownEntitiesCountPerPlayer", knownCount)
		end
	end

	if canUseUnreliable then
		for player, entry in pairs(perPlayerPayloadUnreliable) do
			if not player or player.Parent ~= Players then
				continue
			end
			if entry.updates and #entry.updates == 0 then
				entry.updates = nil
			end
			if entry.shared and next(entry.shared) == nil then
				entry.shared = nil
			end
			if entry.projectiles and #entry.projectiles == 0 then
				entry.projectiles = nil
			end
			if entry.enemies and #entry.enemies == 0 then
				entry.enemies = nil
			end
			if entry.despawns then
				entry.despawns = nil
			end

			if entry.updates or entry.shared or entry.projectiles or entry.enemies then
				local entitiesCount = 0
				local updatesCount = 0
				if entry.updates then
					entitiesCount += #entry.updates
					updatesCount += #entry.updates
				end
				if entry.projectiles then
					entitiesCount += #entry.projectiles
					updatesCount += #entry.projectiles
				end
				if entry.enemies then
					entitiesCount += #entry.enemies
					updatesCount += #entry.enemies
				end

				if PROFILING_ENABLED then
					local payloadBytes = safeJsonSize(entry)
					if payloadBytes then
						Prof.incCounter("SyncSystem.BytesPerTickPlayer", payloadBytes)
						Prof.incCounter("bytesSentUpdates", payloadBytes)
					end
				end
				profInc("SyncSystem.EntitiesPerTickPlayer", entitiesCount)
				profInc("updatesSentCount", updatesCount)
				profInc("updatesSentUnreliable", updatesCount)

				UnreliableUpdateRemote:FireClient(player, entry)
			end
		end
	end

	Prof.endTimer("SyncSystem.PackSend")
end

function SyncSystem.buildInitialSnapshot(player: Player?)
	local snapshot = {
		shared = {},
		entities = {},
		projectileSpawns = {},
		orbSpawns = {},
		isInitial = false,
	}

	if not world then
		print("[SyncSystem] buildInitialSnapshot: world is nil")
		return snapshot
	end
	
	-- Reset player's shared state so ALL shared definitions are sent in initial snapshot
	if player then
		snapshot.isInitial = true
		playerSharedKnown[player] = nil
		playerKnownEntities[player] = {}
	end

	local sharedEntry = { shared = snapshot.shared }

	local query = world:query(Components.Position, Components.EntityType)
	for entity in query do
		if shouldIncludeEntityForPlayer(entity, player) then
			local entityTypeValue = world:get(entity, componentLookup.EntityType)
			local entityType = entityTypeValue and entityTypeValue.type
			if entityType == "Projectile" then
				local spawnData = buildProjectileSpawn(entity)
				if spawnData then
					table.insert(snapshot.projectileSpawns, spawnData)
				end
			elseif entityType == "ExpOrb" then
				local spawnData = buildExpOrbSpawn(entity)
				if spawnData then
					table.insert(snapshot.orbSpawns, spawnData)
				end
			else
				local payload, shareInfo = buildComponentPayload(entity, initialComponents)
				if next(payload) then
					payload.id = entity
					snapshot.entities[entity] = payload
					if player then
						attachSharedForPlayer(player, sharedEntry, shareInfo)

						local recipients = entityRecipients[entity]
						if not recipients then
							recipients = {}
							entityRecipients[entity] = recipients
						end
						recipients[player] = true
					else
						for componentName, info in pairs(shareInfo) do
							local bucket = snapshot.shared[componentName]
							if not bucket then
								bucket = {}
								snapshot.shared[componentName] = bucket
							end
							bucket[info.id] = info.value
						end
					end
				end
			end
		end
	end

	if snapshot.shared and next(snapshot.shared) == nil then
		snapshot.shared = nil
	end
	if snapshot.projectileSpawns and #snapshot.projectileSpawns == 0 then
		snapshot.projectileSpawns = nil
	end
	if snapshot.orbSpawns and #snapshot.orbSpawns == 0 then
		snapshot.orbSpawns = nil
	end

	if player then
		local known = ensurePlayerKnownEntities(player)
		for entityId in pairs(snapshot.entities) do
			if not known[entityId] then
				known[entityId] = true
				profInc("knownEntitiesAdded", 1)
			end
		end
		if snapshot.projectileSpawns then
			for _, spawnData in ipairs(snapshot.projectileSpawns) do
				local entityId = spawnData and spawnData.id
				if entityId and not known[entityId] then
					known[entityId] = true
					profInc("knownEntitiesAdded", 1)
				end
			end
		end
		if snapshot.orbSpawns then
			for _, spawnData in ipairs(snapshot.orbSpawns) do
				local entityId = spawnData and spawnData.id
				if entityId and not known[entityId] then
					known[entityId] = true
					profInc("knownEntitiesAdded", 1)
				end
			end
		end
	end

	return snapshot
end


return SyncSystem





