--!strict
-- ExpSinkSystem - Manages red orb exp-sink when MaxOrbs cap is reached
-- Red orb absorbs voided exp and teleports periodically

local ItemBalance = require(game.ServerScriptService.Balance.ItemBalance)
local OctreeSystem = require(script.Parent.OctreeSystem)
local PauseSystem = require(script.Parent.PauseSystem)

local ExpSinkSystem = {}

local world: any
local Components: any
local DirtyService: any
local ECSWorldService: any
local SyncSystem: any

local Position: any
local EntityTypeComponent: any
local ItemData: any
local Visual: any

-- Cached query
local orbQuery: any

-- MULTIPLAYER: Per-player sink tracking
local playerSinks: {[number]: {
	sinkEntity: number?,
	lastSinkCreatedAt: number,
	pendingBufferedExp: number,
	sinkCreationTime: number?,
	lastTeleportTime: number?,
	totalPausedTime: number,
	lastPauseCheckTime: number,
}} = {}

-- Get or create player sink data
local function getPlayerSinkData(playerEntity: number)
	if not playerSinks[playerEntity] then
		playerSinks[playerEntity] = {
			sinkEntity = nil,
			lastSinkCreatedAt = 0,
			pendingBufferedExp = 0,
			sinkCreationTime = nil,
			lastTeleportTime = nil,
			totalPausedTime = 0,
			lastPauseCheckTime = 0,
		}
	end
	return playerSinks[playerEntity]
end

function ExpSinkSystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any, syncSystem: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService
	SyncSystem = syncSystem
	
	Position = Components.Position
	EntityTypeComponent = Components.EntityType
	ItemData = Components.ItemData
	Visual = Components.Visual
	
	-- Create cached query for orbs
	orbQuery = world:query(Components.Position, Components.EntityType, Components.ItemData):cached()
end

-- MULTIPLAYER: Count non-sink orbs for a specific player
function ExpSinkSystem.countPlayerOrbs(playerEntity: number): number
	if not world then
		return 0
	end
	
	local count = 0
	for entity, position, entityType, itemData in orbQuery do
		if entityType.type == "ExpOrb" 
		   and not (itemData and itemData.isSink) 
		   and itemData.ownerId == playerEntity then
			count = count + 1
		end
	end
	return count
end

-- MULTIPLAYER: Check if specific player should absorb exp instead of spawning new orbs
function ExpSinkSystem.shouldAbsorb(playerEntity: number): boolean
	if not ItemBalance.ExpSink.Enabled or not playerEntity then
		return false
	end
	local orbCount = ExpSinkSystem.countPlayerOrbs(playerEntity)
	return orbCount >= ItemBalance.MaxOrbs
end

-- MULTIPLAYER: Spawn a brand new red orb for specific player
-- Creates the entity directly with all correct properties (no post-modification needed)
local function spawnRedOrb(expAmount: number, playerEntity: number): number?
	-- Get target player position
	local playerPos = world:get(playerEntity, Position)
	if not playerPos then
		return nil
	end
	
	-- Get player sink data
	local sinkData = getPlayerSinkData(playerEntity)
	
	-- Generate random spawn position EXACTLY at radius edge
	local angle = math.random() * math.pi * 2
	local distance = ItemBalance.ExpSink.TeleportRadius  -- Exactly at edge
	
	local offsetX = math.cos(angle) * distance
	local offsetZ = math.sin(angle) * distance
	
	local spawnPos = Vector3.new(
		playerPos.x + offsetX,
		playerPos.y + ItemBalance.OrbHeightOffset,
		playerPos.z + offsetZ
	)
	
	-- Calculate total exp including buffered
	local totalExp = expAmount + sinkData.pendingBufferedExp
	sinkData.pendingBufferedExp = 0
	
	-- Create entity directly with all red orb properties
	-- DON'T use CreateExpOrb - it sets wrong values we'd have to override
	local entity = ECSWorldService.CreateEntity("ExpOrb", spawnPos, nil)
	if not entity then
		warn("[ExpSink] Failed to create red orb entity")
		return nil
	end
	
	-- Set all components with correct red orb values from the start
	local setComp = function(comp, value, name)
		world:set(entity, comp, value)
		DirtyService.mark(entity, name)
	end
	
	setComp(EntityTypeComponent, {
		type = "ExpOrb",
		subtype = "Red",
	}, "EntityType")
	
	setComp(Components.Velocity, { x = 0, y = 0, z = 0 }, "Velocity")
	
	setComp(ItemData, {
		type = "ExpOrb",
		subtype = "Red",
		expAmount = totalExp,
		isSink = true,
		color = ItemBalance.OrbTypes.Red.color,
		collected = false,
		uniqueId = entity,
		ownerId = playerEntity,  -- MULTIPLAYER: Red orb owned by specific player
	}, "ItemData")
	
	-- Start invisible to prevent white flash before color is applied
	setComp(Visual, {
		modelPath = "ReplicatedStorage.ContentDrawer.ItemModels.OrbTemplate",
		visible = false,  -- Start invisible
		scale = ItemBalance.ExpSink.Scale,  -- CORRECT scale from the start
		uniqueId = entity,
	}, "Visual")
	
	setComp(Components.Collision, {
		radius = 1.5,
		solid = false
	}, "Collision")
	
	setComp(Components.Lifetime, {
		remaining = ItemBalance.OrbLifetime,
		max = ItemBalance.OrbLifetime
	}, "Lifetime")
	
	-- Mark entity for initial sync (sends to all clients immediately)
	if SyncSystem then
		SyncSystem.markForInitialSync(entity)
	end
	
	-- Set tracking variables for this player
	sinkData.sinkEntity = entity
	sinkData.sinkCreationTime = tick()
	sinkData.lastTeleportTime = nil
	
	-- Make visible after client has time to process all component data
	task.defer(function()
		if world and world:contains(entity) then
			local visual = world:get(entity, Visual)
			if visual then
				visual.visible = true
				world:set(entity, Visual, visual)
				DirtyService.mark(entity, "Visual")
			end
		end
	end)
	
	return entity
end

-- MULTIPLAYER: Deposit exp into player's sink (or buffer if on cooldown)
function ExpSinkSystem.depositExp(amount: number, playerEntity: number)
	if not world or not ItemBalance.ExpSink.Enabled or not playerEntity then
		return
	end
	
	local sinkData = getPlayerSinkData(playerEntity)
	
	-- Try to add to existing sink
	if sinkData.sinkEntity and world:contains(sinkData.sinkEntity) then
		local itemData = world:get(sinkData.sinkEntity, ItemData)
		if itemData and itemData.isSink then
			-- Add to existing sink's exp
			DirtyService.setIfChanged(world, sinkData.sinkEntity, ItemData, {
				type = itemData.type,
				subtype = itemData.subtype,
				expAmount = itemData.expAmount + amount,
				isSink = itemData.isSink,
				color = itemData.color,
				collected = itemData.collected or false,
				uniqueId = sinkData.sinkEntity,
				ownerId = playerEntity,  -- MULTIPLAYER: Maintain owner
			}, "ItemData")
			return
		else
			-- Sink no longer valid
			sinkData.sinkEntity = nil
		end
	end
	
	-- Check cooldown
	local cooldownActive = (tick() - sinkData.lastSinkCreatedAt) < ItemBalance.ExpSink.SinkCooldown
	
	if cooldownActive then
		-- Buffer exp for next sink
		sinkData.pendingBufferedExp = sinkData.pendingBufferedExp + amount
	else
		-- Only create sink if we don't already have one
		if not sinkData.sinkEntity then
			local newSink = spawnRedOrb(amount, playerEntity)
			if newSink then
				sinkData.lastSinkCreatedAt = tick()  -- Start cooldown immediately
			else
				-- Failed to spawn, buffer for later
				sinkData.pendingBufferedExp = sinkData.pendingBufferedExp + amount
			end
		end
	end
end

-- MULTIPLAYER: Cleanup when sink is collected
function ExpSinkSystem.onSinkCollected(sinkEntity: number)
	-- Find which player owned this sink
	for playerEntity, sinkData in pairs(playerSinks) do
		if sinkData.sinkEntity == sinkEntity then
			sinkData.sinkEntity = nil
			sinkData.lastSinkCreatedAt = tick()  -- Start cooldown
			sinkData.sinkCreationTime = nil
			sinkData.lastTeleportTime = nil
			return
		end
	end
end

-- MULTIPLAYER: Cleanup when any orb entity is destroyed
function ExpSinkSystem.cleanupEntity(entity: number)
	-- Find which player owned this sink
	for playerEntity, sinkData in pairs(playerSinks) do
		if sinkData.sinkEntity == entity then
			sinkData.sinkEntity = nil
			sinkData.sinkCreationTime = nil
			sinkData.lastTeleportTime = nil
			return
		end
	end
end

-- MULTIPLAYER: Teleport player's red orb by destroying old entity and creating new one
-- This is the most reliable way to ensure proper sync
local function teleportSinkToPlayer(playerEntity: number)
	local sinkData = getPlayerSinkData(playerEntity)
	
	if not world or not sinkData.sinkEntity or not world:contains(sinkData.sinkEntity) then
		return false
	end
	
	-- Get player position
	local playerPos = world:get(playerEntity, Position)
	if not playerPos then
		return false
	end
	
	-- Generate position EXACTLY at radius edge
	local angle = math.random() * math.pi * 2
	local distance = ItemBalance.ExpSink.TeleportRadius  -- Exactly at edge
	
	local offsetX = math.cos(angle) * distance
	local offsetZ = math.sin(angle) * distance
	
	local newPos = Vector3.new(
		playerPos.x + offsetX,
		playerPos.y + ItemBalance.OrbHeightOffset,
		playerPos.z + offsetZ
	)
	
	-- Get current exp from old sink
	local oldSink = sinkData.sinkEntity
	local itemData = world:get(oldSink, ItemData)
	local currentExp = (itemData and itemData.expAmount) or 0
	
	-- Destroy old entity
	ECSWorldService.DestroyEntity(oldSink)
	sinkData.sinkEntity = nil
	
	-- Create new entity at new position
	local entity = ECSWorldService.CreateEntity("ExpOrb", newPos, nil)
	if not entity then
		warn("[ExpSink] Failed to create red orb entity during teleport for player", playerEntity)
		return false
	end
	
	-- Set all components
	local setComp = function(comp, value, name)
		world:set(entity, comp, value)
		DirtyService.mark(entity, name)
	end
	
	setComp(EntityTypeComponent, {
		type = "ExpOrb",
		subtype = "Red",
	}, "EntityType")
	
	setComp(Components.Velocity, { x = 0, y = 0, z = 0 }, "Velocity")
	
	setComp(ItemData, {
		type = "ExpOrb",
		subtype = "Red",
		expAmount = currentExp,
		isSink = true,
		color = ItemBalance.OrbTypes.Red.color,
		collected = false,
		uniqueId = entity,
		ownerId = playerEntity,  -- MULTIPLAYER: Maintain owner
	}, "ItemData")
	
	-- Start invisible to prevent white flash
	setComp(Visual, {
		modelPath = "ReplicatedStorage.ContentDrawer.ItemModels.OrbTemplate",
		visible = false,  -- Start invisible
		scale = ItemBalance.ExpSink.Scale,
		uniqueId = entity,
	}, "Visual")
	
	setComp(Components.Collision, {
		radius = 1.5,
		solid = false
	}, "Collision")
	
	setComp(Components.Lifetime, {
		remaining = ItemBalance.OrbLifetime,
		max = ItemBalance.OrbLifetime
	}, "Lifetime")
	
	-- Mark for initial sync
	if SyncSystem then
		SyncSystem.markForInitialSync(entity)
	end
	
	-- Update tracking
	sinkData.sinkEntity = entity
	sinkData.lastTeleportTime = tick()
	
	-- Make visible after client has time to process all component data
	task.defer(function()
		if world and world:contains(entity) then
			local visual = world:get(entity, Visual)
			if visual then
				visual.visible = true
				world:set(entity, Visual, visual)
				DirtyService.mark(entity, "Visual")
			end
		end
	end)
	
	return true
end

-- MULTIPLAYER: Step function for teleportation logic (per-player, pause-aware)
function ExpSinkSystem.step(dt: number)
	if not ItemBalance.ExpSink.Enabled or not ItemBalance.ExpSink.TeleportEnabled then
		return
	end
	
	local currentTime = tick()
	
	-- Iterate over all players' red orbs
	for playerEntity, sinkData in pairs(playerSinks) do
		if not sinkData.sinkEntity then
			continue
		end
		
		if not world:contains(sinkData.sinkEntity) then
			-- Sink destroyed, reset tracking
			sinkData.sinkEntity = nil
			sinkData.sinkCreationTime = nil
			sinkData.lastTeleportTime = nil
			continue
		end
		
		-- Check if game is paused and adjust timers
		if PauseSystem.isPaused() then
			-- Game is paused, accumulate pause time
			if sinkData.lastPauseCheckTime > 0 then
				local pauseDelta = currentTime - sinkData.lastPauseCheckTime
				sinkData.totalPausedTime = sinkData.totalPausedTime + pauseDelta
			end
			sinkData.lastPauseCheckTime = currentTime
			continue  -- Don't process teleportation while paused
		else
			-- Game unpaused, update tracking
			sinkData.lastPauseCheckTime = currentTime
		end
		
		-- Initialize creation time if missing
		if not sinkData.sinkCreationTime then
			sinkData.sinkCreationTime = currentTime
			sinkData.lastTeleportTime = nil
		end
		
		-- Calculate pause-adjusted time
		local pauseAdjustedTime = currentTime - sinkData.totalPausedTime
		local timeSinceCreation = pauseAdjustedTime - (sinkData.sinkCreationTime - sinkData.totalPausedTime)
		
		-- Check if we've passed initial delay
		if timeSinceCreation < ItemBalance.ExpSink.InitialTeleportDelay then
			continue
		end
		
		-- Check if it's time to teleport
		if not sinkData.lastTeleportTime then
			-- First teleport after initial delay
			teleportSinkToPlayer(playerEntity)
		else
			local timeSinceLastTeleport = pauseAdjustedTime - (sinkData.lastTeleportTime - sinkData.totalPausedTime)
			if timeSinceLastTeleport >= ItemBalance.ExpSink.TeleportInterval then
				teleportSinkToPlayer(playerEntity)
			end
		end
	end
end

return ExpSinkSystem
