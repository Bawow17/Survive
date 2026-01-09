--!strict
-- SyncSystem - packages dirty component state and dispatches to clients

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfilingConfig = require(ReplicatedStorage.Shared.ProfilingConfig)
local Prof = ProfilingConfig.ENABLED and require(ReplicatedStorage.Shared.ProfilingServer) or require(ReplicatedStorage.Shared.ProfilingStub)
local PROFILING_ENABLED = ProfilingConfig.ENABLED

local SyncSystem = {}

local world
local DirtyService
local Components
local Remotes
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

local componentLookup: {[string]: any} = {}
local pendingDespawn: {[number]: boolean} = {}
local entityRecipients: {[number]: {[any]: boolean}} = {}

-- PERFORMANCE FIX: Cached query to avoid creating new query every frame (CRITICAL!)
local playerPositionQuery: any

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

Players.PlayerRemoving:Connect(function(player)
	playerSharedKnown[player] = nil
end)

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

local function ensurePlayerPayload(map: {[any]: {updates: {any}?, shared: {[string]: {[number]: any}}?, despawns: {number}?}}, player: Player)
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

local function copyRecipients(source: {[any]: boolean}): {[any]: boolean}
	local copy = getRecipientTable()
	for player in pairs(source) do
		copy[player] = true
	end
	return copy
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

local function attachSharedForPlayer(player: Player, entry: {shared: {[string]: {[number]: any}}?}, shareInfo: {[string]: {id: number, value: any}}?)
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

local function shouldIncludeEntityForPlayer(entity: number, player: Player?)
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

local function buildComponentPayload(entity: number, flags: {[string]: boolean})
	local payload: {[string]: any} = {}
	local shareInfo: {[string]: {id: number, value: any}} = {}

	for componentName in pairs(flags) do
		local component = componentLookup[componentName]
		if component then
			local value = world:get(entity, component)
			if value ~= nil then
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

local function appendDespawns(perPlayerPayload: {[any]: {updates: {any}?, shared: {[string]: {[number]: any}}?, despawns: {number}?}})
	local activePlayers = Players:GetPlayers()
	-- PERFORMANCE FIX: Track despawns per player to enforce batch limits
	local playerDespawnCounts: {[Player]: number} = {}

	for entity in pairs(pendingDespawn) do
		local recipients = entityRecipients[entity]

		if recipients and next(recipients) then
			for player in pairs(recipients) do
				if player and player.Parent == Players then
					-- Enforce batch limit for despawns
					if not playerDespawnCounts[player] then
						playerDespawnCounts[player] = 0
					end
					if playerDespawnCounts[player] < MAX_DESPAWNS_PER_BATCH then
						local entry = ensurePlayerPayload(perPlayerPayload, player)
						table.insert(entry.despawns, entity)
						playerDespawnCounts[player] = playerDespawnCounts[player] + 1
					end
				end
			end
		else
			for _, player in ipairs(activePlayers) do
				-- Enforce batch limit for despawns
				if not playerDespawnCounts[player] then
					playerDespawnCounts[player] = 0
				end
				if playerDespawnCounts[player] < MAX_DESPAWNS_PER_BATCH then
					local entry = ensurePlayerPayload(perPlayerPayload, player)
					table.insert(entry.despawns, entity)
					playerDespawnCounts[player] = playerDespawnCounts[player] + 1
				end
			end
		end

		-- Only clean up if despawn was successfully queued
		local wasQueued = false
		if recipients and next(recipients) then
			for player in pairs(recipients) do
				if playerDespawnCounts[player] and playerDespawnCounts[player] > 0 then
					wasQueued = true
					break
				end
			end
		else
			for _, player in ipairs(activePlayers) do
				if playerDespawnCounts[player] and playerDespawnCounts[player] > 0 then
					wasQueued = true
					break
				end
			end
		end
		
		if wasQueued then
			pendingDespawn[entity] = nil
			entityRecipients[entity] = nil
		end
		-- If not queued due to batch limit, it will be tried again next frame
	end
end

function SyncSystem.init(worldRef: any, components: any, dirtyService: any, remotes: any, opts: any?)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	Remotes = remotes
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
end

function SyncSystem.queueDespawn(entity: number)
	pendingDespawn[entity] = true
	
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
	local perPlayerPayload: {[any]: {updates: {any}?, shared: {[string]: {[number]: any}}?, despawns: {number}?, projectiles: {{number}}?, enemies: {{number}}?}} = {}
	
	-- PERFORMANCE FIX: Track updates per player to enforce batch limits
	local playerUpdateCounts: {[Player]: number} = {}
	
	-- Phase 4.5: Separate projectiles and enemies for compact batching
	local projectileUpdates: {[Player]: {{number}}} = {}  -- Compact arrays per player
	local enemyUpdates: {[Player]: {{number}}} = {}  -- Compact arrays per player
	
	for entity, flags in pairs(dirty) do
		-- Check entity type for batching logic
		local entityTypeValue = world:get(entity, componentLookup.EntityType)
		local entityType = entityTypeValue and entityTypeValue.type
		local isProjectile = entityType == "Projectile"
		local isEnemy = entityType == "Enemy"
		
		-- Check if this is a NEW entity (first sync) or UPDATE (subsequent sync)
		local isNewEntity = entityRecipients[entity] == nil
		
		-- Phase 4.5: Determine if we can use compact format
		-- Can ONLY use compact if:
		-- 1. Is projectile or enemy
		-- 2. Not a new entity
		-- 3. ONLY Position/Velocity/FacingDirection changed (no HitFlash, DeathAnimation, Health, etc.)
		local canUseCompact = false
		if (isProjectile or isEnemy) and not isNewEntity then
			-- Check what components changed
			local hasOnlyMovementComponents = true
			for componentName in pairs(flags) do
				if componentName ~= "Position" and componentName ~= "Velocity" and componentName ~= "FacingDirection" then
					hasOnlyMovementComponents = false
					break
				end
			end
			canUseCompact = hasOnlyMovementComponents
		end
		
		if canUseCompact then
			-- This is a pure movement UPDATE - use compact format
			local pos = world:get(entity, componentLookup.Position)
			local vel = world:get(entity, componentLookup.Velocity)
			
			if pos and vel then
				local recipients = determineRecipients(entity)
				if next(recipients) then
					-- Don't overwrite entityRecipients - it already exists
					
					-- Compact format: {id, px, py, pz, vx, vy, vz}
					local compactData = {
						entity,
						pos.x, pos.y, pos.z,
						vel.x, vel.y, vel.z
					}
					
					for player in pairs(recipients) do
						if isProjectile then
							if not projectileUpdates[player] then
								projectileUpdates[player] = {}
							end
							table.insert(projectileUpdates[player], compactData)
						elseif isEnemy then
							if not enemyUpdates[player] then
								enemyUpdates[player] = {}
							end
							table.insert(enemyUpdates[player], compactData)
						end
					end
				end
			end
		else
			-- NEW entity OR has non-movement components (HitFlash, Health, etc.): use full payload
			local payload, shareInfo = buildComponentPayload(entity, flags)
			if next(payload) then
				payload.id = entity
				local recipients = determineRecipients(entity)
				if next(recipients) then
					-- Only set entityRecipients if it doesn't exist (new entity)
					if not entityRecipients[entity] then
						local recipientCopy = copyRecipients(recipients)
						entityRecipients[entity] = recipientCopy
					end
					
					for player in pairs(recipients) do
						if not playerUpdateCounts[player] then
							playerUpdateCounts[player] = 0
						end
						
						if playerUpdateCounts[player] < MAX_UPDATES_PER_BATCH then
							local entry = ensurePlayerPayload(perPlayerPayload, player)
							attachSharedForPlayer(player, entry, shareInfo)
							table.insert(entry.updates, payload)
							playerUpdateCounts[player] = playerUpdateCounts[player] + 1
						end
					end
				end
			end
		end
	end

	appendDespawns(perPlayerPayload)
	
	-- Phase 4.5: Attach compact projectile and enemy batches
	for player, compactProj in pairs(projectileUpdates) do
		local entry = ensurePlayerPayload(perPlayerPayload, player)
		entry.projectiles = compactProj
	end
	for player, compactEnem in pairs(enemyUpdates) do
		local entry = ensurePlayerPayload(perPlayerPayload, player)
		entry.enemies = compactEnem
	end

	for player, entry in pairs(perPlayerPayload) do
		if not player or player.Parent ~= Players then
			playerSharedKnown[player] = nil
			continue
		end
		if entry.updates and #entry.updates == 0 then
			entry.updates = nil
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

		if entry.updates or entry.despawns or entry.shared or entry.projectiles or entry.enemies then
			local entitiesCount = 0
			if entry.updates then
				entitiesCount += #entry.updates
			end
			if entry.projectiles then
				entitiesCount += #entry.projectiles
			end
			if entry.enemies then
				entitiesCount += #entry.enemies
			end
			if entry.despawns then
				entitiesCount += #entry.despawns
			end

			if PROFILING_ENABLED then
				local payloadBytes = #HttpService:JSONEncode(entry)
				Prof.incCounter("SyncSystem.BytesPerTickPlayer", payloadBytes)
			end
			Prof.incCounter("SyncSystem.EntitiesPerTickPlayer", entitiesCount)

			Remotes.EntityUpdate:FireClient(player, entry)
		end
	end

	Prof.endTimer("SyncSystem.PackSend")
end

function SyncSystem.buildInitialSnapshot(player: Player?)
	local snapshot = {
		shared = {},
		entities = {},
	}

	if not world then
		print("[SyncSystem] buildInitialSnapshot: world is nil")
		return snapshot
	end
	
	-- Reset player's shared state so ALL shared definitions are sent in initial snapshot
	if player then
		playerSharedKnown[player] = nil
	end

	local sharedEntry = { shared = snapshot.shared }

	local query = world:query(Components.Position, Components.EntityType)
	for entity in query do
		if shouldIncludeEntityForPlayer(entity, player) then
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

	if snapshot.shared and next(snapshot.shared) == nil then
		snapshot.shared = nil
	end

	return snapshot
end


return SyncSystem





