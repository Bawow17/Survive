--!strict
-- TemporalStasisSystem - Server-authoritative localized time stop.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EnemySlowSystem = require(game.ServerScriptService.ECS.Systems.EnemySlowSystem)
local EnemyColliderService = require(game.ServerScriptService.Services.EnemyColliderService)

local TemporalStasisSystem = {}

local world: any
local Components: any
local DirtyService: any
local DamageSystemRef: any

local Position: any
local EntityType: any
local Health: any
local PlayerStats: any
local Knockback: any
local DeathAnimation: any
local EnemySlow: any
local EnemyFrostbite: any
local EnemyTimeStopped: any

local enemyQuery: any

local timeStopStateRemote: RemoteEvent? = nil

type TimeStopField = {
	casterEntity: number?,
	center: Vector3,
	radius: number,
	startTime: number,
	endTime: number,
}

type DeferredPacket = {
	targetEntity: number?,
	sourceEntity: number?,
	damageAmount: number,
	procCoefficient: number?,
	damageType: string?,
	abilityId: string?,
	timestamp: number,
	sequence: number,
	sideEffects: {any},
	replayHitscan: boolean?,
	replayOrigin: Vector3?,
	replayEnd: Vector3?,
}

type DeferredSortPacket = {
	packet: DeferredPacket,
	sourceEntity: number?,
	abilityId: string?,
	damageType: string?,
	timestamp: number,
	sequence: number,
}

type ActiveSession = {
	sessionId: number,
	startTime: number,
	endTime: number,
	fields: {TimeStopField},
	deferredPackets: {DeferredPacket},
	deferSequence: number,
}

local activeSession: ActiveSession? = nil
local sessionIdCounter = 0

local frozenEnemyStateByEntity: {[number]: {enteredAt: number, sessionId: number}} = {}
local DEFERRED_HITSCAN_BOX_INFLATE = 0.75

local function ensureRemoteEvent(parent: Instance, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function isPointInsideField(point: Vector3, field: TimeStopField): boolean
	local delta = point - field.center
	return delta:Dot(delta) <= (field.radius * field.radius)
end

local function isPointFrozenAt(point: Vector3, now: number): boolean
	local session = activeSession
	if not session then
		return false
	end
	for _, field in ipairs(session.fields) do
		if field.endTime > now and isPointInsideField(point, field) then
			return true
		end
	end
	return false
end

local function normalizeSegment(origin: Vector3, finalImpact: Vector3): (Vector3, number)
	local segment = finalImpact - origin
	local segLen = segment.Magnitude
	if segLen <= 1e-6 then
		return Vector3.new(0, 0, 0), 0
	end
	return segment, segLen
end

local function appendSphereIntersections(ts: {number}, origin: Vector3, segment: Vector3, field: TimeStopField)
	local a = segment:Dot(segment)
	if a <= 1e-8 then
		return
	end
	local rel = origin - field.center
	local b = 2 * rel:Dot(segment)
	local c = rel:Dot(rel) - (field.radius * field.radius)
	local disc = (b * b) - (4 * a * c)
	if disc < 0 then
		return
	end
	local sqrtDisc = math.sqrt(disc)
	local inv = 1 / (2 * a)
	local t1 = (-b - sqrtDisc) * inv
	local t2 = (-b + sqrtDisc) * inv
	if t1 >= 0 and t1 <= 1 then
		table.insert(ts, t1)
	end
	if t2 >= 0 and t2 <= 1 then
		table.insert(ts, t2)
	end
end

local function collectSegmentIntersections(origin: Vector3, finalImpact: Vector3, now: number): {number}
	local session = activeSession
	if not session then
		return {}
	end
	local segment = finalImpact - origin
	local ts: {number} = {}
	for _, field in ipairs(session.fields) do
		if field.endTime > now then
			appendSphereIntersections(ts, origin, segment, field)
		end
	end
	table.sort(ts)
	return ts
end

local function findEntryT(origin: Vector3, finalImpact: Vector3, now: number): number?
	local segment = finalImpact - origin
	local ts = collectSegmentIntersections(origin, finalImpact, now)
	for _, t in ipairs(ts) do
		local beforeT = math.max(0, t - 1e-4)
		local afterT = math.min(1, t + 1e-4)
		local beforeInside = isPointFrozenAt(origin + (segment * beforeT), now)
		local afterInside = isPointFrozenAt(origin + (segment * afterT), now)
		if not beforeInside and afterInside then
			return t
		end
	end
	return nil
end

local function findExitT(origin: Vector3, finalImpact: Vector3, now: number): number?
	local segment = finalImpact - origin
	local ts = collectSegmentIntersections(origin, finalImpact, now)
	for _, t in ipairs(ts) do
		local beforeT = math.max(0, t - 1e-4)
		local afterT = math.min(1, t + 1e-4)
		local beforeInside = isPointFrozenAt(origin + (segment * beforeT), now)
		local afterInside = isPointFrozenAt(origin + (segment * afterT), now)
		if beforeInside and not afterInside then
			return t
		end
	end
	return nil
end

local function sendTimeStopState()
	local remote = timeStopStateRemote
	if not remote then
		return
	end
	local now = tick()
	local session = activeSession
	if not session then
		remote:FireAllClients({
			active = false,
			sessionId = nil,
			serverTime = now,
		})
		return
	end

	local fieldsPayload: {any} = table.create(#session.fields)
	for i, field in ipairs(session.fields) do
		fieldsPayload[i] = {
			center = field.center,
			radius = field.radius,
			startTime = field.startTime,
			endTime = field.endTime,
		}
	end

	remote:FireAllClients({
		active = true,
		sessionId = session.sessionId,
		startTime = session.startTime,
		endTime = session.endTime,
		fields = fieldsPayload,
		serverTime = now,
	})
end

local function shiftEnemyTimedState(enemyEntity: number, frozenDuration: number)
	if frozenDuration <= 0 then
		return
	end

	if EnemySlow then
		local slow = world:get(enemyEntity, EnemySlow)
		if slow and typeof(slow) == "table" then
			local updated = table.clone(slow)
			if typeof(updated.startTime) == "number" then
				updated.startTime += frozenDuration
			end
			if typeof(updated.endTime) == "number" then
				updated.endTime += frozenDuration
			end
			DirtyService.setIfChanged(world, enemyEntity, EnemySlow, updated, "EnemySlow")
		end
	end

	if EnemyFrostbite then
		local frostbite = world:get(enemyEntity, EnemyFrostbite)
		if frostbite and typeof(frostbite) == "table" then
			local updated = table.clone(frostbite)
			if typeof(updated.startTime) == "number" then
				updated.startTime += frozenDuration
			end
			if typeof(updated.endTime) == "number" then
				updated.endTime += frozenDuration
			end
			DirtyService.setIfChanged(world, enemyEntity, EnemyFrostbite, updated, "EnemyFrostbite")
		end
	end

	if Knockback then
		local knockback = world:get(enemyEntity, Knockback)
		if knockback and typeof(knockback) == "table" and typeof(knockback.endTime) == "number" then
			local updated = table.clone(knockback)
			updated.endTime += frozenDuration
			DirtyService.setIfChanged(world, enemyEntity, Knockback, updated, "Knockback")
		end
	end
end

local function freezeEnemy(enemyEntity: number, now: number, sessionId: number)
	if frozenEnemyStateByEntity[enemyEntity] then
		return
	end
	frozenEnemyStateByEntity[enemyEntity] = {
		enteredAt = now,
		sessionId = sessionId,
	}
	if EnemyTimeStopped then
		DirtyService.setIfChanged(world, enemyEntity, EnemyTimeStopped, {
			sessionId = sessionId,
			startedAt = now,
			active = true,
		}, "EnemyTimeStopped")
	end
end

local function unfreezeEnemy(enemyEntity: number, now: number)
	local state = frozenEnemyStateByEntity[enemyEntity]
	local frozenDuration = 0
	if state then
		frozenDuration = math.max(now - state.enteredAt, 0)
		frozenEnemyStateByEntity[enemyEntity] = nil
	end
	if EnemyTimeStopped then
		DirtyService.setIfChanged(world, enemyEntity, EnemyTimeStopped, {
			sessionId = state and state.sessionId or nil,
			startedAt = state and state.enteredAt or nil,
			endedAt = now,
			active = false,
		}, "EnemyTimeStopped")
	end
	if frozenDuration > 0 then
		shiftEnemyTimedState(enemyEntity, frozenDuration)
	end
end

local function applyQueuedSideEffect(targetEntity: number, effect: any)
	if typeof(effect) ~= "table" then
		return
	end
	local kind = effect.kind
	if kind == "frostbite" then
		if DamageSystemRef and DamageSystemRef.applyEnemyFrostbite then
			DamageSystemRef.applyEnemyFrostbite(
				targetEntity,
				math.max(math.floor((effect.stacks or 0) + 0.0001), 0),
				math.max(effect.duration or 0, 0),
				math.max(effect.damageTakenPerStack or 0, 0),
				effect.statusId
			)
		end
	elseif kind == "slow" then
		EnemySlowSystem.applySlow(
			targetEntity,
			math.max(effect.duration or 0, 0),
			math.clamp(effect.multiplier or 1, 0, 1),
			effect.impaleModelPath
		)
	elseif kind == "knockback" then
		if DamageSystemRef and DamageSystemRef.applyKnockback and typeof(effect.direction) == "Vector3" then
			DamageSystemRef.applyKnockback(
				targetEntity,
				effect.direction,
				math.max(effect.distance or 0, 0),
				math.max(effect.duration or 0.2, 0.05),
				effect.stunned
			)
		end
	end
end

local function isEnemyAlive(enemyEntity: number): boolean
	if not world or not world:contains(enemyEntity) then
		return false
	end
	if DeathAnimation and world:has(enemyEntity, DeathAnimation) then
		return false
	end
	local health = Health and world:get(enemyEntity, Health)
	return health and health.current and health.current > 0 or false
end

local function inflateHalfExtents(halfExtents: Vector3, inflateAmount: number): Vector3
	if inflateAmount <= 0 then
		return halfExtents
	end
	return Vector3.new(
		halfExtents.X + inflateAmount,
		halfExtents.Y + inflateAmount,
		halfExtents.Z + inflateAmount
	)
end

local function segmentIntersectsOrientedBox(
	segmentStart: Vector3,
	segmentEnd: Vector3,
	boxCFrame: CFrame,
	halfExtents: Vector3,
	inflateAmount: number
): (boolean, number?)
	local expandedHalf = inflateHalfExtents(halfExtents, inflateAmount)
	local p0 = boxCFrame:PointToObjectSpace(segmentStart)
	local p1 = boxCFrame:PointToObjectSpace(segmentEnd)
	local dir = p1 - p0
	local tMin = 0
	local tMax = 1

	local function clipAxis(originValue: number, dirValue: number, minValue: number, maxValue: number): boolean
		if math.abs(dirValue) < 1e-6 then
			return originValue >= minValue and originValue <= maxValue
		end
		local invDir = 1 / dirValue
		local t1 = (minValue - originValue) * invDir
		local t2 = (maxValue - originValue) * invDir
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		tMin = math.max(tMin, t1)
		tMax = math.min(tMax, t2)
		return tMin <= tMax
	end

	if not clipAxis(p0.X, dir.X, -expandedHalf.X, expandedHalf.X) then
		return false, nil
	end
	if not clipAxis(p0.Y, dir.Y, -expandedHalf.Y, expandedHalf.Y) then
		return false, nil
	end
	if not clipAxis(p0.Z, dir.Z, -expandedHalf.Z, expandedHalf.Z) then
		return false, nil
	end

	local hitT = tMin >= 0 and tMin or tMax
	if hitT < 0 or hitT > 1 then
		return false, nil
	end
	return true, hitT
end

local function resolveDeferredHitscanTarget(origin: Vector3, segmentEnd: Vector3): number?
	if not world or not enemyQuery then
		return nil
	end

	local nearestT = math.huge
	local nearestEnemy: number? = nil
	for enemyEntity, entityType in enemyQuery do
		if entityType and entityType.type == "Enemy" and isEnemyAlive(enemyEntity) then
			local hitbox = EnemyColliderService.getWorldHitbox(enemyEntity)
			if hitbox and typeof(hitbox.boxCFrame) == "CFrame" and typeof(hitbox.halfExtents) == "Vector3" then
				local intersects, hitT = segmentIntersectsOrientedBox(
					origin,
					segmentEnd,
					hitbox.boxCFrame,
					hitbox.halfExtents,
					DEFERRED_HITSCAN_BOX_INFLATE
				)
				if intersects and typeof(hitT) == "number" and hitT < nearestT then
					nearestT = hitT
					nearestEnemy = enemyEntity
				end
			end
		end
	end
	return nearestEnemy
end

local function flushDeferredDamage()
	local session = activeSession
	if not session then
		return
	end
	if not DamageSystemRef then
		table.clear(session.deferredPackets)
		return
	end

	local orderedPackets: {DeferredSortPacket} = table.create(#session.deferredPackets)
	for i, packet in ipairs(session.deferredPackets) do
		orderedPackets[i] = {
			packet = packet,
			sourceEntity = packet.sourceEntity,
			abilityId = packet.abilityId,
			damageType = packet.damageType,
			timestamp = packet.timestamp,
			sequence = packet.sequence,
		}
	end
	table.sort(orderedPackets, function(a, b)
		if a.timestamp == b.timestamp then
			return a.sequence < b.sequence
		end
		return a.timestamp < b.timestamp
	end)

	for _, entry in ipairs(orderedPackets) do
		local packet = entry.packet
		local damageAmount = tonumber(packet.damageAmount) or 0
		if damageAmount > 0 then
			local targetEntity = packet.targetEntity
			local targetAlive = typeof(targetEntity) == "number" and isEnemyAlive(targetEntity)
			if (not targetAlive) and packet.replayHitscan == true
				and typeof(packet.replayOrigin) == "Vector3"
				and typeof(packet.replayEnd) == "Vector3" then
				targetEntity = resolveDeferredHitscanTarget(packet.replayOrigin, packet.replayEnd)
				targetAlive = typeof(targetEntity) == "number" and isEnemyAlive(targetEntity)
			end
			if targetAlive and typeof(targetEntity) == "number" then
				local _, applied = DamageSystemRef.applyDamage(
					targetEntity,
					damageAmount,
					packet.damageType or "magic",
					packet.sourceEntity,
					packet.abilityId,
					{
						skipTemporalStasis = true,
						procCoefficient = packet.procCoefficient,
					}
				)
				if applied then
					for _, effect in ipairs(packet.sideEffects) do
						applyQueuedSideEffect(targetEntity, effect)
					end
				end
			end
		end
	end
	table.clear(session.deferredPackets)
end

local function endSession(now: number)
	for enemyEntity in pairs(frozenEnemyStateByEntity) do
		if world:contains(enemyEntity) then
			unfreezeEnemy(enemyEntity, now)
		else
			frozenEnemyStateByEntity[enemyEntity] = nil
		end
	end

	-- Unfreeze first so pre-existing debuff timers are shifted once, then
	-- release deferred side effects at true resume time.
	flushDeferredDamage()

	activeSession = nil
	sendTimeStopState()
end

local function updateEnemyFreeze(now: number)
	local session = activeSession
	if not session then
		return
	end
	if not enemyQuery then
		return
	end

	local shouldBeFrozen: {[number]: boolean} = {}
	for enemyEntity, entityType, pos in enemyQuery do
		if entityType and entityType.type == "Enemy" then
			if DeathAnimation and world:has(enemyEntity, DeathAnimation) then
				continue
			end
			local point = Vector3.new(pos.x, pos.y, pos.z)
			if isPointFrozenAt(point, now) then
				shouldBeFrozen[enemyEntity] = true
			end
		end
	end

	for enemyEntity in pairs(shouldBeFrozen) do
		freezeEnemy(enemyEntity, now, session.sessionId)
	end

	for enemyEntity in pairs(frozenEnemyStateByEntity) do
		if not world:contains(enemyEntity) then
			frozenEnemyStateByEntity[enemyEntity] = nil
			continue
		end
		if not shouldBeFrozen[enemyEntity] then
			unfreezeEnemy(enemyEntity, now)
		end
	end
end

local function isPlayerSourceEntity(sourceEntity: number?): boolean
	if not sourceEntity or not world then
		return false
	end
	if EntityType then
		local sourceType = world:get(sourceEntity, EntityType)
		if sourceType and sourceType.type == "Player" then
			return true
		end
	end
	if PlayerStats then
		local sourceStats = world:get(sourceEntity, PlayerStats)
		if sourceStats and sourceStats.player ~= nil then
			return true
		end
	end
	return false
end

function TemporalStasisSystem.init(worldRef: any, components: any, dirtyService: any, services: any?)
	world = worldRef
	Components = components
	DirtyService = dirtyService

	EntityType = Components.EntityType
	Position = Components.Position
	Health = Components.Health
	PlayerStats = Components.PlayerStats
	Knockback = Components.Knockback
	DeathAnimation = Components.DeathAnimation
	EnemySlow = Components.EnemySlow
	EnemyFrostbite = Components.EnemyFrostbite
	EnemyTimeStopped = Components.EnemyTimeStopped

	DamageSystemRef = services and services.DamageSystem or DamageSystemRef

	enemyQuery = world:query(EntityType, Position):cached()

	local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	timeStopStateRemote = ensureRemoteEvent(remotesFolder, "TimeStopState")
	sendTimeStopState()
end

function TemporalStasisSystem.setDamageSystem(damageSystem: any)
	DamageSystemRef = damageSystem
end

function TemporalStasisSystem.isActive(): boolean
	return activeSession ~= nil
end

function TemporalStasisSystem.getActiveSessionId(): number?
	return activeSession and activeSession.sessionId or nil
end

function TemporalStasisSystem.isEnemyFrozen(enemyEntity: number): boolean
	if not activeSession then
		return false
	end
	if frozenEnemyStateByEntity[enemyEntity] ~= nil then
		return true
	end
	local state = EnemyTimeStopped and world:get(enemyEntity, EnemyTimeStopped)
	return state and state.active == true or false
end

function TemporalStasisSystem.isPointFrozen(point: Vector3): boolean
	return isPointFrozenAt(point, tick())
end

function TemporalStasisSystem.getFreezeEntryPoint(segmentStart: Vector3, segmentEnd: Vector3): (Vector3?, number?, number?)
	local session = activeSession
	if not session then
		return nil, nil, nil
	end
	local now = tick()
	if isPointFrozenAt(segmentStart, now) then
		return nil, nil, session.sessionId
	end
	local entryT = findEntryT(segmentStart, segmentEnd, now)
	if not entryT then
		return nil, nil, session.sessionId
	end
	local segment = segmentEnd - segmentStart
	return segmentStart + (segment * entryT), entryT, session.sessionId
end

function TemporalStasisSystem.clipHitscan(origin: Vector3, finalImpact: Vector3): any
	local session = activeSession
	if not session then
		return {
			active = false,
			sessionId = nil,
			holdImpactPosition = finalImpact,
			finalImpactPosition = finalImpact,
			holdT = 1,
			hasBoundaryHold = false,
			touchesFrozenVolume = false,
			targetInside = false,
			startInside = false,
		}
	end

	local now = tick()
	local segment, segLen = normalizeSegment(origin, finalImpact)
	local startInside = isPointFrozenAt(origin, now)
	local finalInside = isPointFrozenAt(finalImpact, now)

	if segLen <= 1e-6 then
		return {
			active = true,
			sessionId = session.sessionId,
			holdImpactPosition = finalImpact,
			finalImpactPosition = finalImpact,
			holdT = 1,
			hasBoundaryHold = false,
			touchesFrozenVolume = startInside or finalInside,
			targetInside = finalInside,
			startInside = startInside,
		}
	end

	local holdT = 1
	local hasBoundaryHold = false
	local intersections = collectSegmentIntersections(origin, finalImpact, now)
	local touchesFrozenVolume = startInside or finalInside or (#intersections > 0)
	if startInside then
		local exitT = findExitT(origin, finalImpact, now)
		if exitT and exitT >= 0 and exitT <= 1 then
			holdT = exitT
			hasBoundaryHold = holdT < 0.9999
		else
			holdT = 1
			hasBoundaryHold = false
		end
	else
		local entryT = findEntryT(origin, finalImpact, now)
		if entryT and entryT >= 0 and entryT <= 1 then
			holdT = entryT
			hasBoundaryHold = holdT < 0.9999
		end
	end

	local holdImpact = origin + (segment * holdT)
	return {
		active = true,
		sessionId = session.sessionId,
		holdImpactPosition = holdImpact,
		finalImpactPosition = finalImpact,
		holdT = holdT,
		hasBoundaryHold = hasBoundaryHold,
		touchesFrozenVolume = touchesFrozenVolume,
		targetInside = finalInside,
		startInside = startInside,
	}
end

function TemporalStasisSystem.beginField(
	casterEntity: number?,
	center: Vector3,
	radius: number,
	startTime: number,
	endTime: number
): number?
	if not world or typeof(center) ~= "Vector3" then
		return nil
	end
	local now = tick()
	local fieldStart = math.max(startTime or now, now)
	local fieldEnd = math.max(endTime or (fieldStart + 0.01), fieldStart + 0.01)
	local fieldRadius = math.max(radius or 0, 0.1)

	if not activeSession then
		sessionIdCounter += 1
		activeSession = {
			sessionId = sessionIdCounter,
			startTime = fieldStart,
			endTime = fieldEnd,
			fields = {},
			deferredPackets = {},
			deferSequence = 0,
		}
	end

	local session = activeSession :: ActiveSession
	table.insert(session.fields, {
		casterEntity = casterEntity,
		center = center,
		radius = fieldRadius,
		startTime = fieldStart,
		endTime = fieldEnd,
	})
	if fieldEnd > session.endTime then
		session.endTime = fieldEnd
	end

	sendTimeStopState()
	updateEnemyFreeze(now)
	return session.sessionId
end

function TemporalStasisSystem.shouldDeferDamage(targetEntity: number?, sourceEntity: number?): boolean
	if not activeSession then
		return false
	end
	if not targetEntity or not sourceEntity then
		return false
	end
	if not frozenEnemyStateByEntity[targetEntity] then
		return false
	end
	return isPlayerSourceEntity(sourceEntity)
end

function TemporalStasisSystem.deferDamagePacket(packet: any): boolean
	local session = activeSession
	if not session then
		return false
	end
	if typeof(packet) ~= "table" then
		return false
	end
	local damageAmount = tonumber(packet.damageAmount) or 0
	if damageAmount <= 0 then
		return false
	end
	local targetEntity = packet.targetEntity
	local forceDefer = packet.forceDefer == true
	if typeof(targetEntity) == "number" then
		if not world:contains(targetEntity) then
			return false
		end
		if (not forceDefer) and not frozenEnemyStateByEntity[targetEntity] then
			return false
		end
	elseif (not forceDefer) then
		return false
	end

	local sideEffects: {any} = {}
	if typeof(packet.sideEffects) == "table" then
		for _, effect in ipairs(packet.sideEffects) do
			table.insert(sideEffects, effect)
		end
	end
	local procCoefficient = if typeof(packet.procCoefficient) == "number" then packet.procCoefficient else nil
	session.deferSequence += 1
	table.insert(session.deferredPackets, {
		targetEntity = if typeof(targetEntity) == "number" then targetEntity else nil,
		sourceEntity = packet.sourceEntity,
		damageAmount = damageAmount,
		procCoefficient = procCoefficient,
		damageType = packet.damageType,
		abilityId = packet.abilityId,
		timestamp = tonumber(packet.timestamp) or tick(),
		sequence = session.deferSequence,
		sideEffects = sideEffects,
		replayHitscan = packet.replayHitscan == true,
		replayOrigin = if typeof(packet.replayOrigin) == "Vector3" then packet.replayOrigin else nil,
		replayEnd = if typeof(packet.replayEnd) == "Vector3" then packet.replayEnd else nil,
	})

	return true
end

function TemporalStasisSystem.submitEnemyHit(packet: any): (boolean, boolean, boolean)
	if typeof(packet) ~= "table" then
		return false, false, false
	end
	if not DamageSystemRef then
		return false, false, false
	end

	local targetEntity = packet.targetEntity
	local sourceEntity = packet.sourceEntity
	local damageAmount = tonumber(packet.damageAmount) or 0
	if typeof(targetEntity) ~= "number" or damageAmount <= 0 then
		return false, false, false
	end

	if TemporalStasisSystem.shouldDeferDamage(targetEntity, sourceEntity) then
		TemporalStasisSystem.deferDamagePacket(packet)
		return false, false, true
	end

	local died, applied = DamageSystemRef.applyDamage(
		targetEntity,
		damageAmount,
		packet.damageType or "magic",
		sourceEntity,
		packet.abilityId,
		{
			skipTemporalStasis = true,
			procCoefficient = if typeof(packet.procCoefficient) == "number" then packet.procCoefficient else nil,
		}
	)

	if applied and typeof(packet.sideEffects) == "table" then
		for _, effect in ipairs(packet.sideEffects) do
			applyQueuedSideEffect(targetEntity, effect)
		end
	end

	return died, applied, false
end

function TemporalStasisSystem.step(_dt: number)
	local session = activeSession
	if not session then
		return
	end

	local now = tick()
	local fields = session.fields
	local writeIndex = 1
	local latestEnd = 0

	for readIndex = 1, #fields do
		local field = fields[readIndex]
		if field and field.endTime > now then
			fields[writeIndex] = field
			writeIndex += 1
			if field.endTime > latestEnd then
				latestEnd = field.endTime
			end
		end
	end

	for i = writeIndex, #fields do
		fields[i] = nil
	end

	if #fields == 0 then
		endSession(now)
		return
	end

	session.endTime = latestEnd
	updateEnemyFreeze(now)
end

return TemporalStasisSystem
