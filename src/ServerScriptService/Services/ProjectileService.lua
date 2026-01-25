--!strict
-- ProjectileService - Server-authoritative projectile records (no ECS entities).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local OctreeSystem = require(game.ServerScriptService.ECS.Systems.OctreeSystem)
local DamageSystem = require(game.ServerScriptService.ECS.Systems.DamageSystem)
local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local TargetingService = require(game.ServerScriptService.Abilities.TargetingService)
local EnemySlowSystem = require(game.ServerScriptService.ECS.Systems.EnemySlowSystem)

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
	splitOnHit: SplitConfig?,
	slowOnHit: SlowConfig?,
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
}

local world: any
local Components: any
local getPlayerFromEntity: ((number) -> Player?)?

local Position: any
local EntityType: any
local Collision: any
local Health: any
local PlayerStats: any

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

local RAYCAST_PARAMS = RaycastParams.new()
RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
RAYCAST_PARAMS.IgnoreWater = true

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
}} = {}
local lastRecipientRefresh = 0

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

local enemyHitboxCache: {[string]: {offset: Vector3, radius: number}} = {}

local function getEnemyCollisionCenter(enemyId: number): (Vector3?, number?)
	if not world then
		return nil, nil
	end
	local pos = world:get(enemyId, Position)
	if not pos then
		return nil, nil
	end
	local basePos = Vector3.new(pos.x, pos.y, pos.z)
	local entityType = world:get(enemyId, EntityType)
	local subtype = entityType and entityType.subtype
	if subtype then
		local cached = enemyHitboxCache[subtype]
		if not cached then
			local hitbox = ModelReplicationService.getEnemyHitbox(subtype)
			if not hitbox then
				ModelReplicationService.replicateEnemy(subtype)
				hitbox = ModelReplicationService.getEnemyHitbox(subtype)
			end
			if hitbox and hitbox.size then
				local size = hitbox.size
				local radius = math.max(size.X, size.Y, size.Z) * 0.5
				cached = {
					offset = hitbox.offset or Vector3.new(0, 0, 0),
					radius = radius,
				}
				enemyHitboxCache[subtype] = cached
			end
		end
		if cached then
			return basePos + cached.offset, cached.radius
		end
	end
	return basePos, nil
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

local function spawnSplitProjectiles(record: ProjectileRecord, hitPos: Vector3, now: number)
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

		ProjectileService.spawnProjectile({
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
		})
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
	if homing.stayHorizontal or homing.alwaysStayHorizontal then
		desired = Vector3.new(desired.X, 0, desired.Z)
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

local function passesRaycastCheck(startPos: Vector3, endPos: Vector3): boolean
	local dir = endPos - startPos
	local result = Workspace:Raycast(startPos, dir, RAYCAST_PARAMS)
	return result == nil
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
	splitOnHit: SplitConfig?,
	slowOnHit: SlowConfig?,
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
		pierceRemaining = (payload.pierce or 0) + 1,
		basePierce = payload.pierce or 0,
		hitSet = {},
		hitCooldowns = {},
		hitCooldown = payload.hitCooldown or 0.04,
		homing = payload.homing,
		aoe = payload.aoe,
		collision = payload.collision,
		orbit = payload.orbit,
		petal = payload.petal,
		splitOnHit = payload.splitOnHit,
		slowOnHit = payload.slowOnHit,
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
	}

	if record.homing then
		record.homing.targetEntity = nil
	end
	if record.orbit then
		record.orbit.angle = record.orbit.angle or 0
	end

	projectiles[id] = record
	registerProjectile(id)

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
			local candidates = OctreeSystem.getEnemiesInRadius(explosion.position, radius)
			for _, enemyId in ipairs(candidates) do
				if hitBudget <= 0 then
					break
				end
				if not explosion.hitSet[enemyId] then
					local health = world:get(enemyId, Health)
					local enemyPos = getEnemyCollisionCenter(enemyId)
					if enemyPos and health and health.current and health.current > 0 then
						if (enemyPos - explosion.position).Magnitude <= radius then
							hitAny = true
							explosion.hitSet[enemyId] = true
							hitBudget -= 1
							DamageSystem.applyDamage(enemyId, explosion.damage, "magic", explosion.ownerEntity, explosion.kind)

							if explosion.knockbackDistance and explosion.knockbackDistance > 0 then
								local dir = enemyPos - explosion.position
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

function ProjectileService.step(dt: number)
	local now = getSimTime()
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
		if record.petal then
			allowCollision = true
			simInterval = PETAL_SIM_INTERVAL
		elseif not allowCollision then
			simInterval = FAR_SIM_INTERVAL
		end

		local dtSim = now - record.lastSimTime
		if dtSim <= 0 then
			record.nextSimTime = now + simInterval
			continue
		end

		local newPos = record.lastPos
		if record.petal then
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
					if petal.stayHorizontal or petal.alwaysStayHorizontal then
						desired = Vector3.new(desired.X, 0, desired.Z)
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
			local ownerPosComp = world:get(record.ownerEntity, Position)
			if ownerPosComp then
				local ownerPos = Vector3.new(ownerPosComp.x, ownerPosComp.y, ownerPosComp.z)
				if record.lastOwnerPos then
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
			local segMid = (record.lastPos + newPos) * 0.5
			local segRadius = (record.lastPos - newPos).Magnitude * 0.5 + record.radius + 6
			local candidates = OctreeSystem.getEnemiesInRadius(segMid, segRadius)

			for _, enemyId in ipairs(candidates) do
				if collisionChecks >= MAX_COLLISION_CHECKS_PER_TICK or hitBudget <= 0 then
					break
				end
				collisionChecks += 1

				local hitCooldown = record.hitCooldowns[enemyId]
				if hitCooldown and hitCooldown > now then
					continue
				end
				local entityType = world:get(enemyId, EntityType)
				if not entityType or entityType.type ~= "Enemy" then
					continue
				end
				local enemyPos, enemyRadiusOverride = getEnemyCollisionCenter(enemyId)
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
				local closest = closestPointOnSegment(record.lastPos, newPos, enemyPos)
				local distSq = distanceSq(closest, enemyPos)
				local hitRadius = record.radius + enemyRadius
				if distSq <= hitRadius * hitRadius then
					if record.collision and record.collision.useRaycast then
						if not passesRaycastCheck(record.lastPos, enemyPos) then
							continue
						end
					end
					DamageSystem.applyDamage(enemyId, record.damage, "magic", record.ownerEntity, record.kind)
					if record.slowOnHit then
						EnemySlowSystem.applySlow(
							enemyId,
							record.slowOnHit.duration,
							record.slowOnHit.multiplier,
							record.slowOnHit.impaleModelPath
						)
					end
					record.hitSet[enemyId] = true
					record.hitCooldowns[enemyId] = now + record.hitCooldown
					record.pierceRemaining -= 1
					hitBudget -= 1
					hitPos = closest

					if record.homing then
						record.homing.targetEntity = nil
					end

					if record.splitOnHit and not record.splitOnHit.used then
						record.splitOnHit.used = true
						spawnSplitProjectiles(record, hitPos, now)
						hit = true
						hitReason = "split"
					elseif record.aoe and record.aoe.trigger == "hit" then
						local shouldDespawn = record.pierceRemaining <= 0
						startExplosion(record, hitPos, "exploded", shouldDespawn)
						if shouldDespawn then
							hit = true
							hitReason = "exploded"
						end
					elseif record.pierceRemaining <= 0 then
						hit = true
					end

					if hit then
						break
					end
				end
			end
		end

		record.lastPos = newPos
		record.lastSimTime = now
		record.nextSimTime = now + simInterval
		simCount += 1

		if hit then
			local impactPos = hitReason == "exploded" and nil or hitPos
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

return ProjectileService
