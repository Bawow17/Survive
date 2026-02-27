--!strict
-- UltimateSystem - Server-authoritative ultimate charge + cast orchestration.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameStateManager = require(script.Parent.GameStateManager)
local PassiveEffectSystem = require(script.Parent.PassiveEffectSystem)
local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)

local UltimateSystem = {}
local TemporalStasisSystem: any

local world: any
local Components: any
local _DirtyService: any

local PlayerStats: any
local PlayerPauseState: any
local Health: any
local AbilityDamageStats: any

local playerQuery: any

local MAX_CHARGE = 10000
local CHARGE_PER_SECOND = 83
local CHARGE_PER_KILL = 100
local ULTIMATE_ID = "TempusGelidum"
local ULTIMATE_NAME = "Tempus Gelidum"

local INPUT_LOCK_ATTRIBUTE = "UltimateInputLocked"
local COOLDOWNS_FROZEN_ATTRIBUTE = "CooldownsFrozen"
local WEAPON_M2_CAST_ACTIVE_ATTRIBUTE = "WeaponM2CastActiveServer"
local UTILITY_CAST_ACTIVE_ATTRIBUTE = "UtilityCastActiveServer"

local FRAME_22_TIME = 22 / 60
local FRAME_30_TIME = 30 / 60
local FRAME_65_TIME = 65 / 60
local GROWTH_DURATION = (65 - 22) / 60
local BUBBLE_HOLD_DURATION = 7.0
local BUBBLE_FADE_DURATION = 2.0
local BUBBLE_TARGET_SIZE = Vector3.new(150, 150, 150)
local TIME_STOP_RADIUS = 70

local STATE_SEND_INTERVAL = 0.1
local STATE_CHARGE_EPSILON = 0.5

local ANIMATION_SOURCE_PATH = "ServerStorage.ContentDrawer.PlayerAbilities.Ice.Ultimate.TempusGelidum.TempusGelidum"
local BUBBLE_SOURCE_PATH = "ServerStorage.ContentDrawer.PlayerAbilities.Ice.Ultimate.TempusGelidum.Bubble"
local BUBBLE2_SOURCE_PATH = "ServerStorage.ContentDrawer.PlayerAbilities.Ice.Ultimate.TempusGelidum.Bubble2"

local abilityCastRemote: RemoteEvent? = nil
local sprintForceOffRemote: RemoteEvent? = nil
local ultimateCastRequestRemote: RemoteEvent? = nil
local ultimateStateUpdateRemote: RemoteEvent? = nil

local chargeByEntity: {[number]: number} = {}
local syncStateByEntity: {[number]: {
	lastCharge: number?,
	lastReady: boolean?,
	nextSendAt: number,
}} = {}
local castStateByEntity: {[number]: {
	token: number,
	player: Player,
	hadCooldownsFrozen: boolean,
}} = {}
local castTokenCounter = 0

local animationIdsCache: {[string]: string}? = nil
local warnedMissingAnimationSource = false
local warnedMissingBubbleSource = false
local warnedMissingBubble2Source = false
local resolvedAnimationSourceCache: Instance? = nil
local resolvedBubbleSourceCache: Instance? = nil
local resolvedBubble2SourceCache: Instance? = nil

local ULTIMATE_ROOT_PATH = "ServerStorage.ContentDrawer.PlayerAbilities.Ice.Ultimate.TempusGelidum"
local ULTIMATE_REPLICATED_ROOT_PATH = "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Ultimate.TempusGelidum"

local replicatedAnimationSourcePath: string? = nil
local replicatedBubbleSourcePath: string? = nil
local replicatedBubble2SourcePath: string? = nil
local warnedAnimationReplicationFailure = false
local warnedBubbleReplicationFailure = false
local warnedBubble2ReplicationFailure = false
local lastRejectLogAtByUserId: {[number]: number} = {}

local function logReject(player: Player, reason: string)
	local userId = player.UserId
	local now = tick()
	local last = lastRejectLogAtByUserId[userId] or 0
	if now - last < 0.25 then
		return
	end
	lastRejectLogAtByUserId[userId] = now
	warn(string.format("[UltimateSystem] Cast rejected for %s (%d): %s", player.Name, userId, reason))
end

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
	if string.match(trimmed, "^%d+$") then
		return "rbxassetid://" .. trimmed
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
	if parts[1] == "ServerStorage" then
		current = ServerStorage
		startIndex = 2
	elseif parts[1] == "ReplicatedStorage" then
		current = ReplicatedStorage
		startIndex = 2
	elseif parts[1] == "Workspace" then
		current = Workspace
		startIndex = 2
	elseif parts[1] == "game" then
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

local function findFirstDescendantByName(root: Instance, expectedName: string): Instance?
	if expectedName == "" then
		return nil
	end

	for _, desc in ipairs(root:GetDescendants()) do
		if desc.Name == expectedName then
			return desc
		end
	end

	local loweredExpected = string.lower(expectedName)
	for _, desc in ipairs(root:GetDescendants()) do
		if string.lower(desc.Name) == loweredExpected then
			return desc
		end
	end

	return nil
end

local function extractLeafName(path: string): string
	local parts = string.split(path, ".")
	return parts[#parts] or ""
end

local function getServerRelativePath(dotPath: string): string?
	if typeof(dotPath) ~= "string" or dotPath == "" then
		return nil
	end

	local normalized = dotPath
	if string.find(normalized, "game.", 1, true) == 1 then
		normalized = string.sub(normalized, #"game." + 1)
	end
	if string.find(normalized, "ServerStorage.", 1, true) == 1 then
		return string.sub(normalized, #"ServerStorage." + 1)
	end
	return nil
end

local function getReplicatedDotPathFromServerDotPath(serverDotPath: string): string?
	local serverRelative = getServerRelativePath(serverDotPath)
	if not serverRelative then
		return nil
	end
	return "ReplicatedStorage." .. serverRelative
end

local function replicateSourceToReplicatedStorage(serverDotPath: string, warnOnFailure: boolean): string?
	local relativePath = getServerRelativePath(serverDotPath)
	if not relativePath then
		return nil
	end

	local parts = string.split(relativePath, ".")
	if #parts == 0 then
		return nil
	end

	local replicatedParentPath = if #parts > 1 then table.concat(parts, ".", 1, #parts - 1) else ""
	local success, _ = ModelReplicationService.replicateModel(relativePath, replicatedParentPath)
	if not success then
		if warnOnFailure then
			warn(string.format("[UltimateSystem] Failed to replicate source: %s", serverDotPath))
		end
		return nil
	end

	return "ReplicatedStorage." .. relativePath
end

local function ensureUltimateAssetsReplicated()
	if not replicatedAnimationSourcePath then
		replicatedAnimationSourcePath = replicateSourceToReplicatedStorage(
			ANIMATION_SOURCE_PATH,
			not warnedAnimationReplicationFailure
		)
		if not replicatedAnimationSourcePath then
			warnedAnimationReplicationFailure = true
		end
	end

	if not replicatedBubbleSourcePath then
		replicatedBubbleSourcePath = replicateSourceToReplicatedStorage(
			BUBBLE_SOURCE_PATH,
			not warnedBubbleReplicationFailure
		)
		if not replicatedBubbleSourcePath then
			warnedBubbleReplicationFailure = true
		end
	end

	if not replicatedBubble2SourcePath then
		replicatedBubble2SourcePath = replicateSourceToReplicatedStorage(
			BUBBLE2_SOURCE_PATH,
			not warnedBubble2ReplicationFailure
		)
		if not replicatedBubble2SourcePath then
			warnedBubble2ReplicationFailure = true
		end
	end
end

local function resolveSourceWithFallback(path: string, fallbackRootPath: string): Instance?
	local direct = findInstanceByDotPath(path)
	if direct then
		return direct
	end

	local root = findInstanceByDotPath(fallbackRootPath)
	if root then
		local leafName = extractLeafName(path)
		local fromRoot = findFirstDescendantByName(root, leafName)
		if fromRoot then
			return fromRoot
		end
	end

	local serverFallback = findFirstDescendantByName(ServerStorage, extractLeafName(path))
	if serverFallback then
		return serverFallback
	end

	local replicatedFallback = findFirstDescendantByName(ReplicatedStorage, extractLeafName(path))
	if replicatedFallback then
		return replicatedFallback
	end

	return nil
end

local function classifyAnimationSlot(name: string): string?
	local lowered = string.lower(name)
	if lowered == "first" or lowered == "start" then
		return "first"
	end
	if lowered == "loop" or lowered == "middle" then
		return "loop"
	end
	if lowered == "last" or lowered == "end" then
		return "last"
	end
	return nil
end

local function getAnimationIdsFromSourcePath(sourcePath: string): {[string]: string}?
	if animationIdsCache then
		return animationIdsCache
	end

	ensureUltimateAssetsReplicated()

	local source = resolvedAnimationSourceCache
	if source and not source.Parent then
		source = nil
		resolvedAnimationSourceCache = nil
	end
	if not source then
		source = resolveSourceWithFallback(sourcePath, ULTIMATE_ROOT_PATH)
	end
	if not source and replicatedAnimationSourcePath then
		source = resolveSourceWithFallback(replicatedAnimationSourcePath, ULTIMATE_REPLICATED_ROOT_PATH)
	end
	if not source then
		local replicatedMirrorPath = getReplicatedDotPathFromServerDotPath(sourcePath)
		if replicatedMirrorPath then
			source = resolveSourceWithFallback(replicatedMirrorPath, ULTIMATE_REPLICATED_ROOT_PATH)
		end
	end
	if source then
		resolvedAnimationSourceCache = source
	end
	if not source then
		if not warnedMissingAnimationSource then
			warn(string.format("[UltimateSystem] Animation source path not found: %s", sourcePath))
			warnedMissingAnimationSource = true
		end
		return nil
	end

	local firstAnimSource: Instance? = nil
	local loopAnimSource: Instance? = nil
	local lastAnimSource: Instance? = nil
	local allAnimSources: {Instance} = {}

	local function addSourceCandidate(candidate: Instance)
		if not (candidate:IsA("Animation") or candidate:IsA("StringValue") or candidate:IsA("NumberValue")) then
			return
		end
		table.insert(allAnimSources, candidate)

		local slot = classifyAnimationSlot(candidate.Name)
		if slot == "first" then
			firstAnimSource = firstAnimSource or candidate
		elseif slot == "loop" then
			loopAnimSource = loopAnimSource or candidate
		elseif slot == "last" then
			lastAnimSource = lastAnimSource or candidate
		end
	end

	addSourceCandidate(source)
	for _, desc in ipairs(source:GetDescendants()) do
		if desc:IsA("Animation") or desc:IsA("StringValue") or desc:IsA("NumberValue") then
			addSourceCandidate(desc)
		end
	end

	table.sort(allAnimSources, function(a: Instance, b: Instance)
		return a:GetFullName() < b:GetFullName()
	end)

	local fallbackFirst = resolveAnimationIdFromInstance(firstAnimSource or allAnimSources[1])
	local fallbackLoop = resolveAnimationIdFromInstance(loopAnimSource or allAnimSources[2]) or fallbackFirst
	local fallbackLast = resolveAnimationIdFromInstance(lastAnimSource or allAnimSources[3]) or fallbackLoop or fallbackFirst

	if not fallbackFirst and not fallbackLoop and not fallbackLast then
		if not warnedMissingAnimationSource then
			warn(string.format("[UltimateSystem] No valid animation IDs found under source: %s", source:GetFullName()))
			warnedMissingAnimationSource = true
		end
		return nil
	end

	animationIdsCache = {
		first = fallbackFirst or fallbackLoop or fallbackLast,
		loop = fallbackLoop or fallbackFirst or fallbackLast,
		last = fallbackLast or fallbackLoop or fallbackFirst,
	}
	return animationIdsCache
end

local function buildCastAnimationData(): any?
	local animationIds = getAnimationIdsFromSourcePath(ANIMATION_SOURCE_PATH)
	local replicatedPath = replicatedAnimationSourcePath
		or getReplicatedDotPathFromServerDotPath(ANIMATION_SOURCE_PATH)
		or ANIMATION_SOURCE_PATH

	return {
		animationIds = animationIds or {},
		sourcePath = replicatedPath,
		loopFrame = 65,
		totalFrames = 65,
		duration = FRAME_65_TIME,
		animationPriority = Enum.AnimationPriority.Action4,
		anticipation = 0,
	}
end

local function clampCharge(value: number): number
	return math.clamp(value, 0, MAX_CHARGE)
end

local function getPlayerFromEntity(playerEntity: number): Player?
	if not world or not PlayerStats then
		return nil
	end
	local stats = world:get(playerEntity, PlayerStats)
	if stats and stats.player then
		return stats.player
	end
	return nil
end

local function isEntityAlive(playerEntity: number, player: Player): boolean
	if not world or not world:contains(playerEntity) then
		return false
	end

	local pauseState = PlayerPauseState and world:get(playerEntity, PlayerPauseState)
	if pauseState and pauseState.pauseReason == "death" then
		return false
	end

	local health = Health and world:get(playerEntity, Health)
	if health and health.current and health.current <= 0.01 then
		return false
	end

	local character = player.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0.01 then
		return false
	end

	return true
end

local function getCharge(playerEntity: number): number
	return chargeByEntity[playerEntity] or 0
end

local function setCharge(playerEntity: number, charge: number): number
	local clamped = clampCharge(charge)
	chargeByEntity[playerEntity] = clamped
	return clamped
end

local function sendStateToPlayer(playerEntity: number, player: Player, force: boolean?)
	if not ultimateStateUpdateRemote then
		return
	end

	local now = tick()
	local state = syncStateByEntity[playerEntity]
	if not state then
		state = {
			lastCharge = nil,
			lastReady = nil,
			nextSendAt = 0,
		}
		syncStateByEntity[playerEntity] = state
	end

	local charge = getCharge(playerEntity)
	local ready = charge >= MAX_CHARGE
	local changed = state.lastCharge == nil
		or math.abs((state.lastCharge :: number) - charge) >= STATE_CHARGE_EPSILON
		or state.lastReady ~= ready
	if not force then
		if not changed then
			return
		end
		if now < state.nextSendAt then
			return
		end
	end

	ultimateStateUpdateRemote:FireClient(player, {
		charge = charge,
		maxCharge = MAX_CHARGE,
		ready = ready,
		ultimateId = ULTIMATE_ID,
	})

	state.lastCharge = charge
	state.lastReady = ready
	state.nextSendAt = now + STATE_SEND_INTERVAL
end

local function getBubbleSpawnPosition(player: Player): Vector3?
	local character = player.Character
	if not character then
		return nil
	end

	local torso = character:FindFirstChild("Torso")
	if not torso then
		torso = character:FindFirstChild("UpperTorso")
	end
	if not torso then
		torso = character:FindFirstChild("HumanoidRootPart")
	end
	if torso and torso:IsA("BasePart") then
		return (torso :: BasePart).Position + Vector3.new(0, -2.5, 0)
	end
	return nil
end

local function collectBubbleParts(instance: Instance): {BasePart}
	local parts = {}
	if instance:IsA("BasePart") then
		table.insert(parts, instance)
		return parts
	end
	for _, desc in ipairs(instance:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	return parts
end

local function setBubblePhysics(parts: {BasePart})
	for _, part in ipairs(parts) do
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Massless = true
	end
end

local function sexticOut(t: number): number
	local inv = 1 - t
	return 1 - (inv * inv * inv * inv * inv * inv)
end

local function quadIn(t: number): number
	return t * t
end

local function resolveBubbleSource(
	sourcePath: string,
	replicatedPath: string?,
	cachedSource: Instance?
): Instance?
	local source = cachedSource
	if source and not source.Parent then
		source = nil
	end
	if not source then
		source = resolveSourceWithFallback(sourcePath, ULTIMATE_ROOT_PATH)
	end
	if not source and replicatedPath then
		source = resolveSourceWithFallback(replicatedPath, ULTIMATE_REPLICATED_ROOT_PATH)
	end
	if not source then
		local replicatedMirrorPath = getReplicatedDotPathFromServerDotPath(sourcePath)
		if replicatedMirrorPath then
			source = resolveSourceWithFallback(replicatedMirrorPath, ULTIMATE_REPLICATED_ROOT_PATH)
		end
	end
	return source
end

local function animateBubbleFromSource(source: Instance, position: Vector3, spawnTransparency: number, fallbackNamePrefix: string)
	local bubble = source:Clone()
	bubble.Parent = Workspace

	if bubble:IsA("Model") then
		(bubble :: Model):PivotTo(CFrame.new(position))
	elseif bubble:IsA("BasePart") then
		(bubble :: BasePart).CFrame = CFrame.new(position)
	else
		local basePart = bubble:FindFirstChildWhichIsA("BasePart", true)
		if basePart then
			if bubble:IsA("PVInstance") then
				(bubble :: PVInstance):PivotTo(CFrame.new(position))
			else
				basePart.CFrame = CFrame.new(position)
			end
		end
	end

	local parts = collectBubbleParts(bubble)
	if #parts == 0 then
		bubble:Destroy()
		local fallbackPart = Instance.new("Part")
		fallbackPart.Name = fallbackNamePrefix .. "VFXFallback"
		fallbackPart.Shape = Enum.PartType.Ball
		fallbackPart.Material = Enum.Material.ForceField
		fallbackPart.Color = Color3.fromRGB(170, 225, 255)
		fallbackPart.Size = Vector3.new(1, 1, 1)
		fallbackPart.CFrame = CFrame.new(position)
		fallbackPart.Anchored = true
		fallbackPart.CanCollide = false
		fallbackPart.CanTouch = false
		fallbackPart.CanQuery = false
		fallbackPart.Parent = Workspace
		bubble = fallbackPart
		parts = { fallbackPart }
	end

	setBubblePhysics(parts)

	for _, desc in ipairs(bubble:GetDescendants()) do
		if desc:IsA("ParticleEmitter") then
			desc.Enabled = true
			if desc.Rate <= 0 then
				pcall(function()
					desc:Emit(40)
				end)
			end
		elseif desc:IsA("Trail") then
			desc.Enabled = true
		elseif desc:IsA("Beam") then
			desc.Enabled = true
		end
	end

	local baseSizes: {[BasePart]: Vector3} = {}
	local baseTransparency: {[BasePart]: number} = {}
	for _, part in ipairs(parts) do
		baseSizes[part] = part.Size
		part.Transparency = spawnTransparency
		baseTransparency[part] = spawnTransparency
	end

	local rootPart = parts[1]
	local rootBaseSize = baseSizes[rootPart]
	local targetScale = Vector3.new(
		if rootBaseSize.X > 0 then BUBBLE_TARGET_SIZE.X / rootBaseSize.X else 1,
		if rootBaseSize.Y > 0 then BUBBLE_TARGET_SIZE.Y / rootBaseSize.Y else 1,
		if rootBaseSize.Z > 0 then BUBBLE_TARGET_SIZE.Z / rootBaseSize.Z else 1
	)
	local startPivot = if bubble:IsA("PVInstance") then (bubble :: PVInstance):GetPivot() else CFrame.new(position)
	local relativeCFrames: {[BasePart]: CFrame} = {}
	for _, part in ipairs(parts) do
		relativeCFrames[part] = startPivot:ToObjectSpace(part.CFrame)
	end

	local function applyScale(alpha: number)
		local scale = Vector3.new(
			1 + ((targetScale.X - 1) * alpha),
			1 + ((targetScale.Y - 1) * alpha),
			1 + ((targetScale.Z - 1) * alpha)
		)

		for _, part in ipairs(parts) do
			if not part.Parent then
				continue
			end
			local baseSize = baseSizes[part]
			if baseSize then
				part.Size = Vector3.new(
					baseSize.X * scale.X,
					baseSize.Y * scale.Y,
					baseSize.Z * scale.Z
				)
			end

			local relative = relativeCFrames[part]
			if relative then
				local relativePos = relative.Position
				local rotation = relative - relativePos
				local scaledPos = Vector3.new(
					relativePos.X * scale.X,
					relativePos.Y * scale.Y,
					relativePos.Z * scale.Z
				)
				part.CFrame = startPivot * CFrame.new(scaledPos) * rotation
			end
		end
	end

	local function runTween(duration: number, fn: (number) -> ())
		if duration <= 0 then
			fn(1)
			return
		end
		local startedAt = tick()
		while bubble.Parent do
			local elapsed = tick() - startedAt
			local t = math.clamp(elapsed / duration, 0, 1)
			fn(t)
			if t >= 1 then
				return
			end
			RunService.Heartbeat:Wait()
		end
	end

	task.spawn(function()
		runTween(GROWTH_DURATION, function(t: number)
			applyScale(sexticOut(t))
		end)

		if not bubble.Parent then
			return
		end

		task.wait(BUBBLE_HOLD_DURATION)
		if not bubble.Parent then
			return
		end

		runTween(BUBBLE_FADE_DURATION, function(t: number)
			local fadeAlpha = quadIn(t)
			for _, part in ipairs(parts) do
				if not part.Parent then
					continue
				end
				local base = baseTransparency[part] or 0
				part.Transparency = base + ((1 - base) * fadeAlpha)
			end
		end)

		if bubble.Parent then
			bubble:Destroy()
		end
	end)
end

local function spawnBubbleAt(position: Vector3)
	ensureUltimateAssetsReplicated()

	local bubble1Source = resolveBubbleSource(BUBBLE_SOURCE_PATH, replicatedBubbleSourcePath, resolvedBubbleSourceCache)
	resolvedBubbleSourceCache = bubble1Source
	if bubble1Source then
		animateBubbleFromSource(bubble1Source, position, 0.5, "TempusGelidumBubble")
	elseif not warnedMissingBubbleSource then
		warn(string.format("[UltimateSystem] Bubble source path not found: %s", BUBBLE_SOURCE_PATH))
		warnedMissingBubbleSource = true
	end

	local bubble2Source = resolveBubbleSource(BUBBLE2_SOURCE_PATH, replicatedBubble2SourcePath, resolvedBubble2SourceCache)
	resolvedBubble2SourceCache = bubble2Source
	if bubble2Source then
		animateBubbleFromSource(bubble2Source, position, 0.0, "TempusGelidumBubble2")
	elseif not warnedMissingBubble2Source then
		warn(string.format("[UltimateSystem] Bubble2 source path not found: %s", BUBBLE2_SOURCE_PATH))
		warnedMissingBubble2Source = true
	end
end

local function clearCastLock(playerEntity: number, expectedToken: number?)
	local castState = castStateByEntity[playerEntity]
	if not castState then
		return
	end
	if expectedToken and castState.token ~= expectedToken then
		return
	end

	castStateByEntity[playerEntity] = nil

	local player = castState.player
	if not player or not player.Parent then
		return
	end

	player:SetAttribute(INPUT_LOCK_ATTRIBUTE, false)

	local pauseState = PlayerPauseState and world and world:get(playerEntity, PlayerPauseState)
	if pauseState and pauseState.isPaused then
		return
	end

	player:SetAttribute(COOLDOWNS_FROZEN_ATTRIBUTE, castState.hadCooldownsFrozen == true)
end

local function playCastAnimation(playerEntity: number, player: Player)
	local remote = abilityCastRemote
	if not remote then
		warn("[UltimateSystem] AbilityCast remote unavailable for ultimate cast")
		return
	end

	local animationData = buildCastAnimationData()
	if not animationData then
		warn("[UltimateSystem] Failed to build animation data for ultimate cast")
	end
	local castData = {
		projectileCount = 1,
		pulseInterval = 0,
		damageStats = if AbilityDamageStats then (world:get(playerEntity, AbilityDamageStats) or {}) else {},
		animationData = animationData,
	}
	-- Important: do not send 0 cooldown; client animation controller treats that as "instant segment"
	-- and can stop the track immediately.
	remote:FireClient(player, ULTIMATE_ID, FRAME_65_TIME, ULTIMATE_NAME, castData)
end

local function beginCast(playerEntity: number, player: Player)
	castTokenCounter += 1
	local castToken = castTokenCounter
	local castStartedAt = tick()

	local hadCooldownsFrozen = player:GetAttribute(COOLDOWNS_FROZEN_ATTRIBUTE) == true
	castStateByEntity[playerEntity] = {
		token = castToken,
		player = player,
		hadCooldownsFrozen = hadCooldownsFrozen,
	}

	player:SetAttribute(INPUT_LOCK_ATTRIBUTE, true)
	player:SetAttribute(COOLDOWNS_FROZEN_ATTRIBUTE, true)

	local animationOk, animationErr = pcall(function()
		playCastAnimation(playerEntity, player)
	end)
	if not animationOk then
		warn(string.format("[UltimateSystem] playCastAnimation failed: %s", tostring(animationErr)))
	end

	task.delay(FRAME_22_TIME, function()
		local bubblePosition = getBubbleSpawnPosition(player)
		if bubblePosition then
			local bubbleOk, bubbleErr = pcall(function()
				spawnBubbleAt(bubblePosition)
			end)
			if not bubbleOk then
				warn(string.format("[UltimateSystem] spawnBubbleAt failed: %s", tostring(bubbleErr)))
			end
		else
			warn("[UltimateSystem] Bubble spawn skipped: no torso/upperTorso/rootPart position")
		end
	end)

	task.delay(FRAME_30_TIME, function()
		if not TemporalStasisSystem or not TemporalStasisSystem.beginField then
			return
		end
		local bubblePosition = getBubbleSpawnPosition(player)
		if not bubblePosition then
			return
		end
		local ok, err = pcall(function()
			TemporalStasisSystem.beginField(
				playerEntity,
				bubblePosition,
				TIME_STOP_RADIUS,
				castStartedAt + FRAME_30_TIME,
				castStartedAt + FRAME_65_TIME + BUBBLE_HOLD_DURATION + BUBBLE_FADE_DURATION
			)
		end)
		if not ok then
			warn(string.format("[UltimateSystem] beginField failed: %s", tostring(err)))
		end
	end)

	task.delay(FRAME_65_TIME, function()
		clearCastLock(playerEntity, castToken)
	end)
end

local function stopSprint(playerEntity: number, player: Player)
	if PassiveEffectSystem.setSprintIntent then
		PassiveEffectSystem.setSprintIntent(playerEntity, false)
	end
	if sprintForceOffRemote then
		sprintForceOffRemote:FireClient(player)
	end
end

local function cleanupStaleEntityState()
	for playerEntity in pairs(chargeByEntity) do
		if not world or not world:contains(playerEntity) then
			chargeByEntity[playerEntity] = nil
			syncStateByEntity[playerEntity] = nil
		end
	end
	for playerEntity, castState in pairs(castStateByEntity) do
		if not world or not world:contains(playerEntity) then
			local player = castState.player
			if player and player.Parent then
				player:SetAttribute(INPUT_LOCK_ATTRIBUTE, false)
				player:SetAttribute(COOLDOWNS_FROZEN_ATTRIBUTE, castState.hadCooldownsFrozen == true)
			end
			castStateByEntity[playerEntity] = nil
		end
	end
end

local function ensurePlayerStateInitialized(playerEntity: number, player: Player)
	if chargeByEntity[playerEntity] == nil then
		chargeByEntity[playerEntity] = 0
	end
	if syncStateByEntity[playerEntity] == nil then
		syncStateByEntity[playerEntity] = {
			lastCharge = nil,
			lastReady = nil,
			nextSendAt = 0,
		}
	end
	if player:GetAttribute(INPUT_LOCK_ATTRIBUTE) == nil then
		player:SetAttribute(INPUT_LOCK_ATTRIBUTE, false)
	end
end

local function shouldGainPassiveCharge(playerEntity: number, player: Player): boolean
	if not GameStateManager.isPlayerInGame(player) then
		return false
	end
	if not isEntityAlive(playerEntity, player) then
		return false
	end
	return true
end

local function handleCastRequest(player: Player, _payload: any)
	if not world or not playerQuery then
		logReject(player, "system not ready")
		return
	end

	local playerEntity: number? = nil
	for entity, stats in playerQuery do
		if stats and stats.player == player then
			playerEntity = entity
			break
		end
	end
	if not playerEntity then
		logReject(player, "player entity not found")
		return
	end

	local castEntity = playerEntity :: number
	if castStateByEntity[castEntity] then
		logReject(player, "already casting")
		return
	end
	if not GameStateManager.isPlayerInGame(player) then
		logReject(player, "player not in active run")
		return
	end
	if not isEntityAlive(castEntity, player) then
		logReject(player, "player not alive")
		return
	end
	if player:GetAttribute(COOLDOWNS_FROZEN_ATTRIBUTE) == true then
		logReject(player, "blocked: cooldowns frozen")
		return
	end
	if player:GetAttribute(WEAPON_M2_CAST_ACTIVE_ATTRIBUTE) == true then
		logReject(player, "blocked: weapon m2 cast active")
		return
	end
	if player:GetAttribute(UTILITY_CAST_ACTIVE_ATTRIBUTE) == true then
		logReject(player, "blocked: utility cast active")
		return
	end
	if getCharge(castEntity) < MAX_CHARGE then
		logReject(player, string.format("insufficient charge (%.1f / %d)", getCharge(castEntity), MAX_CHARGE))
		return
	end

	setCharge(castEntity, 0)
	sendStateToPlayer(castEntity, player, true)
	warn(string.format("[UltimateSystem] Cast accepted for %s (%d)", player.Name, player.UserId))

	stopSprint(castEntity, player)
	beginCast(castEntity, player)
end

function UltimateSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	_DirtyService = dirtyService

	PlayerStats = Components.PlayerStats
	PlayerPauseState = Components.PlayerPauseState
	Health = Components.Health
	AbilityDamageStats = Components.AbilityDamageStats

	playerQuery = world:query(PlayerStats):cached()

	local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	ultimateCastRequestRemote = ensureRemoteEvent(remotesFolder, "UltimateCastRequest")
	ultimateStateUpdateRemote = ensureRemoteEvent(remotesFolder, "UltimateStateUpdate")
	abilityCastRemote = ensureRemoteEvent(remotesFolder, "AbilityCast")
	ensureUltimateAssetsReplicated()

	local weaponsFolder = remotesFolder:FindFirstChild("Weapons")
	if weaponsFolder and weaponsFolder:IsA("Folder") then
		local sprintRemote = weaponsFolder:FindFirstChild("SprintForceOff")
		if sprintRemote and sprintRemote:IsA("RemoteEvent") then
			sprintForceOffRemote = sprintRemote
		end
	end

	ultimateCastRequestRemote.OnServerEvent:Connect(function(player: Player, payload: any)
		handleCastRequest(player, payload)
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		player:SetAttribute(INPUT_LOCK_ATTRIBUTE, false)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		player:SetAttribute(INPUT_LOCK_ATTRIBUTE, false)
	end
end

function UltimateSystem.setTemporalStasisSystem(temporalStasisSystem: any)
	TemporalStasisSystem = temporalStasisSystem
end

function UltimateSystem.step(dt: number)
	if not world or not playerQuery then
		return
	end

	cleanupStaleEntityState()

	for playerEntity, stats in playerQuery do
		if not stats or not stats.player then
			continue
		end
		local player = stats.player :: Player
		if not player.Parent then
			continue
		end

		ensurePlayerStateInitialized(playerEntity, player)

		local oldCharge = getCharge(playerEntity)
		local newCharge = oldCharge
		if shouldGainPassiveCharge(playerEntity, player) then
			newCharge = setCharge(playerEntity, oldCharge + (CHARGE_PER_SECOND * dt))
		end

		local reachedReady = oldCharge < MAX_CHARGE and newCharge >= MAX_CHARGE
		sendStateToPlayer(playerEntity, player, reachedReady)
	end
end

function UltimateSystem.onEnemyKilledByPlayer(playerEntity: number)
	if not world or not world:contains(playerEntity) then
		return
	end
	local player = getPlayerFromEntity(playerEntity)
	if not player or not player.Parent then
		return
	end
	if not GameStateManager.isPlayerInGame(player) then
		return
	end

	local oldCharge = getCharge(playerEntity)
	local newCharge = setCharge(playerEntity, oldCharge + CHARGE_PER_KILL)
	local reachedReady = oldCharge < MAX_CHARGE and newCharge >= MAX_CHARGE
	sendStateToPlayer(playerEntity, player, reachedReady)
end

function UltimateSystem.debugSetMaxCharge(playerEntity: number): boolean
	if not world or not world:contains(playerEntity) then
		return false
	end
	local player = getPlayerFromEntity(playerEntity)
	if not player or not player.Parent then
		return false
	end

	setCharge(playerEntity, MAX_CHARGE)
	sendStateToPlayer(playerEntity, player, true)
	return true
end

return UltimateSystem
