--!strict
-- IceShardSpecial System - Manual-cast special that fires toward cursor aim.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local AbilitySystemBase = require(script.Parent.Parent.AbilitySystemBase)
local TargetingService = require(script.Parent.Parent.TargetingService)
local PassiveEffectSystem = require(game.ServerScriptService.ECS.Systems.PassiveEffectSystem)
local Config = require(script.Parent.Config)
local Balance = Config

local AbilityCastRemote = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("AbilityCast")

local IceShardSpecialSystem = {}

local world: any
local Components: any
local DirtyService: any
local _ECSWorldService: any

-- Component references
local Position: any
local EntityType: any
local AbilityData: any
local AbilityCooldown: any
local AbilityPulse: any

local ICESHARD_SPECIAL_ID = "IceShardSpecial"
local ICESHARD_SPECIAL_NAME = Balance.Name
local CAST_REQUEST_REMOTE_NAME = "IceShardSpecialCastRequest"

local playerQuery: any
local castRequestConnection: RBXScriptConnection? = nil
local sprintForceOffRemote: RemoteEvent? = nil
local animationIdsBySourcePath: {[string]: {[string]: string}} = {}
local warnedMissingAnimationSource: {[string]: boolean} = {}
local pendingCastTokenByEntity: {[number]: number} = {}
local pendingCastTokenCounter = 0

local function normalizeAnimationId(rawId: any): string?
	if typeof(rawId) == "number" then
		if rawId <= 0 then
			return nil
		end
		return "rbxassetid://" .. tostring(math.floor(rawId))
	end
	if typeof(rawId) ~= "string" then
		return nil
	end

	local trimmed = string.gsub(rawId, "^%s*(.-)%s*$", "%1")
	if trimmed == "" then
		return nil
	end
	if string.find(trimmed, "rbxassetid://", 1, true) == 1 then
		return trimmed
	end
	local numeric = tonumber(trimmed)
	if numeric and numeric > 0 then
		return "rbxassetid://" .. tostring(math.floor(numeric))
	end
	return nil
end

local function resolveAnimationIdFromInstance(source: Instance?): string?
	if not source then
		return nil
	end
	if source:IsA("Animation") then
		return normalizeAnimationId(source.AnimationId)
	end
	if source:IsA("StringValue") then
		return normalizeAnimationId(source.Value)
	end
	if source:IsA("NumberValue") then
		return normalizeAnimationId(source.Value)
	end
	return nil
end

local function findInstanceByDotPath(path: string): Instance?
	if typeof(path) ~= "string" or path == "" then
		return nil
	end

	local parts = string.split(path, ".")
	local current: Instance? = game
	local startIndex = 1
	if parts[1] == "game" then
		startIndex = 2
	elseif parts[1] == "ServerStorage" then
		current = ServerStorage
		startIndex = 2
	elseif parts[1] == "ReplicatedStorage" then
		current = ReplicatedStorage
		startIndex = 2
	end

	for i = startIndex, #parts do
		if not current then
			return nil
		end
		current = current:FindFirstChild(parts[i])
	end
	return current
end

local function getAnimationSourceIds(sourcePath: string): {[string]: string}?
	local cached = animationIdsBySourcePath[sourcePath]
	if cached then
		return cached
	end

	local source = findInstanceByDotPath(sourcePath)
	if not source then
		if not warnedMissingAnimationSource[sourcePath] then
			warn(string.format("[IceShardSpecial] Animation source path not found: %s", sourcePath))
			warnedMissingAnimationSource[sourcePath] = true
		end
		return nil
	end

	local firstAnim: Animation? = nil
	local loopAnim: Animation? = nil
	local lastAnim: Animation? = nil
	local allAnimations: {Animation} = {}

	if source:IsA("Animation") then
		firstAnim = source
		allAnimations[1] = source
	end

	for _, desc in ipairs(source:GetDescendants()) do
		if desc:IsA("Animation") then
			local anim = desc :: Animation
			allAnimations[#allAnimations + 1] = anim
			local lowered = string.lower(anim.Name)
			if lowered == "first" or lowered == "start" then
				firstAnim = firstAnim or anim
			elseif lowered == "loop" or lowered == "middle" then
				loopAnim = loopAnim or anim
			elseif lowered == "last" or lowered == "end" then
				lastAnim = lastAnim or anim
			end
		end
	end

	table.sort(allAnimations, function(a: Animation, b: Animation)
		return a:GetFullName() < b:GetFullName()
	end)

	local fallbackFirst = resolveAnimationIdFromInstance(firstAnim or allAnimations[1])
	local fallbackLoop = resolveAnimationIdFromInstance(loopAnim or allAnimations[2]) or fallbackFirst
	local fallbackLast = resolveAnimationIdFromInstance(lastAnim or allAnimations[3]) or fallbackLoop or fallbackFirst

	if not fallbackFirst and not fallbackLoop and not fallbackLast then
		return nil
	end

	local resolved = {
		first = fallbackFirst or fallbackLoop or fallbackLast,
		loop = fallbackLoop or fallbackFirst or fallbackLast,
		last = fallbackLast or fallbackLoop or fallbackFirst,
	}
	animationIdsBySourcePath[sourcePath] = resolved
	return resolved
end

local function buildAnimationData(): any?
	if not Config.animations then
		return nil
	end

	local configuredIds = Config.animations.animationIds or {}
	local animationIds = {
		first = normalizeAnimationId(configuredIds.first),
		loop = normalizeAnimationId(configuredIds.loop),
		last = normalizeAnimationId(configuredIds.last),
	}

	local sourcePath = Config.animations.sourcePath
	if typeof(sourcePath) == "string" and sourcePath ~= "" then
		local sourceIds = getAnimationSourceIds(sourcePath)
		if sourceIds then
			animationIds.first = animationIds.first or sourceIds.first
			animationIds.loop = animationIds.loop or sourceIds.loop
			animationIds.last = animationIds.last or sourceIds.last
		end
	end

	if not animationIds.first and not animationIds.loop and not animationIds.last then
		return nil
	end

	return {
		animationIds = animationIds,
		loopFrame = Config.animations.loopFrame,
		totalFrames = Config.animations.totalFrames,
		duration = Config.animations.duration,
		animationPriority = Config.animations.animationPriority,
		anticipation = Config.animations.anticipation,
	}
end

local function buildExtraProjectileConfig(stats: any): any?
	local splitCount = math.max(math.floor((stats.splitCount or 0) + 0.0001), 0)
	local splitDamageMultiplier = stats.splitDamageMultiplier or 0
	local splitScaleMultiplier = stats.splitScaleMultiplier or 1
	local splitMaxSpreadDeg = stats.splitMaxSpreadDeg or 180

	local frostbiteStacks = math.max(math.floor((stats.frostbiteStacksPerHit or 0) + 0.0001), 0)
	local frostbiteDuration = stats.frostbiteDuration or 0
	local frostbiteDamageTakenPerStack = stats.frostbiteDamageTakenPerStack or 0

	local extraConfig = {}
	if splitCount > 0 and splitDamageMultiplier > 0 then
		extraConfig.splitOnHit = {
			count = splitCount,
			damageMultiplier = splitDamageMultiplier,
			procCoefficient = stats.splitProcCoefficient or stats.procCoefficient,
			scaleMultiplier = splitScaleMultiplier,
			maxSpreadDeg = splitMaxSpreadDeg,
			targetingAngle = stats.targetingAngle,
		}
	end

	if frostbiteStacks > 0 and frostbiteDuration > 0 and frostbiteDamageTakenPerStack > 0 then
		extraConfig.frostbiteOnHit = {
			statusId = "Frostbite",
			stacks = frostbiteStacks,
			duration = frostbiteDuration,
			damageTakenPerStack = frostbiteDamageTakenPerStack,
		}
	end

	if next(extraConfig) == nil then
		return nil
	end
	return extraConfig
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

local function getFallbackLookDirection(player: Player): Vector3
	local character = player.Character
	local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
	if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
		return (humanoidRootPart :: BasePart).CFrame.LookVector
	end
	return Vector3.new(0, 0, 1)
end

local function getManualAimDirection(stats: any, player: Player, origin: Vector3, targetPoint: Vector3): Vector3
	local direction = AbilitySystemBase.calculateTargetingDirection(
		origin,
		2,
		targetPoint,
		stats,
		stats.StayHorizontal,
		player,
		nil
	)
	if direction.Magnitude <= 0.0001 then
		local raw = targetPoint - origin
		if raw.Magnitude > 0.0001 then
			direction = raw.Unit
		else
			direction = getFallbackLookDirection(player)
		end
	end
	return direction.Unit
end

local function performIceShardSpecialBurst(
	playerEntity: number,
	player: Player,
	statsOverride: any?,
	targetPointOverride: Vector3?
): boolean
	local position = AbilitySystemBase.getPlayerPosition(playerEntity, player)
	if not position then
		return false
	end

	local stats = statsOverride or AbilitySystemBase.getAbilityStats(playerEntity, ICESHARD_SPECIAL_ID, Balance)
	local shots = math.max(stats.shotAmount or 1, 1)
	local totalSpread = math.min(math.abs(stats.targetingAngle or 0) * 2, math.rad(10))
	local step = shots > 1 and totalSpread / (shots - 1) or 0
	local offsets = buildSpreadOffsets(shots)

	local targetEntity: number? = nil
	local aimPoint: Vector3
	local baseDirection: Vector3
	if typeof(targetPointOverride) == "Vector3" then
		aimPoint = targetPointOverride
		baseDirection = getManualAimDirection(stats, player, position, aimPoint)
	else
		local targetingResult = TargetingService.acquireTarget({
			playerEntity = playerEntity,
			player = player,
			origin = position,
			maxRange = stats.targetingRange,
			mode = stats.targetingMode,
			stayHorizontal = stats.StayHorizontal,
			alwaysStayHorizontal = stats.AlwaysStayHorizontal,
			stickToPlayer = stats.StickToPlayer,
			enablePrediction = stats.enablePrediction,
			projectileSpeed = stats.projectileSpeed,
			duration = stats.duration,
			lockDuration = stats.targetLockDuration,
			reacquireDelay = stats.reacquireDelay,
			minTargetableAge = stats.minTargetableAge,
			fovAngle = stats.targetingFov,
			damage = stats.damage,
			abilityId = ICESHARD_SPECIAL_ID,
		})
		targetEntity = targetingResult.targetEntity
		baseDirection = targetingResult.direction
		aimPoint = targetingResult.aimPoint or (position + baseDirection * stats.targetingRange)
	end

	if baseDirection.Magnitude == 0 then
		baseDirection = getFallbackLookDirection(player)
	end
	baseDirection = baseDirection.Unit

	local targetDistance = AbilitySystemBase.getTargetDistance(
		position,
		aimPoint,
		stats.StayHorizontal,
		stats.AlwaysStayHorizontal,
		player
	)

	local created = 0
	for shotIndex = 1, shots do
		if targetEntity then
			TargetingService.recordPredictedDamage(playerEntity, ICESHARD_SPECIAL_ID, targetEntity, stats.damage)
		end

		local direction = baseDirection
		if shots > 1 then
			local offsetIndex = offsets[shotIndex] or 0
			local finalAngle = offsetIndex * step
			local cos = math.cos(finalAngle)
			local sin = math.sin(finalAngle)
			direction = Vector3.new(
				direction.X * cos - direction.Z * sin,
				direction.Y,
				direction.X * sin + direction.Z * cos
			)
		end
		if direction.Magnitude == 0 then
			direction = getFallbackLookDirection(player)
		end
		direction = direction.Unit

		local targetPoint: Vector3
		if targetDistance > 0 then
			targetPoint = position + direction * targetDistance
		else
			targetPoint = position + direction * (stats.projectileSpeed * stats.duration)
		end

		local projectileEntity = AbilitySystemBase.createProjectile(
			ICESHARD_SPECIAL_ID,
			stats,
			position,
			direction,
			player,
			targetPoint,
			playerEntity,
			buildExtraProjectileConfig(stats)
		)
		if projectileEntity then
			created += 1
		end
	end

	return created > 0
end

local function castIceShardSpecial(playerEntity: number, player: Player, targetPointOverride: Vector3?): (boolean, any)
	local stats = AbilitySystemBase.getAbilityStats(playerEntity, ICESHARD_SPECIAL_ID, Balance)

	TargetingService.startCastPrediction(playerEntity, ICESHARD_SPECIAL_ID)
	local success = performIceShardSpecialBurst(playerEntity, player, stats, targetPointOverride)

	if success and (stats.projectileCount or 1) > 1 then
		local interval = math.max(stats.pulseInterval or 0, 0.01)
		local pulseData = {
			ability = ICESHARD_SPECIAL_ID,
			remaining = (stats.projectileCount or 1) - 1,
			timer = interval,
			interval = interval,
			targetPoint = targetPointOverride,
		}
		DirtyService.setIfChanged(world, playerEntity, AbilityPulse, pulseData, "AbilityPulse")
	else
		TargetingService.endCastPrediction(playerEntity, ICESHARD_SPECIAL_ID)
	end

	return success, stats
end

local function findPlayerEntity(player: Player): number?
	if not playerQuery then
		return nil
	end
	for entity, entityType in playerQuery do
		if entityType.type == "Player" and entityType.player == player then
			return entity
		end
	end
	return nil
end

local function isAbilityEnabled(playerEntity: number): boolean
	local abilityData = world:get(playerEntity, AbilityData)
	return abilityData
		and abilityData.abilities
		and abilityData.abilities[ICESHARD_SPECIAL_ID]
		and abilityData.abilities[ICESHARD_SPECIAL_ID].enabled == true
end

local function stopSprintOnCastPress(playerEntity: number, player: Player)
	PassiveEffectSystem.setSprintIntent(playerEntity, false)
	if sprintForceOffRemote then
		sprintForceOffRemote:FireClient(player)
	end
end

local function tryCastFromRequest(player: Player, payload: any)
	if not world or not player or not player.Parent then
		return
	end
	if player:GetAttribute("CooldownsFrozen") then
		return
	end
	if not AbilitySystemBase.isPlayerAlive(player) then
		return
	end

	local playerEntity = findPlayerEntity(player)
	if not playerEntity then
		return
	end

	stopSprintOnCastPress(playerEntity, player)

	if pendingCastTokenByEntity[playerEntity] then
		return
	end
	if not isAbilityEnabled(playerEntity) then
		return
	end

	local pulseComponent = world:get(playerEntity, AbilityPulse)
	if pulseComponent and pulseComponent.ability == ICESHARD_SPECIAL_ID then
		return
	end

	local stats = AbilitySystemBase.getAbilityStats(playerEntity, ICESHARD_SPECIAL_ID, Balance)
	local cooldownData = world:get(playerEntity, AbilityCooldown)
	local cooldowns = cooldownData and cooldownData.cooldowns or {}
	local cooldown = cooldowns[ICESHARD_SPECIAL_ID] or { remaining = 0, max = stats.cooldown }
	if (cooldown.remaining or 0) > 0 then
		return
	end

	local targetPoint = nil
	if typeof(payload) == "table" and typeof(payload.targetPoint) == "Vector3" then
		targetPoint = payload.targetPoint
	end

	local windup = math.max(tonumber(stats.windup) or 0, 0)
	local function executeCastAfterWindup()
		if not world or not player or not player.Parent then
			return
		end
		if player:GetAttribute("CooldownsFrozen") then
			return
		end
		if not AbilitySystemBase.isPlayerAlive(player) then
			return
		end

		local currentEntity = findPlayerEntity(player)
		if currentEntity ~= playerEntity then
			return
		end
		if not isAbilityEnabled(playerEntity) then
			return
		end

		local livePulseComponent = world:get(playerEntity, AbilityPulse)
		if livePulseComponent and livePulseComponent.ability == ICESHARD_SPECIAL_ID then
			return
		end

		local liveStats = AbilitySystemBase.getAbilityStats(playerEntity, ICESHARD_SPECIAL_ID, Balance)
		local liveCooldownData = world:get(playerEntity, AbilityCooldown)
		local liveCooldowns = liveCooldownData and liveCooldownData.cooldowns or {}
		local liveCooldown = liveCooldowns[ICESHARD_SPECIAL_ID] or { remaining = 0, max = liveStats.cooldown }
		if (liveCooldown.remaining or 0) > 0 then
			return
		end

		local success, castStats = castIceShardSpecial(playerEntity, player, targetPoint)
		if not success then
			return
		end

		local damageStats = world:get(playerEntity, Components.AbilityDamageStats) or {}
		local animationData = buildAnimationData()

		AbilityCastRemote:FireClient(player, ICESHARD_SPECIAL_ID, castStats.cooldown, ICESHARD_SPECIAL_NAME, {
			projectileCount = castStats.projectileCount or 1,
			pulseInterval = castStats.pulseInterval or 0,
			damageStats = damageStats,
			animationData = animationData,
		})

		liveCooldowns[ICESHARD_SPECIAL_ID] = {
			remaining = castStats.cooldown,
			max = castStats.cooldown,
		}
		DirtyService.setIfChanged(world, playerEntity, AbilityCooldown, {
			cooldowns = liveCooldowns,
		}, "AbilityCooldown")
	end

	if windup <= 0 then
		executeCastAfterWindup()
		return
	end

	pendingCastTokenCounter += 1
	local castToken = pendingCastTokenCounter
	pendingCastTokenByEntity[playerEntity] = castToken
	task.delay(windup, function()
		if pendingCastTokenByEntity[playerEntity] ~= castToken then
			return
		end
		pendingCastTokenByEntity[playerEntity] = nil
		executeCastAfterWindup()
	end)
end

function IceShardSpecialSystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	_ECSWorldService = ecsWorldService

	AbilitySystemBase.init(worldRef, components, dirtyService, ecsWorldService)

	Position = Components.Position
	EntityType = Components.EntityType
	AbilityData = Components.AbilityData
	AbilityCooldown = Components.AbilityCooldown
	AbilityPulse = Components.AbilityPulse

	playerQuery = world:query(Components.EntityType, Components.Position, Components.Ability):cached()

	local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	local castRequestRemote = remotesFolder:FindFirstChild(CAST_REQUEST_REMOTE_NAME)
	if not castRequestRemote then
		castRequestRemote = Instance.new("RemoteEvent")
		castRequestRemote.Name = CAST_REQUEST_REMOTE_NAME
		castRequestRemote.Parent = remotesFolder
	end
	local weaponRemotesFolder = remotesFolder:FindFirstChild("Weapons")
	if weaponRemotesFolder and weaponRemotesFolder:IsA("Folder") then
		local sprintRemote = weaponRemotesFolder:FindFirstChild("SprintForceOff")
		if sprintRemote and sprintRemote:IsA("RemoteEvent") then
			sprintForceOffRemote = sprintRemote
		end
	end

	if castRequestConnection then
		castRequestConnection:Disconnect()
		castRequestConnection = nil
	end
	castRequestConnection = (castRequestRemote :: RemoteEvent).OnServerEvent:Connect(function(player: Player, payload: any)
		tryCastFromRequest(player, payload)
	end)
end

function IceShardSpecialSystem.step(dt: number)
	if not world then
		return
	end

	for entity, entityType in playerQuery do
		if entityType.type ~= "Player" or not entityType.player then
			continue
		end

		local player = entityType.player
		if not AbilitySystemBase.isPlayerAlive(player) then
			continue
		end
		if player:GetAttribute("CooldownsFrozen") then
			continue
		end
		if not isAbilityEnabled(entity) then
			continue
		end

		local pulseComponent = world:get(entity, AbilityPulse)
		if pulseComponent and pulseComponent.ability == ICESHARD_SPECIAL_ID then
			local stats = AbilitySystemBase.getAbilityStats(entity, ICESHARD_SPECIAL_ID, Balance)
			local interval = pulseComponent.interval or stats.pulseInterval or 0
			local timer = 0
			local remaining = pulseComponent.remaining or 0
			local targetPoint = if typeof(pulseComponent.targetPoint) == "Vector3" then pulseComponent.targetPoint else nil

			if interval <= 0 then
				while remaining > 0 do
					if performIceShardSpecialBurst(entity, player, stats, targetPoint) then
						remaining -= 1
					else
						remaining = 0
					end
				end
			else
				local actualInterval = math.max(interval, 0.01)
				timer = (pulseComponent.timer or actualInterval) - dt
				while remaining > 0 and timer <= 0 do
					if performIceShardSpecialBurst(entity, player, stats, targetPoint) then
						remaining -= 1
						timer += actualInterval
					else
						remaining = 0
					end
				end
				interval = actualInterval
			end

			if remaining <= 0 then
				world:remove(entity, AbilityPulse)
				TargetingService.endCastPrediction(entity, ICESHARD_SPECIAL_ID)
			else
				local newPulse = {
					ability = ICESHARD_SPECIAL_ID,
					timer = timer,
					remaining = remaining,
					interval = interval,
					targetPoint = targetPoint,
				}
				DirtyService.setIfChanged(world, entity, AbilityPulse, newPulse, "AbilityPulse")
			end
		end

		local stats = AbilitySystemBase.getAbilityStats(entity, ICESHARD_SPECIAL_ID, Balance)
		local cooldownData = world:get(entity, AbilityCooldown)
		local cooldowns = cooldownData and cooldownData.cooldowns or {}
		local cooldown = cooldowns[ICESHARD_SPECIAL_ID] or { remaining = 0, max = stats.cooldown }
		local currentRemaining = cooldown.remaining or 0
		local currentMax = cooldown.max or stats.cooldown

		if currentRemaining > 0 then
			cooldowns[ICESHARD_SPECIAL_ID] = {
				remaining = math.max(currentRemaining - dt, 0),
				max = currentMax,
			}
			DirtyService.setIfChanged(world, entity, AbilityCooldown, {
				cooldowns = cooldowns,
			}, "AbilityCooldown")
		elseif currentMax ~= stats.cooldown then
			cooldowns[ICESHARD_SPECIAL_ID] = {
				remaining = 0,
				max = stats.cooldown,
			}
			DirtyService.setIfChanged(world, entity, AbilityCooldown, {
				cooldowns = cooldowns,
			}, "AbilityCooldown")
		end
	end
end

return IceShardSpecialSystem
