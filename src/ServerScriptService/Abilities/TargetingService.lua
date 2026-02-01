--!strict
-- TargetingService - Centralized target selection + aimpoint calculation
-- Returns stable aim points aligned with enemy hitbox centers.

local TargetingService = {}

local SpatialGridSystem = require(game.ServerScriptService.ECS.Systems.SpatialGridSystem)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)

local world: any
local Components: any
local EnemyRegistry: any
local ModelHitboxHelper: any

local GRID_SIZE = SpatialGridSystem.getGridSize()

-- Default tuning (can be overridden via ctx)
local DEFAULT_LOCK_DURATION = 0.2
local DEFAULT_REACQUIRE_DELAY = 0
local DEFAULT_MIN_TARGETABLE_AGE = 0.6
local MAX_PREDICTION_TIME = 1.0

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

-- Cached enemy hitbox offsets by subtype
local hitboxOffsetBySubtype: {[string]: Vector3} = {}

local function keyFor(playerEntity: number, abilityId: string?): string
	return tostring(playerEntity) .. ":" .. tostring(abilityId or "default")
end

function TargetingService.init(worldRef: any, components: any, enemyRegistry: any, hitboxHelper: any)
	world = worldRef
	Components = components
	EnemyRegistry = enemyRegistry
	ModelHitboxHelper = hitboxHelper

	table.clear(hitboxOffsetBySubtype)
	if EnemyRegistry and ModelHitboxHelper then
		for enemyId, enemy in pairs(EnemyRegistry.getAll()) do
			local balance = enemy and enemy.balance
			local modelPath = balance and balance.modelPath
			if modelPath then
				local _, offset = ModelHitboxHelper.getModelHitboxData(modelPath)
				if offset then
					hitboxOffsetBySubtype[enemyId] = offset
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

local function isPlayerGrounded(player: Player?): boolean
	local character = player and player.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end
	local state = humanoid:GetState()
	return state ~= Enum.HumanoidStateType.Freefall and state ~= Enum.HumanoidStateType.Flying
end

local function gatherEnemyCandidates(center: Vector3, maxRange: number): {number}
	if not world or not Components then
		return {}
	end
	local radiusCells = math.max(1, math.ceil(maxRange / GRID_SIZE))
	local candidates = SpatialGridSystem.getNeighboringEntities(center, radiusCells)
	if #candidates == 0 then
		candidates = SpatialGridSystem.getNeighboringEntities(center, radiusCells + 1)
	end
	return candidates
end

local function getEnemyAimPoint(enemyEntity: number): (Vector3?, any?, any?, any?)
	if not world or not Components then
		return nil, nil, nil, nil
	end
	local pos = world:get(enemyEntity, Components.Position)
	if not pos then
		return nil, nil, nil, nil
	end
	local base = Vector3.new(pos.x, pos.y, pos.z)
	local entityType = world:get(enemyEntity, Components.EntityType)
	local subtype = entityType and entityType.subtype
	local offset = subtype and hitboxOffsetBySubtype[subtype]
	if offset then
		return base + offset, entityType, offset, base
	end
	return base, entityType, nil, base
end

function TargetingService.getEnemyAimPoint(enemyEntity: number): Vector3?
	local aimPoint = getEnemyAimPoint(enemyEntity)
	return aimPoint
end

local function isTargetable(enemyEntity: number, origin: Vector3, maxRange: number, minAge: number, gameTime: number): (boolean, any?, Vector3?)
	if not world or not Components then
		return false, nil, nil
	end
	if not world:contains(enemyEntity) then
		return false, nil, nil
	end
	local entityType = world:get(enemyEntity, Components.EntityType)
	if not entityType or entityType.type ~= "Enemy" then
		return false, nil, nil
	end
	if world:has(enemyEntity, Components.DeathAnimation) then
		return false, nil, nil
	end
	local health = world:get(enemyEntity, Components.Health)
	if not health or health.current <= 0 then
		return false, nil, nil
	end
	local spawnTime = world:get(enemyEntity, Components.SpawnTime)
	if spawnTime and (gameTime - spawnTime.time) < minAge then
		return false, nil, nil
	end
	local aimPoint = TargetingService.getEnemyAimPoint(enemyEntity)
	if not aimPoint then
		return false, nil, nil
	end
	if (aimPoint - origin).Magnitude > maxRange then
		return false, nil, nil
	end
	return true, entityType, aimPoint
end

local function pickBestTarget(ctx: any, origin: Vector3, maxRange: number): (number?, Vector3?)
	local candidates = gatherEnemyCandidates(origin, maxRange)
	local best: number? = nil
	local bestDist = math.huge
	local bestAim: Vector3? = nil
	local gameTime = GameTimeSystem.getGameTime()
	local minAge = ctx.minTargetableAge or DEFAULT_MIN_TARGETABLE_AGE
	local key = keyFor(ctx.playerEntity, ctx.abilityId)

	for _, enemyEntity in ipairs(candidates) do
		local ok, _, aimPoint = isTargetable(enemyEntity, origin, maxRange, minAge, gameTime)
		if ok and aimPoint then
			local predicted = TargetingService.getPredictedDamage(ctx.playerEntity, ctx.abilityId, enemyEntity)
			local health = world:get(enemyEntity, Components.Health)
			if not health or health.current > predicted then
				local dist = (aimPoint - origin).Magnitude
				if dist < bestDist then
					best = enemyEntity
					bestDist = dist
					bestAim = aimPoint
				end
			end
		end
	end

	if not best then
		for _, enemyEntity in ipairs(candidates) do
			local ok, _, aimPoint = isTargetable(enemyEntity, origin, maxRange, minAge, gameTime)
			if ok and aimPoint then
				local dist = (aimPoint - origin).Magnitude
				if dist < bestDist then
					best = enemyEntity
					bestDist = dist
					bestAim = aimPoint
				end
			end
		end
	end

	if best then
		currentTargets[key] = best
		local lock = ctx.lockDuration or DEFAULT_LOCK_DURATION
		targetLockUntil[key] = tick() + lock
		pendingSwitchUntil[key] = nil
		pendingTargetId[key] = nil
	end

	return best, bestAim
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

	cleanupStalePredictions()

	local origin: Vector3 = ctx.origin
	local maxRange = ctx.maxRange or 200
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

	if mode == 0 then
		local angle = math.random() * math.pi * 2
		local yAngle = (math.random() * 2 - 1) * 0.5
		local dir = Vector3.new(math.cos(angle), yAngle, math.sin(angle))
		if dir.Magnitude == 0 then
			dir = Vector3.new(0, 0, 1)
		end
		dir = dir.Unit
		local finalDir = dir
		if ctx.alwaysStayHorizontal or (ctx.stayHorizontal and isPlayerGrounded(player)) then
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
		if ctx.alwaysStayHorizontal or (ctx.stayHorizontal and isPlayerGrounded(player)) then
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
	if current then
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
				else
					-- Keep the same valid target even without a lock to preserve stickiness.
					targetEntity = current
					aimPoint = currentAim
				end
			end
		end
	end

	if not targetEntity then
		targetEntity, aimPoint = pickBestTarget(ctx, origin, maxRange)
	end

	-- mode 1 handled above (random, no enemy influence)

	if not aimPoint then
		local forward = getPlayerForward(player)
		local dir = forward or Vector3.new(0, 0, 1)
		return { targetEntity = nil, aimPoint = origin + dir * maxRange, direction = dir, reason = "fallback" }
	end

	-- Apply prediction if enabled
	if ctx.enablePrediction and ctx.projectileSpeed and targetEntity then
		local velocity = world:get(targetEntity, Components.Velocity)
		if velocity then
			local targetVel = Vector3.new(velocity.x, velocity.y, velocity.z)
			aimPoint = maybeIntercept(origin, aimPoint, targetVel, ctx.projectileSpeed, maxRange)
		end
	end

	-- Horizontal aiming rules
	local finalAimPoint = aimPoint
	if ctx.alwaysStayHorizontal then
		finalAimPoint = Vector3.new(aimPoint.X, origin.Y, aimPoint.Z)
	elseif ctx.stayHorizontal and isPlayerGrounded(player) then
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

return TargetingService
