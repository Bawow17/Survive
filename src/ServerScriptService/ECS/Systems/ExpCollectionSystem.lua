--!strict
-- ExpCollectionSystem - Handles collecting exp orbs when players get near them
-- Phase 4.2 optimization: Uses spatial grid pre-filtering to reduce O(n*m) → O(n*k)

local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local SpatialGridSystem = require(game.ServerScriptService.ECS.Systems.SpatialGridSystem)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)

local ExpCollectionSystem = {}
local GRID_SIZE = SpatialGridSystem.getGridSize()

local world: any
local Components: any
local DirtyService: any
local ECSWorldService: any
local ExpSystem: any  -- Will be set after ExpSystem is loaded
local ExpSinkSystem: any  -- Reference to sink system

local Position: any
local ItemData: any
local EntityTypeComponent: any
local PlayerStats: any

-- Cached queries
local orbQuery: any
local playerQuery: any
local DEBUG = GameOptions.Debug and GameOptions.Debug.Enabled
local DEBUG_LOG_INTERVAL = 2.0
local lastDebugLogTime = 0.0

local function logPickupFailure(orbEntity: number, playerEntity: number, playerName: string?, distance: number?, reason: string)
	if not DEBUG then
		return
	end
	local distanceStr = distance and string.format("%.2f", distance) or "unknown"
	local playerStr = playerName or tostring(playerEntity)
	print(string.format("[ExpCollection] Pickup validation failed | orb=%d | player=%s | distance=%s | reason=%s",
		orbEntity,
		playerStr,
		distanceStr,
		reason
	))
end

function ExpCollectionSystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService
	
	Position = Components.Position
	ItemData = Components.ItemData
	EntityTypeComponent = Components.EntityType
	PlayerStats = Components.PlayerStats
	
	-- Create cached queries
	orbQuery = world:query(Components.Position, Components.ItemData, Components.EntityType):cached()
	playerQuery = world:query(Components.Position, Components.PlayerStats):cached()
end

-- Set ExpSystem reference after it's initialized
function ExpCollectionSystem.setExpSystem(expSystemRef: any)
	ExpSystem = expSystemRef
end

-- Set ExpSinkSystem reference after it's initialized
function ExpCollectionSystem.setExpSinkSystem(expSinkSystemRef: any)
	ExpSinkSystem = expSinkSystemRef
end

-- Collect an orb
local function collectOrb(playerEntity: number, orbEntity: number, expAmount: number, isSink: boolean)
	if not ExpSystem then
		warn("[ExpCollectionSystem] ExpSystem not initialized yet!")
		return
	end
	
	-- Get exp multiplier from player (from BaseExpMultiplier in PlayerBalance)
	local playerStats = world:get(playerEntity, PlayerStats)
	local expMult = 1.0
	if playerStats and playerStats.player then
		expMult = playerStats.player:GetAttribute("ExpMultiplier") or 1.0
	end
	
	-- Apply exp multiplier to amount
	local finalExpAmount = math.floor(expAmount * expMult)
	
	-- Add experience to player
	ExpSystem.addExperience(playerEntity, finalExpAmount)
	
	-- If this was a sink, notify ExpSinkSystem
	if isSink and ExpSinkSystem then
		ExpSinkSystem.onSinkCollected(orbEntity)
	end
	
	-- Remove MagnetPull component if present (before destroying entity)
	local magnetPull = world:get(orbEntity, Components.MagnetPull)
	if magnetPull then
		world:remove(orbEntity, Components.MagnetPull)
	end
	
	-- Mark orb as collected (prevents double collection)
	local itemData = world:get(orbEntity, ItemData)
	local ownerId = nil
	if itemData then
		ownerId = itemData.ownerId
		itemData.collected = true
		DirtyService.setIfChanged(world, orbEntity, ItemData, itemData, "ItemData")
	end
	
	-- Return orb to pool instead of destroying
	local ExpOrbPool = require(game.ServerScriptService.ECS.ExpOrbPool)
	local SyncSystem = require(game.ServerScriptService.ECS.Systems.SyncSystem)
	SyncSystem.queueDespawn(orbEntity)  -- Notify clients to remove visual
	ExpOrbPool.release(orbEntity)
end

function ExpCollectionSystem.step(dt: number)
	if not world or not ExpSystem then
		return
	end
	
	-- Check each player against each orb
	for playerEntity, playerPos, playerStats in playerQuery do
		local playerName = playerStats and playerStats.player and playerStats.player.Name or nil
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
		
		local shouldLogDebug = false
		if DEBUG then
			local now = tick()
			if now - lastDebugLogTime >= DEBUG_LOG_INTERVAL then
				shouldLogDebug = true
				lastDebugLogTime = now
			end
		end
		
		-- DIAGNOSTIC: Log player info (throttled)
		if shouldLogDebug then
			print(string.format("[ExpCollection] Player %d: pos=(%.1f,%.1f,%.1f) radius=%.1f", 
				playerEntity, playerPos.x, playerPos.y, playerPos.z, collectionRadius))
		end
		
		-- Phase 4.2: Spatial grid pre-filtering - only check nearby orbs (O(n*k) instead of O(n*m))
		local playerPosition = Vector3.new(playerPos.x, playerPos.y, playerPos.z)
		local searchRadiusCells = math.max(1, math.ceil((collectionRadius + 10) / GRID_SIZE))  -- +10 stud buffer
		local nearbyEntities = SpatialGridSystem.getNeighboringEntities(playerPosition, searchRadiusCells)
		
		-- Build lookup set for O(1) membership test
		local nearbySet = {}
		for _, entity in ipairs(nearbyEntities) do
			nearbySet[entity] = true
		end
		
		-- Spatial grid does not track exp orbs, so don't use it for orb filtering
		local skipSpatialFilter = true
		
		-- DIAGNOSTIC: Count total orbs and nearby orbs
		local totalOrbs = 0
		local nearbyCount = 0
		local orbsInRange = 0
		local collectionAttempts = 0
		
		for orbEntity, orbPos, orbItemData, orbEntityType in orbQuery do
			totalOrbs += 1

			local distance = nil
			if DEBUG and orbPos then
				local dx = playerPos.x - orbPos.x
				local dy = playerPos.y - orbPos.y
				local dz = playerPos.z - orbPos.z
				distance = math.sqrt(dx * dx + dy * dy + dz * dz)
			end
			
			-- Skip if not nearby (spatial pre-filter) UNLESS spatial grid is empty
			if not skipSpatialFilter and not nearbySet[orbEntity] then
				continue
			end
			nearbyCount += 1
			
			-- Skip if not an exp orb or already collected
			if not orbEntityType or orbEntityType.type ~= "ExpOrb" then
				logPickupFailure(orbEntity, playerEntity, playerName, distance, "wrong_type")
				continue
			end
			if not orbItemData then
				logPickupFailure(orbEntity, playerEntity, playerName, distance, "missing_item_data")
				continue
			end
			if orbItemData and orbItemData.collected then
				logPickupFailure(orbEntity, playerEntity, playerName, distance, "already_collected")
				continue
			end
			-- MULTIPLAYER: Check ownership - can't collect other players' orbs
			if orbItemData and orbItemData.ownerId and orbItemData.ownerId ~= playerEntity then
				logPickupFailure(orbEntity, playerEntity, playerName, distance, "ownership_mismatch")
				-- DIAGNOSTIC: Log ownership mismatch
				print(string.format("[ExpCollection] Orb %d: SKIP - ownership mismatch (ownerId=%s, playerEntity=%s)", 
					orbEntity, tostring(orbItemData.ownerId), tostring(playerEntity)))
				continue
			end
			
			-- Check if orb is being pulled by magnet
			local magnetPull = world:get(orbEntity, Components.MagnetPull)
			local effectiveRadius = collectionRadius
			local effectiveRadiusSq = collectionRadiusSq
			
			-- CRITICAL: Magnetized orbs require VERY small collection radius
			-- This prevents early pickup while orbs are still flying towards player
			-- Ultra-tight radius ensures orbs visually reach the player before collection
			-- Compensates for client interpolation lag (0.03s * 200 studs/s = 6 studs)
			if magnetPull then
				effectiveRadius = 0.8  -- Tight enough to look good, loose enough for reliable collection
				effectiveRadiusSq = effectiveRadius * effectiveRadius
			end
			
			-- Calculate distance squared (avoid sqrt for performance)
			local dx = playerPos.x - orbPos.x
			local dy = playerPos.y - orbPos.y
			local dz = playerPos.z - orbPos.z
			local distSq = dx * dx + dy * dy + dz * dz
			distance = math.sqrt(distSq)
			
			-- DIAGNOSTIC: Log orbs within 30 studs for debugging
			if shouldLogDebug and distance <= 30 then
				orbsInRange += 1
				print(string.format("[ExpCollection] Orb %d: dist=%.2f type=%s collected=%s ownerId=%s playerEntity=%s magnetPull=%s", 
					orbEntity, distance, orbEntityType.type, tostring(orbItemData and orbItemData.collected), 
					tostring(orbItemData and orbItemData.ownerId), tostring(playerEntity), tostring(magnetPull ~= nil)))
			end
			
			-- Check if within collection radius
			if distSq <= effectiveRadiusSq then
				collectionAttempts += 1
				if shouldLogDebug then
					print(string.format("[ExpCollection] ATTEMPTING COLLECTION: Orb %d at distance %.2f (radius %.2f)", 
						orbEntity, distance, effectiveRadius))
				end
				
				local expAmount = orbItemData and orbItemData.expAmount or 10
				local isSink = orbItemData and orbItemData.isSink or false
				collectOrb(playerEntity, orbEntity, expAmount, isSink)
			end
		end
		
		-- DIAGNOSTIC: Summary for this player (throttled)
		if shouldLogDebug then
			print(string.format("[ExpCollection] Player %d summary: %d total orbs, %d nearby, %d in range, %d collection attempts", 
				playerEntity, totalOrbs, nearbyCount, orbsInRange, collectionAttempts))
		end
	end
end

return ExpCollectionSystem

