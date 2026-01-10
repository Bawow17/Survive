--!strict
-- Client Entity Renderer - Renders ECS entities on the client side
-- Optimized to use shared payload references and client-side interpolation.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ModelPaths = require(ReplicatedStorage.Shared.ModelPaths)
local ProfilingConfig = require(ReplicatedStorage.Shared.ProfilingConfig)
local Prof = ProfilingConfig.ENABLED and require(ReplicatedStorage.Shared.ProfilingClient) or require(ReplicatedStorage.Shared.ProfilingStub)
local PROFILING_ENABLED = ProfilingConfig.ENABLED

local function profInc(name: string, amount: number?)
	if PROFILING_ENABLED then
		Prof.incCounter(name, amount)
	end
end

local player = Players.LocalPlayer

-- Debug flags for diagnostics
local debugFlags = ReplicatedStorage:FindFirstChild("DebugFlags")
local enableInvisibleEnemyDiagnostics = debugFlags and debugFlags:FindFirstChild("InvisibleEnemyDiagnostics")

-- Track pause state to freeze all rendering
local isPaused = false
local pauseStartTime = 0
local totalPausedTime = 0
local isIndividuallyPaused = false  -- Track if THIS player is in individual pause

local enemiesFolder: Instance = workspace:FindFirstChild("Enemies") or Instance.new("Folder")
enemiesFolder.Name = "Enemies"
enemiesFolder.Parent = workspace

local projectilesFolder: Instance = workspace:FindFirstChild("Projectiles") or Instance.new("Folder")
projectilesFolder.Name = "Projectiles"
projectilesFolder.Parent = workspace

local expOrbsFolder: Instance = workspace:FindFirstChild("ExpOrbs") or Instance.new("Folder")
expOrbsFolder.Name = "ExpOrbs"
expOrbsFolder.Parent = workspace

local powerupsFolder: Instance = workspace:FindFirstChild("Powerups") or Instance.new("Folder")
powerupsFolder.Name = "Powerups"
powerupsFolder.Parent = workspace

local afterimageClonesFolder: Instance = workspace:FindFirstChild("AfterimageClones") or Instance.new("Folder")
afterimageClonesFolder.Name = "AfterimageClones"
afterimageClonesFolder.Parent = workspace

local EntitySync = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS"):WaitForChild("EntitySync")
local EntityUpdate = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS"):WaitForChild("EntityUpdate")
local EntityUpdateUnreliable = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS"):FindFirstChild("EntityUpdateUnreliable")
local EntityDespawn = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS"):WaitForChild("EntityDespawn")
local RequestInitialSync = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS"):WaitForChild("RequestInitialSync")

local INTERPOLATION_WINDOW = 0.25 -- default window for slow movement
local FAST_MOVEMENT_INTERPOLATION_WINDOW = 0.05 -- tighter window for high-speed enemies (dashing)
local FAST_MOVEMENT_THRESHOLD = 20 -- studs/sec; lowered from 40 to 20 for tighter interpolation
local HARD_SNAP_THRESHOLD = 30 -- studs; if delta exceeds this, snap immediately (reduced from 50 to prevent teleporting)
local DEAD_RECKONING_TIMEOUT = 0.1 -- Start prediction after 100ms without update
local DEAD_RECKONING_MAX_TIME = 0.2 -- Stop predicting after 200ms total
local DEAD_RECKONING_CORRECTION_TIME = 0.1 -- Smooth correction over 100ms when server update arrives
local PROJECTILE_INTERPOLATION_WINDOW = 0.03 -- tighter window for high-speed projectiles
local PROJECTILE_DEATH_VISUAL_DELAY = 0
local PROJECTILE_MIN_CONTINUE_SPEED = 0.5 -- studs/sec; if slower, despawn immediately
local USE_PROJECTILE_TWEENS = false
local PROJECTILE_TWEEN_USES_FIXED_PATH = false -- ensure server updates drive visuals
local FACE_THRESHOLD = 0.05
local BUFFERED_UPDATE_TTL = 0.75
local BUFFERED_UPDATE_CLEAN_INTERVAL = 0.5
local ORB_BOB_AMPLITUDE = 0.6
local ORB_BOB_FREQUENCY = 1.6

local shareableComponents = {
	EntityType = true,
	AI = true,
	-- Visual = true,  -- REMOVED: Visual is no longer shareable (sent per-entity for red orb teleportation)
	ItemData = true,
	AbilityData = true,
}

local sharedComponents: {[string]: {[number]: any}} = {
	EntityType = {},
	AI = {},
	-- Visual = {},  -- REMOVED: Visual is no longer shareable
	ItemData = {},
	AbilityData = {},
}

type RenderRecord = {
	model: Model,
	entityType: string,
	velocity: any?,
	facingDirection: any?,
	lastUpdate: number,
	fromCFrame: CFrame?,
	toCFrame: CFrame?,
	lerpStart: number?,
	lerpEnd: number?,
	currentCFrame: CFrame?,
    activeTween: Tween?,
    tweenEndsAt: number?,
	tweenEndPosition: Vector3?,
	pendingRemovalTime: number?,
	despawnQueued: boolean?,
	lastRenderTick: number?,
	isFadedOut: boolean?,  -- Track if entity is faded out due to distance
	isSpawning: boolean?,  -- Track if entity is still fading in from spawn
	fadeParts: {BasePart}?,
	fadeDecals: {Decal}?,
	fadeTextures: {Texture}?,
	fadeSurfaceGuis: {SurfaceGui}?,
	anchoredParts: {BasePart}?,
	spawnToken: number?,
	simType: string?,
	simOrigin: Vector3?,
	simVelocity: Vector3?,
	simSpawnTime: number?,
	simLifetime: number?,
	simSeed: number?,
}

local renderedEntities: {[string]: RenderRecord} = {}
local recordByModel: {[Model]: RenderRecord} = {}
local modelCache: {[string]: Model} = {}
local MAX_CACHE_SIZE = 50 -- Limit model cache size to prevent memory bloat (increased to prevent clearing)
local hasInitialSync = false
local knownEntityIds: {[string]: boolean} = {}
local bufferedUpdates: {[string]: {data: {[string]: any}, expiresAt: number}} = {}
local bufferedUpdateTotal = 0
local MAX_BUFFERED_UPDATES = 5000
local lastBufferedUpdateCleanup = 0
local handleEntityDespawn: (string | number, boolean?) -> ()
local lastProjectileCleanup = 0
local lastExpOrbCleanup = 0
local lastDeathCleanupCheck = 0
local lastInvisibleEnemyCheck = 0
local DEATH_CLEANUP_INTERVAL = 1.0  -- Check every second

local function entityKey(entityId: string | number): string
	if typeof(entityId) == "number" then
		return tostring(entityId)
	end
	return entityId
end

local function bufferUpdate(key: string, updateData: {[string]: any})
	local now = tick()
	local existing = bufferedUpdates[key]
	if existing then
		existing.data = updateData
		existing.expiresAt = now + BUFFERED_UPDATE_TTL
		profInc("bufferedUpdateCount", 1)
		return
	end

	if bufferedUpdateTotal >= MAX_BUFFERED_UPDATES then
		local cleanupNow = now
		if cleanupNow - lastBufferedUpdateCleanup >= BUFFERED_UPDATE_CLEAN_INTERVAL then
			lastBufferedUpdateCleanup = cleanupNow
			for entryKey, entry in pairs(bufferedUpdates) do
				if entry.expiresAt <= cleanupNow then
					bufferedUpdates[entryKey] = nil
					bufferedUpdateTotal = math.max(bufferedUpdateTotal - 1, 0)
					profInc("bufferedUnknownUpdatesEvicted", 1)
				end
			end
		end
	end

	if bufferedUpdateTotal >= MAX_BUFFERED_UPDATES then
		profInc("droppedUpdateCount", 1)
		return
	end

	bufferedUpdates[key] = {
		data = updateData,
		expiresAt = now + BUFFERED_UPDATE_TTL,
	}
	bufferedUpdateTotal += 1
	profInc("bufferedUpdateCount", 1)
end

local function cleanupExpiredBufferedUpdates(now: number)
	if now - lastBufferedUpdateCleanup < BUFFERED_UPDATE_CLEAN_INTERVAL then
		return
	end
	lastBufferedUpdateCleanup = now
	for entryKey, entry in pairs(bufferedUpdates) do
		if entry.expiresAt <= now then
			bufferedUpdates[entryKey] = nil
			bufferedUpdateTotal = math.max(bufferedUpdateTotal - 1, 0)
			profInc("bufferedUnknownUpdatesEvicted", 1)
		end
	end
end

local function buildModelCaches(model: Model): {fadeParts: {BasePart}, fadeDecals: {Decal}, fadeTextures: {Texture}, fadeSurfaceGuis: {SurfaceGui}, anchoredParts: {BasePart}}
	local fadeParts = {}
	local fadeDecals = {}
	local fadeTextures = {}
	local fadeSurfaceGuis = {}
	local anchoredParts = {}

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if descendant.Name ~= "Hitbox" and descendant.Name ~= "Attackbox" then
				table.insert(fadeParts, descendant)
			end
			if descendant.Anchored then
				table.insert(anchoredParts, descendant)
			end
		elseif descendant:IsA("Decal") then
			table.insert(fadeDecals, descendant)
		elseif descendant:IsA("Texture") then
			table.insert(fadeTextures, descendant)
		elseif descendant:IsA("SurfaceGui") then
			table.insert(fadeSurfaceGuis, descendant)
		end
	end

	return {
		fadeParts = fadeParts,
		fadeDecals = fadeDecals,
		fadeTextures = fadeTextures,
		fadeSurfaceGuis = fadeSurfaceGuis,
		anchoredParts = anchoredParts,
	}
end

local function destroyVisualModel(model: Model)
	profInc("visualsDestroyed", 1)
	model:Destroy()
end

local function shallowCopy(original: {[any]: any}): {[any]: any}
	local copy = {}
	for key, value in pairs(original) do
		copy[key] = value
	end
	return copy
end

local function applySharedDefinitions(sharedData: any)
	if typeof(sharedData) ~= "table" then
		return
	end

	for componentName, entries in pairs(sharedData) do
		local bucket = sharedComponents[componentName]
		if bucket and typeof(entries) == "table" then
			for id, value in pairs(entries) do
				local numericId = tonumber(id)
				if numericId then
					bucket[numericId] = value
				end
			end
		end
	end
end

local function resolveEntityData(entityData: {[string]: any}): {[string]: any}
	local resolved = shallowCopy(entityData)
	for componentName, value in pairs(entityData) do
		if shareableComponents[componentName] and typeof(value) == "number" then
			local bucket = sharedComponents[componentName]
			if bucket and bucket[value] then
				resolved[componentName] = bucket[value]
			end
		end
	end
	return resolved
end

local function toVector3(position: any): Vector3?
	if typeof(position) == "Vector3" then
		return position
	end
	if typeof(position) == "table" then
		local x = position.x or position.X
		local y = position.y or position.Y
		local z = position.z or position.Z
		if x and y and z then
			return Vector3.new(x, y, z)
		end
	end
	return nil
end

local function toVelocityVector(velocityData: any): Vector3?
	if typeof(velocityData) == "Vector3" then
		return velocityData
	elseif typeof(velocityData) == "table" then
		local x = velocityData.x or velocityData.X
		local y = velocityData.y or velocityData.Y
		local z = velocityData.z or velocityData.Z
		if x or y or z then
			return Vector3.new(x or 0, y or 0, z or 0)
		end
	end
	return nil
end

-- Hit flash and death animation tracking
local hitFlashHighlights: {[Model]: {highlight: Highlight, endTime: number}} = {}
local deathAnimations: {[Model]: {
	startTime: number,
	duration: number,
	started: boolean,
	fadeStarted: boolean,
	expireTime: number,
}} = {}

-- Maximum render distance for projectiles
local MAX_RENDER_DISTANCE = 500 -- Cull projectiles beyond this distance

-- TweenService for smooth enemy movement
local activeEnemyTweens: {[Model]: Tween} = {}

-- Tween event connection tracking for memory leak prevention (CRITICAL FIX)
local activeTweenConnections: {[Instance]: {RBXScriptConnection}} = {}

-- PERFORMANCE OPTIMIZED: Fade in/out management for spawning and culling
-- Chunked transparency changes with proper timing (no expensive TweenService)
local SPAWN_FADE_DURATION = 0.5  -- Total fade duration in seconds
local CULL_FADE_DURATION = 0.3   -- Total fade duration for culling
local DEATH_FADE_DURATION = 0.2  -- Death fade duration
local FADE_CHUNK_INTERVAL = 0.05 -- Update transparency every 0.05s (20 FPS fade rate)
local EXPLOSION_STEPS = 10
local EXPLOSION_EXPAND_DURATION = 0.25
local EXPLOSION_FADE_DURATION = 0.25
local PROJECTILE_CLEAN_INTERVAL = 5
local PROJECTILE_STALE_THRESHOLD = 1.5
local EXP_ORB_STALE_THRESHOLD = 5.0  -- Exp orbs without updates for 5s are stale
local INVISIBLE_ENEMY_DIAGNOSTIC_INTERVAL = 5.0  -- Check for invisible enemies every 5s
local SPAWN_BUDGET_PER_FRAME = 15
local FADE_OP_BUDGET_PER_FRAME = 750

-- Active fades being processed with chunked updates
local activeFades: {[Model]: {
	targetTrans: number,
	startTrans: number,
	startTime: number,
	duration: number,
	lastUpdate: number,
	pendingOpsCount: number?,
	done: boolean?,
	model: Model?,
	fadeParts: {BasePart}?,
	fadeDecals: {Decal}?,
	fadeTextures: {Texture}?,
	fadeSurfaceGuis: {SurfaceGui}?,
	onComplete: (() -> ())?
}} = {}

local fadeOpQueue: {{list: {any}, index: number, target: number, kind: string, fade: any}} = {}
local fadeOpQueueHead = 1
local fadeQueuedOps = 0

local spawnQueue: {{entityId: string | number, data: {[string]: any}}} = {}
local spawnQueueHead = 1
local spawnQueueSet: {[string]: boolean} = {}

-- Optimized fade function - sets transparency immediately without tweens
local function setModelTransparency(model: Model, targetTransparency: number, cache: {fadeParts: {BasePart}?, fadeDecals: {Decal}?, fadeTextures: {Texture}?, fadeSurfaceGuis: {SurfaceGui}?}?)
	if not model or not model.Parent then
		return
	end
	
	-- Set transparency for all visible parts (much faster than tweens!)
	local descendantOps = 0
	local fadeParts = cache and cache.fadeParts
	local fadeDecals = cache and cache.fadeDecals
	local fadeTextures = cache and cache.fadeTextures
	local fadeSurfaceGuis = cache and cache.fadeSurfaceGuis

	if not fadeParts then
		local record = recordByModel[model]
		if record then
			fadeParts = record.fadeParts
			fadeDecals = record.fadeDecals
			fadeTextures = record.fadeTextures
			fadeSurfaceGuis = record.fadeSurfaceGuis
		end
	end

	if fadeParts then
		for _, part in ipairs(fadeParts) do
			if part and part.Parent then
				descendantOps += 1
				local originalTrans = part:GetAttribute("OriginalTransparency")
				if not originalTrans or typeof(originalTrans) ~= "number" then
					part:SetAttribute("OriginalTransparency", part.Transparency)
					originalTrans = part.Transparency
				end

				local actualTarget = targetTransparency
				if targetTransparency == 0 and typeof(originalTrans) == "number" then
					actualTarget = originalTrans
				end

				part.Transparency = actualTarget
			end
		end

		if fadeDecals then
			for _, decal in ipairs(fadeDecals) do
				if decal and decal.Parent then
					descendantOps += 1
					local originalDecalTrans = decal:GetAttribute("OriginalTransparency")
					if not originalDecalTrans or typeof(originalDecalTrans) ~= "number" then
						decal:SetAttribute("OriginalTransparency", decal.Transparency)
						originalDecalTrans = decal.Transparency
					end

					local actualDecalTarget = targetTransparency
					if targetTransparency == 0 and typeof(originalDecalTrans) == "number" then
						actualDecalTarget = originalDecalTrans
					end

					decal.Transparency = actualDecalTarget
				end
			end
		end

		if fadeTextures then
			for _, texture in ipairs(fadeTextures) do
				if texture and texture.Parent then
					descendantOps += 1
					local originalTextureTrans = texture:GetAttribute("OriginalTransparency")
					if not originalTextureTrans or typeof(originalTextureTrans) ~= "number" then
						texture:SetAttribute("OriginalTransparency", texture.Transparency)
						originalTextureTrans = texture.Transparency
					end

					local actualTextureTarget = targetTransparency
					if targetTransparency == 0 and typeof(originalTextureTrans) == "number" then
						actualTextureTarget = originalTextureTrans
					end

					texture.Transparency = actualTextureTarget
				end
			end
		end

		if fadeSurfaceGuis then
			for _, surfaceGui in ipairs(fadeSurfaceGuis) do
				if surfaceGui and surfaceGui.Parent then
					descendantOps += 1
					surfaceGui.Enabled = targetTransparency < 0.5
				end
			end
		end
	else
		return
	end

	if descendantOps > 0 then
		Prof.incCounter("ClientEntityRenderer.DescendantOps", descendantOps)
	end
end

-- Get current average transparency of model
local function getCurrentModelTransparency(model: Model, cache: {fadeParts: {BasePart}?}?): number
	if not model or not model.Parent then
		return 0
	end
	
	local totalTrans = 0
	local count = 0
	local fadeParts = cache and cache.fadeParts
	if not fadeParts then
		local record = recordByModel[model]
		if record then
			fadeParts = record.fadeParts
		end
	end

	if fadeParts then
		for _, part in ipairs(fadeParts) do
			if part and part.Parent then
				totalTrans = totalTrans + part.Transparency
				count = count + 1
				break
			end
		end
	end
	
	return count > 0 and (totalTrans / count) or 0
end

local function applyFadeInstance(instance: Instance, targetTransparency: number, kind: string)
	if kind == "part" then
		local part = instance :: BasePart
		if part and part.Parent then
			local originalTrans = part:GetAttribute("OriginalTransparency")
			if not originalTrans or typeof(originalTrans) ~= "number" then
				part:SetAttribute("OriginalTransparency", part.Transparency)
				originalTrans = part.Transparency
			end
			local actualTarget = targetTransparency
			if targetTransparency == 0 and typeof(originalTrans) == "number" then
				actualTarget = originalTrans
			end
			part.Transparency = actualTarget
			return true
		end
	elseif kind == "decal" then
		local decal = instance :: Decal
		if decal and decal.Parent then
			local originalDecalTrans = decal:GetAttribute("OriginalTransparency")
			if not originalDecalTrans or typeof(originalDecalTrans) ~= "number" then
				decal:SetAttribute("OriginalTransparency", decal.Transparency)
				originalDecalTrans = decal.Transparency
			end
			local actualDecalTarget = targetTransparency
			if targetTransparency == 0 and typeof(originalDecalTrans) == "number" then
				actualDecalTarget = originalDecalTrans
			end
			decal.Transparency = actualDecalTarget
			return true
		end
	elseif kind == "texture" then
		local texture = instance :: Texture
		if texture and texture.Parent then
			local originalTextureTrans = texture:GetAttribute("OriginalTransparency")
			if not originalTextureTrans or typeof(originalTextureTrans) ~= "number" then
				texture:SetAttribute("OriginalTransparency", texture.Transparency)
				originalTextureTrans = texture.Transparency
			end
			local actualTextureTarget = targetTransparency
			if targetTransparency == 0 and typeof(originalTextureTrans) == "number" then
				actualTextureTarget = originalTextureTrans
			end
			texture.Transparency = actualTextureTarget
			return true
		end
	elseif kind == "surface" then
		local surfaceGui = instance :: SurfaceGui
		if surfaceGui and surfaceGui.Parent then
			surfaceGui.Enabled = targetTransparency < 0.5
			return true
		end
	end

	return false
end

local function enqueueFadeList(fade: any, list: {any}?, kind: string, targetTransparency: number)
	if not list or #list == 0 then
		return
	end
	table.insert(fadeOpQueue, {
		list = list,
		index = 1,
		target = targetTransparency,
		kind = kind,
		fade = fade,
	})
	fade.pendingOpsCount = (fade.pendingOpsCount or 0) + 1
	fadeQueuedOps += #list
end

local function enqueueFadeOps(fade: any, targetTransparency: number)
	enqueueFadeList(fade, fade.fadeParts, "part", targetTransparency)
	enqueueFadeList(fade, fade.fadeDecals, "decal", targetTransparency)
	enqueueFadeList(fade, fade.fadeTextures, "texture", targetTransparency)
	enqueueFadeList(fade, fade.fadeSurfaceGuis, "surface", targetTransparency)
end

local function finishFadeIfReady(fade: any)
	if fade.pendingOpsCount and fade.pendingOpsCount <= 0 then
		fade.pendingOpsCount = 0
		if fade.done and fade.model then
			activeFades[fade.model] = nil
			if fade.onComplete then
				local callback = fade.onComplete
				fade.onComplete = nil
				callback()
			end
		end
	end
end

local function processFadeOps()
	local opsThisFrame = 0
	local budget = FADE_OP_BUDGET_PER_FRAME
	while budget > 0 and fadeOpQueueHead <= #fadeOpQueue do
		local task = fadeOpQueue[fadeOpQueueHead]
		local list = task.list
		while budget > 0 and task.index <= #list do
			local instance = list[task.index]
			task.index += 1
			if applyFadeInstance(instance, task.target, task.kind) then
				opsThisFrame += 1
				Prof.incCounter("ClientEntityRenderer.DescendantOps", 1)
			end
			fadeQueuedOps = math.max(fadeQueuedOps - 1, 0)
			budget -= 1
		end
		if task.index > #list then
			fadeOpQueueHead += 1
			if task.fade then
				task.fade.pendingOpsCount = (task.fade.pendingOpsCount or 1) - 1
				finishFadeIfReady(task.fade)
			end
		end
	end

	if fadeOpQueueHead > 50 and fadeOpQueueHead > (#fadeOpQueue / 2) then
		local newQueue = {}
		for i = fadeOpQueueHead, #fadeOpQueue do
			newQueue[#newQueue + 1] = fadeOpQueue[i]
		end
		fadeOpQueue = newQueue
		fadeOpQueueHead = 1
	end

	if opsThisFrame > 0 then
		Prof.incCounter("fadeOpsThisFrame", opsThisFrame)
	end
	Prof.gauge("fadeQueueDepth", fadeQueuedOps)
end

-- Queue a fade operation (non-blocking, processed in chunks)
local function fadeModel(model: Model, targetTransparency: number, duration: number, onComplete: (() -> ())?)
	if not model or not model.Parent then
		if onComplete then
			onComplete()
		end
		return
	end
	
	-- If immediate (0 duration), just set transparency now
	if duration <= 0 then
		local record = recordByModel[model]
		local cache = record and {
			fadeParts = record.fadeParts,
			fadeDecals = record.fadeDecals,
			fadeTextures = record.fadeTextures,
			fadeSurfaceGuis = record.fadeSurfaceGuis,
		} or buildModelCaches(model)
		setModelTransparency(model, targetTransparency, cache)
		if onComplete then
			onComplete()
		end
		return
	end
	
	local record = recordByModel[model]
	local cache = record and {
		fadeParts = record.fadeParts,
		fadeDecals = record.fadeDecals,
		fadeTextures = record.fadeTextures,
		fadeSurfaceGuis = record.fadeSurfaceGuis,
	} or buildModelCaches(model)
	local startTrans = getCurrentModelTransparency(model, cache)
	local currentTime = tick()
	
	-- Queue fade to be processed in chunks over time
	activeFades[model] = {
		model = model,
		targetTrans = targetTransparency,
		startTrans = startTrans,
		startTime = currentTime,
		duration = duration,
		lastUpdate = currentTime,
		pendingOpsCount = 0,
		done = false,
		fadeParts = cache and cache.fadeParts or nil,
		fadeDecals = cache and cache.fadeDecals or nil,
		fadeTextures = cache and cache.fadeTextures or nil,
		fadeSurfaceGuis = cache and cache.fadeSurfaceGuis or nil,
		onComplete = onComplete
	}
end

-- Process all active fades with chunked updates (OPTIMIZED - only updates every FADE_CHUNK_INTERVAL)
local function processFades()
	local currentTime = tick()
	if next(activeFades) == nil then
		return
	end

	local fadesProcessed = 0
	for model, fade in pairs(activeFades) do
		fadesProcessed += 1
		if not model or not model.Parent then
			-- Model destroyed, clean up
			activeFades[model] = nil
			fade.done = true
			fade.pendingOpsCount = 0
			finishFadeIfReady(fade)
			continue
		end
		
		-- Calculate elapsed time since fade started
		local elapsed = currentTime - fade.startTime
		
		-- Check if fade is complete
		if elapsed >= fade.duration then
			if fade.pendingOpsCount and fade.pendingOpsCount > 0 then
				fade.done = true
			else
				fade.done = true
				enqueueFadeOps(fade, fade.targetTrans)
				finishFadeIfReady(fade)
			end
			continue
		end
		
		-- OPTIMIZATION: Only update transparency in chunks (every FADE_CHUNK_INTERVAL)
		local timeSinceLastUpdate = currentTime - fade.lastUpdate
		if timeSinceLastUpdate >= FADE_CHUNK_INTERVAL and (not fade.pendingOpsCount or fade.pendingOpsCount == 0) then
			fade.lastUpdate = currentTime
			
			-- Calculate progress (0 to 1)
			local progress = math.clamp(elapsed / fade.duration, 0, 1)
			
			-- Linear interpolation from start to target transparency
			local currentTrans = fade.startTrans + (fade.targetTrans - fade.startTrans) * progress
			
			enqueueFadeOps(fade, currentTrans)
		end
	end

	if fadesProcessed > 0 then
		Prof.incCounter("ClientEntityRenderer.Fades", fadesProcessed)
	end
end


-- Handle hit flash VFX (white highlight effect)
local function handleHitFlash(model: Model, hitFlashData: any)
	if not model or not hitFlashData then
		return
	end
	
	local existing = hitFlashHighlights[model]
	local currentTime = tick()
	
	-- ALWAYS use CLIENT time for flash duration (never trust server timestamps)
	local flashDuration = 0.15  -- Match server-side HIT_FLASH_DURATION
	local endTime = currentTime + flashDuration
	
	-- If already has highlight, just refresh the timer
	if existing then
		existing.endTime = endTime
		return
	end
	
	-- Find or create highlight directly in the model
	local highlight = model:FindFirstChildOfClass("Highlight")
	if not highlight then
		highlight = Instance.new("Highlight")
		highlight.Name = "HitFlash"
		highlight.FillColor = Color3.new(1, 1, 1) -- White
		highlight.OutlineColor = Color3.new(1, 1, 1) -- White
		highlight.FillTransparency = 0.5
		highlight.OutlineTransparency = 0
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Parent = model
	end
	
	hitFlashHighlights[model] = {
		highlight = highlight,
		endTime = endTime
	}
	
	-- DIAGNOSTICS: Log HitFlash events (only for first few per game)
	local modelEid = model:GetAttribute("ECS_EntityId")
	if not model:GetAttribute("HitFlashLogged") then
		model:SetAttribute("HitFlashLogged", true)
	end
end

local function findRecordByModel(model: Model): RenderRecord?
	for _, record in pairs(renderedEntities) do
		if record.model == model then
			return record
		end
	end
	return nil
end

-- OPTIMIZED: Handle death fade animation using chunked fade system
local function handleDeathAnimation(model: Model, deathData: any)
	if not model or not deathData then
		return
	end
	
	-- Check if death animation already started
	if deathAnimations[model] and deathAnimations[model].started then
		-- Already started, don't restart
		return
	end
	
	-- ALWAYS use CLIENT time, never trust server timestamps
	local now = tick()
	local flashDuration = 0.15  -- Match HIT_FLASH_DURATION (must match server!)
	local fadeDuration = deathData.duration or DEATH_FADE_DURATION or 0.5
	local deathBufferTime = 0.05  -- Match server DEATH_ANIMATION_BUFFER
	local startTime = now + flashDuration + deathBufferTime  -- Wait for HitFlash + buffer
	
	-- CRITICAL FIX: If we're receiving this late (e.g. after pause), start immediately
	-- Check if model has been waiting for a while (stale data)
	local modelAge = 0
	local record = findRecordByModel(model)
	if record and record.spawnTime then
		modelAge = now - record.spawnTime
	end
	
	-- If model is old (>0.5s) and we're getting death animation, assume we missed the flash
	if modelAge > 0.5 then
		startTime = now  -- Start fade immediately, skip flash
	end
	
	local expireTime = startTime + fadeDuration + 0.5
	
	-- DIAGNOSTICS: Log death animation creation (first few per session)
	local modelEid = model:GetAttribute("ECS_EntityId")
	if not model:GetAttribute("DeathAnimLogged") then
		model:SetAttribute("DeathAnimLogged", true)
	end
	
	-- Mark as started IMMEDIATELY to prevent multiple animations
	deathAnimations[model] = {
		started = true,
		fadeStarted = false,
		startTime = startTime,
		duration = fadeDuration,
		expireTime = expireTime,
	}
end

local function updateDeathAnimations()
	if next(deathAnimations) == nil then
		return
	end

	local now = tick()
	for model, info in pairs(deathAnimations) do
		if not model or not model.Parent then
			deathAnimations[model] = nil
			-- Explicitly destroy highlight before clearing reference
			local flashData = hitFlashHighlights[model]
			if flashData and flashData.highlight then
				flashData.highlight:Destroy()
			end
			hitFlashHighlights[model] = nil
			-- Ensure model is destroyed if it still exists
			if model and model.Parent then
				recordByModel[model] = nil
				destroyVisualModel(model)
			end
		else
			local startTime = info.startTime or now
			local duration = math.max(0, info.duration or DEATH_FADE_DURATION)
			if not info.fadeStarted and now >= startTime then
				info.fadeStarted = true
				fadeModel(model, 1, duration, function()
					if model and model.Parent then
						if activeEnemyTweens[model] then
							pcall(function()
								activeEnemyTweens[model]:Cancel()
							end)
							activeEnemyTweens[model] = nil
						end
						if activeFades[model] then
							activeFades[model] = nil
						end
						recordByModel[model] = nil
						destroyVisualModel(model)
					end
					deathAnimations[model] = nil
					-- Explicitly destroy highlight before clearing reference
					local flashData = hitFlashHighlights[model]
					if flashData and flashData.highlight then
						flashData.highlight:Destroy()
					end
					hitFlashHighlights[model] = nil
				end)
			elseif info.fadeStarted then
				if now >= (startTime + duration + 0.25) then
					if model and model.Parent then
						if activeEnemyTweens[model] then
							pcall(function()
								activeEnemyTweens[model]:Cancel()
							end)
							activeEnemyTweens[model] = nil
						end
						if activeFades[model] then
							activeFades[model] = nil
						end
						recordByModel[model] = nil
						destroyVisualModel(model)
					end
					deathAnimations[model] = nil
					-- Explicitly destroy highlight before clearing reference
					local flashData = hitFlashHighlights[model]
					if flashData and flashData.highlight then
						flashData.highlight:Destroy()
					end
					hitFlashHighlights[model] = nil
				end
			elseif now >= info.expireTime then
				-- Failsafe: trigger immediate fade if we missed the window
				info.startTime = now
				info.duration = DEATH_FADE_DURATION
				info.expireTime = now + DEATH_FADE_DURATION + 0.5
			end
		end
	end
end

local function cleanupStaleProjectiles(now: number)
	if now - lastProjectileCleanup < PROJECTILE_CLEAN_INTERVAL then
		return
	end
	lastProjectileCleanup = now

	for _, projectileModel in ipairs(projectilesFolder:GetChildren()) do
		if projectileModel:IsA("Model") then
			local entityIdAttr = projectileModel:GetAttribute("ECS_EntityId")
			local lastUpdateAttr = projectileModel:GetAttribute("ECS_LastUpdate")
			local keyFromAttr = nil
			if typeof(entityIdAttr) == "string" or typeof(entityIdAttr) == "number" then
				keyFromAttr = entityKey(entityIdAttr)
			end
			local mappedRecord = keyFromAttr and renderedEntities[keyFromAttr]
			local lastStamp = typeof(lastUpdateAttr) == "number" and lastUpdateAttr or 0

			if mappedRecord and mappedRecord.simType == "Projectile" then
				if mappedRecord.simLifetime and mappedRecord.simSpawnTime then
					if (now - mappedRecord.simSpawnTime) > (mappedRecord.simLifetime + 0.25) then
						handleEntityDespawn(keyFromAttr, true)
					end
				end
			elseif not mappedRecord or (now - lastStamp) > PROJECTILE_STALE_THRESHOLD then
				if activeFades[projectileModel] then
					activeFades[projectileModel] = nil
				end
				if mappedRecord then
					handleEntityDespawn(keyFromAttr, true)
				elseif projectileModel and projectileModel.Parent then
					if keyFromAttr then
						knownEntityIds[keyFromAttr] = nil
					end
					recordByModel[projectileModel] = nil
					destroyVisualModel(projectileModel)
				end
			end
		end
	end
end

local function cleanupStaleExpOrbs(now: number)
	if now - lastExpOrbCleanup < PROJECTILE_CLEAN_INTERVAL then
		return
	end
	lastExpOrbCleanup = now

	local cleanupCount = 0
	for _, orbModel in ipairs(expOrbsFolder:GetChildren()) do
		if orbModel:IsA("Model") then
			local entityIdAttr = orbModel:GetAttribute("ECS_EntityId")
			local lastUpdateAttr = orbModel:GetAttribute("ECS_LastUpdate")
			local keyFromAttr = nil
			if typeof(entityIdAttr) == "string" or typeof(entityIdAttr) == "number" then
				keyFromAttr = entityKey(entityIdAttr)
			end
			local mappedRecord = keyFromAttr and renderedEntities[keyFromAttr]
			local lastStamp = typeof(lastUpdateAttr) == "number" and lastUpdateAttr or 0
			local timeSinceUpdate = now - lastStamp

			if mappedRecord and mappedRecord.simType == "ExpOrb" then
				if mappedRecord.simLifetime and mappedRecord.simSpawnTime then
					if (now - mappedRecord.simSpawnTime) > (mappedRecord.simLifetime + 0.25) then
						handleEntityDespawn(keyFromAttr, true)
					end
				end
			elseif not mappedRecord or timeSinceUpdate > EXP_ORB_STALE_THRESHOLD then
				if activeFades[orbModel] then
					activeFades[orbModel] = nil
				end
				if deathAnimations[orbModel] then
					deathAnimations[orbModel] = nil
				end
				if mappedRecord then
					local ok = false
					if handleEntityDespawn then
						ok = pcall(handleEntityDespawn, keyFromAttr, true)
					end
					if not ok then
						profInc("cleanupErrors", 1)
					end
				elseif orbModel and orbModel.Parent then
					if keyFromAttr then
						knownEntityIds[keyFromAttr] = nil
					end
					recordByModel[orbModel] = nil
					destroyVisualModel(orbModel)
				end
				cleanupCount = cleanupCount + 1
			end
		end
	end
end

-- Diagnostic function to detect invisible enemies (entities without models)
local function checkForInvisibleEnemies(now: number)
	if now - lastInvisibleEnemyCheck < INVISIBLE_ENEMY_DIAGNOSTIC_INTERVAL then
		return
	end
	lastInvisibleEnemyCheck = now
	
	-- Check for entity records without workspace models
	local invisibleCount = 0
	local enemyRecordCount = 0
	for key, record in pairs(renderedEntities) do
		if record.entityType == "Enemy" then
			enemyRecordCount = enemyRecordCount + 1
			if not record.model or not record.model.Parent then
				invisibleCount = invisibleCount + 1
			end
		end
	end
	
	-- Check for workspace enemy models without entity records
	local orphanCount = 0
	local workspaceEnemyCount = 0
	for _, enemyModel in ipairs(enemiesFolder:GetChildren()) do
		if enemyModel:IsA("Model") then
			workspaceEnemyCount = workspaceEnemyCount + 1
			local entityIdAttr = enemyModel:GetAttribute("ECS_EntityId")
			if entityIdAttr then
				local key = entityKey(entityIdAttr)
				if not renderedEntities[key] then
					orphanCount = orphanCount + 1
				end
			end
		end
	end
end

-- Client-side ground detection using raycasting
local groundRaycastParams = RaycastParams.new()
groundRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
groundRaycastParams.IgnoreWater = true

local groundIgnoreCache = {}
local lastGroundIgnoreRefresh = 0
local GROUND_IGNORE_REFRESH_INTERVAL = 1

local function getGroundIgnoreList()
	local now = tick()
	if now - lastGroundIgnoreRefresh < GROUND_IGNORE_REFRESH_INTERVAL and #groundIgnoreCache > 0 then
		return groundIgnoreCache
	end

	table.clear(groundIgnoreCache)
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character then
			for _, descendant in ipairs(character:GetDescendants()) do
				if descendant:IsA("BasePart") then
					table.insert(groundIgnoreCache, descendant)
				end
			end
		end
	end

	lastGroundIgnoreRefresh = now
	return groundIgnoreCache
end

local function getGroundHeight(position: Vector3): number?
	groundRaycastParams.FilterDescendantsInstances = getGroundIgnoreList()
	
	local origin = Vector3.new(position.X, position.Y + 25, position.Z)
	local result = workspace:Raycast(origin, Vector3.new(0, -250, 0), groundRaycastParams)
	if result then
		return result.Position.Y
	end
	return nil
end

local function setCFramePosition(base: CFrame, position: Vector3): CFrame
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = base:GetComponents()
	return CFrame.new(position.X, position.Y, position.Z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
end

local function computeTargetCFrame(position: Vector3?, facingData: any, velocityData: any, fallback: CFrame?, entityType: string?): CFrame
	local targetPosition = position
	local reference = fallback or CFrame.new()
	if not targetPosition then
		targetPosition = reference.Position
	end

	-- Only apply ground snapping to enemies, not projectiles, exp orbs, powerups, or afterimage clones
	if entityType ~= "Projectile" and entityType ~= "ExpOrb" and entityType ~= "Powerup" and entityType ~= "AfterimageClone" then
		local groundHeight = getGroundHeight(targetPosition)
		if groundHeight then
			targetPosition = Vector3.new(targetPosition.X, groundHeight, targetPosition.Z)
		end
	end

	-- First try to use FacingDirection component if available
	if facingData and typeof(facingData) == "table" then
		local facingX = facingData.x or facingData.X
		local facingY = facingData.y or facingData.Y
		local facingZ = facingData.z or facingData.Z
		
		-- For projectiles, use full 3D facing direction
		if entityType == "Projectile" and facingX and facingY and facingZ then
			local facingVector = Vector3.new(facingX, facingY, facingZ)
			if facingVector.Magnitude > FACE_THRESHOLD then
				return CFrame.lookAt(targetPosition, targetPosition + facingVector.Unit)
			end
		-- For other entities (like enemies), use horizontal facing only
		elseif facingX and facingZ then
			local facingVector = Vector3.new(facingX, 0, facingZ)
			if facingVector.Magnitude > FACE_THRESHOLD then
				return CFrame.lookAt(targetPosition, targetPosition + facingVector.Unit)
			end
		end
	end

	-- Fallback to velocity-based facing if no FacingDirection
	local velocityVector = toVelocityVector(velocityData)
	if velocityVector and velocityVector.Magnitude > FACE_THRESHOLD then
		-- For projectiles, use full 3D velocity direction
		if entityType == "Projectile" then
			return CFrame.lookAt(targetPosition, targetPosition + velocityVector.Unit)
		-- For other entities, use horizontal velocity only
		else
			local horizontal = Vector3.new(velocityVector.X, 0, velocityVector.Z)
			if horizontal.Magnitude > FACE_THRESHOLD then
				return CFrame.lookAt(targetPosition, targetPosition + horizontal.Unit)
			end
		end
	end

	return setCFramePosition(reference, targetPosition)
end

-- Clone a player's character appearance for afterimage clones
local function clonePlayerCharacter(sourcePlayer: Player, transparency: number): Model?
	if not sourcePlayer or not sourcePlayer.Character then
		warn("[ClientEntityRenderer] Cannot clone character - sourcePlayer or character is nil")
		return nil
	end
	
	local sourceCharacter = sourcePlayer.Character
	local cloneModel = Instance.new("Model")
	cloneModel.Name = sourcePlayer.Name .. "_Clone"
	
	
	-- Get source character's HumanoidRootPart as reference for relative positioning
	local sourceHRP = sourceCharacter:FindFirstChild("HumanoidRootPart")
	if not sourceHRP then
		warn("[ClientEntityRenderer] Source character has no HumanoidRootPart - cannot clone")
		return nil
	end
	
	-- Store part CFrames RELATIVE to HumanoidRootPart (maintains pose, not world position)
	local partOffsets = {}
	for _, child in ipairs(sourceCharacter:GetChildren()) do
		if child:IsA("BasePart") then
			-- Store offset from HumanoidRootPart in local space
			partOffsets[child.Name] = sourceHRP.CFrame:ToObjectSpace(child.CFrame)
		elseif child:IsA("Accessory") then
			-- Store accessory handle position relative to HumanoidRootPart
			local handle = child:FindFirstChild("Handle")
			if handle and handle:IsA("BasePart") then
				partOffsets[child.Name .. "_Handle"] = sourceHRP.CFrame:ToObjectSpace(handle.CFrame)
			end
		end
	end
	
	-- Clone all body parts and accessories
	for _, child in ipairs(sourceCharacter:GetChildren()) do
		-- Clone Humanoid (needed for Shirts/Pants to display properly)
		if child:IsA("Humanoid") then
			local humanoidClone = child:Clone()
			
			-- Remove all status effects that could affect gameplay
			for _, statusEffect in ipairs(humanoidClone:GetChildren()) do
				if statusEffect:IsA("NumberValue") or statusEffect:IsA("ObjectValue") then
					statusEffect:Destroy()
				end
			end
			
			-- CRITICAL: Completely disable humanoid physics and movement
			humanoidClone.Health = 0
			humanoidClone.MaxHealth = 0
			humanoidClone.WalkSpeed = 0
			humanoidClone.JumpPower = 0
			humanoidClone.JumpHeight = 0
			humanoidClone.AutoRotate = false
			humanoidClone.AutoJumpEnabled = false
			humanoidClone.PlatformStand = true  -- Prevent physics
			humanoidClone.Sit = true  -- Disable walking
			humanoidClone.RequiresNeck = false  -- Don't need neck joint
			
			-- Disable all humanoid display elements
			humanoidClone.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			humanoidClone.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			humanoidClone.NameDisplayDistance = 0
			humanoidClone.NameOcclusion = Enum.NameOcclusion.OccludeAll
			
			humanoidClone.Parent = cloneModel
		-- Clone body parts (R6 parts) - exclude HumanoidRootPart
		elseif child:IsA("BasePart") and child.Name ~= "HumanoidRootPart" then
			local partClone = child:Clone()
			
			-- CRITICAL: Remove all Motor6D and Weld constraints that connect to original character
			-- But KEEP Attachments (needed for accessories)
			for _, descendant in ipairs(partClone:GetDescendants()) do
				if descendant:IsA("Motor6D") or descendant:IsA("Weld") or descendant:IsA("WeldConstraint") then
					descendant:Destroy()
				end
			end
			
			partClone.CanCollide = false
			partClone.Anchored = true
			partClone.CastShadow = false
			partClone.Transparency = transparency
			partClone.Parent = cloneModel
			
		-- Clone accessories (hats, clothing, etc.) - MANUAL cloning to avoid welds
		elseif child:IsA("Accessory") then
			-- Clone just the Handle (visual mesh) from the accessory, NOT the accessory itself
			local handle = child:FindFirstChild("Handle")
			if handle and handle:IsA("BasePart") then
				local handleClone = handle:Clone()
				handleClone.Name = child.Name .. "_Handle"  -- Match the name used in partOffsets
				handleClone.CanCollide = false
				handleClone.Anchored = true
				handleClone.CastShadow = false
				handleClone.Transparency = transparency
				
				-- Remove any welds that connect to original character (but keep mesh/texture children)
				for _, descendant in ipairs(handleClone:GetDescendants()) do
					if descendant:IsA("Weld") or descendant:IsA("Motor6D") or descendant:IsA("WeldConstraint") then
						descendant:Destroy()
					elseif descendant:IsA("BasePart") then
						descendant.CanCollide = false
						descendant.Anchored = true
						descendant.CastShadow = false
						descendant.Transparency = transparency
					end
				end
				
				handleClone.Parent = cloneModel
			end
		-- Clone body colors
		elseif child:IsA("BodyColors") then
			child:Clone().Parent = cloneModel
		-- Clone shirts and pants
		elseif child:IsA("Shirt") or child:IsA("Pants") or child:IsA("ShirtGraphic") then
			child:Clone().Parent = cloneModel
		-- Clone CharacterMesh (for R6 customization)
		elseif child:IsA("CharacterMesh") then
			child:Clone().Parent = cloneModel
		-- Skip scripts, highlights, and other non-visual children
		end
	end
	
	-- Create HumanoidRootPart for proper model structure
	local humanoidRootPart = Instance.new("Part")
	humanoidRootPart.Name = "HumanoidRootPart"
	humanoidRootPart.Size = Vector3.new(2, 2, 1)
	humanoidRootPart.Transparency = 1
	humanoidRootPart.CanCollide = false
	humanoidRootPart.Anchored = true
	humanoidRootPart.CastShadow = false
	
	-- Position HumanoidRootPart at origin (clone will be repositioned by client-side orbit logic)
	humanoidRootPart.CFrame = CFrame.new(0, 0, 0)
	
	humanoidRootPart.Parent = cloneModel
	
	-- Set HumanoidRootPart as PrimaryPart (standard for characters)
	cloneModel.PrimaryPart = humanoidRootPart
	
	-- CRITICAL: Position all body parts AND accessories RELATIVE to clone's HumanoidRootPart (at origin)
	-- This maintains the character's pose (including accessories) while allowing the entire clone to be repositioned
	local cloneOrigin = CFrame.new(0, 0, 0)
	for _, part in ipairs(cloneModel:GetChildren()) do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			local relativeOffset = partOffsets[part.Name]
			if relativeOffset then
				-- Position part (or accessory) relative to clone's HumanoidRootPart (at origin)
				part.CFrame = cloneOrigin * relativeOffset
			end
		end
	end
	
	-- FINAL SAFETY CHECK: Verify no connections remain to original character
	for _, descendant in ipairs(cloneModel:GetDescendants()) do
		if descendant:IsA("Motor6D") or descendant:IsA("Weld") or descendant:IsA("WeldConstraint") then
			-- CRITICAL: Destroy ALL joints to prevent affecting original character
			descendant:Destroy()
		end
		-- Ensure ALL parts are non-collidable, anchored, and don't cast shadows
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.Anchored = true
			descendant.CastShadow = false
		end
	end
	
	return cloneModel
end

local function createVisualModel(entityType: string, entitySubtype: string?, visualColor: Color3?): Model?
	if entityType ~= "Enemy" and entityType ~= "Projectile" and entityType ~= "Explosion" and entityType ~= "ExpOrb" and entityType ~= "Powerup" and entityType ~= "AfterimageClone" then
		return nil
	end
	
	debug.profilebegin("CreateVisualModel")

	local cacheKey = entitySubtype or entityType
	local cached = modelCache[cacheKey]
	if cached then
		profInc("visualsReusedFromPool", 1)
		local cloned = cached:Clone()
		-- Apply color to cloned models (exp orbs and projectiles with attribute colors)
		if visualColor then
			for _, part in ipairs(cloned:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Color = visualColor
					if entityType == "ExpOrb" or entityType == "Projectile" then
						part.Material = Enum.Material.Neon  -- Make it glow
					end
				end
			end
		end
		return cloned
	end

	local model: Model?

	-- Handle different entity types
	if entityType == "Enemy" then
		if entitySubtype and ModelPaths.modelPathExists(entityType, entitySubtype) then
			local modelPath = ModelPaths.getModelPath(entityType, entitySubtype)
			if modelPath then
				-- Check if model is available (PERFORMANCE FIX - NO WAIT LOOPS!)
				local parts = string.split(modelPath, ".")
				local current: Instance? = game
				local found = true
				
				for _, partName in ipairs(parts) do
					if current then
						current = current:FindFirstChild(partName)
						if not current then
							found = false
							break
						end
					end
				end
				
				-- If model found, clone it; otherwise return nil (retry next frame)
				if found and current and current:IsA("Model") then
					model = current:Clone()
				else
					debug.profileend()
					return nil  -- Model not ready, skip this frame
				end
			end
		end
	elseif entityType == "Projectile" or entityType == "Explosion" then
		-- Handle projectile/explosion models using ModelPaths (like enemies)
		-- Treat explosions as projectiles for model lookup
		local lookupType = entityType == "Explosion" and "Projectile" or entityType
		if entitySubtype and ModelPaths.modelPathExists(lookupType, entitySubtype) then
			local modelPath = ModelPaths.getModelPath(lookupType, entitySubtype)
			if modelPath then
				-- Check if model is available immediately (PERFORMANCE FIX - NO WAIT LOOPS!)
				local parts = string.split(modelPath, ".")
				local current: Instance? = game
				local found = true
				
				for i, partName in ipairs(parts) do
					if current then
						current = current:FindFirstChild(partName)
						if not current then
							found = false
							break
						end
					end
				end
				
				-- If model found, clone it; otherwise return nil (retry next frame)
				if found and current and current:IsA("Model") then
					model = current:Clone()
				else
					debug.profileend()
					return nil  -- Model not ready, skip this frame
				end
			end
		end
	elseif entityType == "ExpOrb" then
		-- Handle exp orbs from ReplicatedStorage
		local orbTemplate = ReplicatedStorage:FindFirstChild("ContentDrawer")
		if orbTemplate then
			orbTemplate = orbTemplate:FindFirstChild("ItemModels")
			if orbTemplate then
				orbTemplate = orbTemplate:FindFirstChild("OrbTemplate")
				if orbTemplate and orbTemplate:IsA("Model") then
					model = orbTemplate:Clone()
				end
			end
		end
		
		if not model then
			debug.profileend()
			return nil  -- Model not ready
		end
	elseif entityType == "Powerup" then
		-- Handle powerups from ReplicatedStorage
		-- Path: ReplicatedStorage.ContentDrawer.ItemModels.Powerups.[PowerupType]
		if entitySubtype then
			local powerupsFolder = ReplicatedStorage:FindFirstChild("ContentDrawer")
			if powerupsFolder then
				powerupsFolder = powerupsFolder:FindFirstChild("ItemModels")
				if powerupsFolder then
					powerupsFolder = powerupsFolder:FindFirstChild("Powerups")
					if powerupsFolder then
						local powerupModel = powerupsFolder:FindFirstChild(entitySubtype)
						if powerupModel and powerupModel:IsA("Model") then
							model = powerupModel:Clone()
						end
					end
				end
			end
		end
		
		if not model then
			debug.profileend()
			return nil  -- Model not ready, will retry next frame
		end
	end

	if not model then
		return nil
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
		end
	end

	-- Configure existing Hitbox and Attackbox parts from the model
	local hitbox = model:FindFirstChild("Hitbox")
	local attackbox = model:FindFirstChild("Attackbox")
	
	-- Set Hitbox as PrimaryPart if it exists
	if hitbox and hitbox:IsA("BasePart") then
		hitbox.Anchored = true
		hitbox.CanCollide = false -- Hitbox handles projectile collision but not physics collision
		model.PrimaryPart = hitbox
	else
		-- Fallback to any BasePart if no Hitbox found
		local primary = model:FindFirstChildWhichIsA("BasePart")
		if primary then
			primary.Anchored = true
			primary.CanCollide = false
			model.PrimaryPart = primary
		end
	end
	
	-- Configure Attackbox if it exists
	if attackbox and attackbox:IsA("BasePart") then
		attackbox.Anchored = true
		attackbox.CanCollide = false -- Attackbox should never have physics collision
		-- Make sure projectiles cannot hit the Attackbox
		attackbox.CanTouch = false -- Prevents Touched events
	end
	
	-- Apply color to exp orbs and make them fully anchored/static
	if entityType == "ExpOrb" then
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				if visualColor then
					part.Color = visualColor
					part.Material = Enum.Material.Neon  -- Make it glow
				end
				-- Ensure orbs are fully static (no physics, no movement)
				part.Anchored = true
				part.CanCollide = false
				part.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
				part.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
			end
		end
	end
	
	-- Apply color to projectiles (for attribute visual effects)
	if entityType == "Projectile" and visualColor then
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.Name ~= "Hitbox" and part.Name ~= "Attackbox" then
				part.Color = visualColor
				part.Material = Enum.Material.Neon  -- Make it glow
			end
		end
	end

	-- Manage cache size to prevent memory bloat
	if next(modelCache) then
		local cacheCount = 0
		for _ in pairs(modelCache) do
			cacheCount = cacheCount + 1
		end
		
		if cacheCount >= MAX_CACHE_SIZE then
			-- Clear oldest entries (simple approach: clear all and rebuild)
			for key in pairs(modelCache) do
				modelCache[key]:Destroy()
				modelCache[key] = nil
			end
		end
	end
	
	-- Cache a clone of the template model to avoid issues with parenting
	-- The original model will be parented, but the cached version stays unparented
	local templateClone = model:Clone()
	modelCache[cacheKey] = templateClone

	debug.profileend()
	return model
end

local function extractEntityType(entityData: {[string]: any}): (string, string?)
	local component = entityData.EntityType or entityData.entityType
	if component and typeof(component) == "table" then
		return component.type or "Unknown", component.subtype
	end
	
	-- Fallback: Try to determine entity type from other components
	if entityData.Position and entityData.Velocity and entityData.ProjectileData then
		return "Projectile", "MagicBolt" -- Default projectile type
	elseif entityData.Position and entityData.Health and entityData.EnemyData then
		return "Enemy", "Zombie" -- Default enemy type
	elseif entityData.Position and entityData.PlayerStats then
		return "Player", nil
	end
	
	return "Unknown", nil
end

local function buildProjectileEntityData(spawnData: {[string]: any}): {[string]: any}?
	local origin = spawnData.origin
	local velocity = spawnData.velocity
	local visualTypeId = spawnData.visualTypeId
	if not visualTypeId then
		return nil
	end
	local data: {[string]: any} = {
		Position = origin,
		Velocity = velocity,
		EntityType = {
			type = "Projectile",
			subtype = visualTypeId,
			owner = spawnData.ownerEntity,
		},
		spawnTime = spawnData.spawnTime,
		lifetime = spawnData.lifetime,
		origin = origin,
		velocity = velocity,
		visualTypeId = visualTypeId,
		ownerUserId = spawnData.ownerUserId,
	}
	if spawnData.visualColor or spawnData.visualScale then
		data.Visual = {
			color = spawnData.visualColor,
			scale = spawnData.visualScale,
		}
	end
	if spawnData.lifetime then
		data.Lifetime = {
			remaining = spawnData.lifetime,
			max = spawnData.lifetime,
		}
	end
	if spawnData.ownerUserId or spawnData.ownerEntity then
		data.Owner = {
			userId = spawnData.ownerUserId,
			entity = spawnData.ownerEntity,
		}
	end
	if velocity then
		local vx = velocity.x or velocity.X or 0
		local vy = velocity.y or velocity.Y or 0
		local vz = velocity.z or velocity.Z or 0
		local speed = math.sqrt(vx * vx + vy * vy + vz * vz)
		data.ProjectileData = {
			type = visualTypeId,
			speed = speed,
		}
	else
		data.ProjectileData = {
			type = visualTypeId,
		}
	end
	return data
end

local function buildOrbEntityData(spawnData: {[string]: any}): {[string]: any}?
	local origin = spawnData.origin
	if not origin then
		return nil
	end
	local data: {[string]: any} = {
		Position = origin,
		EntityType = { type = "ExpOrb" },
		ItemData = {
			type = "ExpOrb",
			expAmount = spawnData.expAmount,
			isSink = spawnData.isSink,
			color = spawnData.itemColor,
			uniqueId = spawnData.uniqueId,
			ownerId = spawnData.ownerId,
			collected = false,
		},
		spawnTime = spawnData.spawnTime,
		lifetime = spawnData.lifetime,
		seed = spawnData.seed,
	}
	if spawnData.visualScale or spawnData.uniqueId then
		data.Visual = {
			scale = spawnData.visualScale,
			uniqueId = spawnData.uniqueId,
			visible = true,
		}
	end
	if spawnData.magnetPull then
		data.MagnetPull = spawnData.magnetPull
	end
	return data
end

local function ensureModelTransform(record: RenderRecord, position: Vector3?, velocityComponent: any, facingComponent: any)
	local model = record.model
	if not model then
		return
	end

	local baseCFrame = record.currentCFrame or model:GetPivot()
	local targetCFrame = computeTargetCFrame(position, facingComponent, velocityComponent, baseCFrame, record.entityType)

	-- CRITICAL: For AfterimageClones, manually position each anchored part
	if record.entityType == "AfterimageClone" then
		local offset = targetCFrame.Position - baseCFrame.Position
		if record.anchoredParts then
			for _, part in ipairs(record.anchoredParts) do
				if part and part.Parent then
					part.CFrame = part.CFrame + offset
				end
			end
		end
		-- Update model's pivot tracking
		if model.PrimaryPart then
			model.PrimaryPart.CFrame = model.PrimaryPart.CFrame + offset
		end
	else
		model:PivotTo(targetCFrame)
	end
	
	record.currentCFrame = targetCFrame
	record.fromCFrame = targetCFrame
	record.toCFrame = targetCFrame
	record.lerpStart = tick()
	record.lerpEnd = record.lerpStart
end

local function scheduleTransform(entityId: string | number, position: Vector3?, velocityComponent: any, facingComponent: any)
	local key = entityKey(entityId)
	local record = renderedEntities[key]
	if not record then
		return
	end
	if record.model then
		record.model:SetAttribute("ECS_LastUpdate", tick())
	end

	local model = record.model
	if not model then
		return
	end

	local now = tick()
	local currentCFrame = record.currentCFrame or model:GetPivot()
	local targetPosition = position or currentCFrame.Position
	local targetCFrame = computeTargetCFrame(targetPosition, facingComponent or record.facingDirection, velocityComponent or record.velocity, currentCFrame, record.entityType)

	-- CRITICAL FIX: For enemies, immediately snap to server Y to prevent floating models
	if record.entityType == "Enemy" and position then
		local currentPos = currentCFrame.Position
		-- If Y difference is significant (>2 studs), immediately correct it
		if math.abs(currentPos.Y - position.Y) > 2 then
			currentCFrame = CFrame.new(currentPos.X, position.Y, currentPos.Z) * (currentCFrame - currentCFrame.Position)
			model:PivotTo(currentCFrame)
		end
	end

    record.fromCFrame = currentCFrame
    record.toCFrame = targetCFrame
    record.lerpStart = now
    record.lastUpdate = now  -- Mark that server sent an update (CRITICAL for LOD)
    
    -- Snap if delta exceeds hard cap (prevents large desync from lag)
    local deltaPos = (targetCFrame.Position - currentCFrame.Position).Magnitude
    if deltaPos > HARD_SNAP_THRESHOLD then
        model:PivotTo(targetCFrame)
        record.currentCFrame = targetCFrame
        record.fromCFrame = targetCFrame
        record.toCFrame = targetCFrame
        record.lerpStart = now
        record.lerpEnd = now
        return
    end
    
    -- Dynamic interpolation window based on entity type and velocity
    local window = INTERPOLATION_WINDOW
    if record.entityType == "Projectile" then
        window = PROJECTILE_INTERPOLATION_WINDOW
        if USE_PROJECTILE_TWEENS then
            local primary = model.PrimaryPart
            if primary then
                if PROJECTILE_TWEEN_USES_FIXED_PATH and record.activeTween then
                    -- If using a fixed path, ignore mid-flight server updates to avoid jitter
                else
                    if record.activeTween then
                        pcall(function()
                            record.activeTween:Cancel()
                        end)
                        record.activeTween = nil
                    end
                    local tweenInfo = TweenInfo.new(window, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
                    local goal = { Position = targetCFrame.Position }
                    local tween = TweenService:Create(primary, tweenInfo, goal)
                    record.activeTween = tween
                    tween:Play()
                end
            end
        end
    elseif record.entityType == "Enemy" then
        -- CRITICAL: Use tighter interpolation for high-speed enemies (e.g. Charger dash)
        if velocityComponent then
            local vx = velocityComponent.x or 0
            local vz = velocityComponent.z or 0
            local speed = math.sqrt(vx * vx + vz * vz)
            if speed >= FAST_MOVEMENT_THRESHOLD then
                window = FAST_MOVEMENT_INTERPOLATION_WINDOW
            end
        end
    elseif record.entityType == "ExpOrb" then
        -- CRITICAL: Use very tight interpolation for magnetized orbs
        if velocityComponent then
            local vx = velocityComponent.x or 0
            local vz = velocityComponent.z or 0
            local speed = math.sqrt(vx * vx + vz * vz)
            if speed > 0.5 then
                -- Orb is moving (magnetized), use tight interpolation
                window = 0.03  -- Same as projectiles for minimal lag
            end
        end
    elseif record.entityType == "AfterimageClone" then
        -- CRITICAL: NO interpolation for clones - snap directly to server position
        -- Clones should stay exactly at player Y + 5, no smooth movement
        window = 0  -- Immediate snap
        -- Directly set position without interpolation
        if position then
            local snapCFrame = computeTargetCFrame(targetPosition, facingComponent or record.facingDirection, nil, currentCFrame, record.entityType)
            
        -- CRITICAL: Manually position each anchored part (PivotTo doesn't work with anchored parts)
        local offset = snapCFrame.Position - currentCFrame.Position
        if record.anchoredParts then
            for _, part in ipairs(record.anchoredParts) do
                if part and part.Parent then
                    part.CFrame = part.CFrame + offset
                end
            end
        end
            
            record.currentCFrame = snapCFrame
            record.fromCFrame = snapCFrame
            record.toCFrame = snapCFrame
        end
    end
    record.lerpEnd = now + window
    record.currentCFrame = currentCFrame
    record.velocity = velocityComponent or record.velocity
    record.facingDirection = facingComponent or record.facingDirection
    record.lastUpdate = now
end

local function handleEntitySync(entityId: string | number, rawData: {[string]: any})
	local key = entityKey(entityId)
	
	-- Check if entity already exists
	if renderedEntities[key] then
		profInc("duplicateSpawnForExistingEntityId", 1)
		return
	end
	
	local entityData = resolveEntityData(rawData)
	local entityTypeName, entitySubtype = extractEntityType(entityData)
	if entityTypeName == "Projectile" and (not entitySubtype or entitySubtype == "Unknown") then
		entitySubtype = entityData.visualTypeId or (entityData.ProjectileData and entityData.ProjectileData.type)
	end

	if entityTypeName == "Player" or entityTypeName == "Unknown" then
		return
	end

	-- Extract visual color for exp orbs from ItemData (not Visual, which is shareable)
	local itemData = entityData.ItemData or entityData.itemData
	local visualColor = nil
	if entityTypeName == "ExpOrb" and itemData and itemData.color then
		visualColor = itemData.color
	end
	
	-- Extract visual color for projectiles from Visual component (for attribute colors)
	local visualData = entityData.Visual
	if entityTypeName == "Projectile" and visualData and type(visualData) == "table" and visualData.color then
		visualColor = visualData.color
	end

	-- Special handling for AfterimageClone entities
	local model = nil
	local cloneSourcePlayer = nil  -- Store source player for client-side positioning
	local cloneIndex = nil  -- Store clone index for orbit calculation
	
	if entityTypeName == "AfterimageClone" then
		-- Clone the source player's character
		if visualData and type(visualData) == "table" and visualData.sourcePlayerUserId then
			local sourcePlayerUserId = visualData.sourcePlayerUserId
			local transparency = visualData.transparency or 0.5
			
			-- Resolve UserId to Player object
			local sourcePlayer = Players:GetPlayerByUserId(sourcePlayerUserId)
			if sourcePlayer then
				model = clonePlayerCharacter(sourcePlayer, transparency)
				cloneSourcePlayer = sourcePlayer  -- Store for client-side positioning
			else
				warn(string.format("[ClientEntityRenderer] Could not find player with UserId: %d", sourcePlayerUserId))
			end
		else
			warn("[ClientEntityRenderer] AfterimageClone missing visualData or sourcePlayerUserId")
		end
		
		-- Extract clone index from EntityType component (server sets this during clone creation)
		local entityTypeData = entityData.EntityType
		if entityTypeData and type(entityTypeData) == "table" then
			cloneIndex = entityTypeData.cloneIndex or 1  -- Default to 1 if not set
		end
	else
		model = createVisualModel(entityTypeName, entitySubtype, visualColor)
	end
	
	if not model then
		return
	end
	
	-- Apply scale from Visual component if present (for projectile size upgrades)
	if visualData and type(visualData) == "table" and visualData.scale and visualData.scale ~= 1 then
		local scale = visualData.scale
		model:ScaleTo(scale)
	end
	
	-- CRITICAL FIX PHASE 2: Parent FIRST, then set CFrame to avoid position desync
	local parentSuccess, parentErr = pcall(function()
		if entityTypeName == "Enemy" then
			model.Parent = enemiesFolder
		elseif entityTypeName == "ExpOrb" then
			model.Parent = expOrbsFolder
		elseif entityTypeName == "Projectile" or entityTypeName == "Explosion" then
			model.Parent = projectilesFolder
		elseif entityTypeName == "Powerup" then
			model.Parent = powerupsFolder
		elseif entityTypeName == "AfterimageClone" then
			model.Parent = afterimageClonesFolder
		else
			model.Parent = workspace
		end
	end)

	if not parentSuccess then
		warn(string.format("[ClientRenderer] Error parenting/configuring model for entity %s: %s", tostring(entityId), tostring(parentErr)))
		return
	end
	
	-- Validate model structure after parenting
	if entityTypeName == "Enemy" then
		local primaryPart = model.PrimaryPart
		if not primaryPart then
			warn(string.format("[ClientRenderer] WARNING: Enemy model %d has no PrimaryPart! Checking for parts...", entityId))
			local parts = {}
			for _, child in ipairs(model:GetChildren()) do
				if child:IsA("BasePart") then
					table.insert(parts, child.Name)
				end
			end
			if #parts == 0 then
				warn(string.format("[ClientRenderer] ERROR: Enemy model %d has NO PARTS at all! This will cause visual glitches.", entityId))
			end
		end
	end
	
	-- Add trail for red sink orbs (after model is created and parented)
	if entityTypeName == "ExpOrb" and itemData and itemData.isSink then
		local primaryPart = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
		if primaryPart then
			-- Create attachments for trail
			local attachment0 = Instance.new("Attachment")
			attachment0.Name = "SinkTrail0"
			attachment0.Position = Vector3.new(0, -primaryPart.Size.Y * 0.5, 0)
			attachment0.Parent = primaryPart
			
			local attachment1 = Instance.new("Attachment")
			attachment1.Name = "SinkTrail1"
			attachment1.Position = Vector3.new(0, primaryPart.Size.Y * 0.5, 0)
			attachment1.Parent = primaryPart
			
			-- Create red trail
			local trail = Instance.new("Trail")
			trail.Name = "SinkTrail"
			trail.Attachment0 = attachment0
			trail.Attachment1 = attachment1
			trail.Color = ColorSequence.new(Color3.fromRGB(255, 60, 60))
			trail.LightEmission = 0.8
			trail.LightInfluence = 0
			trail.WidthScale = NumberSequence.new(1.2)
			trail.Lifetime = 0.5
			trail.Parent = primaryPart
		end
	end

	local caches = buildModelCaches(model)

	-- Extract position early for spawn distance check
	local positionComponent = entityData.Position or entityData.position
	local positionVector = positionComponent and toVector3(positionComponent)
	local originVector = entityData.origin and toVector3(entityData.origin)
	local velocityComponent = entityData.Velocity or entityData.velocity
	local velocityVector = velocityComponent and toVelocityVector(velocityComponent)
	local spawnTimeValue = typeof(entityData.spawnTime) == "number" and entityData.spawnTime or nil
	local lifetimeSeconds = typeof(entityData.lifetime) == "number" and entityData.lifetime or nil
	if not lifetimeSeconds and entityData.Lifetime and typeof(entityData.Lifetime) == "table" then
		lifetimeSeconds = entityData.Lifetime.remaining or entityData.Lifetime.max
	end
	local projectileData = entityData.ProjectileData
	if entityTypeName == "Projectile" and originVector and velocityVector and spawnTimeValue then
		local age = math.max(tick() - spawnTimeValue, 0)
		if lifetimeSeconds then
			age = math.min(age, lifetimeSeconds)
		end
		positionVector = originVector + velocityVector * age
	end

	    local record: RenderRecord = {
			model = model,
			spawnTime = tick(),  -- NEW: Track when model was created
			entityType = entityTypeName,
			velocity = velocityComponent or entityData.Velocity,
		facingDirection = entityData.FacingDirection,
			lastUpdate = tick(),
			isFadedOut = false,
			isSpawning = entityTypeName == "Enemy",  -- Enemies start fading in
			visualUniqueId = (visualData and type(visualData) == "table") and visualData.uniqueId or nil,  -- Track Visual uniqueId for red orb teleportation
			-- Clone-specific fields for client-side positioning
			cloneSourcePlayer = cloneSourcePlayer,  -- Player to orbit around
			cloneIndex = cloneIndex,  -- Index in triangle formation (1-3)
			fadeParts = caches.fadeParts,
			fadeDecals = caches.fadeDecals,
			fadeTextures = caches.fadeTextures,
			fadeSurfaceGuis = caches.fadeSurfaceGuis,
			anchoredParts = caches.anchoredParts,
			spawnToken = 0,
			simType = nil,
			simOrigin = originVector or positionVector,
			simVelocity = velocityVector,
			simSpawnTime = spawnTimeValue,
			simLifetime = lifetimeSeconds,
			simSeed = entityData.seed,
		}
		renderedEntities[key] = record
		recordByModel[model] = record
		if entityTypeName == "Projectile" then
			if record.simOrigin and record.simVelocity then
				record.simType = "Projectile"
				record.simSpawnTime = record.simSpawnTime or tick()
			end
		elseif entityTypeName == "ExpOrb" then
			if record.simOrigin then
				record.simType = "ExpOrb"
				record.simSpawnTime = record.simSpawnTime or tick()
				record.simSeed = record.simSeed or tonumber(key) or 0
			end
		end
		profInc("visualsCreated", 1)
		model:SetAttribute("ECS_EntityId", key)
		model:SetAttribute("ECS_LastUpdate", record.lastUpdate)
	
	-- OPTIMIZED: Fade in new enemies from transparent
	if entityTypeName == "Enemy" then
		-- Check if spawning near culling distance
		local spawnDistance = 0
		local camera = workspace.CurrentCamera
		if positionVector and camera then
			local cameraPos = camera.CFrame.Position
			local dx = positionVector.X - cameraPos.X
			local dy = positionVector.Y - cameraPos.Y
			local dz = positionVector.Z - cameraPos.Z
			spawnDistance = math.sqrt(dx * dx + dy * dy + dz * dz)
		end
		
		-- PERFORMANCE FIX: If spawning near culling distance (>280 studs), start already faded
		local nearCullingEdge = spawnDistance > 280
		
		-- Set initial transparency
		setModelTransparency(model, 1, record)
		
		if nearCullingEdge then
			-- Start already faded out, don't waste time fading in then out
			record.isFadedOut = true
			record.isSpawning = false
		else
			-- Normal spawn - fade in over time
			local spawnToken = record.spawnToken or 0
			task.delay(0.05, function()  -- Small delay to ensure model is fully set up
				if renderedEntities[key] ~= record or record.spawnToken ~= spawnToken then
					return
				end
				if model and model.Parent then
					fadeModel(model, 0, SPAWN_FADE_DURATION, function()
						if renderedEntities[key] == record then
							record.isSpawning = false
						end
					end)
				end
			end)
		end
	end
	
	-- Special handling for FireBall explosion VFX
	if entitySubtype == "FireBallExplosion" or (projectileData and projectileData.type == "FireBallExplosion") then
		-- Find the VFX part and tween it
		local vfxPart = model:FindFirstChild("Part")
		if vfxPart and vfxPart:IsA("BasePart") then
			-- Store original size and transparency
			local originalSize = vfxPart.Size
			local originalTransparency = vfxPart.Transparency
			
			-- Start at scale 0
			vfxPart.Size = Vector3.new(0, 0, 0)
			vfxPart.Transparency = originalTransparency

			local expandStepDuration = EXPLOSION_STEPS > 0 and (EXPLOSION_EXPAND_DURATION / EXPLOSION_STEPS) or 0
			for step = 1, EXPLOSION_STEPS do
				local sizeAlpha = step / EXPLOSION_STEPS
				local scheduledDelay = (step - 1) * expandStepDuration
				task.delay(scheduledDelay, function()
					if vfxPart and vfxPart.Parent then
						vfxPart.Size = originalSize * sizeAlpha
					end
				end)
			end

			local fadeStepDuration = EXPLOSION_STEPS > 0 and (EXPLOSION_FADE_DURATION / EXPLOSION_STEPS) or 0
			for step = 1, EXPLOSION_STEPS do
				local fadeAlpha = step / EXPLOSION_STEPS
				local transparencyTarget = originalTransparency + (1 - originalTransparency) * fadeAlpha
				local scheduledDelay = EXPLOSION_EXPAND_DURATION + (step - 1) * fadeStepDuration
				task.delay(scheduledDelay, function()
					if vfxPart and vfxPart.Parent then
						vfxPart.Transparency = transparencyTarget
					end
				end)
			end

			task.delay(EXPLOSION_EXPAND_DURATION + EXPLOSION_FADE_DURATION + 0.05, function()
				if vfxPart and vfxPart.Parent then
					vfxPart.Transparency = 1
					vfxPart.Size = originalSize
				end
			end)
		else
			warn(string.format("[ClientRenderer] VFX Part not found in explosion model. Model has %d children", #model:GetChildren()))
		end
	end

	-- For projectiles, place instantly at the exact spawn position without interpolation delay
	if entityTypeName == "Projectile" then
		record.fromCFrame = nil
		record.toCFrame = nil
		record.lerpStart = tick()
		record.lerpEnd = record.lerpStart
		-- If we have FacingDirection and Lifetime, compute a fixed end position for a single tween
		if USE_PROJECTILE_TWEENS and PROJECTILE_TWEEN_USES_FIXED_PATH then
			local facing = entityData.FacingDirection
			local lifetime = entityData.Lifetime
			local speed = 0
			local projectileData = entityData.ProjectileData
			if projectileData and projectileData.speed then
				speed = projectileData.speed
			end
			if facing and positionVector and lifetime and lifetime.remaining and speed > 0 then
				local dir = Vector3.new(facing.x or 0, facing.y or 0, facing.z or 0)
				if dir.Magnitude > 0 then
					dir = dir.Unit
					local travelDist = speed * lifetime.remaining
					record.tweenEndPosition = positionVector + dir * travelDist
					
					-- Fix: Reverse the direction to compensate for client-side interpretation
					local reversedDir = -dir
					record.tweenEndPosition = positionVector + reversedDir * travelDist
					local primary = model.PrimaryPart
					if primary then
						if record.activeTween then
							pcall(function()
								record.activeTween:Cancel()
							end)
							record.activeTween = nil
						end
						-- Use dt-based duration for consistent speed: duration = distance / speed
						local travelDist = (record.tweenEndPosition - positionVector).Magnitude
						local duration = math.max(0.02, travelDist / speed)
						-- Linear tween with no acceleration/deceleration
						local tweenInfo = TweenInfo.new(
							duration, 
							Enum.EasingStyle.Linear, 
							Enum.EasingDirection.InOut, -- InOut for truly linear (no ease)
							0, -- Repeat count
							false, -- Don't reverse
							0 -- No delay
						)
						local tween = TweenService:Create(primary, tweenInfo, { Position = record.tweenEndPosition })
						record.activeTween = tween
						tween:Play()
					end
				end
			end
		end
	end
	
	-- For AfterimageClones, skip server position syncing - client will calculate orbit positions
	if entityTypeName ~= "AfterimageClone" then
		ensureModelTransform(record, positionVector, entityData.Velocity, entityData.FacingDirection)
	else
		-- Initial position for clone (will be updated in render loop based on player position)
		-- Just set it at origin for now
		model:PivotTo(CFrame.new(0, 1000, 0))  -- Put it high up so it's out of the way until positioned
	end
	
	-- CLIENT-SIDE PROJECTILE SPAWN OVERRIDE: Use local player's actual position
	if entityTypeName == "Projectile" and positionVector then
		-- Check if this projectile is owned by local player
		local ownerData = entityData.Owner or entityData.owner
		local ownerUserId = ownerData and (ownerData.userId or ownerData.UserId)
		if (ownerData and ownerData.player == player) or (ownerUserId and ownerUserId == player.UserId) or (entityData.ownerUserId and entityData.ownerUserId == player.UserId) then
			-- This is our projectile, override spawn position with our current position
			local character = player.Character
			local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
			
			if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
				-- Get current local position
				local clientPosition = (humanoidRootPart :: BasePart).Position
				
				-- Calculate position offset from server to client
				local positionOffset = clientPosition - positionVector
				
				-- Apply offset to model (visual override, doesn't affect server physics)
				local currentCFrame = model:GetPivot()
				model:PivotTo(currentCFrame + positionOffset)
				
				-- Update record positions to match (for interpolation)
				if record.currentCFrame then
					record.currentCFrame = record.currentCFrame + positionOffset
				end
				if record.fromCFrame then
					record.fromCFrame = record.fromCFrame + positionOffset
				end
				if record.toCFrame then
					record.toCFrame = record.toCFrame + positionOffset
				end
				if record.tweenEndPosition then
					record.tweenEndPosition = record.tweenEndPosition + positionOffset
				end
				
				-- Update active tween if using fixed path tweens
				if record.activeTween then
					pcall(function()
						record.activeTween:Cancel()
					end)
					record.activeTween = nil
					
					-- Recreate tween with adjusted end position
					if USE_PROJECTILE_TWEENS and PROJECTILE_TWEEN_USES_FIXED_PATH and record.tweenEndPosition then
						local primary = model.PrimaryPart
						if primary then
							local facing = entityData.FacingDirection
							local lifetime = entityData.Lifetime
							local projectileData = entityData.ProjectileData
							local speed = projectileData and projectileData.speed or 0
							
							if facing and lifetime and lifetime.remaining and speed > 0 then
								local travelDist = (record.tweenEndPosition - clientPosition).Magnitude
								local duration = math.max(0.02, travelDist / speed)
								local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, 0, false, 0)
								local tween = TweenService:Create(primary, tweenInfo, { Position = record.tweenEndPosition })
								record.activeTween = tween
								tween:Play()
							end
						end
					end
				end
			end
		end
	end
end

local function updateEntityType(record: RenderRecord, newType: any)
	if typeof(newType) == "table" and newType.type then
		record.entityType = newType.type
	end
end

local function handleEntityUpdate(entityId: string | number, rawData: {[string]: any})
	local key = entityKey(entityId)
	local entityData = resolveEntityData(rawData)
	local record = renderedEntities[key]

	if not record then
		return
	end

	local positionComponent = entityData.Position or entityData.position
	local positionVector = positionComponent and toVector3(positionComponent)
	local velocityComponent = entityData.Velocity or record.velocity
	local facingComponent = entityData.FacingDirection or record.facingDirection

	if positionVector or velocityComponent or facingComponent then
		-- For projectiles with fixed tween path, ignore per-update transforms to avoid jitter
		local ignore = record.simType == "Projectile" or record.simType == "ExpOrb"
		if record.entityType == "Projectile" and USE_PROJECTILE_TWEENS and PROJECTILE_TWEEN_USES_FIXED_PATH then
			ignore = true
		end
		if not ignore then
			scheduleTransform(entityId, positionVector, velocityComponent, facingComponent)
		end
	end

	if entityData.Velocity then
		record.velocity = entityData.Velocity
		if record.simType == "Projectile" then
			record.simVelocity = toVelocityVector(entityData.Velocity)
		end
	end
	
	if entityData.FacingDirection then
		record.facingDirection = entityData.FacingDirection
	end

	if entityData.EntityType then
		updateEntityType(record, entityData.EntityType)
	end

	-- Handle hit flash VFX
	if entityData.HitFlash then
		handleHitFlash(record.model, entityData.HitFlash)
	end

	-- Handle death animation
	if entityData.DeathAnimation then
		handleDeathAnimation(record.model, entityData.DeathAnimation)
	end
	
	-- Handle Visual component changes (for red orb teleportation)
	if record.entityType == "ExpOrb" then
		local itemData = entityData.ItemData or entityData.itemData
		local visualData = entityData.Visual
		
		-- CLIENT-SIDE FALLBACK: Immediately fade collected orbs even if despawn is delayed
		-- ONLY fade when collected = true (not when MagnetPull is removed)
		if itemData and itemData.collected and not record.isFadedOut then
			local despawnId = entityId
			fadeModel(record.model, 1, 0.1, function()
				handleEntityDespawn(despawnId, true)
			end)
			record.isFadedOut = true
		end
		
		-- Handle Visual uniqueId changes for teleportation
		if itemData and itemData.isSink then
			if visualData and type(visualData) == "table" and visualData.uniqueId and visualData.uniqueId ~= record.visualUniqueId then
				-- UniqueId changed = red orb teleported, reuse existing model
				record.visualUniqueId = visualData.uniqueId

				if record.model and positionVector then
					record.model:PivotTo(CFrame.new(positionVector))
					record.currentCFrame = record.model:GetPivot()
					record.fromCFrame = record.currentCFrame
					record.toCFrame = record.currentCFrame
					record.lerpStart = tick()
					record.lerpEnd = record.lerpStart
				end

				-- Ensure red trail exists
				local primaryPart = record.model and (record.model.PrimaryPart or record.model:FindFirstChildWhichIsA("BasePart"))
				if primaryPart and not primaryPart:FindFirstChild("SinkTrail") then
					local attachment0 = Instance.new("Attachment")
					attachment0.Name = "SinkTrail0"
					attachment0.Position = Vector3.new(0, -primaryPart.Size.Y * 0.5, 0)
					attachment0.Parent = primaryPart
					
					local attachment1 = Instance.new("Attachment")
					attachment1.Name = "SinkTrail1"
					attachment1.Position = Vector3.new(0, primaryPart.Size.Y * 0.5, 0)
					attachment1.Parent = primaryPart
					
					local trail = Instance.new("Trail")
					trail.Name = "SinkTrail"
					trail.Attachment0 = attachment0
					trail.Attachment1 = attachment1
					trail.Color = ColorSequence.new(Color3.fromRGB(255, 60, 60))
					trail.LightEmission = 0.8
					trail.LightInfluence = 0
					trail.WidthScale = NumberSequence.new(1.2)
					trail.Lifetime = 0.5
					trail.Parent = primaryPart
				end
			end
		end
		
		if itemData then
			-- Always check if this orb is a sink and hasn't been converted yet
			if itemData.isSink and not record.isSink then
				-- This orb just became a red sink! Re-apply color
				record.isSink = true
				local redColor = itemData.color or Color3.fromRGB(255, 60, 60)
				
				-- Re-color all parts
				if record.fadeParts then
					for _, part in ipairs(record.fadeParts) do
						if part and part.Parent then
							part.Color = redColor
							part.Material = Enum.Material.Neon
						end
					end
				end
				
				-- Add red trail if not already present
				local primaryPart = record.model and (record.model.PrimaryPart or record.model:FindFirstChildWhichIsA("BasePart"))
				if primaryPart and not primaryPart:FindFirstChild("SinkTrail") then
					-- Create attachments for trail
					local attachment0 = Instance.new("Attachment")
					attachment0.Name = "SinkTrail0"
					attachment0.Position = Vector3.new(0, -primaryPart.Size.Y * 0.5, 0)
					attachment0.Parent = primaryPart
					
					local attachment1 = Instance.new("Attachment")
					attachment1.Name = "SinkTrail1"
					attachment1.Position = Vector3.new(0, primaryPart.Size.Y * 0.5, 0)
					attachment1.Parent = primaryPart
					
					-- Create red trail
					local trail = Instance.new("Trail")
					trail.Name = "SinkTrail"
					trail.Attachment0 = attachment0
					trail.Attachment1 = attachment1
					trail.Color = ColorSequence.new(redColor)
					trail.LightEmission = 0.8
					trail.LightInfluence = 0
					trail.WidthScale = NumberSequence.new(1.2)
					trail.Lifetime = 0.5
					trail.Parent = primaryPart
				end
			end
		end
	end

	-- Fast client-side removal when Lifetime hits 0
	local lifetime = entityData.Lifetime
	if lifetime and lifetime.remaining and lifetime.remaining <= 0 then
		handleEntityDespawn(entityId, true)
	elseif lifetime and lifetime.remaining and lifetime.remaining > 0 and record.entityType == "Projectile" then
		record.pendingRemovalTime = nil
		record.despawnQueued = nil
	end
end

local function performDespawn(key: string, record: RenderRecord)
	local model = record.model
	
	-- Clean up active tween if exists (MEMORY LEAK FIX 1.4)
	if model and activeEnemyTweens[model] then
		pcall(function()
			activeEnemyTweens[model]:Cancel()
		end)
		activeEnemyTweens[model] = nil
	end
	
	-- Clean up tween event connections (MEMORY LEAK FIX 1.1)
	if model and activeTweenConnections[model] then
		for _, conn in ipairs(activeTweenConnections[model]) do
			conn:Disconnect()
		end
		activeTweenConnections[model] = nil
	end
	
	-- Clean up active fades (PERFORMANCE OPTIMIZATION)
	if model and activeFades[model] then
		activeFades[model] = nil
	end
	
	-- Check if this entity has an active death animation
	if model and deathAnimations[model] and deathAnimations[model].started then
		-- Don't destroy the model yet, death animation will handle it
		-- Just clean up from renderedEntities
		renderedEntities[key] = nil
		-- Note: deathAnimations and hitFlashHighlights cleaned by death animation itself
		return
	end
	
	-- Clean up death animation and hit flash tables (MEMORY LEAK FIX 1.5 - safety net)
	if model then
		deathAnimations[model] = nil
		-- Explicitly destroy highlight before clearing reference
		local flashData = hitFlashHighlights[model]
		if flashData and flashData.highlight then
			flashData.highlight:Destroy()
		end
		hitFlashHighlights[model] = nil
	end
	
	if model then
		-- ALWAYS destroy highlights explicitly
		local flashData = hitFlashHighlights[model]
		if flashData and flashData.highlight then
			flashData.highlight:Destroy()
		end
		hitFlashHighlights[model] = nil
		
		if record.entityType == "Projectile" then
			if record.fadeParts then
				for _, part in ipairs(record.fadeParts) do
					if part and part.Parent then
						part.Transparency = 1
					end
				end
			end
			recordByModel[model] = nil
			destroyVisualModel(model)
		else
			-- For non-projectiles (enemies), force immediate destroy in published games
			-- Don't wait for tween, just destroy
			if activeEnemyTweens[model] then
				activeEnemyTweens[model]:Cancel()
				activeEnemyTweens[model] = nil
			end
			if activeFades[model] then
				activeFades[model] = nil
			end
			recordByModel[model] = nil
			destroyVisualModel(model)
		end
	end

	renderedEntities[key] = nil
end

handleEntityDespawn = function(entityId: string | number, force: boolean?)
	local key = entityKey(entityId)
	knownEntityIds[key] = nil
	local record = renderedEntities[key]
	if not record then
		if spawnQueueSet[key] then
			spawnQueueSet[key] = nil
			for i = spawnQueueHead, #spawnQueue do
				if spawnQueue[i] and entityKey(spawnQueue[i].entityId) == key then
					spawnQueue[i] = spawnQueue[#spawnQueue]
					spawnQueue[#spawnQueue] = nil
					break
				end
			end
		end
		if bufferedUpdates[key] then
			bufferedUpdates[key] = nil
			bufferedUpdateTotal = math.max(bufferedUpdateTotal - 1, 0)
		end
		return
	end
	record.spawnToken = (record.spawnToken or 0) + 1

	if record.entityType == "Projectile" and not force then
		record.pendingRemovalTime = record.pendingRemovalTime or (tick() + PROJECTILE_DEATH_VISUAL_DELAY)
		record.despawnQueued = true
		return
	end

	performDespawn(key, record)
end

local function enqueueSpawn(entityId: string | number, rawData: {[string]: any})
	local key = entityKey(entityId)
	if renderedEntities[key] or spawnQueueSet[key] then
		profInc("duplicateSpawnForExistingEntityId", 1)
		return
	end
	spawnQueueSet[key] = true
	table.insert(spawnQueue, {
		entityId = entityId,
		data = rawData,
		enqueuedAt = tick(),
	})
end

local function processSpawnQueue()
	local now = tick()
	local processed = 0
	local queueTimeTotal = 0
	local queueTimeCount = 0
	while processed < SPAWN_BUDGET_PER_FRAME do
		local entry = spawnQueue[spawnQueueHead]
		if not entry then
			break
		end
		spawnQueue[spawnQueueHead] = nil
		spawnQueueHead += 1
		processed += 1

		local entityId = entry.entityId
		local key = entityKey(entityId)
		if entry.enqueuedAt then
			queueTimeTotal += math.max(now - entry.enqueuedAt, 0)
			queueTimeCount += 1
		end
		spawnQueueSet[key] = nil
		if not renderedEntities[key] then
			knownEntityIds[key] = true
			handleEntitySync(entityId, entry.data)
			if not renderedEntities[key] then
				knownEntityIds[key] = nil
			end
			local buffered = bufferedUpdates[key]
			if buffered then
				bufferedUpdates[key] = nil
				bufferedUpdateTotal = math.max(bufferedUpdateTotal - 1, 0)
				if buffered.expiresAt > now then
					handleEntityUpdate(entityId, buffered.data)
					profInc("bufferedUnknownUpdatesApplied", 1)
				else
					profInc("bufferedUnknownUpdatesEvicted", 1)
				end
			end
		end
	end

	if spawnQueueHead > 50 and spawnQueueHead > (#spawnQueue / 2) then
		local newQueue = {}
		for i = spawnQueueHead, #spawnQueue do
			newQueue[#newQueue + 1] = spawnQueue[i]
		end
		spawnQueue = newQueue
		spawnQueueHead = 1
	end

	local depth = math.max(#spawnQueue - spawnQueueHead + 1, 0)
	Prof.gauge("spawnQueueDepth", depth)
	if queueTimeCount > 0 then
		Prof.gauge("spawnQueueTimeAvgMs", (queueTimeTotal / queueTimeCount) * 1000)
	end
	if processed > 0 then
		Prof.incCounter("spawnsProcessedThisFrame", processed)
	end
	if depth > 0 and processed >= SPAWN_BUDGET_PER_FRAME then
		Prof.incCounter("spawnBudgetHitCount", 1)
	end
	cleanupExpiredBufferedUpdates(now)
end

local function processSpawnPayloads(entities: any, projectileSpawns: any, orbSpawns: any): number
	local spawnCount = 0
	if typeof(entities) == "table" then
		for entityId, data in pairs(entities) do
			if typeof(data) == "table" then
				spawnCount += 1
				enqueueSpawn(entityId, data)
			end
		end
	end
	if typeof(projectileSpawns) == "table" then
		for _, spawnData in ipairs(projectileSpawns) do
			if typeof(spawnData) == "table" and spawnData.id then
				local entityData = buildProjectileEntityData(spawnData)
				if entityData then
					spawnCount += 1
					enqueueSpawn(spawnData.id, entityData)
				end
			end
		end
	end
	if typeof(orbSpawns) == "table" then
		for _, spawnData in ipairs(orbSpawns) do
			if typeof(spawnData) == "table" and spawnData.id then
				local entityData = buildOrbEntityData(spawnData)
				if entityData then
					spawnCount += 1
					enqueueSpawn(spawnData.id, entityData)
				end
			end
		end
	end
	return spawnCount
end

local function processSnapshot(snapshot: any)
	if typeof(snapshot) ~= "table" then
		return
	end

	applySharedDefinitions(snapshot.shared)

	local spawnCount = processSpawnPayloads(snapshot.entities, snapshot.projectileSpawns, snapshot.orbSpawns)

	if spawnCount > 0 then
		profInc("spawnEventsReceived", spawnCount)
		profInc("spawnBatchEntities", spawnCount)
	end

	if snapshot.isInitial == true and not hasInitialSync then
		hasInitialSync = true
		profInc("initialSyncReceivedCount", 1)
	end
end

local function processUpdates(message: any)
	if typeof(message) ~= "table" then
		return
	end

	applySharedDefinitions(message.shared)

	local spawnCount = processSpawnPayloads(message.entities, message.projectileSpawns, message.orbSpawns)
	if spawnCount > 0 then
		profInc("spawnEventsReceived", spawnCount)
		profInc("spawnBatchEntities", spawnCount)
	end

	local function handleUpdate(entityId: string | number, updateData: {[string]: any})
		local key = entityKey(entityId)
		if not hasInitialSync then
			profInc("updatesBeforeInitialSync", 1)
		end

		if not knownEntityIds[key] then
			profInc("updatesForUnknownEntityId", 1)
			bufferUpdate(key, updateData)
			return
		end

		handleEntityUpdate(entityId, updateData)
	end

	local updateCount = 0
	-- Phase 4.5: Process compact projectile batches (40-60% bandwidth reduction)
	local projectiles = message.projectiles
	if typeof(projectiles) == "table" then
		for _, compactData in ipairs(projectiles) do
			if typeof(compactData) == "table" and #compactData >= 7 then
				local entityId = compactData[1]
				-- Decode compact format: {id, px, py, pz, vx, vy, vz}
				local updateData = {
					id = entityId,
					Position = {x = compactData[2], y = compactData[3], z = compactData[4]},
					Velocity = {x = compactData[5], y = compactData[6], z = compactData[7]},
				}
				updateCount += 1
				handleUpdate(entityId, updateData)
			end
		end
	end
	
	-- Phase 4.5: Process compact enemy batches
	local enemies = message.enemies
	if typeof(enemies) == "table" then
		for _, compactData in ipairs(enemies) do
			if typeof(compactData) == "table" and #compactData >= 7 then
				local entityId = compactData[1]
				-- Decode compact format: {id, px, py, pz, vx, vy, vz}
				local updateData = {
					id = entityId,
					Position = {x = compactData[2], y = compactData[3], z = compactData[4]},
					Velocity = {x = compactData[5], y = compactData[6], z = compactData[7]},
				}
				updateCount += 1
				handleUpdate(entityId, updateData)
			end
		end
	end

	-- Standard updates for non-batched entities (players, items, etc)
	local updates = message.updates
	if typeof(updates) == "table" then
		for _, updateData in ipairs(updates) do
			if typeof(updateData) == "table" and updateData.id then
				updateCount += 1
				handleUpdate(updateData.id, updateData)
			end
		end
	end

	local resyncs = message.resyncs
	if typeof(resyncs) == "table" then
		for _, updateData in ipairs(resyncs) do
			if typeof(updateData) == "table" and updateData.id then
				updateCount += 1
				handleUpdate(updateData.id, updateData)
			end
		end
	end

	if updateCount > 0 then
		profInc("updateEventsReceived", updateCount)
	end

	local despawns = message.despawns
	local despawnCount = 0
	if typeof(despawns) == "table" then
		for _, entityId in ipairs(despawns) do
			despawnCount += 1
			handleEntityDespawn(entityId)
		end
	elseif despawns then
		despawnCount = 1
		handleEntityDespawn(despawns)
	end

	if despawnCount > 0 then
		profInc("despawnEventsReceived", despawnCount)
	end
end

local function requestInitialSync()
	local success, snapshot = pcall(function()
		return RequestInitialSync:InvokeServer()
	end)

	if success then
		processSnapshot(snapshot)
	else
		warn("[ClientRenderer] Initial sync failed", snapshot)
	end
end

EntitySync.OnClientEvent:Connect(processSnapshot)
EntityUpdate.OnClientEvent:Connect(processUpdates)
if EntityUpdateUnreliable and EntityUpdateUnreliable:IsA("UnreliableRemoteEvent") then
	EntityUpdateUnreliable.OnClientEvent:Connect(processUpdates)
end

EntityDespawn.OnClientEvent:Connect(function(despawns)
	if typeof(despawns) == "table" then
		local count = 0
		for _, entityId in ipairs(despawns) do
			count += 1
			handleEntityDespawn(entityId)
		end
		if count > 0 then
			profInc("despawnEventsReceived", count)
		end
	elseif despawns then
		profInc("despawnEventsReceived", 1)
		handleEntityDespawn(despawns)
	end
end)

	RunService:BindToRenderStep("ECS.EntityLerp", Enum.RenderPriority.Camera.Value, function()
		Prof.beginTimer("ClientEntityRenderer.Render")
		local now = tick()
		
		-- CRITICAL: Death animations must process even during pause
		-- Otherwise enemies that die during pause freeze
		updateDeathAnimations()
		
		-- Skip other rendering updates when game is paused
		if isPaused then
			return
		end
		
		processSpawnQueue()
		processFades()
		processFadeOps()
		cleanupStaleProjectiles(now)
		cleanupStaleExpOrbs(now)
		-- Diagnostic toggle for invisible enemy detection
		if enableInvisibleEnemyDiagnostics and enableInvisibleEnemyDiagnostics.Value then
			checkForInvisibleEnemies(now)
		end
	
	-- Clean up expired hit flashes
	for model, flashData in pairs(hitFlashHighlights) do
		if now >= flashData.endTime then
			if flashData.highlight then
				flashData.highlight:Destroy()
			end
			hitFlashHighlights[model] = nil
		end
	end
	
	-- OPTIMIZATION: Death animations now handled by the chunked fade system (processFades)
	-- Removed manual interpolation loop - processFades() handles all fading now
	
	-- FAILSAFE: Clean up stale death animations and orphaned models
	if now - lastDeathCleanupCheck >= DEATH_CLEANUP_INTERVAL then
		lastDeathCleanupCheck = now
		
		-- Check for stale death animations (taking too long)
		for model, info in pairs(deathAnimations) do
			if not model or not model.Parent then
				-- Model already gone, clean up references
				deathAnimations[model] = nil
				local flashData = hitFlashHighlights[model]
				if flashData and flashData.highlight then
					flashData.highlight:Destroy()
				end
				hitFlashHighlights[model] = nil
			elseif now > info.expireTime + 1.0 then
				-- Death animation expired way too long ago, force cleanup
				-- Destroy highlight
				local flashData = hitFlashHighlights[model]
				if flashData and flashData.highlight then
					flashData.highlight:Destroy()
				end
				hitFlashHighlights[model] = nil
				
				-- Destroy model
				if model and model.Parent then
					recordByModel[model] = nil
					destroyVisualModel(model)
				end
				deathAnimations[model] = nil
			end
		end
		
		-- NOTE: Enemy cleanup is handled server-side only (ZombieAISystem)
		-- Client should never despawn enemies - server is authoritative
		
		-- Check for orphaned highlights (no model or no death animation)
		for model, flashData in pairs(hitFlashHighlights) do
			if not model or not model.Parent then
				if flashData and flashData.highlight then
					flashData.highlight:Destroy()
				end
				hitFlashHighlights[model] = nil
			end
		end
	end
	
	-- Get camera position for LOD calculations
	local camera = workspace.CurrentCamera
	local cameraPos = camera and camera.CFrame.Position or Vector3.zero
	
	local toRemove = {}
	local activeModels = 0
	local activeEnemies = 0
	local activeProjectiles = 0
	local activeOrbs = 0
	local simulatedProjectiles = 0
	for key, record in pairs(renderedEntities) do
		activeModels += 1
		if record.entityType == "Enemy" then
			activeEnemies += 1
		elseif record.entityType == "Projectile" or record.entityType == "Explosion" then
			activeProjectiles += 1
			if record.simType == "Projectile" then
				simulatedProjectiles += 1
			end
		elseif record.entityType == "ExpOrb" then
			activeOrbs += 1
		end
		if record.pendingRemovalTime and now >= record.pendingRemovalTime then
			table.insert(toRemove, key)
		end

		local model = record.model
		if not model then
			continue
		end

		local primary = model.PrimaryPart
		if not primary then
			continue
		end
		
		-- CLIENT-SIDE POSITIONING FOR AFTERIMAGE CLONES
		-- Calculate orbit position based on player's character position
		if record.entityType == "AfterimageClone" and record.cloneSourcePlayer and record.cloneIndex then
			local character = record.cloneSourcePlayer.Character
			local sourceHRP = character and character:FindFirstChild("HumanoidRootPart")
			
			if sourceHRP and sourceHRP:IsA("BasePart") then
				local playerPos = (sourceHRP :: BasePart).Position
				
				-- Calculate orbit position (equilateral triangle formation)
				-- Triangle side length = 30 studs, radius = 30 / sqrt(3) ≈ 17.32
				local radius = 30 / math.sqrt(3)
				local angleRadians = math.rad((record.cloneIndex - 1) * 120)  -- 0°, 120°, 240°
				local offsetX = math.sin(angleRadians) * radius
				local offsetZ = math.cos(angleRadians) * radius
				
				-- Calculate target position (orbit around player, +5 studs above)
				local targetPos = Vector3.new(
					playerPos.X + offsetX,
					playerPos.Y + 5,
					playerPos.Z + offsetZ
				)
				
				-- Update clone to match source character's pose AND position
				-- Store body part AND accessory handle offsets from source character
				local sourcePartCFrames = {}
				for _, sourcePart in ipairs(character:GetChildren()) do
					if sourcePart:IsA("BasePart") then
						-- Store relative to source HRP
						sourcePartCFrames[sourcePart.Name] = (sourceHRP :: BasePart).CFrame:ToObjectSpace(sourcePart.CFrame)
					elseif sourcePart:IsA("Accessory") then
						-- Store accessory handle position relative to source HRP
						local handle = sourcePart:FindFirstChild("Handle")
						if handle and handle:IsA("BasePart") then
							sourcePartCFrames[sourcePart.Name .. "_Handle"] = (sourceHRP :: BasePart).CFrame:ToObjectSpace(handle.CFrame)
						end
					end
				end
				
				-- Calculate target CFrame for clone's HRP (at orbit position, same rotation as player)
				local targetCFrame = CFrame.new(targetPos) * (sourceHRP :: BasePart).CFrame.Rotation
				
				-- Update all parts (body parts AND accessories) to match source character's current pose
				for _, clonePart in ipairs(model:GetChildren()) do
					if clonePart:IsA("BasePart") and clonePart.Anchored then
						if clonePart.Name == "HumanoidRootPart" then
							clonePart.CFrame = targetCFrame
						else
							-- Use stored offset from source character (maintains pose for both body parts and accessories)
							local offset = sourcePartCFrames[clonePart.Name]
							if offset then
								clonePart.CFrame = targetCFrame * offset
							end
						end
					end
				end
			end
		end

		local simPosition: Vector3? = nil
		if record.simType == "Projectile" then
			local simOrigin = record.simOrigin
			local simVelocity = record.simVelocity
			local simSpawnTime = record.simSpawnTime
			if simOrigin and simVelocity and simSpawnTime then
				local age = math.max(now - simSpawnTime, 0)
				if record.simLifetime then
					if age >= record.simLifetime then
						record.pendingRemovalTime = now
						table.insert(toRemove, key)
					else
						simPosition = simOrigin + simVelocity * age
					end
				else
					simPosition = simOrigin + simVelocity * age
				end
			end
		elseif record.simType == "ExpOrb" then
			local simOrigin = record.simOrigin
			local simSpawnTime = record.simSpawnTime
			if simOrigin then
				local phase = (record.simSeed or 0) * 0.1
				local bob = math.sin((now + phase) * ORB_BOB_FREQUENCY) * ORB_BOB_AMPLITUDE
				simPosition = simOrigin + Vector3.new(0, bob, 0)
				if record.simLifetime and simSpawnTime and (now - simSpawnTime) >= record.simLifetime then
					record.pendingRemovalTime = now
					table.insert(toRemove, key)
				end
			end
		end
		if simPosition and model then
			model:SetAttribute("ECS_LastUpdate", now)
		end
		
		-- Skip ExpOrbs and Powerups from render loop UNLESS they're moving
		if record.entityType == "ExpOrb" or record.entityType == "Powerup" then
			-- Check if this item is moving (has velocity updates)
			-- Use a very low threshold (0.01) to catch even slow-moving magnetized orbs
			local hasVelocity = record.velocity and 
			                    (math.abs(record.velocity.x or 0) > 0.01 or 
			                     math.abs(record.velocity.y or 0) > 0.01 or 
			                     math.abs(record.velocity.z or 0) > 0.01)
			if not hasVelocity and not record.simType then
				continue  -- Static item, skip rendering updates
			end
			-- Otherwise, allow interpolation for movement (e.g., magnet pull)
		end
		
		-- Calculate distance to camera for LOD
		local modelPos = simPosition or model:GetPivot().Position
		local dx = modelPos.X - cameraPos.X
		local dy = modelPos.Y - cameraPos.Y
		local dz = modelPos.Z - cameraPos.Z
		local distSq = dx * dx + dy * dy + dz * dz  -- Squared distance (no sqrt!)
		local distance = math.sqrt(distSq)
		
		-- OPTIMIZED: Handle distance-based fade out/in for enemies (not projectiles)
		if record.entityType == "Enemy" then
			if distSq > MAX_RENDER_DISTANCE * MAX_RENDER_DISTANCE then
				-- Enemy is beyond culling distance, fade out if not already faded
				if not record.isFadedOut and not record.isSpawning then
					record.isFadedOut = true
					fadeModel(model, 1, CULL_FADE_DURATION)  -- Fade out over 0.3s
				end
				-- Still continue to process updates (just invisible)
			else
				-- Enemy is within render distance, fade in if currently faded
				if record.isFadedOut then
					record.isFadedOut = false
					fadeModel(model, 0, CULL_FADE_DURATION)  -- Fade in over 0.3s
				end
			end
		end
		
		-- Skip projectiles/explosions beyond render distance (they move fast, full cull is fine)
		if record.entityType ~= "Enemy" and distSq > MAX_RENDER_DISTANCE * MAX_RENDER_DISTANCE then
			continue  -- Don't render projectiles >300 studs away
		end

		if simPosition then
			local baseCFrame = record.currentCFrame or model:GetPivot()
			local simCFrame = computeTargetCFrame(simPosition, record.facingDirection, record.velocity, baseCFrame, record.entityType)
			record.fromCFrame = simCFrame
			record.toCFrame = simCFrame
			record.lerpStart = now
			record.lerpEnd = now
		end
		
		local fromCFrame = record.fromCFrame or model:GetPivot()
		local toCFrame = record.toCFrame or fromCFrame
		local startTime = record.lerpStart or 0
		local endTime = record.lerpEnd or startTime
		
		-- CRITICAL FIX: Removed TweenService for enemies - it was only tweening PrimaryPart Position
		-- which caused visual desync (models floating). Manual lerp with PivotTo is more reliable.
		-- Clean up any existing tweens from previous implementation
		if record.entityType == "Enemy" and activeEnemyTweens[model] then
			pcall(function()
				activeEnemyTweens[model]:Cancel()
			end)
			activeEnemyTweens[model] = nil
		end

		local alpha = 1
		if endTime > startTime then
			alpha = math.clamp((now - startTime) / (endTime - startTime), 0, 1)
		end

		-- CRITICAL: AfterimageClones should NOT interpolate - always snap to exact position
		local newCFrame
		if record.entityType == "AfterimageClone" then
			newCFrame = toCFrame  -- Direct snap, no interpolation
		else
			newCFrame = fromCFrame:Lerp(toCFrame, alpha)
		end
		
		-- CRITICAL FIX: For enemies, clamp Y to toCFrame Y to prevent floating during rapid zooming
		if record.entityType == "Enemy" and toCFrame then
			local targetY = toCFrame.Position.Y
			local currentY = newCFrame.Position.Y
			-- If Y is drifting too far from target (>5 studs), snap it back
			if math.abs(currentY - targetY) > 5 then
				local pos = newCFrame.Position
				newCFrame = CFrame.new(pos.X, targetY, pos.Z) * (newCFrame - newCFrame.Position)
			end
		end

		local forceRemoval = false

		if record.entityType == "Projectile" and record.pendingRemovalTime and record.pendingRemovalTime > now then
			local velocityVector = toVelocityVector(record.velocity)
			if velocityVector and velocityVector.Magnitude > PROJECTILE_MIN_CONTINUE_SPEED then
				local lastTick = record.lastRenderTick or now
				local delta = math.max(now - lastTick, 0)
				if delta > 0 then
					newCFrame = newCFrame + velocityVector * delta
					record.fromCFrame = newCFrame
					record.toCFrame = newCFrame
					record.lerpStart = now
					record.lerpEnd = now
				end
			else
				forceRemoval = true
			end
		elseif record.entityType == "Projectile" and record.pendingRemovalTime then
			local velocityVector = toVelocityVector(record.velocity)
			if not velocityVector or velocityVector.Magnitude <= PROJECTILE_MIN_CONTINUE_SPEED then
				forceRemoval = true
			end
		end

		-- CRITICAL: For AfterimageClones, manually position each anchored part
		if record.entityType == "AfterimageClone" and record.currentCFrame then
			local offset = newCFrame.Position - record.currentCFrame.Position
			if record.anchoredParts then
				for _, part in ipairs(record.anchoredParts) do
					if part and part.Parent then
						part.CFrame = part.CFrame + offset
					end
				end
			end
		else
			model:PivotTo(newCFrame)
		end
		
		record.currentCFrame = newCFrame
		record.lastRenderTick = now

		if alpha >= 1 and (not record.pendingRemovalTime or record.pendingRemovalTime <= now) then
			record.fromCFrame = newCFrame
			record.toCFrame = newCFrame
			record.lerpStart = now
			record.lerpEnd = now
		end

		if forceRemoval then
			record.pendingRemovalTime = now
			table.insert(toRemove, key)
		end
	end

	for _, key in ipairs(toRemove) do
		handleEntityDespawn(key, true)
	end

	Prof.gauge("ActiveModels", activeModels)
	Prof.gauge("ActiveEnemies", activeEnemies)
	Prof.gauge("ActiveProjectiles", activeProjectiles)
	Prof.gauge("projectilesSimulated", simulatedProjectiles)
	Prof.gauge("ActiveOrbs", activeOrbs)
	Prof.endTimer("ClientEntityRenderer.Render")
end)

-- Listen for pause/unpause events
local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local GamePaused = remotes:WaitForChild("GamePaused") :: RemoteEvent
local GameUnpaused = remotes:WaitForChild("GameUnpaused") :: RemoteEvent

GamePaused.OnClientEvent:Connect(function(data: any)
	-- Only pause rendering for global pause mode
	-- Individual pause (multiplayer) should NOT freeze entity rendering
	local reason = data and data.reason
	local showTimer = data and data.showTimer
	
	-- If showTimer is true, this is individual pause (don't freeze rendering)
	-- If showTimer is false/nil, this is global pause (freeze rendering)
	if not showTimer then
		isPaused = true
		pauseStartTime = tick()
	else
		-- Individual pause mode - track for cleanup prevention
		isIndividuallyPaused = true
	end
end)

GameUnpaused.OnClientEvent:Connect(function()
	isPaused = false
	isIndividuallyPaused = false
	
	-- Calculate how long we were paused
	local pauseDuration = tick() - pauseStartTime
	totalPausedTime = totalPausedTime + pauseDuration
	
	-- Adjust projectile cleanup timer
	lastProjectileCleanup = lastProjectileCleanup + pauseDuration
	
	-- Adjust all time-based values in rendered entities to compensate for pause
	for _, record in pairs(renderedEntities) do
		if record.pendingRemovalTime then
			record.pendingRemovalTime = record.pendingRemovalTime + pauseDuration
		end
		if record.lerpStart then
			record.lerpStart = record.lerpStart + pauseDuration
		end
		if record.lerpEnd then
			record.lerpEnd = record.lerpEnd + pauseDuration
		end
		if record.lastRenderTick then
			record.lastRenderTick = record.lastRenderTick + pauseDuration
		end
		if record.spawnTime then
			record.spawnTime = record.spawnTime + pauseDuration
		end
		if record.lastUpdate then
			record.lastUpdate = record.lastUpdate + pauseDuration
		end
		
		-- Also adjust model attributes that track timestamps
		if record.model then
			local lastUpdateAttr = record.model:GetAttribute("ECS_LastUpdate")
			if typeof(lastUpdateAttr) == "number" then
				record.model:SetAttribute("ECS_LastUpdate", lastUpdateAttr + pauseDuration)
			end
		end
	end
	
	-- Adjust fade timers
	for model, fadeData in pairs(activeFades) do
		if fadeData.startTime then
			fadeData.startTime = fadeData.startTime + pauseDuration
		end
		if fadeData.endTime then
			fadeData.endTime = fadeData.endTime + pauseDuration
		end
	end
	
	-- Adjust hit flash timers
	for model, flashData in pairs(hitFlashHighlights) do
		if flashData.endTime then
			flashData.endTime = flashData.endTime + pauseDuration
		end
	end
end)

if player.Character then
	requestInitialSync()
else
	player.CharacterAdded:Connect(requestInitialSync)
end
