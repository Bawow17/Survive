--!strict
-- TargetingService - Centralized target selection + aimpoint calculation
-- Returns stable aim points aligned with enemy hitbox centers.

local TargetingService = {}

local SpatialGridSystem = require(game.ServerScriptService.ECS.Systems.SpatialGridSystem)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)

local world: any
local Components: any
local EnemyRegistry: any
local ModelHitboxHelper: any
local enemyFallbackQuery: any

local GRID_SIZE = SpatialGridSystem.getGridSize()
local INVINCIBLE_ENEMY_DIAGNOSTICS = GameOptions.Debug and GameOptions.Debug.InvincibleEnemyDiagnostics or false
local ENEMY_VISUAL_HITBOX_DIAGNOSTICS = GameOptions.Debug and GameOptions.Debug.EnemyVisualHitboxDiagnostics or false
local targetingDiagCounters = {
	acquireCalls = 0,
	candidatesFromGridScanned = 0,
	candidatesFromFallbackScanned = 0,
	targetsChosenFromFallback = 0,
	rejectNotEnemy = 0,
	rejectDeadOrNoHealth = 0,
	rejectDeathAnimation = 0,
	rejectSpawnAge = 0,
	rejectNoAimPoint = 0,
	rejectOutOfRange = 0,
	acquireNoTargetFallbackUsed = 0,
}

local function resetTargetingDiagnostics()
	for key in pairs(targetingDiagCounters) do
		targetingDiagCounters[key] = 0
	end
end

-- Default tuning (can be overridden via ctx)
local DEFAULT_LOCK_DURATION = 0.2
local DEFAULT_REACQUIRE_DELAY = 0
local DEFAULT_MIN_TARGETABLE_AGE = 0.6
local MAX_PREDICTION_TIME = 1.0
local STAY_HORIZONTAL_TARGET_Y_DIFF = 10.0

-- Prediction tracking (per player+ability)
local activePredictions: {[string]: {[number]: number}} = {}
local predictionStartTimes: {[string]: number} = {}
local PREDICTION_TIMEOUT = 5.0
local CLEANUP_INTERVAL = 10.0
local lastCleanupTime = 0

-- Target lock tracking (per player+ability)
local currentTargets: {[string]: number} = {}
local targetLockUntil: {[string]: number} = {}
local pendingSwitchUntil: {[string]: number} = {}
local pendingTargetId: {[string]: number} = {}

-- Cached enemy hitbox transform data by subtype.
local hitboxBySubtype: {[string]: {
	offset: Vector3,
	radius: number,
}} = {}
local warnedSuspiciousOffsetBySubtype: {[string]: boolean} = {}

local function keyFor(playerEntity: number, abilityId: string?): string
	return tostring(playerEntity) .. ":" .. tostring(abilityId or "default")
end

function TargetingService.init(worldRef: any, components: any, enemyRegistry: any, hitboxHelper: any)
	world = worldRef
	Components = components
	EnemyRegistry = enemyRegistry
	ModelHitboxHelper = hitboxHelper
	enemyFallbackQuery = world:query(Components.EntityType, Components.Position, Components.Health):cached()

	table.clear(hitboxBySubtype)
	table.clear(warnedSuspiciousOffsetBySubtype)
	if EnemyRegistry then
		for enemyId in pairs(EnemyRegistry.getAll()) do
			local replicatedHitbox = ModelReplicationService.getEnemyHitbox(enemyId)
			if not replicatedHitbox then
				ModelReplicationService.replicateEnemy(enemyId)
				replicatedHitbox = ModelReplicationService.getEnemyHitbox(enemyId)
			end
			if replicatedHitbox and replicatedHitbox.size then
				local size = replicatedHitbox.size
				local offset = replicatedHitbox.offset or Vector3.new(0, 0, 0)
				local radius = math.max(size.X, size.Y, size.Z) * 0.5
				hitboxBySubtype[enemyId] = {
					offset = offset,
					radius = radius,
				}
				if ENEMY_VISUAL_HITBOX_DIAGNOSTICS then
					local halfXZ = math.max(size.X, size.Z) * 0.5
					local offsetXZ = Vector3.new(offset.X, 0, offset.Z).Magnitude
					if halfXZ > 0 and offsetXZ > (halfXZ * 1.5) and not warnedSuspiciousOffsetBySubtype[enemyId] then
						warnedSuspiciousOffsetBySubtype[enemyId] = true
						warn(string.format(
							"[TargetingService] Suspicious hitbox offset subtype=%s offsetXZ=%.2f halfXZ=%.2f",
							tostring(enemyId),
							offsetXZ,
							halfXZ
						))
					end
				end
			end
		end
	end
end

local function cleanupStalePredictions()
	local now = tick()
	if now - lastCleanupTime < CLEANUP_INTERVAL then
		return
	end
	lastCleanupTime = now

	for key, startTime in pairs(predictionStartTimes) do
		if now - startTime > PREDICTION_TIMEOUT then
			activePredictions[key] = nil
			currentTargets[key] = nil
			targetLockUntil[key] = nil
			pendingSwitchUntil[key] = nil
			pendingTargetId[key] = nil
			predictionStartTimes[key] = nil
		end
	end
end

function TargetingService.startCastPrediction(playerEntity: number, abilityId: string?)
	local key = keyFor(playerEntity, abilityId)
	activePredictions[key] = {}
	currentTargets[key] = nil
	predictionStartTimes[key] = tick()
	pendingSwitchUntil[key] = nil
	pendingTargetId[key] = nil
end

function TargetingService.endCastPrediction(playerEntity: number, abilityId: string?)
	local key = keyFor(playerEntity, abilityId)
	activePredictions[key] = nil
	currentTargets[key] = nil
	targetLockUntil[key] = nil
	pendingSwitchUntil[key] = nil
	pendingTargetId[key] = nil
	predictionStartTimes[key] = nil
end

function TargetingService.recordPredictedDamage(playerEntity: number, abilityId: string?, enemyEntity: number, damage: number)
	local key = keyFor(playerEntity, abilityId)
	local predictions = activePredictions[key]
	if not predictions then
		predictions = {}
		activePredictions[key] = predictions
		predictionStartTimes[key] = predictionStartTimes[key] or tick()
	end
	predictions[enemyEntity] = (predictions[enemyEntity] or 0) + damage
end

function TargetingService.getPredictedDamage(playerEntity: number, abilityId: string?, enemyEntity: number): number
	local key = keyFor(playerEntity, abilityId)
	local predictions = activePredictions[key]
	return predictions and predictions[enemyEntity] or 0
end

local function getPlayerForward(player: Player?): Vector3?
	local character = player and player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return (hrp :: BasePart).CFrame.LookVector
	end
	return nil
end

local function shouldUseStayHorizontal(stayHorizontal: boolean?, origin: Vector3, targetPoint: Vector3?): boolean
	if not stayHorizontal then
		return false
	end
	if not targetPoint then
		return true
	end
	return math.abs(targetPoint.Y - origin.Y) <= STAY_HORIZONTAL_TARGET_Y_DIFF
end

local function gatherGridEnemyCandidates(center: Vector3, maxRange: number): {number}
	if not world or not Components then
		return {}
	end
	local radiusCells = math.max(1, math.ceil(maxRange / GRID_SIZE))
	local candidates = SpatialGridSystem.getNeighboringEntities(center, radiusCells)
	if #candidates == 0 then
		candidates = SpatialGridSystem.getNeighboringEntities(center, radiusCells + 1)
	end
	if INVINCIBLE_ENEMY_DIAGNOSTICS then
		targetingDiagCounters.candidatesFromGridScanned += #candidates
	end
	return candidates
end

local function gatherFallbackEnemyCandidates(): {number}
	if not enemyFallbackQuery then
		return {}
	end
	local candidates = {}
	for enemyEntity, entityType in enemyFallbackQuery do
		if entityType and entityType.type == "Enemy" then
			candidates[#candidates + 1] = enemyEntity
		end
	end
	if INVINCIBLE_ENEMY_DIAGNOSTICS then
		targetingDiagCounters.candidatesFromFallbackScanned += #candidates
	end
	return candidates
end

local function getCachedHitboxForSubtype(subtype: string?): {offset: Vector3, radius: number}?
	if not subtype or subtype == "" then
		return nil
	end
	local cached = hitboxBySubtype[subtype]
	if cached then
		return cached
	end

	local replicatedHitbox = ModelReplicationService.getEnemyHitbox(subtype)
	if not replicatedHitbox then
		ModelReplicationService.replicateEnemy(subtype)
		replicatedHitbox = ModelReplicationService.getEnemyHitbox(subtype)
	end
	if not replicatedHitbox or not replicatedHitbox.size then
		return nil
	end

	local size = replicatedHitbox.size
	local offset = replicatedHitbox.offset or Vector3.new(0, 0, 0)
	cached = {
		offset = offset,
		radius = math.max(size.X, size.Y, size.Z) * 0.5,
	}
	hitboxBySubtype[subtype] = cached
	if ENEMY_VISUAL_HITBOX_DIAGNOSTICS then
		local halfXZ = math.max(size.X, size.Z) * 0.5
		local offsetXZ = Vector3.new(offset.X, 0, offset.Z).Magnitude
		if halfXZ > 0 and offsetXZ > (halfXZ * 1.5) and not warnedSuspiciousOffsetBySubtype[subtype] then
			warnedSuspiciousOffsetBySubtype[subtype] = true
			warn(string.format(
				"[TargetingService] Suspicious hitbox offset subtype=%s offsetXZ=%.2f halfXZ=%.2f",
				tostring(subtype),
				offsetXZ,
				halfXZ
			))
		end
	end
	return cached
end

local function getEnemyFacingOrientation(enemyEntity: number): CFrame
	if not world or not Components or not Components.FacingDirection then
		return CFrame.new()
	end
	local facing = world:get(enemyEntity, Components.FacingDirection)
	if typeof(facing) ~= "table" then
		return CFrame.new()
	end
	local fx = facing.x or facing.X
	local fz = facing.z or facing.Z
	if typeof(fx) ~= "number" or typeof(fz) ~= "number" then
		return CFrame.new()
	end
	local dir = Vector3.new(fx, 0, fz)
	if dir.Magnitude <= 1e-4 then
		return CFrame.new()
	end
	return CFrame.lookAt(Vector3.zero, dir.Unit)
end

local function getEnemyScale(enemyEntity: number): number
	local scale = 1.0
	if not world or not Components then
		return scale
	end

	local visual = Components.Visual and world:get(enemyEntity, Components.Visual)
	local visualScale = visual and visual.scale
	if typeof(visualScale) == "number" and visualScale == visualScale and visualScale > 0 then
		scale = math.max(scale, math.clamp(visualScale, 0.1, 20.0))
	end

	local tierData = Components.EnemyTier and world:get(enemyEntity, Components.EnemyTier)
	if typeof(tierData) == "table" then
		local tierScale = tierData.scale
		if typeof(tierScale) == "number" and tierScale == tierScale and tierScale > 0 then
			scale = math.max(scale, math.clamp(tierScale, 0.1, 20.0))
		else
			local tierName = tierData.tier
			if tierName == "Super" then
				scale = math.max(scale, 4.0)
			elseif tierName == "Elite" then
				scale = math.max(scale, 7.5)
			end
		end
	end

	return scale
end

local function getEnemyAimPoint(enemyEntity: number): (Vector3?, any?, any?, any?, number?)
	if not world or not Components then
		return nil, nil, nil, nil, nil
	end
	local pos = world:get(enemyEntity, Components.Position)
	if not pos then
		return nil, nil, nil, nil, nil
	end
	local base = Vector3.new(pos.x, pos.y, pos.z)
	local entityType = world:get(enemyEntity, Components.EntityType)
	local subtype = entityType and entityType.subtype
	local scale = getEnemyScale(enemyEntity)
	local hitbox = getCachedHitboxForSubtype(subtype)
	local scaledOffset: Vector3? = nil
	local enemyRadius = if hitbox then (hitbox.radius * scale) else nil
	if hitbox then
		scaledOffset = Vector3.new(hitbox.offset.X * scale, hitbox.offset.Y * scale, hitbox.offset.Z * scale)
	end
	if Components.Collision then
		local collision = world:get(enemyEntity, Components.Collision)
		if collision and collision.radius then
			if enemyRadius then
				enemyRadius = math.max(enemyRadius, collision.radius)
			else
				enemyRadius = collision.radius
			end
		end
	end
	if scaledOffset then
		return base + scaledOffset, entityType, scaledOffset, base, enemyRadius
	end
	return base, entityType, nil, base, enemyRadius
end

function TargetingService.getEnemyAimPoint(enemyEntity: number): Vector3?
	local aimPoint = getEnemyAimPoint(enemyEntity)
	return aimPoint
end

local function isTargetable(enemyEntity: number, origin: Vector3, maxRange: number, minAge: number, gameTime: number): (boolean, any?, Vector3?, Vector3?)
	if not world or not Components then
		return false, nil, nil, nil
	end
	if not world:contains(enemyEntity) then
		if INVINCIBLE_ENEMY_DIAGNOSTICS then
			targetingDiagCounters.rejectDeadOrNoHealth += 1
		end
		return false, nil, nil, nil
	end
	local entityType = world:get(enemyEntity, Components.EntityType)
	if not entityType or entityType.type ~= "Enemy" then
		if INVINCIBLE_ENEMY_DIAGNOSTICS then
			targetingDiagCounters.rejectNotEnemy += 1
		end
		return false, nil, nil, nil
	end
	if world:has(enemyEntity, Components.DeathAnimation) then
		if INVINCIBLE_ENEMY_DIAGNOSTICS then
			targetingDiagCounters.rejectDeathAnimation += 1
		end
		return false, nil, nil, nil
	end
	local health = world:get(enemyEntity, Components.Health)
	if not health or health.current <= 0 then
		if INVINCIBLE_ENEMY_DIAGNOSTICS then
			targetingDiagCounters.rejectDeadOrNoHealth += 1
		end
		return false, nil, nil, nil
	end
	local spawnTime = world:get(enemyEntity, Components.SpawnTime)
	if spawnTime and (gameTime - spawnTime.time) < minAge then
		if INVINCIBLE_ENEMY_DIAGNOSTICS then
			targetingDiagCounters.rejectSpawnAge += 1
		end
		return false, nil, nil, nil
	end
	local aimPoint, _, _, base, enemyRadius = getEnemyAimPoint(enemyEntity)
	if not aimPoint then
		if INVINCIBLE_ENEMY_DIAGNOSTICS then
			targetingDiagCounters.rejectNoAimPoint += 1
		end
		return false, nil, nil, nil
	end
	local distPoint = base
	if not distPoint then
		distPoint = aimPoint
	end
	local allowedRange = maxRange + (enemyRadius or 0)
	if (distPoint - origin).Magnitude > allowedRange then
		if INVINCIBLE_ENEMY_DIAGNOSTICS then
			targetingDiagCounters.rejectOutOfRange += 1
		end
		return false, nil, nil, nil
	end
	return true, entityType, aimPoint, base
end

local function pickBestTargetFromCandidates(ctx: any, origin: Vector3, maxRange: number, candidates: {number}): (number?, Vector3?, number?)
	local best: number? = nil
	local bestDist = math.huge
	local bestAim: Vector3? = nil
	local gameTime = GameTimeSystem.getGameTime()
	local minAge = ctx.minTargetableAge or DEFAULT_MIN_TARGETABLE_AGE
	local usePredictedDamage = ctx.usePredictedDamage ~= false
	local function planarDistance(from: Vector3, to: Vector3): number
		local dx = from.X - to.X
		local dz = from.Z - to.Z
		return math.sqrt(dx * dx + dz * dz)
	end

	if usePredictedDamage then
		for _, enemyEntity in ipairs(candidates) do
			local ok, _, aimPoint, base = isTargetable(enemyEntity, origin, maxRange, minAge, gameTime)
			if ok and aimPoint then
				local predicted = TargetingService.getPredictedDamage(ctx.playerEntity, ctx.abilityId, enemyEntity)
				local health = world:get(enemyEntity, Components.Health)
				if not health or health.current > predicted then
					if not base then
						base = aimPoint
					end
					local dist = planarDistance(base, origin)
					if dist < bestDist or (math.abs(dist - bestDist) <= 1e-4 and (not best or enemyEntity < best)) then
						best = enemyEntity
						bestDist = dist
						bestAim = aimPoint
					end
				end
			end
		end
	end

	if not best or not usePredictedDamage then
		for _, enemyEntity in ipairs(candidates) do
			local ok, _, aimPoint, base = isTargetable(enemyEntity, origin, maxRange, minAge, gameTime)
			if ok and aimPoint then
				if not base then
					base = aimPoint
				end
				local dist = planarDistance(base, origin)
				if dist < bestDist or (math.abs(dist - bestDist) <= 1e-4 and (not best or enemyEntity < best)) then
					best = enemyEntity
					bestDist = dist
					bestAim = aimPoint
				end
			end
		end
	end

	if best and bestDist < math.huge then
		return best, bestAim, bestDist
	end
	return nil, nil, nil
end

local function maybeIntercept(origin: Vector3, targetPos: Vector3, targetVel: Vector3?, projectileSpeed: number, maxRange: number?): Vector3
	if not targetVel then
		return targetPos
	end
	if projectileSpeed <= 0 then
		return targetPos
	end

	local relPos = targetPos - origin
	local relVel = targetVel
	local a = relVel:Dot(relVel) - projectileSpeed * projectileSpeed
	local b = 2 * relPos:Dot(relVel)
	local c = relPos:Dot(relPos)
	local t: number? = nil

	if math.abs(a) < 1e-6 then
		if math.abs(b) > 1e-6 then
			t = -c / b
		end
	else
		local disc = b * b - 4 * a * c
		if disc >= 0 then
			local sqrtDisc = math.sqrt(disc)
			local t1 = (-b - sqrtDisc) / (2 * a)
			local t2 = (-b + sqrtDisc) / (2 * a)
			if t1 and t1 > 0 then
				t = t1
			end
			if t2 and t2 > 0 and (not t or t2 < t) then
				t = t2
			end
		end
	end

	if not t or t <= 0 then
		return targetPos
	end

	local maxTime = MAX_PREDICTION_TIME
	if maxRange and maxRange > 0 then
		maxTime = math.min(MAX_PREDICTION_TIME, maxRange / projectileSpeed)
	end
	if t > maxTime then
		t = maxTime
	end

	return targetPos + relVel * t
end

function TargetingService.acquireTarget(ctx: any): {targetEntity: number?, aimPoint: Vector3?, direction: Vector3, reason: string}
	if not world or not Components then
		return { targetEntity = nil, aimPoint = nil, direction = Vector3.new(0, 0, 1), reason = "uninitialized" }
	end
	if INVINCIBLE_ENEMY_DIAGNOSTICS then
		targetingDiagCounters.acquireCalls += 1
	end

	cleanupStalePredictions()

	local origin: Vector3 = ctx.origin
	local requestedRange = ctx.maxRange or 200
	local maxRange = requestedRange
	-- Clamp targeting range to actual projectile travel distance when possible.
	if ctx.projectileSpeed and (ctx.duration or ctx.lifetime) then
		local lifetime = ctx.duration or ctx.lifetime
		if typeof(lifetime) == "number" and lifetime > 0 then
			local travelRange = ctx.projectileSpeed * lifetime
			if travelRange > 0 then
				maxRange = math.min(maxRange, travelRange)
			end
		end
	end
	local mode = ctx.mode or 2
	local player = ctx.player
	local key = keyFor(ctx.playerEntity, ctx.abilityId)
	local now = tick()
	local gameTime = GameTimeSystem.getGameTime()
	local minAge = ctx.minTargetableAge or DEFAULT_MIN_TARGETABLE_AGE
	local preferCurrentTarget = ctx.preferCurrentTarget ~= false

	if not preferCurrentTarget then
		currentTargets[key] = nil
		targetLockUntil[key] = nil
		pendingSwitchUntil[key] = nil
		pendingTargetId[key] = nil
	end

	if mode == 0 then
		local angle = math.random() * math.pi * 2
		local yAngle = (math.random() * 2 - 1) * 0.5
		local dir = Vector3.new(math.cos(angle), yAngle, math.sin(angle))
		if dir.Magnitude == 0 then
			dir = Vector3.new(0, 0, 1)
		end
		dir = dir.Unit
		local finalDir = dir
		if ctx.alwaysStayHorizontal or shouldUseStayHorizontal(ctx.stayHorizontal, origin, nil) then
			finalDir = Vector3.new(dir.X, 0, dir.Z)
			if finalDir.Magnitude == 0 then
				finalDir = Vector3.new(0, 0, 1)
			end
			finalDir = finalDir.Unit
		end
		return { targetEntity = nil, aimPoint = origin + finalDir * maxRange, direction = finalDir, reason = "random" }
	end

	if mode == 1 then
		-- Random horizontal direction ONLY; no enemy influence.
		local angle = math.random() * math.pi * 2
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		if dir.Magnitude == 0 then
			dir = Vector3.new(0, 0, 1)
		end
		dir = dir.Unit
		local finalDir = dir
		if ctx.alwaysStayHorizontal or shouldUseStayHorizontal(ctx.stayHorizontal, origin, nil) then
			finalDir = Vector3.new(dir.X, 0, dir.Z)
			if finalDir.Magnitude == 0 then
				finalDir = Vector3.new(0, 0, 1)
			end
			finalDir = finalDir.Unit
		end
		return { targetEntity = nil, aimPoint = origin + finalDir * maxRange, direction = finalDir, reason = "random_horizontal" }
	end

	local targetEntity: number? = nil
	local aimPoint: Vector3? = nil

	-- Try to keep current target if valid; allow predicted-death switching even while locked.
	local current = currentTargets[key]
	local lockUntil = targetLockUntil[key] or 0
	if preferCurrentTarget and current then
		local ok, _, currentAim = isTargetable(current, origin, maxRange, minAge, gameTime)
		if ok and currentAim then
			local predicted = TargetingService.getPredictedDamage(ctx.playerEntity, ctx.abilityId, current)
			local health = world:get(current, Components.Health)
			if health and health.current <= predicted then
				pendingSwitchUntil[key] = nil
				pendingTargetId[key] = nil
			else
				pendingSwitchUntil[key] = nil
				pendingTargetId[key] = nil
				if lockUntil > now then
					targetEntity = current
					aimPoint = currentAim
				end
			end
		end
	end

	local chosenRange = maxRange
	local targetChosenFromFallback = false
	local function acquireFromRange(searchRange: number): (number?, Vector3?, boolean)
		local gridCandidates = gatherGridEnemyCandidates(origin, searchRange)
		local bestEntity, bestAim, bestDist = pickBestTargetFromCandidates(ctx, origin, searchRange, gridCandidates)

		local shouldCompareFallback = (ctx.preferCurrentTarget == false)
		if (not bestEntity) or shouldCompareFallback then
			local fallbackCandidates = gatherFallbackEnemyCandidates()
			if #fallbackCandidates > 0 then
				local fallbackEntity, fallbackAim, fallbackDist = pickBestTargetFromCandidates(ctx, origin, searchRange, fallbackCandidates)
				if fallbackEntity and fallbackAim then
					if not bestEntity then
						return fallbackEntity, fallbackAim, true
					end
					if fallbackDist and bestDist then
						if (fallbackDist + 1e-4) < bestDist then
							return fallbackEntity, fallbackAim, true
						end
						if math.abs(fallbackDist - bestDist) <= 1e-4 and fallbackEntity < bestEntity then
							return fallbackEntity, fallbackAim, true
						end
					end
				end
			end
		end
		if bestEntity and bestAim then
			return bestEntity, bestAim, false
		end
		return nil, nil, false
	end

	if not targetEntity then
		targetEntity, aimPoint, targetChosenFromFallback = acquireFromRange(maxRange)
		-- Fallback pass: if no target found in travel-range window, still acquire closest
		-- enemy in requested range so targeting never appears to "turn off" when enemies
		-- are present but temporarily outside projectile travel distance.
		if not targetEntity and requestedRange > maxRange then
			targetEntity, aimPoint, targetChosenFromFallback = acquireFromRange(requestedRange)
			chosenRange = requestedRange
		end
	end

	-- mode 1 handled above (random, no enemy influence)

	if not aimPoint then
		if INVINCIBLE_ENEMY_DIAGNOSTICS then
			targetingDiagCounters.acquireNoTargetFallbackUsed += 1
		end
		local forward = getPlayerForward(player)
		local dir = forward or Vector3.new(0, 0, 1)
		return { targetEntity = nil, aimPoint = origin + dir * maxRange, direction = dir, reason = "fallback" }
	end

	if targetEntity then
		if targetChosenFromFallback and INVINCIBLE_ENEMY_DIAGNOSTICS then
			targetingDiagCounters.targetsChosenFromFallback += 1
		end
		if ctx.preferCurrentTarget == false then
			currentTargets[key] = nil
			targetLockUntil[key] = nil
			pendingSwitchUntil[key] = nil
			pendingTargetId[key] = nil
		else
			currentTargets[key] = targetEntity
			local lock = ctx.lockDuration or DEFAULT_LOCK_DURATION
			targetLockUntil[key] = tick() + lock
			pendingSwitchUntil[key] = nil
			pendingTargetId[key] = nil
		end
	end

	-- Apply prediction if enabled
	if ctx.enablePrediction and ctx.projectileSpeed and targetEntity then
		local velocity = world:get(targetEntity, Components.Velocity)
		if velocity then
			local targetVel = Vector3.new(velocity.x, velocity.y, velocity.z)
			aimPoint = maybeIntercept(origin, aimPoint, targetVel, ctx.projectileSpeed, chosenRange)
		end
	end

	-- Horizontal aiming rules
	local finalAimPoint = aimPoint
	if ctx.alwaysStayHorizontal then
		finalAimPoint = Vector3.new(aimPoint.X, origin.Y, aimPoint.Z)
	elseif shouldUseStayHorizontal(ctx.stayHorizontal, origin, aimPoint) then
		finalAimPoint = Vector3.new(aimPoint.X, origin.Y, aimPoint.Z)
	end

	local dir = finalAimPoint - origin
	if dir.Magnitude == 0 then
		local forward = getPlayerForward(player)
		dir = forward or Vector3.new(0, 0, 1)
	end

	return {
		targetEntity = targetEntity,
		aimPoint = finalAimPoint,
		direction = dir.Unit,
		reason = targetEntity and "target" or "fallback",
	}
end

function TargetingService.getInvincibleEnemyDebugSnapshot(reset: boolean?): {[string]: any}
	local snapshot = {
		acquireCalls = targetingDiagCounters.acquireCalls,
		candidatesFromGridScanned = targetingDiagCounters.candidatesFromGridScanned,
		candidatesFromFallbackScanned = targetingDiagCounters.candidatesFromFallbackScanned,
		targetsChosenFromFallback = targetingDiagCounters.targetsChosenFromFallback,
		-- Backward compatibility with existing log format.
		candidatesFromGrid = targetingDiagCounters.candidatesFromGridScanned,
		candidatesFromFallback = targetingDiagCounters.candidatesFromFallbackScanned,
		rejectNotEnemy = targetingDiagCounters.rejectNotEnemy,
		rejectDeadOrNoHealth = targetingDiagCounters.rejectDeadOrNoHealth,
		rejectDeathAnimation = targetingDiagCounters.rejectDeathAnimation,
		rejectSpawnAge = targetingDiagCounters.rejectSpawnAge,
		rejectNoAimPoint = targetingDiagCounters.rejectNoAimPoint,
		rejectOutOfRange = targetingDiagCounters.rejectOutOfRange,
		acquireNoTargetFallbackUsed = targetingDiagCounters.acquireNoTargetFallbackUsed,
	}

	if reset then
		resetTargetingDiagnostics()
	end

	return snapshot
end

return TargetingService
