--!strict
-- ProjectileService - Server-authoritative projectile records (no ECS entities).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
local OctreeSystem = require(game.ServerScriptService.ECS.Systems.OctreeSystem)
local DamageSystem = require(game.ServerScriptService.ECS.Systems.DamageSystem)

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
	lastSimTime: number,
	lastPos: Vector3,
	pierceRemaining: number,
	hitSet: {[number]: boolean},
	hitCooldowns: {[number]: number},
	hitCooldown: number,
	homing: HomingConfig?,
	aoe: AoeConfig?,
	collision: CollisionConfig?,
	orbit: OrbitConfig?,
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
local RELEVANCE_RADIUS = 260
local SPAWN_SEND_RADIUS = 300
local MAX_PROJECTILES_SIMULATED_PER_TICK = 600
local MAX_COLLISION_CHECKS_PER_TICK = 4000
local MAX_HITS_PER_TICK = 600
local MAX_SPAWNS_PER_SECOND = 400
local RECIPIENT_REFRESH_INTERVAL = 0.5
local MAX_RECIPIENT_SPAWNS_PER_TICK = 200

local RAYCAST_PARAMS = RaycastParams.new()
RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
RAYCAST_PARAMS.IgnoreWater = true

local spawnCounts: {[Player]: {count: number, resetAt: number}} = setmetatable({}, { __mode = "k" })
local pendingSpawns: {[Player]: {any}} = {}
local pendingDespawns: {[Player]: {any}} = {}
local pendingImpacts: {[Player]: {any}} = {}
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
	})
end

local function sendDespawn(record: ProjectileRecord, reason: string)
	for player in pairs(record.recipients) do
		if player and player.Parent == Players then
			queueForPlayer(pendingDespawns, player, { id = record.id, reason = reason })
		end
	end
end

local function sendImpact(record: ProjectileRecord, position: Vector3, reason: string, aoe: AoeConfig?)
	for player in pairs(record.recipients) do
		if player and player.Parent == Players then
			queueForPlayer(pendingImpacts, player, {
				id = record.id,
				pos = position,
				reason = reason,
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
		local pos = world:get(enemyId, Position)
		if pos then
			local enemyPos = Vector3.new(pos.x, pos.y, pos.z)
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

	local targetPosComp = world:get(targetEntity, Position)
	if not targetPosComp then
		return
	end

	local desired = Vector3.new(targetPosComp.x, targetPosComp.y, targetPosComp.z) - record.lastPos
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
}): number?
	if not payload or typeof(payload.origin) ~= "Vector3" then
		return nil
	end

	local ownerPlayer = payload.ownerEntity and getPlayerFromEntity and getPlayerFromEntity(payload.ownerEntity) or nil
	if ownerPlayer then
		local entry = spawnCounts[ownerPlayer]
		local now = GameTimeSystem.getGameTime()
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
	local now = GameTimeSystem.getGameTime()
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
		lastSimTime = now,
		lastPos = payload.origin,
		pierceRemaining = (payload.pierce or 0) + 1,
		hitSet = {},
		hitCooldowns = {},
		hitCooldown = payload.hitCooldown or 0.04,
		homing = payload.homing,
		aoe = payload.aoe,
		collision = payload.collision,
		orbit = payload.orbit,
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

local function startExplosion(record: ProjectileRecord, center: Vector3, reason: string)
	if not record.aoe then
		return
	end
	local aoe = record.aoe
	local duration = aoe.duration or 0.5
	local now = GameTimeSystem.getGameTime()

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
	}

	sendImpact(record, center, reason, aoe)
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
			local radius = explosion.radius
			local candidates = OctreeSystem.getEnemiesInRadius(explosion.position, radius)
			for _, enemyId in ipairs(candidates) do
				if hitBudget <= 0 then
					break
				end
				if not explosion.hitSet[enemyId] then
					local pos = world:get(enemyId, Position)
					local health = world:get(enemyId, Health)
					if pos and health and health.current and health.current > 0 then
						local enemyPos = Vector3.new(pos.x, pos.y, pos.z)
						if (enemyPos - explosion.position).Magnitude <= radius then
							explosion.hitSet[enemyId] = true
							hitBudget -= 1
							DamageSystem.applyDamage(enemyId, explosion.damage, "magic", explosion.ownerEntity, explosion.kind)
						end
					end
				end
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
	local now = GameTimeSystem.getGameTime()
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
				startExplosion(record, impactPos, "exploded")
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
		if not allowCollision then
			simInterval = FAR_SIM_INTERVAL
		end

		local dtSim = now - record.lastSimTime
		if dtSim <= 0 then
			record.nextSimTime = now + simInterval
			continue
		end

		local newPos = record.lastPos
		if record.orbit then
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
				local enemyPosComp = world:get(enemyId, Position)
				if not enemyPosComp then
					continue
				end
				local enemyPos = Vector3.new(enemyPosComp.x, enemyPosComp.y, enemyPosComp.z)
				local enemyRadius = 2.5
				local collision = world:get(enemyId, Collision)
				if collision and collision.radius then
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
					record.hitSet[enemyId] = true
					record.hitCooldowns[enemyId] = now + record.hitCooldown
					record.pierceRemaining -= 1
					hitBudget -= 1
					hitPos = closest

					if record.homing then
						record.homing.targetEntity = nil
					end

					if record.aoe and record.aoe.trigger == "hit" then
						startExplosion(record, hitPos, "exploded")
						hit = true
						hitReason = "exploded"
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

return ProjectileService
