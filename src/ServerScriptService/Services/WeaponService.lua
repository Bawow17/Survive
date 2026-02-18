--!strict

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local EnemyColliderService = require(game.ServerScriptService.Services.EnemyColliderService)
local OctreeSystem = require(game.ServerScriptService.ECS.Systems.OctreeSystem)
local Oathkeeper = require(game.ServerScriptService.Balance.Weapons.Oathkeeper)

local WeaponService = {}

local world: any = nil
local Components: any = nil
local PassiveEffectSystem: any = nil
local DamageSystem: any = nil
local getPlayerEntity: ((Player) -> number?)? = nil

local primaryFireRequestRemote: RemoteEvent? = nil
local primaryShotRemote: RemoteEvent? = nil
local sprintForceOffRemote: RemoteEvent? = nil

local nextFireAtByPlayer: {[Player]: number} = {}
local warned: {[string]: boolean} = {}
local ENEMY_CANDIDATE_BASE_BUFFER = 30.0
local ENEMY_CANDIDATE_HORIZONTAL_BUFFER = 18.0
local DIAGONAL_VERTICAL_DELTA_THRESHOLD = 0.25
local HITSCAN_THICKNESS = 0.5

local RAYCAST_PARAMS = RaycastParams.new()
RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
RAYCAST_PARAMS.IgnoreWater = true

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn(message)
end

local function findByPath(root: Instance, path: string): Instance?
	local current: Instance = root
	for _, part in ipairs(string.split(path, ".")) do
		local child = current:FindFirstChild(part)
		if not child then
			return nil
		end
		current = child
	end
	return current
end

local function isPlayerFrozen(playerEntity: number): boolean
	if not world or not Components then
		return true
	end
	if Components.PlayerPauseState then
		local pauseState = world:get(playerEntity, Components.PlayerPauseState)
		if pauseState and pauseState.isPaused then
			return true
		end
	end
	return false
end

local function isPlayerAlive(player: Player, playerEntity: number): boolean
	if not world or not Components then
		return false
	end
	local ecsHealth = Components.Health and world:get(playerEntity, Components.Health)
	if ecsHealth and ecsHealth.current and ecsHealth.current <= 0.01 then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0.01 then
		return false
	end
	return true
end

local function getEffectiveCooldown(playerEntity: number): number
	local cooldown = Oathkeeper.baseCooldown
	if Oathkeeper.usesCooldownMultiplier and PassiveEffectSystem and PassiveEffectSystem.getCooldownMultiplier then
		local mult = PassiveEffectSystem.getCooldownMultiplier(playerEntity)
		if typeof(mult) == "number" and mult > 0 then
			cooldown *= mult
		end
	end
	return math.max(0.05, cooldown)
end

local function getEffectiveDamage(playerEntity: number): number
	local damage = Oathkeeper.damage
	if Oathkeeper.usesDamageMultiplier and PassiveEffectSystem and PassiveEffectSystem.getDamageMultiplier then
		local mult = PassiveEffectSystem.getDamageMultiplier(playerEntity)
		if typeof(mult) == "number" and mult > 0 then
			damage *= mult
		end
	end
	return math.max(0, damage)
end

local function resolveMuzzleOrigin(character: Model): Vector3?
	local weaponModelName = Oathkeeper.assetPaths.model
	local weaponModel = character:FindFirstChild(weaponModelName)
	if not weaponModel or not weaponModel:IsA("Model") then
		return nil
	end
	local muzzleInstance = findByPath(weaponModel, Oathkeeper.assetPaths.muzzlePart)
	if not muzzleInstance then
		return nil
	end
	if muzzleInstance:IsA("Attachment") then
		return muzzleInstance.WorldPosition
	end
	if muzzleInstance:IsA("BasePart") then
		return muzzleInstance.Position
	end
	return nil
end

local function isEnemyEntity(entityId: number): boolean
	local entityType = Components.EntityType and world:get(entityId, Components.EntityType)
	return entityType and entityType.type == "Enemy"
end

local function isEnemyAlive(entityId: number): boolean
	if Components.DeathAnimation and world:has(entityId, Components.DeathAnimation) then
		return false
	end
	local health = Components.Health and world:get(entityId, Components.Health)
	return health and health.current and health.current > 0
end

local function distanceSq(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dy = a.Y - b.Y
	local dz = a.Z - b.Z
	return dx * dx + dy * dy + dz * dz
end

local function gatherEnemyCandidates(segmentStart: Vector3, segmentEnd: Vector3, includeHorizontalFallback: boolean): {number}
	local segmentMid = (segmentStart + segmentEnd) * 0.5
	local segmentRadius = (segmentStart - segmentEnd).Magnitude * 0.5 + HITSCAN_THICKNESS + 6
	local searchRadius = segmentRadius + ENEMY_CANDIDATE_BASE_BUFFER

	local octreeCandidates = OctreeSystem.getEnemiesInRadius(segmentMid, searchRadius)
	local dedup: {[number]: boolean} = {}
	local merged: {number} = table.create(#octreeCandidates)
	for _, enemyId in ipairs(octreeCandidates) do
		if not dedup[enemyId] and isEnemyEntity(enemyId) and isEnemyAlive(enemyId) then
			dedup[enemyId] = true
			merged[#merged + 1] = enemyId
		end
	end

	if includeHorizontalFallback and world and Components and Components.EntityType and Components.Position then
		local horizontalRadius = segmentRadius + ENEMY_CANDIDATE_HORIZONTAL_BUFFER
		local horizontalRadiusSq = horizontalRadius * horizontalRadius
		for enemyId, entityType, pos in world:query(Components.EntityType, Components.Position) do
			if entityType and entityType.type == "Enemy" and not dedup[enemyId] and isEnemyAlive(enemyId) then
				local dx = pos.x - segmentMid.X
				local dz = pos.z - segmentMid.Z
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

	-- Last-resort fallback when octree misses due update timing/bounds.
	if not world or not Components or not Components.EntityType or not Components.Position then
		return merged
	end
	local searchSq = searchRadius * searchRadius
	for enemyId, entityType, pos in world:query(Components.EntityType, Components.Position) do
		if entityType and entityType.type == "Enemy" and isEnemyAlive(enemyId) then
			local enemyPos = Vector3.new(pos.x, pos.y, pos.z)
			if distanceSq(segmentMid, enemyPos) <= searchSq then
				merged[#merged + 1] = enemyId
			end
		end
	end
	return merged
end

local function segmentIntersectsOrientedBox(
	segmentStart: Vector3,
	segmentEnd: Vector3,
	boxCFrame: CFrame,
	halfExtents: Vector3,
	inflateAmount: number
): (boolean, Vector3?, number?)
	local expandedHalf = Vector3.new(
		halfExtents.X + inflateAmount,
		halfExtents.Y + inflateAmount,
		halfExtents.Z + inflateAmount
	)
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
		return false, nil, nil
	end
	if not clipAxis(p0.Y, dir.Y, -expandedHalf.Y, expandedHalf.Y) then
		return false, nil, nil
	end
	if not clipAxis(p0.Z, dir.Z, -expandedHalf.Z, expandedHalf.Z) then
		return false, nil, nil
	end

	local hitT = tMin >= 0 and tMin or tMax
	if hitT < 0 or hitT > 1 then
		return false, nil, nil
	end

	local hitLocal = p0 + (dir * hitT)
	return true, boxCFrame:PointToWorldSpace(hitLocal), hitT
end

local function buildShotResult(player: Player, targetPoint: Vector3): {[string]: any}?
	local character = player.Character
	if not character then
		return nil
	end
	if character:GetAttribute("StarterWeaponId") ~= Oathkeeper.id then
		return nil
	end

	local origin = resolveMuzzleOrigin(character)
	if not origin then
		warnOnce("MissingMuzzle_" .. tostring(player.UserId), "[WeaponService] Oathkeeper muzzle missing; cannot fire.")
		return nil
	end

	local direction = targetPoint - origin
	if direction.Magnitude <= 1e-4 then
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			direction = hrp.CFrame.LookVector
		else
			direction = Vector3.new(0, 0, -1)
		end
	end
	direction = direction.Unit

	local maxRange = math.max(1, Oathkeeper.range)
	local segmentEnd = origin + (direction * maxRange)
	local impactNormal = -direction

	RAYCAST_PARAMS.FilterDescendantsInstances = { character }
	local blocker = Workspace:Raycast(origin, direction * maxRange, RAYCAST_PARAMS)
	if blocker then
		segmentEnd = blocker.Position
		impactNormal = blocker.Normal
	end

	local includeHorizontalFallback = math.abs(segmentEnd.Y - origin.Y) >= DIAGONAL_VERTICAL_DELTA_THRESHOLD
	local candidates = gatherEnemyCandidates(origin, segmentEnd, includeHorizontalFallback)
	local hitEnemyEntity: number? = nil
	local hitEnemyPoint: Vector3? = nil
	local nearestT = math.huge

	for _, enemyEntity in ipairs(candidates) do
		local hitbox = EnemyColliderService.getWorldHitbox(enemyEntity)
		if hitbox and typeof(hitbox.boxCFrame) == "CFrame" and typeof(hitbox.halfExtents) == "Vector3" then
			local intersects, hitPoint, hitT = segmentIntersectsOrientedBox(
				origin,
				segmentEnd,
				hitbox.boxCFrame,
				hitbox.halfExtents,
				0.75
			)
			if intersects and hitPoint and hitT and hitT < nearestT then
				nearestT = hitT
				hitEnemyEntity = enemyEntity
				hitEnemyPoint = hitPoint
				local center = hitbox.center
				if typeof(center) == "Vector3" then
					local normal = (hitPoint - center)
					if normal.Magnitude > 1e-4 then
						impactNormal = normal.Unit
					else
						impactNormal = -direction
					end
				else
					impactNormal = -direction
				end
			end
		end
	end

	local impactPosition = hitEnemyPoint or segmentEnd
	return {
		origin = origin,
		impactPosition = impactPosition,
		impactNormal = impactNormal,
		hitEnemyEntity = hitEnemyEntity,
		didHitEnemy = hitEnemyEntity ~= nil,
	}
end

local function canFire(player: Player, playerEntity: number): boolean
	if not world or not Components then
		return false
	end
	if not world:contains(playerEntity) then
		return false
	end
	if player:GetAttribute("CooldownsFrozen") == true then
		return false
	end
	if isPlayerFrozen(playerEntity) then
		return false
	end
	if not isPlayerAlive(player, playerEntity) then
		return false
	end
	return true
end

local function handlePrimaryFireRequest(player: Player, requestPayload: any)
	local targetPoint: Vector3? = nil
	local clientShotId: number? = nil
	if typeof(requestPayload) == "Vector3" then
		targetPoint = requestPayload
	elseif typeof(requestPayload) == "table" then
		if typeof(requestPayload.targetPoint) == "Vector3" then
			targetPoint = requestPayload.targetPoint
		end
		if typeof(requestPayload.clientShotId) == "number" then
			local normalized = math.floor(requestPayload.clientShotId + 0.5)
			if normalized >= 0 then
				clientShotId = normalized
			end
		end
	end
	if not targetPoint then
		return
	end
	if not getPlayerEntity or not primaryShotRemote then
		return
	end

	local playerEntity = getPlayerEntity(player)
	if not playerEntity then
		return
	end
	if not canFire(player, playerEntity) then
		return
	end

	local shot = buildShotResult(player, targetPoint)
	if not shot then
		return
	end

	local now = tick()
	local nextFireAt = nextFireAtByPlayer[player] or 0
	if now < nextFireAt then
		return
	end

	local effectiveCooldown = getEffectiveCooldown(playerEntity)
	nextFireAtByPlayer[player] = now + effectiveCooldown

	if PassiveEffectSystem and PassiveEffectSystem.setSprintIntent then
		PassiveEffectSystem.setSprintIntent(playerEntity, false)
	end
	if sprintForceOffRemote then
		sprintForceOffRemote:FireClient(player)
	end

	local didApplyDamage = false
	if shot.hitEnemyEntity then
		local damageAmount = getEffectiveDamage(playerEntity)
		local _, applied = DamageSystem.applyDamage(
			shot.hitEnemyEntity,
			damageAmount,
			"weapon",
			playerEntity,
			"OathkeeperPrimary"
		)
		didApplyDamage = applied == true
	end

	primaryShotRemote:FireAllClients({
		shooterUserId = player.UserId,
		weaponId = Oathkeeper.id,
		clientShotId = clientShotId,
		origin = shot.origin,
		impactPosition = shot.impactPosition,
		impactNormal = shot.impactNormal,
		didHitEnemy = shot.didHitEnemy,
		didApplyDamage = didApplyDamage,
		effectiveCooldown = effectiveCooldown,
		tracerLifetime = Oathkeeper.tracerLifetime,
		tracerFadeDuration = Oathkeeper.tracerFadeDuration,
		firedAt = now,
	})
end

function WeaponService.init(options: {[string]: any})
	if primaryFireRequestRemote then
		return
	end

	world = options.world
	Components = options.Components
	PassiveEffectSystem = options.PassiveEffectSystem
	DamageSystem = options.DamageSystem
	getPlayerEntity = options.getPlayerEntity

	primaryFireRequestRemote = options.PrimaryFireRequest
	primaryShotRemote = options.PrimaryShot
	sprintForceOffRemote = options.SprintForceOff

	if not primaryFireRequestRemote or not primaryShotRemote or not sprintForceOffRemote then
		error("[WeaponService] Missing weapon remotes during initialization.")
	end

	primaryFireRequestRemote.OnServerEvent:Connect(handlePrimaryFireRequest)
	Players.PlayerRemoving:Connect(function(player)
		nextFireAtByPlayer[player] = nil
	end)
end

return WeaponService
