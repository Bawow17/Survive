--!strict
-- ProjectileService - Server-authoritative projectile records (no ECS entities).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local OctreeSystem = require(game.ServerScriptService.ECS.Systems.OctreeSystem)
local DamageSystem = require(game.ServerScriptService.ECS.Systems.DamageSystem)
local EnemyColliderService = require(game.ServerScriptService.Services.EnemyColliderService)
local TargetingService = require(game.ServerScriptService.Abilities.TargetingService)
local EnemySlowSystem = require(game.ServerScriptService.ECS.Systems.EnemySlowSystem)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local FacingResolver = require(ReplicatedStorage.Shared.FacingResolver)

local ProfilingConfig = require(ReplicatedStorage.Shared.ProfilingConfig)
local Prof = ProfilingConfig.ENABLED and require(ReplicatedStorage.Shared.ProfilingServer) or require(ReplicatedStorage.Shared.ProfilingStub)
local PROFILING_ENABLED = ProfilingConfig.ENABLED

local function getSimTime(): number
	return tick()
end

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

local ProjectileService = {}

type HomingConfig = {
	strengthDeg: number,
	maxAngleDeg: number?,
	maxTurnDeg: number?,
	acquireRadius: number,
	targetEntity: number?,
	stayHorizontal: boolean?,
	alwaysStayHorizontal: boolean?,
}

type AoeConfig = {
	radius: number,
	damage: number,
	falloff: number?,
	trigger: string?,
	triggerOnExpire: boolean?,
	delay: number?,
	duration: number?,
	tickInterval: number?,
	modelPath: string?,
	scale: number?,
	knockbackDistance: number?,
	knockbackDuration: number?,
	knockbackStunned: boolean?,
	retargetPetalsOwner: number?,
}

type CollisionConfig = {
	useRaycast: boolean?,
}

type OrbitConfig = {
	ownerEntity: number,
	radius: number,
	speedDeg: number,
	angle: number,
}

type PetalConfig = {
	ownerEntity: number,
	maxRange: number,
	homingStrength: number?,
	homingMaxAngle: number?,
	stayHorizontal: boolean?,
	alwaysStayHorizontal: boolean?,
	targetEntity: number?,
	role: string?,
}

type BeamConfig = {
	length: number,
	size: Vector3?,
	offset: Vector3?,
	rotation: CFrame?,
	lengthAxis: string?,
}

type SplitConfig = {
	count: number,
	damageMultiplier: number,
	scaleMultiplier: number,
	maxSpreadDeg: number,
	targetingAngle: number?,
}

type SlowConfig = {
	duration: number,
	multiplier: number,
	impaleModelPath: string?,
}

type FrostbiteOnHit = {
	statusId: string?,
	stacks: number,
	duration: number,
	damageTakenPerStack: number,
}

type ProjectileRecord = {
	id: number,
	kind: string,
	origin: Vector3,
	direction: Vector3,
	speed: number,
	radius: number,
	damage: number,
	ownerEntity: number?,
	spawnTime: number,
	expiresAt: number,
	lifetime: number,
	lastSimTime: number,
	lastPos: Vector3,
	pierceRemaining: number,
	basePierce: number,
	hitSet: {[number]: boolean},
	hitCooldowns: {[number]: number},
	hitCooldown: number,
	homing: HomingConfig?,
	aoe: AoeConfig?,
	collision: CollisionConfig?,
	orbit: OrbitConfig?,
	petal: PetalConfig?,
	beam: BeamConfig?,
	splitOnHit: SplitConfig?,
	slowOnHit: SlowConfig?,
	frostbiteOnHit: FrostbiteOnHit?,
	recipients: {[Player]: boolean},
	visualScale: number?,
	visualColor: Color3?,
	modelPath: string?,
	nextSimTime: number?,
	ownerUserId: number?,
	stayHorizontal: boolean?,
	alwaysStayHorizontal: boolean?,
	stickToPlayer: boolean?,
	lastOwnerPos: Vector3?,
	stickOffset: Vector3?,
	isSplitChild: boolean?,
}

local world: any
local Components: any
local getPlayerFromEntity: ((number) -> Player?)?

local Position: any
local EntityType: any
local Collision: any
local Health: any
local PlayerStats: any
local DeathAnimation: any
local Velocity: any
local DesiredVelocity: any
local FacingDirection: any

local playerQuery: any

local projectileIdCounter = 0
local projectiles: {[number]: ProjectileRecord} = {}
local projectileList: {number} = {}
local projectileIndex: {[number]: number} = {}
local nextSimIndex = 1

local remotesFolder: Instance
local projectileRemotesFolder: Instance
local ProjectilesSpawnBatch: RemoteEvent
local ProjectilesDespawnBatch: RemoteEvent
local ProjectilesImpactBatch: RemoteEvent

local SIM_HZ = 15
local SIM_INTERVAL = 1 / SIM_HZ
local FAR_SIM_INTERVAL = 0.25
local PETAL_SIM_INTERVAL = 1 / 60
local RELEVANCE_RADIUS = 260
local SPAWN_SEND_RADIUS = 300
local MAX_PROJECTILES_SIMULATED_PER_TICK = 600
local MAX_COLLISION_CHECKS_PER_TICK = 4000
local MAX_HITS_PER_TICK = 600
local MAX_SPAWNS_PER_SECOND = 400
local RECIPIENT_REFRESH_INTERVAL = 0.5
local MAX_RECIPIENT_SPAWNS_PER_TICK = 200
local PETAL_MIN_SEPARATION = 30
local ENEMY_COLLISION_GRACE_RADIUS = 1.0
local ENEMY_CANDIDATE_BASE_BUFFER = 30.0
local ENEMY_CANDIDATE_HORIZONTAL_BUFFER = 18.0
local DIAGONAL_VERTICAL_DELTA_THRESHOLD = 0.25
local STAY_HORIZONTAL_TARGET_Y_DIFF = 10.0
local INVINCIBLE_ENEMY_DIAGNOSTICS = GameOptions.Debug and GameOptions.Debug.InvincibleEnemyDiagnostics or false
local INVINCIBLE_DIAG_SAMPLE_LIMIT = 20
local invincibleDiagCounters = {
	projectilesTotalSeen = 0,
	projectilesSpawned = 0,
	projectilesSimulated = 0,
	projectilesCollisionEnabled = 0,
	framesWithoutPlayers = 0,
	lastPlayerCount = 0,
	projectilesSkippedBySimBudget = 0,
	projectilesCollisionDisabledByRelevance = 0,
	projectilesCollisionDisabledNoPlayers = 0,
	projectilesSkippedByCollisionBudget = 0,
	projectilesSkippedByHitBudget = 0,
	projectileRaycastBlocked = 0,
	collisionChecks = 0,
	geometricHits = 0,
	nearMissUnder1Stud = 0,
	nearMissUnder3Stud = 0,
	damageCalls = 0,
	damageApplied = 0,
	damageRejectedAfterHit = 0,
}
local invincibleDiagSamples: {any} = {}
local invincibleDiagClosestMissGap = math.huge
local invincibleDiagClosestMissProjectileId = -1
local invincibleDiagClosestMissEnemyId = -1
local invincibleDiagClosestMissKind: string? = nil
local invincibleDiagClosestMissVerticalDelta = 0
local invincibleDiagClosestMissHorizontalDelta = 0

local RAYCAST_PARAMS = RaycastParams.new()
RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
RAYCAST_PARAMS.IgnoreWater = true

local WORLD_COLLISION_RAYCAST_PARAMS = RaycastParams.new()
WORLD_COLLISION_RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
WORLD_COLLISION_RAYCAST_PARAMS.IgnoreWater = true

local spawnCounts: {[Player]: {count: number, resetAt: number}} = setmetatable({}, { __mode = "k" })
local pendingSpawns: {[Player]: {any}} = {}
local pendingDespawns: {[Player]: {any}} = {}
local pendingImpacts: {[Player]: {any}} = {}
local petalRetargetRequests: {[number]: boolean} = {}
local activeExplosions: {{
	position: Vector3,
	radius: number,
	damage: number,
	endTime: number,
	nextTick: number,
	tickInterval: number,
	ownerEntity: number?,
	hitSet: {[number]: boolean},
	modelPath: string?,
	scale: number?,
	kind: string,
	knockbackDistance: number?,
	knockbackDuration: number?,
	knockbackStunned: boolean?,
	retargetOwnerEntity: number?,
	retargetTriggered: boolean?,
	sourceProjectileId: number?,
}} = {}
local lastRecipientRefresh = 0

local function resetInvincibleEnemyDiagnostics()
	for key in pairs(invincibleDiagCounters) do
		invincibleDiagCounters[key] = 0
	end
	table.clear(invincibleDiagSamples)
	invincibleDiagClosestMissGap = math.huge
	invincibleDiagClosestMissProjectileId = -1
	invincibleDiagClosestMissEnemyId = -1
	invincibleDiagClosestMissKind = nil
	invincibleDiagClosestMissVerticalDelta = 0
	invincibleDiagClosestMissHorizontalDelta = 0
end

local function getEnemyScaleForEntity(enemyId: number): number
	return EnemyColliderService.getEffectiveScale(enemyId)
end

local function getEnemyDebugMeta(enemyId: number): (number, string?, string?)
	local scale = getEnemyScaleForEntity(enemyId)
	local subtype = EnemyColliderService.getEnemySubtype(enemyId)
	local tier = EnemyColliderService.getEnemyTier(enemyId)
	return scale, subtype, tier
end

local function horizontalYawDegFromVector(vec: Vector3?): number?
	if typeof(vec) ~= "Vector3" then
		return nil
	end
	local horizontal = Vector3.new(vec.X, 0, vec.Z)
	if horizontal.Magnitude <= 1e-4 then
		return nil
	end
	return math.deg(math.atan2(horizontal.X, horizontal.Z))
end

local function horizontalYawDegFromCFrame(cf: CFrame?): number?
	if typeof(cf) ~= "CFrame" then
		return nil
	end
	return horizontalYawDegFromVector(cf.LookVector)
end

local function recordProjectileRejectionSample(
	projectileId: number?,
	enemyId: number?,
	kind: string?,
	enemyHealth: number?,
	hasDeathAnimation: boolean?,
	enemyScale: number?,
	enemySubtype: string?,
	enemyTier: string?,
	reason: string?,
	blocker: string?
)
	if not INVINCIBLE_ENEMY_DIAGNOSTICS then
		return
	end
	table.insert(invincibleDiagSamples, {
		t = tick(),
		projectileId = projectileId,
		enemyId = enemyId,
		kind = kind,
		reason = reason or "didNotApply",
		enemyHealth = enemyHealth,
		hasDeathAnimation = hasDeathAnimation == true,
		enemyScale = enemyScale,
		enemySubtype = enemySubtype,
		enemyTier = enemyTier,
		blocker = blocker,
	})
	if #invincibleDiagSamples > INVINCIBLE_DIAG_SAMPLE_LIMIT then
		table.remove(invincibleDiagSamples, 1)
	end
end

local function registerProjectile(id: number)
	projectileIndex[id] = #projectileList + 1
	projectileList[#projectileList + 1] = id
end

local function unregisterProjectile(id: number)
	local index = projectileIndex[id]
	if not index then
		return
	end
	local lastId = projectileList[#projectileList]
	projectileList[#projectileList] = nil
	projectileIndex[id] = nil
	if lastId and lastId ~= id then
		projectileList[index] = lastId
		projectileIndex[lastId] = index
	end
end

local function queueForPlayer(bucket: {[Player]: {any}}, player: Player, entry: any)
	local list = bucket[player]
	if not list then
		list = {}
		bucket[player] = list
	end
	table.insert(list, entry)
end

local function queueSpawnForPlayer(player: Player, record: ProjectileRecord)
	queueForPlayer(pendingSpawns, player, {
		id = record.id,
		kind = record.kind,
		origin = record.origin,
		dir = record.direction,
		speed = record.speed,
		spawnTime = tick(),
		lifetime = record.expiresAt - record.spawnTime,
		scale = record.visualScale,
		color = record.visualColor,
		modelPath = record.modelPath,
		ownerUserId = record.ownerUserId,
		stayHorizontal = record.stayHorizontal,
		alwaysStayHorizontal = record.alwaysStayHorizontal,
		stickToPlayer = record.stickToPlayer,
		orbit = record.orbit and {
			ownerUserId = record.ownerUserId,
			radius = record.orbit.radius,
			speedDeg = record.orbit.speedDeg,
			angle = record.orbit.angle,
		} or nil,
		homing = record.homing and {
			acquireRadius = record.homing.acquireRadius,
			strengthDeg = record.homing.strengthDeg,
			maxAngleDeg = record.homing.maxAngleDeg,
			maxTurnDeg = record.homing.maxTurnDeg,
			stayHorizontal = record.homing.stayHorizontal,
			alwaysStayHorizontal = record.homing.alwaysStayHorizontal,
		} or nil,
		petal = record.petal and {
			maxRange = record.petal.maxRange,
			ownerUserId = record.ownerUserId,
			homingStrength = record.petal.homingStrength,
			homingMaxAngle = record.petal.homingMaxAngle,
			stayHorizontal = record.petal.stayHorizontal,
			alwaysStayHorizontal = record.petal.alwaysStayHorizontal,
			role = record.petal.role,
		} or nil,
		beam = record.beam and {
			length = record.beam.length,
			size = record.beam.size,
			offset = record.beam.offset,
			rotation = record.beam.rotation,
			lengthAxis = record.beam.lengthAxis,
		} or nil,
		isSplitChild = record.isSplitChild == true,
	})
end

local function sendDespawn(record: ProjectileRecord, reason: string)
	for player in pairs(record.recipients) do
		if player and player.Parent == Players then
			queueForPlayer(pendingDespawns, player, { id = record.id, reason = reason })
		end
	end
end

local function sendImpact(record: ProjectileRecord, position: Vector3, reason: string, aoe: AoeConfig?, shouldDespawn: boolean?)
	for player in pairs(record.recipients) do
		if player and player.Parent == Players then
			queueForPlayer(pendingImpacts, player, {
				id = record.id,
				pos = position,
				ownerUserId = record.ownerUserId,
				reason = reason,
				despawn = shouldDespawn ~= false,
				aoe = aoe and {
					radius = aoe.radius,
				} or nil,
				effect = aoe and aoe.modelPath and {
					modelPath = aoe.modelPath,
					scale = aoe.scale,
					duration = aoe.duration,
					delay = aoe.delay,
				} or nil,
			})
		end
	end
end

local function distanceSq(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dy = a.Y - b.Y
	local dz = a.Z - b.Z
	return dx * dx + dy * dy + dz * dz
end

local function getEnemyAimPosition(enemyId: number): Vector3?
	local aimPoint = TargetingService.getEnemyAimPoint(enemyId)
	if aimPoint then
		return aimPoint
	end
	local pos = world and world:get(enemyId, Position)
	if pos then
		return Vector3.new(pos.x, pos.y, pos.z)
	end
	return nil
end

local PETAL_AIM_OFFSET_MAX = 30

local function getEnemyBasePosition(enemyId: number): Vector3?
	local pos = world and world:get(enemyId, Position)
	if pos then
		return Vector3.new(pos.x, pos.y, pos.z)
	end
	return nil
end

local function getPetalTargetPosition(enemyId: number): Vector3?
	local basePos = getEnemyBasePosition(enemyId)
	local aimPoint = TargetingService.getEnemyAimPoint(enemyId)
	if not aimPoint then
		return basePos
	end
	if basePos then
		local offset = aimPoint - basePos
		if offset.Magnitude > PETAL_AIM_OFFSET_MAX then
			return basePos
		end
	end
	return aimPoint
end

local function getOwnerPosition(record: ProjectileRecord): Vector3?
	local ownerEntity = record.petal and record.petal.ownerEntity or record.ownerEntity
	if not ownerEntity then
		return nil
	end
	local ownerPlayer = getPlayerFromEntity and getPlayerFromEntity(ownerEntity) or nil
	if ownerPlayer and ownerPlayer.Character then
		local hrp = ownerPlayer.Character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			return (hrp :: BasePart).Position
		end
	end
	local pos = world and world:get(ownerEntity, Position)
	if pos then
		return Vector3.new(pos.x, pos.y, pos.z)
	end
	return nil
end

local function buildPetalAssignments(): {[number]: {closest: number?, toughest: number?}}
	local ownerEntries: {[number]: {pos: Vector3, range: number}} = {}
	for _, id in ipairs(projectileList) do
		local record = projectiles[id]
		if record and record.petal and record.petal.ownerEntity then
			local ownerEntity = record.petal.ownerEntity
			local entry = ownerEntries[ownerEntity]
			if not entry then
				local ownerPos = getOwnerPosition(record)
				if ownerPos then
					ownerEntries[ownerEntity] = {
						pos = ownerPos,
						range = record.petal.maxRange or 0,
					}
				elseif record.lastPos then
					ownerEntries[ownerEntity] = {
						pos = record.lastPos,
						range = record.petal.maxRange or 0,
					}
				end
			else
				local range = record.petal.maxRange or 0
				if range > entry.range then
					entry.range = range
				end
			end
		end
	end

local assignments: {[number]: {closest: number?, toughest: number?}} = {}
	for ownerEntity, entry in pairs(ownerEntries) do
		local candidates = OctreeSystem.getEnemiesInRadius(entry.pos, entry.range)
		local closestId: number? = nil
		local closestDistSq = entry.range * entry.range
		local closestPos: Vector3? = nil
		local candidateList = {}

		for _, enemyId in ipairs(candidates) do
			local health = world:get(enemyId, Health)
			if health and health.current and health.current > 0 then
				local enemyPos = getPetalTargetPosition(enemyId)
				if enemyPos then
					local distSq = distanceSq(entry.pos, enemyPos)
					if distSq <= entry.range * entry.range then
						table.insert(candidateList, {
							id = enemyId,
							pos = enemyPos,
							distSq = distSq,
							hp = typeof(health.max) == "number" and health.max or health.current or 0,
						})
						if distSq < closestDistSq then
							closestDistSq = distSq
							closestId = enemyId
							closestPos = enemyPos
						end
					end
				end
			end
		end

		local toughestId = closestId
		if closestId and #candidateList > 1 and closestPos then
			local minSepSq = PETAL_MIN_SEPARATION * PETAL_MIN_SEPARATION
			local bestOtherId: number? = nil
			local bestOtherHp = -math.huge
			local bestOtherDistSq = math.huge
			local bestSepId: number? = nil
			local bestSepHp = -math.huge
			local bestSepDistSq = math.huge

			for _, entryCandidate in ipairs(candidateList) do
				if entryCandidate.id ~= closestId then
					if entryCandidate.hp > bestOtherHp or (entryCandidate.hp == bestOtherHp and entryCandidate.distSq < bestOtherDistSq) then
						bestOtherHp = entryCandidate.hp
						bestOtherDistSq = entryCandidate.distSq
						bestOtherId = entryCandidate.id
					end
					local sepSq = distanceSq(closestPos, entryCandidate.pos)
					if sepSq >= minSepSq then
						if entryCandidate.hp > bestSepHp or (entryCandidate.hp == bestSepHp and entryCandidate.distSq < bestSepDistSq) then
							bestSepHp = entryCandidate.hp
							bestSepDistSq = entryCandidate.distSq
							bestSepId = entryCandidate.id
						end
					end
				end
			end

			-- Prefer highest total HP that also satisfies min separation; otherwise highest HP among other targets.
			toughestId = bestSepId or bestOtherId or closestId
		end

		assignments[ownerEntity] = {
			closest = closestId,
			toughest = toughestId or closestId,
		}
	end

	return assignments
end

local function getEnemyCollisionCenter(enemyId: number): (Vector3?, number?, Vector3?, CFrame?, Vector3?)
	local hitbox = EnemyColliderService.getWorldHitbox(enemyId)
	if not hitbox then
		return nil, nil, nil, nil, nil
	end
	return hitbox.center, hitbox.radius, hitbox.basePos, hitbox.boxCFrame, hitbox.halfExtents
end

local function closestPointOnSegment(a: Vector3, b: Vector3, p: Vector3): Vector3
	local ab = b - a
	local t = 0
	local denom = ab:Dot(ab)
	if denom > 0 then
		t = (p - a):Dot(ab) / denom
		t = math.clamp(t, 0, 1)
	end
	return a + ab * t
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

local function pointToOrientedBoxDistance(point: Vector3, boxCFrame: CFrame, halfExtents: Vector3): (number, Vector3, Vector3)
	local localPoint = boxCFrame:PointToObjectSpace(point)
	local clamped = Vector3.new(
		math.clamp(localPoint.X, -halfExtents.X, halfExtents.X),
		math.clamp(localPoint.Y, -halfExtents.Y, halfExtents.Y),
		math.clamp(localPoint.Z, -halfExtents.Z, halfExtents.Z)
	)
	local deltaLocal = localPoint - clamped
	local deltaWorld = boxCFrame:VectorToWorldSpace(deltaLocal)
	local closestPoint = boxCFrame:PointToWorldSpace(clamped)
	return deltaWorld:Dot(deltaWorld), closestPoint, deltaWorld
end

local function segmentIntersectsOrientedBox(
	segmentStart: Vector3,
	segmentEnd: Vector3,
	boxCFrame: CFrame,
	halfExtents: Vector3,
	inflateAmount: number
): (boolean, Vector3?)
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

	local hitLocal = p0 + dir * math.clamp(tMin, 0, 1)
	return true, boxCFrame:PointToWorldSpace(hitLocal)
end

local function cloneHomingConfig(homing: HomingConfig?): HomingConfig?
	if not homing then
		return nil
	end
	return {
		strengthDeg = homing.strengthDeg,
		maxAngleDeg = homing.maxAngleDeg,
		maxTurnDeg = homing.maxTurnDeg,
		acquireRadius = homing.acquireRadius,
		stayHorizontal = homing.stayHorizontal,
		alwaysStayHorizontal = homing.alwaysStayHorizontal,
		targetEntity = nil,
	}
end

local function buildSpreadOffsets(count: number): {number}
	local offsets = table.create(count)
	if count == 1 then
		offsets[1] = 0
	elseif count % 2 == 1 then
		local midpoint = (count - 1) * 0.5
		for i = 1, count do
			offsets[i] = (i - 1) - midpoint
		end
	else
		local middleIndex = math.ceil(count / 2)
		offsets[middleIndex] = 0
		local stepIndex = 1
		for i = 1, count do
			if i ~= middleIndex then
				local sign = (stepIndex % 2 == 1) and 1 or -1
				local magnitude = math.floor((stepIndex + 1) / 2)
				offsets[i] = sign * magnitude
				stepIndex += 1
			end
		end
	end
	return offsets
end

local function spawnSplitProjectiles(record: ProjectileRecord, hitPos: Vector3, now: number, excludedTargetEntity: number?)
	if not record.splitOnHit then
		return
	end
	local split = record.splitOnHit
	local count = split.count or 0
	if count <= 0 then
		return
	end
	local baseDirection = record.direction.Magnitude > 0 and record.direction.Unit or Vector3.new(0, 0, 1)
	local totalSpread = math.min(math.abs(split.targetingAngle or 0) * 2, math.rad(split.maxSpreadDeg or 180))
	local step = count > 1 and totalSpread / (count - 1) or 0
	local offsets = buildSpreadOffsets(count)
	local lifetime = record.lifetime or math.max(record.expiresAt - now, 0.05)
	local splitScale = split.scaleMultiplier or 1
	local splitDamage = record.damage * (split.damageMultiplier or 1)
	local splitRadius = record.radius * splitScale
	local splitScaleVisual = (record.visualScale or 1) * splitScale
	local basePierce = record.basePierce or 0
	local homingCopy = cloneHomingConfig(record.homing)

	for i = 1, count do
		local offsetIndex = offsets[i] or 0
		local finalAngle = offsetIndex * step
		local cos = math.cos(finalAngle)
		local sin = math.sin(finalAngle)
		local direction = Vector3.new(
			baseDirection.X * cos - baseDirection.Z * sin,
			baseDirection.Y,
			baseDirection.X * sin + baseDirection.Z * cos
		)
		if direction.Magnitude == 0 then
			direction = Vector3.new(0, 0, 1)
		end
		direction = direction.Unit

		local splitProjectileId = ProjectileService.spawnProjectile({
			kind = record.kind,
			origin = hitPos,
			direction = direction,
			speed = record.speed,
			damage = splitDamage,
			radius = splitRadius,
			lifetime = lifetime,
			ownerEntity = record.ownerEntity,
			pierce = basePierce,
			modelPath = record.modelPath,
			visualScale = splitScaleVisual,
			visualColor = record.visualColor,
			homing = homingCopy,
			hitCooldown = record.hitCooldown,
			stayHorizontal = record.stayHorizontal,
			alwaysStayHorizontal = record.alwaysStayHorizontal,
			stickToPlayer = record.stickToPlayer,
			isSplitChild = true,
		})

		if splitProjectileId and excludedTargetEntity then
			local splitRecord = projectiles[splitProjectileId]
			if splitRecord then
				splitRecord.hitSet[excludedTargetEntity] = true
				splitRecord.hitCooldowns[excludedTargetEntity] = now + math.max(record.hitCooldown or 0.04, 0.04)
			end
		end
	end
end

local function tryAcquireTarget(record: ProjectileRecord, radius: number): number?
	local origin = record.lastPos
	local candidates = OctreeSystem.getEnemiesInRadius(origin, radius)
	local closest = nil
	local closestDistSq = radius * radius
	local currentDir = record.direction
	local homing = record.homing
	local maxAngleRad = homing and homing.maxAngleDeg and math.rad(homing.maxAngleDeg) or math.huge
	for _, enemyId in ipairs(candidates) do
		if record.ownerEntity and enemyId == record.ownerEntity then
			continue
		end
		if record.hitSet[enemyId] then
			continue
		end
		local health = world:get(enemyId, Health)
		if health and health.current and health.current <= 0 then
			continue
		end
		local enemyPos = getEnemyAimPosition(enemyId)
		if enemyPos then
			local distSq = distanceSq(origin, enemyPos)
			if distSq <= closestDistSq then
				if maxAngleRad < math.pi then
					local toEnemy = enemyPos - origin
					if toEnemy.Magnitude == 0 then
						continue
					end
					local angle = math.acos(math.clamp(currentDir:Dot(toEnemy.Unit), -1, 1))
					if angle > maxAngleRad then
						continue
					end
				end
				closestDistSq = distSq
				closest = enemyId
			end
		end
	end
	return closest
end

local function updateHoming(record: ProjectileRecord, now: number)
	if not record.homing then
		return
	end
	local homing = record.homing
	local targetEntity = homing.targetEntity

	if targetEntity and record.hitSet[targetEntity] then
		targetEntity = nil
	end

	if not targetEntity or not world:contains(targetEntity) then
		targetEntity = tryAcquireTarget(record, homing.acquireRadius)
		homing.targetEntity = targetEntity
	end

	if not targetEntity then
		return
	end

	local targetPos = getEnemyAimPosition(targetEntity)
	if not targetPos then
		return
	end

	local desired = targetPos - record.lastPos
	if homing.alwaysStayHorizontal then
		desired = Vector3.new(desired.X, 0, desired.Z)
	elseif homing.stayHorizontal then
		local yDiff = math.abs(targetPos.Y - record.lastPos.Y)
		if yDiff <= STAY_HORIZONTAL_TARGET_Y_DIFF then
			desired = Vector3.new(desired.X, 0, desired.Z)
		end
	end
	if desired.Magnitude == 0 then
		return
	end

	desired = desired.Unit
	local current = record.direction
	local dot = math.clamp(current:Dot(desired), -1, 1)
	local angle = math.acos(dot)
	if homing.maxAngleDeg and angle > math.rad(homing.maxAngleDeg) then
		homing.targetEntity = nil
		return
	end
	if angle <= 0.0001 then
		record.direction = desired
		return
	end

	local maxTurn = homing.maxTurnDeg and math.rad(homing.maxTurnDeg) or math.huge
	local maxStep = math.rad(homing.strengthDeg) * (now - record.lastSimTime)
	local turn = math.min(angle, maxTurn, maxStep)
	local axis = current:Cross(desired)
	if axis.Magnitude <= 0.0001 then
		record.direction = desired
		return
	end
	axis = axis.Unit
	local rotation = CFrame.fromAxisAngle(axis, turn)
	record.direction = rotation:VectorToWorldSpace(current).Unit
end

local function shouldSimulateCollision(record: ProjectileRecord, playerPositions: {{entity: number, position: Vector3}}): (boolean, number)
	local nearestDistSq = math.huge
	for _, entry in ipairs(playerPositions) do
		local distSq = distanceSq(record.lastPos, entry.position)
		if distSq < nearestDistSq then
			nearestDistSq = distSq
		end
	end
	local relevanceSq = RELEVANCE_RADIUS * RELEVANCE_RADIUS
	return nearestDistSq <= relevanceSq, nearestDistSq
end

local function passesRaycastCheck(startPos: Vector3, endPos: Vector3): (boolean, string?)
	local dir = endPos - startPos
	local result = Workspace:Raycast(startPos, dir, RAYCAST_PARAMS)
	if result == nil then
		return true, nil
	end
	local blocker = result.Instance and result.Instance:GetFullName() or "unknown"
	return false, blocker
end

local function getWorldCollisionHit(record: ProjectileRecord, startPos: Vector3, endPos: Vector3): RaycastResult?
	local dir = endPos - startPos
	if dir.Magnitude <= 1e-4 then
		return nil
	end

	local filters = table.create(10)
	local enemiesFolder = Workspace:FindFirstChild("Enemies")
	if enemiesFolder then
		filters[#filters + 1] = enemiesFolder
	end
	local projectilesFolder = Workspace:FindFirstChild("Projectiles")
	if projectilesFolder then
		filters[#filters + 1] = projectilesFolder
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			filters[#filters + 1] = player.Character
		end
	end

	WORLD_COLLISION_RAYCAST_PARAMS.FilterDescendantsInstances = filters
	return Workspace:Raycast(startPos, dir, WORLD_COLLISION_RAYCAST_PARAMS)
end

local function gatherEnemyCollisionCandidates(center: Vector3, radius: number, includeHorizontalFallback: boolean?): {number}
	local searchRadius = radius + ENEMY_CANDIDATE_BASE_BUFFER
	local candidates = OctreeSystem.getEnemiesInRadius(center, searchRadius)
	local dedup: {[number]: boolean} = {}
	local merged = table.create(#candidates)
	for _, enemyId in ipairs(candidates) do
		if not dedup[enemyId] then
			dedup[enemyId] = true
			merged[#merged + 1] = enemyId
		end
	end

	-- For diagonal travel, supplement octree with a horizontal-distance pass so
	-- tall enemies are still considered when their base position is far below
	-- the projectile segment.
	if includeHorizontalFallback then
		local horizontalRadius = radius + ENEMY_CANDIDATE_HORIZONTAL_BUFFER
		local horizontalRadiusSq = horizontalRadius * horizontalRadius
		for enemyId, entityType, pos in world:query(EntityType, Position) do
			if entityType and entityType.type == "Enemy" and not dedup[enemyId] then
				local dx = pos.x - center.X
				local dz = pos.z - center.Z
				if (dx * dx + dz * dz) <= horizontalRadiusSq then
					dedup[enemyId] = true
					merged[#merged + 1] = enemyId
				end
			end
		end
	end

	if #merged > 0 then
		return merged
	end

	-- Last-resort fallback scan when octree misses due update delay/base-vs-hitbox offset.
	if not world or not EntityType or not Position then
		return merged
	end
	local fallback = {}
	local searchSq = searchRadius * searchRadius
	for enemyId, entityType, pos in world:query(EntityType, Position) do
		if entityType and entityType.type == "Enemy" then
			local enemyPos = Vector3.new(pos.x, pos.y, pos.z)
			if distanceSq(center, enemyPos) <= searchSq then
				fallback[#fallback + 1] = enemyId
			end
		end
	end
	return fallback
end

function ProjectileService.init(worldRef: any, components: any, getPlayerFromEntityFn: (number) -> Player?)
	world = worldRef
	Components = components
	getPlayerFromEntity = getPlayerFromEntityFn

	Position = Components.Position
	EntityType = Components.EntityType
	Collision = Components.Collision
	Health = Components.Health
	PlayerStats = Components.PlayerStats
	DeathAnimation = Components.DeathAnimation
	Velocity = Components.Velocity
	DesiredVelocity = Components.DesiredVelocity
	FacingDirection = Components.FacingDirection

	playerQuery = world:query(Components.Position, Components.PlayerStats):cached()

	remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	projectileRemotesFolder = remotesFolder:FindFirstChild("Projectiles") or Instance.new("Folder")
	projectileRemotesFolder.Name = "Projectiles"
	projectileRemotesFolder.Parent = remotesFolder

	ProjectilesSpawnBatch = projectileRemotesFolder:FindFirstChild("ProjectilesSpawnBatch") :: RemoteEvent
	if not ProjectilesSpawnBatch then
		ProjectilesSpawnBatch = Instance.new("RemoteEvent")
		ProjectilesSpawnBatch.Name = "ProjectilesSpawnBatch"
		ProjectilesSpawnBatch.Parent = projectileRemotesFolder
	end

	ProjectilesDespawnBatch = projectileRemotesFolder:FindFirstChild("ProjectilesDespawnBatch") :: RemoteEvent
	if not ProjectilesDespawnBatch then
		ProjectilesDespawnBatch = Instance.new("RemoteEvent")
		ProjectilesDespawnBatch.Name = "ProjectilesDespawnBatch"
		ProjectilesDespawnBatch.Parent = projectileRemotesFolder
	end

	ProjectilesImpactBatch = projectileRemotesFolder:FindFirstChild("ProjectilesImpactBatch") :: RemoteEvent
	if not ProjectilesImpactBatch then
		ProjectilesImpactBatch = Instance.new("RemoteEvent")
		ProjectilesImpactBatch.Name = "ProjectilesImpactBatch"
		ProjectilesImpactBatch.Parent = projectileRemotesFolder
	end

	Players.PlayerAdded:Connect(function(player: Player)
		if #projectileList == 0 then
			return
		end
		for _, id in ipairs(projectileList) do
			local record = projectiles[id]
			if record and not record.recipients[player] then
				if record.ownerUserId and record.ownerUserId ~= player.UserId then
					-- still allow visibility for other players if within range
				end
				local ownerPosComp = record.ownerEntity and world:get(record.ownerEntity, Position)
				local samplePos = ownerPosComp and Vector3.new(ownerPosComp.x, ownerPosComp.y, ownerPosComp.z) or record.lastPos
				local playerCharacter = player.Character
				local playerPos = samplePos
				if playerCharacter then
					local hrp = playerCharacter:FindFirstChild("HumanoidRootPart")
					if hrp and hrp:IsA("BasePart") then
						playerPos = (hrp :: BasePart).Position
					end
				end
				if distanceSq(playerPos, record.lastPos) <= SPAWN_SEND_RADIUS * SPAWN_SEND_RADIUS then
					record.recipients[player] = true
					queueSpawnForPlayer(player, record)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		pendingSpawns[player] = nil
		pendingDespawns[player] = nil
		pendingImpacts[player] = nil
		spawnCounts[player] = nil
	end)
end

function ProjectileService.spawnProjectile(payload: {
	kind: string,
	origin: Vector3,
	direction: Vector3,
	speed: number,
	damage: number,
	radius: number?,
	lifetime: number,
	ownerEntity: number?,
	pierce: number?,
	modelPath: string?,
	visualScale: number?,
	visualColor: Color3?,
	homing: HomingConfig?,
	aoe: AoeConfig?,
	collision: CollisionConfig?,
	orbit: OrbitConfig?,
	hitCooldown: number?,
	stayHorizontal: boolean?,
	alwaysStayHorizontal: boolean?,
	stickToPlayer: boolean?,
	petal: PetalConfig?,
	beam: BeamConfig?,
	splitOnHit: SplitConfig?,
	slowOnHit: SlowConfig?,
	frostbiteOnHit: FrostbiteOnHit?,
	isSplitChild: boolean?,
}): number?
	if not payload or typeof(payload.origin) ~= "Vector3" then
		return nil
	end

	local ownerPlayer = payload.ownerEntity and getPlayerFromEntity and getPlayerFromEntity(payload.ownerEntity) or nil
	if ownerPlayer then
		local entry = spawnCounts[ownerPlayer]
		local now = getSimTime()
		if not entry or now >= entry.resetAt then
			entry = { count = 0, resetAt = now + 1 }
			spawnCounts[ownerPlayer] = entry
		end
		entry.count += 1
		if entry.count > MAX_SPAWNS_PER_SECOND then
			profInc("ProjectileService.SpawnRateLimited", 1)
			return nil
		end
	end

	projectileIdCounter += 1
	local id = projectileIdCounter
	local now = getSimTime()
	local lifetime = math.max(payload.lifetime, 0.05)
	local direction = payload.direction.Magnitude > 0 and payload.direction.Unit or Vector3.new(0, 0, 1)
	if payload.alwaysStayHorizontal then
		direction = Vector3.new(direction.X, 0, direction.Z)
		if direction.Magnitude > 0 then
			direction = direction.Unit
		else
			direction = Vector3.new(0, 0, 1)
		end
	end
	-- Only Refractions should spawn beam projectiles. If any other ability
	-- accidentally passes beam data, strip it to prevent infinite pierce.
	if payload.beam and payload.kind ~= "Refractions" then
		payload.beam = nil
	end

	local basePierce = math.max(math.floor(payload.pierce or 0), 0)
	local record: ProjectileRecord = {
		id = id,
		kind = payload.kind,
		origin = payload.origin,
		direction = direction,
		speed = payload.speed,
		radius = payload.radius or 1.0,
		damage = payload.damage,
		ownerEntity = payload.ownerEntity,
		spawnTime = now,
		expiresAt = now + lifetime,
		lifetime = lifetime,
		lastSimTime = now,
		lastPos = payload.origin,
		pierceRemaining = basePierce + 1,
		basePierce = basePierce,
		hitCount = 0,
		hitSet = {},
		hitCooldowns = {},
		hitCooldown = payload.hitCooldown or 0.04,
		homing = payload.homing,
		aoe = payload.aoe,
		collision = payload.collision,
		orbit = payload.orbit,
		petal = payload.petal,
		beam = payload.beam,
		splitOnHit = payload.splitOnHit,
		slowOnHit = payload.slowOnHit,
		frostbiteOnHit = payload.frostbiteOnHit,
		recipients = {},
		visualScale = payload.visualScale,
		visualColor = payload.visualColor,
		modelPath = payload.modelPath,
		nextSimTime = now,
		ownerUserId = ownerPlayer and ownerPlayer.UserId or nil,
		stayHorizontal = payload.stayHorizontal,
		alwaysStayHorizontal = payload.alwaysStayHorizontal,
		stickToPlayer = payload.stickToPlayer,
		lastOwnerPos = nil,
		stickOffset = nil,
		isSplitChild = payload.isSplitChild == true,
	}

	if record.homing then
		record.homing.targetEntity = nil
	end
	if record.orbit then
		record.orbit.angle = record.orbit.angle or 0
	end
	if record.stickToPlayer and record.ownerEntity then
		local ownerPos = getOwnerPosition(record)
		if ownerPos then
			record.lastOwnerPos = ownerPos
			record.stickOffset = record.origin - ownerPos
		end
	end

	projectiles[id] = record
	registerProjectile(id)
	if INVINCIBLE_ENEMY_DIAGNOSTICS then
		invincibleDiagCounters.projectilesSpawned += 1
	end

	for playerEntity, pos, playerStats in playerQuery do
		if playerStats and playerStats.player and playerStats.player.Parent then
			local playerPos = Vector3.new(pos.x, pos.y, pos.z)
			if distanceSq(playerPos, record.origin) <= SPAWN_SEND_RADIUS * SPAWN_SEND_RADIUS then
				record.recipients[playerStats.player] = true
				queueSpawnForPlayer(playerStats.player, record)
			end
		end
	end

	profInc("ProjectileService.Spawned", 1)
	return id
end

local function startExplosion(record: ProjectileRecord, center: Vector3, reason: string, despawnOnImpact: boolean?)
	if not record.aoe then
		return
	end
	local aoe = record.aoe
	local duration = aoe.duration or 0.5
	local now = getSimTime()

	activeExplosions[#activeExplosions + 1] = {
		position = center,
		radius = aoe.radius,
		damage = aoe.damage,
		endTime = now + duration,
		nextTick = now,
		tickInterval = aoe.tickInterval or 0,
		ownerEntity = record.ownerEntity,
		hitSet = {},
		modelPath = aoe.modelPath,
		scale = aoe.scale,
		kind = record.kind,
		knockbackDistance = aoe.knockbackDistance,
		knockbackDuration = aoe.knockbackDuration,
		knockbackStunned = aoe.knockbackStunned,
		retargetOwnerEntity = aoe.retargetPetalsOwner,
		retargetTriggered = false,
		sourceProjectileId = record.id,
	}

	sendImpact(record, center, reason, aoe, despawnOnImpact)
end

local function processExplosions(now: number, hitBudget: number): number
	if #activeExplosions == 0 then
		return hitBudget
	end

	local index = 1
	while index <= #activeExplosions do
		local explosion = activeExplosions[index]
		if now >= explosion.endTime then
			activeExplosions[index] = activeExplosions[#activeExplosions]
			activeExplosions[#activeExplosions] = nil
		elseif now >= explosion.nextTick then
			local hitAny = false
			local radius = explosion.radius
			local candidates = gatherEnemyCollisionCandidates(explosion.position, radius)
			for _, enemyId in ipairs(candidates) do
				if hitBudget <= 0 then
					if INVINCIBLE_ENEMY_DIAGNOSTICS then
						invincibleDiagCounters.projectilesSkippedByHitBudget += 1
					end
					break
				end
				if INVINCIBLE_ENEMY_DIAGNOSTICS then
					invincibleDiagCounters.collisionChecks += 1
				end
				if not explosion.hitSet[enemyId] then
					local health = world:get(enemyId, Health)
					local enemyPos, enemyRadiusOverride, _, enemyBoxCFrame, enemyHalfExtents = getEnemyCollisionCenter(enemyId)
					if enemyPos and health and health.current and health.current > 0 then
						local enemyRadius = enemyRadiusOverride or 2.5
						local testPos = enemyPos
						local hitThis = false
						if enemyBoxCFrame and enemyHalfExtents then
							local distSq, closestPoint = pointToOrientedBoxDistance(explosion.position, enemyBoxCFrame, enemyHalfExtents)
							if distSq <= (radius + ENEMY_COLLISION_GRACE_RADIUS) * (radius + ENEMY_COLLISION_GRACE_RADIUS) then
								hitThis = true
								testPos = closestPoint
							end
						else
							hitThis = (testPos - explosion.position).Magnitude <= (radius + enemyRadius + ENEMY_COLLISION_GRACE_RADIUS)
						end
						if hitThis then
							if INVINCIBLE_ENEMY_DIAGNOSTICS then
								invincibleDiagCounters.geometricHits += 1
							end
							hitAny = true
							explosion.hitSet[enemyId] = true
							hitBudget -= 1
							if INVINCIBLE_ENEMY_DIAGNOSTICS then
								invincibleDiagCounters.damageCalls += 1
							end
							local enemyHealthAtHit = health.current
							local _, didApply = DamageSystem.applyDamage(enemyId, explosion.damage, "magic", explosion.ownerEntity, explosion.kind)
							if INVINCIBLE_ENEMY_DIAGNOSTICS then
								if didApply then
									invincibleDiagCounters.damageApplied += 1
								else
									invincibleDiagCounters.damageRejectedAfterHit += 1
									local enemyScale, enemySubtype, enemyTier = getEnemyDebugMeta(enemyId)
									recordProjectileRejectionSample(
										explosion.sourceProjectileId,
										enemyId,
										explosion.kind,
										enemyHealthAtHit,
										world:has(enemyId, DeathAnimation),
										enemyScale,
										enemySubtype,
										enemyTier,
										"didNotApply",
										nil
									)
								end
							end

							if explosion.knockbackDistance and explosion.knockbackDistance > 0 then
								local dir = testPos - explosion.position
								dir = Vector3.new(dir.X, 0, dir.Z)
								if dir.Magnitude > 0.01 then
									DamageSystem.applyKnockback(
										enemyId,
										dir,
										explosion.knockbackDistance,
										explosion.knockbackDuration or 0.25,
										explosion.knockbackStunned
									)
								end
							end
						end
					end
				end
			end

			if hitAny and explosion.retargetOwnerEntity and not explosion.retargetTriggered then
				petalRetargetRequests[explosion.retargetOwnerEntity] = true
				explosion.retargetTriggered = true
			end

			if explosion.tickInterval > 0 then
				explosion.nextTick = now + explosion.tickInterval
			else
				explosion.nextTick = now + SIM_INTERVAL
			end
			index += 1
		else
			index += 1
		end
	end

	return hitBudget
end

local function despawnProjectile(record: ProjectileRecord, reason: string, impactPos: Vector3?)
	projectiles[record.id] = nil
	unregisterProjectile(record.id)
	sendDespawn(record, reason)
	if impactPos then
		sendImpact(record, impactPos, reason, record.aoe)
	end
	profInc("ProjectileService.Despawned", 1)
end

function ProjectileService.despawnOwnedProjectiles(ownerEntity: number)
	if not ownerEntity then
		return
	end

	local removedIds: {[number]: boolean} = {}
	local ids = table.clone(projectileList)
	for _, id in ipairs(ids) do
		local record = projectiles[id]
		if record then
			local petalOwner = record.petal and record.petal.ownerEntity or nil
			local orbitOwner = record.orbit and record.orbit.ownerEntity or nil
			if record.ownerEntity == ownerEntity or petalOwner == ownerEntity or orbitOwner == ownerEntity then
				removedIds[record.id] = true
				despawnProjectile(record, "owner_died", nil)
			end
		end
	end

	-- Remove any pending spawns for removed projectiles
	for player, payloads in pairs(pendingSpawns) do
		local write = 1
		for read = 1, #payloads do
			local entry = payloads[read]
			if entry and not removedIds[entry.id] then
				payloads[write] = entry
				write += 1
			end
		end
		for i = write, #payloads do
			payloads[i] = nil
		end
	end

	-- Clear active explosions owned by the player
	for i = #activeExplosions, 1, -1 do
		local explosion = activeExplosions[i]
		if explosion and (explosion.ownerEntity == ownerEntity or explosion.retargetOwnerEntity == ownerEntity) then
			table.remove(activeExplosions, i)
		end
	end

	petalRetargetRequests[ownerEntity] = nil
end

function ProjectileService.step(dt: number)
	local now = getSimTime()
	if INVINCIBLE_ENEMY_DIAGNOSTICS then
		invincibleDiagCounters.projectilesTotalSeen += #projectileList
	end
	if #projectileList == 0 and #activeExplosions == 0 then
		if next(pendingSpawns) or next(pendingDespawns) or next(pendingImpacts) then
			for player, payloads in pairs(pendingSpawns) do
				if player and player.Parent == Players then
					ProjectilesSpawnBatch:FireClient(player, payloads)
				end
				pendingSpawns[player] = nil
			end
			for player, payloads in pairs(pendingDespawns) do
				if player and player.Parent == Players then
					ProjectilesDespawnBatch:FireClient(player, payloads)
				end
				pendingDespawns[player] = nil
			end
			for player, payloads in pairs(pendingImpacts) do
				if player and player.Parent == Players then
					ProjectilesImpactBatch:FireClient(player, payloads)
				end
				pendingImpacts[player] = nil
			end
		end
		return
	end

	local playerPositions = OctreeSystem.getPlayerPositions()
	if INVINCIBLE_ENEMY_DIAGNOSTICS then
		invincibleDiagCounters.lastPlayerCount = #playerPositions
		if #playerPositions == 0 then
			invincibleDiagCounters.framesWithoutPlayers += 1
		end
	end
	local simCount = 0
	local collisionChecks = 0
	local hitBudget = MAX_HITS_PER_TICK
	local petalRetargetConsumed: {[number]: boolean} = {}
	local petalAssignmentsByOwner = buildPetalAssignments()

	if now - lastRecipientRefresh >= RECIPIENT_REFRESH_INTERVAL then
		lastRecipientRefresh = now
		local perPlayerSpawnCount: {[Player]: number} = {}
		for _, id in ipairs(projectileList) do
			local record = projectiles[id]
			if record then
				for playerEntity, pos, playerStats in playerQuery do
					local player = playerStats and playerStats.player or nil
					if player and player.Parent == Players then
						if not record.recipients[player] then
							local playerPos = Vector3.new(pos.x, pos.y, pos.z)
							if distanceSq(playerPos, record.lastPos) <= SPAWN_SEND_RADIUS * SPAWN_SEND_RADIUS then
								local count = perPlayerSpawnCount[player] or 0
								if count < MAX_RECIPIENT_SPAWNS_PER_TICK then
									record.recipients[player] = true
									queueSpawnForPlayer(player, record)
									perPlayerSpawnCount[player] = count + 1
								end
							end
						end
					end
				end
			end
		end
	end

	local processed = 0
	while processed < #projectileList do
		if simCount >= MAX_PROJECTILES_SIMULATED_PER_TICK then
			if INVINCIBLE_ENEMY_DIAGNOSTICS then
				invincibleDiagCounters.projectilesSkippedBySimBudget += math.max(#projectileList - processed, 1)
			end
			break
		end
		local id = projectileList[nextSimIndex]
		nextSimIndex += 1
		if nextSimIndex > #projectileList then
			nextSimIndex = 1
		end
		processed += 1

		local record = id and projectiles[id] or nil
		if not record then
			continue
		end
		if record.expiresAt <= now then
			local impactPos = record.lastPos
			if record.splitOnHit and not record.splitOnHit.used then
				record.splitOnHit.used = true
				spawnSplitProjectiles(record, impactPos, now, nil)
			end
			if record.aoe and record.aoe.triggerOnExpire then
				startExplosion(record, impactPos, "exploded", true)
				despawnProjectile(record, "exploded", nil)
			else
				despawnProjectile(record, "expired", impactPos)
			end
			continue
		end

		if record.nextSimTime and now < record.nextSimTime then
			continue
		end

		local allowCollision, nearestDistSq = shouldSimulateCollision(record, playerPositions)
		local simInterval = SIM_INTERVAL
		if record.beam then
			allowCollision = true
			simInterval = SIM_INTERVAL
		elseif record.petal then
			allowCollision = true
			simInterval = PETAL_SIM_INTERVAL
		elseif not allowCollision then
			simInterval = FAR_SIM_INTERVAL
		end
		if INVINCIBLE_ENEMY_DIAGNOSTICS and allowCollision then
			invincibleDiagCounters.projectilesCollisionEnabled += 1
		end
		if INVINCIBLE_ENEMY_DIAGNOSTICS and not allowCollision then
			invincibleDiagCounters.projectilesCollisionDisabledByRelevance += 1
			if #playerPositions == 0 and not record.beam and not record.petal then
				invincibleDiagCounters.projectilesCollisionDisabledNoPlayers += 1
			end
		end

		local dtSim = now - record.lastSimTime
		if dtSim <= 0 then
			record.nextSimTime = now + simInterval
			continue
		end

		local newPos = record.lastPos
		if record.beam then
			newPos = record.lastPos
		elseif record.petal then
			local petal = record.petal
			local ownerEntity = petal.ownerEntity
			local forceRetarget = ownerEntity and petalRetargetRequests[ownerEntity] or false
			if forceRetarget and ownerEntity then
				petal.targetEntity = nil
				petalRetargetConsumed[ownerEntity] = true
			end

			local ownerPos = getOwnerPosition(record)
			local target = petal.targetEntity
			if target and not world:contains(target) then
				target = nil
			end
			if target then
				local health = world:get(target, Health)
				if health and health.current and health.current <= 0 then
					target = nil
				end
			end
			if target then
				local targetPos = getPetalTargetPosition(target)
				if not targetPos then
					target = nil
				elseif ownerPos and distanceSq(ownerPos, targetPos) > (petal.maxRange * petal.maxRange) then
					target = nil
				end
			end
			if not target then
				local role = petal.role or "closest"
				local assignment = ownerEntity and petalAssignmentsByOwner[ownerEntity] or nil
				if assignment then
					if role == "toughest" then
						target = assignment.toughest
					else
						target = assignment.closest
					end
				end
			end
			petal.targetEntity = target

				if target and ownerPos then
					local targetPos = getPetalTargetPosition(target)
					if targetPos and distanceSq(ownerPos, targetPos) <= (petal.maxRange * petal.maxRange) then
						local desired = targetPos - record.lastPos
						if petal.alwaysStayHorizontal then
							desired = Vector3.new(desired.X, 0, desired.Z)
						elseif petal.stayHorizontal then
							local yDiff = math.abs(targetPos.Y - record.lastPos.Y)
							if yDiff <= STAY_HORIZONTAL_TARGET_Y_DIFF then
								desired = Vector3.new(desired.X, 0, desired.Z)
							end
						end
						if desired.Magnitude > 0 then
						desired = desired.Unit
						local current = record.direction
						local dot = math.clamp(current:Dot(desired), -1, 1)
						local angle = math.acos(dot)
						local maxAngle = petal.homingMaxAngle and math.rad(petal.homingMaxAngle) or math.huge
						if maxAngle < math.pi and angle > maxAngle then
							petal.targetEntity = nil
						else
							if angle <= 0.0001 then
								record.direction = desired
							else
								local maxStep = math.rad(petal.homingStrength or 360) * (now - record.lastSimTime)
								local turn = math.min(angle, maxStep)
								local axis = current:Cross(desired)
								if axis.Magnitude <= 0.0001 then
									record.direction = desired
								else
									axis = axis.Unit
									local rotation = CFrame.fromAxisAngle(axis, turn)
									record.direction = rotation:VectorToWorldSpace(current).Unit
								end
							end
							newPos = record.lastPos + record.direction * record.speed * dtSim
						end
					end
				end
			end
		elseif record.orbit then
			local ownerPosComp = record.orbit.ownerEntity and world:get(record.orbit.ownerEntity, Position)
			if not ownerPosComp then
				despawnProjectile(record, "expired", record.lastPos)
				continue
			end
			local ownerPos = Vector3.new(ownerPosComp.x, ownerPosComp.y, ownerPosComp.z)
			local angle = record.orbit.angle + math.rad(record.orbit.speedDeg) * dtSim
			record.orbit.angle = angle
			newPos = ownerPos + Vector3.new(math.cos(angle) * record.orbit.radius, 0, math.sin(angle) * record.orbit.radius)
			record.direction = Vector3.new(-math.sin(angle), 0, math.cos(angle)).Unit
		else
			updateHoming(record, now)
			newPos = record.lastPos + record.direction * record.speed * dtSim
		end

		if record.stickToPlayer and record.ownerEntity then
			local ownerPos = getOwnerPosition(record)
			if ownerPos then
				if record.stickOffset then
					newPos = ownerPos + record.stickOffset
				elseif record.lastOwnerPos then
					local delta = ownerPos - record.lastOwnerPos
					newPos = newPos + delta
				end
				record.lastOwnerPos = ownerPos
			end
		end

		if record.alwaysStayHorizontal and not record.stickToPlayer then
			newPos = Vector3.new(newPos.X, record.origin.Y, newPos.Z)
		elseif record.homing and record.homing.alwaysStayHorizontal then
			newPos = Vector3.new(newPos.X, record.origin.Y, newPos.Z)
		end

		local hit = false
		local hitPos = newPos
		local hitReason = "hit"

		if record.hitCooldowns and next(record.hitCooldowns) then
			for enemyId, expiresAt in pairs(record.hitCooldowns) do
				if expiresAt <= now then
					record.hitCooldowns[enemyId] = nil
				end
			end
		end

		if allowCollision and collisionChecks < MAX_COLLISION_CHECKS_PER_TICK and hitBudget > 0 then
			local segmentStart = record.lastPos
			local segmentEnd = newPos
			local beamSize: Vector3? = nil
			local beamOffset: Vector3? = nil
			local beamRotation: CFrame? = nil
			local beamLengthAxis = "Z"
			if record.beam then
				local beamLength = record.beam.length
				if typeof(beamLength) ~= "number" or beamLength <= 0 then
					beamLength = record.speed * record.lifetime
				end
				if record.beam.size and typeof(record.beam.size) == "Vector3" then
					beamSize = record.beam.size
					if record.beam.lengthAxis == "X" then
						beamLength = beamSize.X > 0 and beamSize.X or beamLength
						beamLengthAxis = "X"
					elseif record.beam.lengthAxis == "Y" then
						beamLength = beamSize.Y > 0 and beamSize.Y or beamLength
						beamLengthAxis = "Y"
					else
						beamLength = beamSize.Z > 0 and beamSize.Z or beamLength
						beamLengthAxis = "Z"
					end
				end
				if record.beam.offset and typeof(record.beam.offset) == "Vector3" then
					beamOffset = record.beam.offset
				end
				if record.beam.rotation and typeof(record.beam.rotation) == "CFrame" then
					beamRotation = record.beam.rotation
				end
				if beamSize then
					local halfLen = 0.5
					if beamLengthAxis == "X" then
						halfLen = beamSize.X * 0.5
					elseif beamLengthAxis == "Y" then
						halfLen = beamSize.Y * 0.5
					else
						halfLen = beamSize.Z * 0.5
					end
					local cf = CFrame.lookAt(segmentStart, segmentStart + record.direction)
					if beamRotation then
						cf = cf * beamRotation
					end
					local center = cf:PointToWorldSpace(beamOffset or Vector3.new(0, 0, 0))
					local axisDir = cf.LookVector
					if beamLengthAxis == "X" then
						axisDir = cf.RightVector
					elseif beamLengthAxis == "Y" then
						axisDir = cf.UpVector
					end
					segmentStart = center - axisDir * halfLen
					segmentEnd = center + axisDir * halfLen
				else
					segmentEnd = segmentStart + record.direction * beamLength
				end
			end

			local thickness = record.radius
			if beamSize then
				if beamLengthAxis == "X" then
					thickness = math.max(beamSize.Y, beamSize.Z) * 0.5
				elseif beamLengthAxis == "Y" then
					thickness = math.max(beamSize.X, beamSize.Z) * 0.5
				else
					thickness = math.max(beamSize.X, beamSize.Y) * 0.5
				end
			end

			-- IceShardSpecial should collide with world geometry (walls/terrain) for
			-- both primary and split shards.
			if record.kind == "IceShardSpecial" and not record.beam then
				local worldHit = getWorldCollisionHit(record, segmentStart, segmentEnd)
				if worldHit then
					hit = true
					hitPos = worldHit.Position
					if record.splitOnHit and not record.splitOnHit.used then
						record.splitOnHit.used = true
						spawnSplitProjectiles(record, hitPos, now, nil)
						hitReason = "split"
					else
						hitReason = "wall"
					end
				end
			end

			if not hit then
				local segMid = (segmentStart + segmentEnd) * 0.5
				local segRadius = (segmentStart - segmentEnd).Magnitude * 0.5 + thickness + 6
				local segmentVerticalDelta = math.abs(segmentEnd.Y - segmentStart.Y)
				local includeHorizontalFallback = segmentVerticalDelta >= DIAGONAL_VERTICAL_DELTA_THRESHOLD
				local candidates = gatherEnemyCollisionCandidates(segMid, segRadius, includeHorizontalFallback)

				for _, enemyId in ipairs(candidates) do
					if collisionChecks >= MAX_COLLISION_CHECKS_PER_TICK or hitBudget <= 0 then
						if INVINCIBLE_ENEMY_DIAGNOSTICS then
							if collisionChecks >= MAX_COLLISION_CHECKS_PER_TICK then
								invincibleDiagCounters.projectilesSkippedByCollisionBudget += 1
							end
							if hitBudget <= 0 then
								invincibleDiagCounters.projectilesSkippedByHitBudget += 1
							end
						end
						break
					end
					collisionChecks += 1
					if INVINCIBLE_ENEMY_DIAGNOSTICS then
						invincibleDiagCounters.collisionChecks += 1
					end

					local hitCooldown = record.hitCooldowns[enemyId]
					if hitCooldown and hitCooldown > now then
						continue
					end
					if not record.beam and record.hitSet[enemyId] then
						continue
					end
					local entityType = world:get(enemyId, EntityType)
					if not entityType or entityType.type ~= "Enemy" then
						continue
					end
					local enemyHealth = world:get(enemyId, Health)
					local enemyPos, enemyRadiusOverride, _, enemyBoxCFrame, enemyHalfExtents = getEnemyCollisionCenter(enemyId)
					if not enemyPos then
						continue
					end
					local enemyRadius = 2.5
					local collision = world:get(enemyId, Collision)
					if enemyRadiusOverride then
						enemyRadius = enemyRadiusOverride
					elseif collision and collision.radius then
						enemyRadius = collision.radius
					end
					local hitThis = false
					local hitPosCandidate = enemyPos
					local raycastTarget = enemyPos
					local inflatedBy = thickness + ENEMY_COLLISION_GRACE_RADIUS
					if enemyBoxCFrame and enemyHalfExtents then
						local intersects, hitPoint = segmentIntersectsOrientedBox(
							segmentStart,
							segmentEnd,
							enemyBoxCFrame,
							enemyHalfExtents,
							inflatedBy
						)
						if intersects and hitPoint then
							hitThis = true
							-- Use an uninflated hit point when possible so split origin is at the
							-- actual collision contact, not the inflated broad-phase shell.
							local _, preciseHitPoint = segmentIntersectsOrientedBox(
								segmentStart,
								segmentEnd,
								enemyBoxCFrame,
								enemyHalfExtents,
								0
							)
							hitPosCandidate = preciseHitPoint or hitPoint
							raycastTarget = enemyPos
						elseif INVINCIBLE_ENEMY_DIAGNOSTICS then
							local segClosestToCenter = closestPointOnSegment(segmentStart, segmentEnd, enemyPos)
							local expandedHalf = inflateHalfExtents(enemyHalfExtents, inflatedBy)
							local missDistSq, _, delta = pointToOrientedBoxDistance(segClosestToCenter, enemyBoxCFrame, expandedHalf)
							local missGap = math.sqrt(missDistSq)
							if missGap <= 1 then
								invincibleDiagCounters.nearMissUnder1Stud += 1
							elseif missGap <= 3 then
								invincibleDiagCounters.nearMissUnder3Stud += 1
							end
							if missGap >= 0 and missGap < invincibleDiagClosestMissGap then
								invincibleDiagClosestMissGap = missGap
								invincibleDiagClosestMissProjectileId = record.id
								invincibleDiagClosestMissEnemyId = enemyId
								invincibleDiagClosestMissKind = record.kind
								invincibleDiagClosestMissVerticalDelta = math.abs(delta.Y)
								invincibleDiagClosestMissHorizontalDelta = Vector3.new(delta.X, 0, delta.Z).Magnitude
							end
						end
					else
						local centerClosest = closestPointOnSegment(segmentStart, segmentEnd, enemyPos)
						local centerDistSq = distanceSq(centerClosest, enemyPos)
						local hitRadius = inflatedBy + enemyRadius
						if centerDistSq <= hitRadius * hitRadius then
							hitThis = true
							-- Fallback collision approximation: place contact on enemy surface.
							local contactDir = centerClosest - enemyPos
							if contactDir.Magnitude <= 1e-4 then
								contactDir = -record.direction
							end
							if contactDir.Magnitude > 1e-4 then
								contactDir = contactDir.Unit
							else
								contactDir = Vector3.new(0, 0, -1)
							end
							hitPosCandidate = enemyPos + contactDir * enemyRadius
							raycastTarget = enemyPos
						end
					end

					if hitThis then
						if INVINCIBLE_ENEMY_DIAGNOSTICS then
							invincibleDiagCounters.geometricHits += 1
						end
						if record.collision and record.collision.useRaycast then
							local passesRaycast, blocker = passesRaycastCheck(record.lastPos, raycastTarget)
							if not passesRaycast then
								if INVINCIBLE_ENEMY_DIAGNOSTICS then
									invincibleDiagCounters.projectileRaycastBlocked += 1
									local enemyScale, enemySubtype, enemyTier = getEnemyDebugMeta(enemyId)
									recordProjectileRejectionSample(
										record.id,
										enemyId,
										record.kind,
										enemyHealth and enemyHealth.current or nil,
										world:has(enemyId, DeathAnimation),
										enemyScale,
										enemySubtype,
										enemyTier,
										"raycastBlocked",
										blocker
									)
								end
								continue
							end
						end
						if INVINCIBLE_ENEMY_DIAGNOSTICS then
							invincibleDiagCounters.damageCalls += 1
						end
						local enemyHealthAtHit = enemyHealth and enemyHealth.current or nil
						local _, didApply = DamageSystem.applyDamage(enemyId, record.damage, "magic", record.ownerEntity, record.kind)
						if INVINCIBLE_ENEMY_DIAGNOSTICS then
							if didApply then
								invincibleDiagCounters.damageApplied += 1
							else
								invincibleDiagCounters.damageRejectedAfterHit += 1
								local enemyScale, enemySubtype, enemyTier = getEnemyDebugMeta(enemyId)
								recordProjectileRejectionSample(
									record.id,
									enemyId,
									record.kind,
									enemyHealthAtHit,
									world:has(enemyId, DeathAnimation),
									enemyScale,
									enemySubtype,
									enemyTier,
									"didNotApply",
									nil
								)
							end
						end
						if didApply and record.frostbiteOnHit and DamageSystem.applyEnemyFrostbite then
							DamageSystem.applyEnemyFrostbite(
								enemyId,
								record.frostbiteOnHit.stacks,
								record.frostbiteOnHit.duration,
								record.frostbiteOnHit.damageTakenPerStack,
								record.frostbiteOnHit.statusId
							)
						end
						if record.slowOnHit then
							EnemySlowSystem.applySlow(
								enemyId,
								record.slowOnHit.duration,
								record.slowOnHit.multiplier,
								record.slowOnHit.impaleModelPath
							)
						end
						if not record.beam then
							record.hitSet[enemyId] = true
						end
						record.hitCooldowns[enemyId] = now + record.hitCooldown
						if not record.beam then
							record.hitCount += 1
							record.pierceRemaining -= 1
						end
						hitBudget -= 1
						hitPos = hitPosCandidate

						if record.homing and not record.beam then
							record.homing.targetEntity = nil
						end

						if record.beam then
							-- Beam persists; no despawn or split handling.
							-- no despawn
						elseif record.splitOnHit and not record.splitOnHit.used then
							record.splitOnHit.used = true
							spawnSplitProjectiles(record, hitPosCandidate, now, enemyId)
							hit = true
							hitReason = "split"
						elseif record.aoe and record.aoe.trigger == "hit" then
							local shouldDespawn = record.pierceRemaining <= 0 or record.hitCount >= ((record.basePierce or 0) + 1)
							startExplosion(record, hitPosCandidate, "exploded", shouldDespawn)
							if shouldDespawn then
								hit = true
								hitReason = "exploded"
							end
						elseif record.pierceRemaining <= 0 or record.hitCount >= ((record.basePierce or 0) + 1) then
							hit = true
						end

						if hit then
							hitPos = hitPosCandidate
							break
						end
					end
				end
			end
		elseif allowCollision and INVINCIBLE_ENEMY_DIAGNOSTICS then
			if collisionChecks >= MAX_COLLISION_CHECKS_PER_TICK then
				invincibleDiagCounters.projectilesSkippedByCollisionBudget += 1
			end
			if hitBudget <= 0 then
				invincibleDiagCounters.projectilesSkippedByHitBudget += 1
			end
		end

		record.lastPos = newPos
		record.lastSimTime = now
		record.nextSimTime = now + simInterval
		simCount += 1
		if INVINCIBLE_ENEMY_DIAGNOSTICS then
			invincibleDiagCounters.projectilesSimulated += 1
		end

		if hit then
			local impactPos = hitReason == "exploded" and nil or hitPos
			if record.hitCount and (record.hitCount > ((record.basePierce or 0) + 1)) then
				warn(string.format(
					"[ProjectileService] Pierce mismatch for %s id=%d hits=%d basePierce=%s remaining=%s",
					tostring(record.kind),
					record.id,
					record.hitCount,
					tostring(record.basePierce),
					tostring(record.pierceRemaining)
				))
			end
			despawnProjectile(record, hitReason, impactPos)
		end
	end

	for ownerEntity in pairs(petalRetargetConsumed) do
		petalRetargetRequests[ownerEntity] = nil
	end

	hitBudget = processExplosions(now, hitBudget)

	profGauge("ProjectileService.Active", #projectileList)
	profGauge("ActiveRecordProjectiles", #projectileList)
	profInc("ProjectileService.Simulated", simCount)
	profInc("ProjectileService.CollisionChecks", collisionChecks)

	for player, payloads in pairs(pendingSpawns) do
		if player and player.Parent == Players then
			ProjectilesSpawnBatch:FireClient(player, payloads)
		end
		pendingSpawns[player] = nil
	end
	for player, payloads in pairs(pendingDespawns) do
		if player and player.Parent == Players then
			ProjectilesDespawnBatch:FireClient(player, payloads)
		end
		pendingDespawns[player] = nil
	end
	for player, payloads in pairs(pendingImpacts) do
		if player and player.Parent == Players then
			ProjectilesImpactBatch:FireClient(player, payloads)
		end
		pendingImpacts[player] = nil
	end
end

function ProjectileService.isProjectileActive(projectileId: number): boolean
	return projectiles[projectileId] ~= nil
end

function ProjectileService.getEnemyVisualHitboxDebugSamples(maxSamples: number?): {any}
	local samples = {}
	if not world then
		return samples
	end

	local limit = math.max(1, math.floor(maxSamples or 3))
	local count = 0
	for enemyId, entityType, pos in world:query(EntityType, Position) do
		if entityType and entityType.type == "Enemy" then
			local basePos = Vector3.new(pos.x, pos.y, pos.z)
			local center, _, _, boxCFrame, halfExtents = getEnemyCollisionCenter(enemyId)
			local scale, subtype, tier = getEnemyDebugMeta(enemyId)
			local facingData = FacingDirection and world:get(enemyId, FacingDirection) or nil
			local desiredVelocityData = DesiredVelocity and world:get(enemyId, DesiredVelocity) or nil
			local velocityData = Velocity and world:get(enemyId, Velocity) or nil
			local resolvedFacing = FacingResolver.resolveEnemyFacing(facingData, desiredVelocityData, velocityData, Vector3.new(0, 0, 1))
			local facingYaw = horizontalYawDegFromVector(resolvedFacing)
			local boxYaw = horizontalYawDegFromCFrame(boxCFrame)
			samples[#samples + 1] = {
				enemyId = enemyId,
				subtype = subtype,
				tier = tier,
				scale = scale,
				basePos = basePos,
				center = center or basePos,
				halfExtents = halfExtents,
				baseToCenterY = (center and (center.Y - basePos.Y)) or 0,
				bottomY = (center and halfExtents and (center.Y - halfExtents.Y)) or nil,
				facingYaw = facingYaw,
				boxYaw = boxYaw,
			}
			count += 1
			if count >= limit then
				break
			end
		end
	end
	return samples
end

function ProjectileService.getInvincibleEnemyDebugSnapshot(reset: boolean?): {[string]: any}
	local samples = table.create(#invincibleDiagSamples)
	for i, sample in ipairs(invincibleDiagSamples) do
		samples[i] = sample
	end

	local snapshot = {
		projectilesTotalSeen = invincibleDiagCounters.projectilesTotalSeen,
		projectilesSpawned = invincibleDiagCounters.projectilesSpawned,
		projectilesSimulated = invincibleDiagCounters.projectilesSimulated,
		projectilesCollisionEnabled = invincibleDiagCounters.projectilesCollisionEnabled,
		framesWithoutPlayers = invincibleDiagCounters.framesWithoutPlayers,
		lastPlayerCount = invincibleDiagCounters.lastPlayerCount,
		projectilesSkippedBySimBudget = invincibleDiagCounters.projectilesSkippedBySimBudget,
		projectilesCollisionDisabledByRelevance = invincibleDiagCounters.projectilesCollisionDisabledByRelevance,
		projectilesCollisionDisabledNoPlayers = invincibleDiagCounters.projectilesCollisionDisabledNoPlayers,
		projectilesSkippedByCollisionBudget = invincibleDiagCounters.projectilesSkippedByCollisionBudget,
		projectilesSkippedByHitBudget = invincibleDiagCounters.projectilesSkippedByHitBudget,
		projectileRaycastBlocked = invincibleDiagCounters.projectileRaycastBlocked,
		collisionChecks = invincibleDiagCounters.collisionChecks,
		geometricHits = invincibleDiagCounters.geometricHits,
		nearMissUnder1Stud = invincibleDiagCounters.nearMissUnder1Stud,
		nearMissUnder3Stud = invincibleDiagCounters.nearMissUnder3Stud,
		closestMissGap = if invincibleDiagClosestMissGap < math.huge then invincibleDiagClosestMissGap else nil,
		closestMissProjectileId = if invincibleDiagClosestMissProjectileId > 0 then invincibleDiagClosestMissProjectileId else nil,
		closestMissEnemyId = if invincibleDiagClosestMissEnemyId > 0 then invincibleDiagClosestMissEnemyId else nil,
		closestMissKind = invincibleDiagClosestMissKind,
		closestMissVerticalDelta = invincibleDiagClosestMissVerticalDelta,
		closestMissHorizontalDelta = invincibleDiagClosestMissHorizontalDelta,
		damageCalls = invincibleDiagCounters.damageCalls,
		damageApplied = invincibleDiagCounters.damageApplied,
		damageRejectedAfterHit = invincibleDiagCounters.damageRejectedAfterHit,
		samples = samples,
	}

	if reset then
		resetInvincibleEnemyDiagnostics()
	end

	return snapshot
end

return ProjectileService
