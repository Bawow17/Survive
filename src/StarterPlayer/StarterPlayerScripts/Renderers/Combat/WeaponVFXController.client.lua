--!strict
-- WeaponVFXController - renders replicated Oathkeeper weapon muzzle/tracer/impact VFX.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local weaponRemotesFolder = remotesFolder:WaitForChild("Weapons")
local timeStopStateRemote = remotesFolder:WaitForChild("TimeStopState")
local primaryShotRemote = weaponRemotesFolder:WaitForChild("PrimaryShot")
local secondaryShotRemote = weaponRemotesFolder:WaitForChild("SecondaryShot")
local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
if not playerScripts then
	playerScripts = localPlayer:WaitForChild("PlayerScripts", 10)
end
local scriptsContainer = playerScripts or script:FindFirstAncestor("StarterPlayerScripts")
if not scriptsContainer then
	warn("[WeaponVFXController] Could not locate StarterPlayerScripts ancestor")
	return
end
local localSharedFolder = scriptsContainer:WaitForChild("_Shared", 10)
if not localSharedFolder then
	warn("[WeaponVFXController] Could not locate _Shared folder")
	return
end
local LocalEventRegistry = require(localSharedFolder:WaitForChild("LocalEventRegistry"))
local InstancePath = require(localSharedFolder:WaitForChild("InstancePath"))

local WEAPON_ID = "Oathkeeper"
local DEFAULT_TRACER_LIFETIME = 2.0
local DEFAULT_TRACER_FADE_DURATION = 0.5
local DEFAULT_STASIS_VISUAL_HOLD_DISTANCE = 1.5
local WEAPON_MUZZLE_PART_PATH = "OathkeeperModel.Barrel"
local MUZZLE_FLASH_PATH = WEAPON_MUZZLE_PART_PATH .. ".MuzzleFlash"
local M1_HIT_EFFECT_PATH = "HitEnd.HitEffect"
local M2_HIT_EFFECT_PATH = "HitEndM2"

local warned: {[string]: boolean} = {}
local predictedPrimaryShotIds: {[number]: number} = {}
local predictedSecondaryShotIds: {[number]: number} = {}
local PREDICTED_SHOT_ID_TTL = 4.0
local heldTracersBySession: {[number]: {any}} = {}
local heldTracersNoSession: {any} = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn(message)
end

local primaryShotLocalEvent = LocalEventRegistry.getOrCreate(weaponRemotesFolder, "PrimaryShotLocal")
local secondaryShotLocalEvent = LocalEventRegistry.getOrCreate(weaponRemotesFolder, "SecondaryShotLocal")

local function getWeaponFolder(): Instance?
	return InstancePath.findByPath(ReplicatedStorage, "ContentDrawer.WeaponModels.HandCannons.Oathkeeper")
end

local function findParticleEmitter(source: Instance?): ParticleEmitter?
	if not source then
		return nil
	end
	if source:IsA("ParticleEmitter") then
		return source
	end
	return source:FindFirstChildWhichIsA("ParticleEmitter", true)
end

local function emitParticles(source: Instance?, count: number?)
	local emitter = findParticleEmitter(source)
	if not emitter then
		return
	end
	emitter:Emit(math.max(1, math.floor(count or 1)))
end

local function setSequenceToOne(target: Instance)
	if target:IsA("Beam") or target:IsA("Trail") then
		target.Transparency = NumberSequence.new(1)
	end
end

local function lerpSequenceToOne(sequence: NumberSequence, alpha: number): NumberSequence
	local keypoints = table.create(#sequence.Keypoints)
	for _, keypoint in ipairs(sequence.Keypoints) do
		local value = keypoint.Value + ((1 - keypoint.Value) * alpha)
		table.insert(keypoints, NumberSequenceKeypoint.new(keypoint.Time, math.clamp(value, 0, 1), keypoint.Envelope))
	end
	return NumberSequence.new(keypoints)
end

local function fadeSequenceObjects(sequenceTargets: {{instance: Instance, start: NumberSequence}}, fadeDuration: number)
	if fadeDuration <= 0 then
		for _, target in ipairs(sequenceTargets) do
			setSequenceToOne(target.instance)
		end
		return
	end

	task.spawn(function()
		local elapsed = 0
		while elapsed < fadeDuration do
			local dt = RunService.Heartbeat:Wait()
			elapsed += dt
			local alpha = math.clamp(elapsed / fadeDuration, 0, 1)
			for _, target in ipairs(sequenceTargets) do
				if target.instance.Parent then
					if target.instance:IsA("Beam") or target.instance:IsA("Trail") then
						target.instance.Transparency = lerpSequenceToOne(target.start, alpha)
					end
				end
			end
		end
		for _, target in ipairs(sequenceTargets) do
			if target.instance.Parent then
				setSequenceToOne(target.instance)
			end
		end
	end)
end

local function createAnchorPart(position: Vector3, parent: Instance, name: string): (Part, Attachment)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CFrame = CFrame.new(position)
	part.Parent = parent

	local attachment = Instance.new("Attachment")
	attachment.Name = name .. "Attachment"
	attachment.Parent = part
	return part, attachment
end

local function spawnTracer(
	origin: Vector3,
	impactPosition: Vector3,
	tracerTemplate: Instance?,
	lifetime: number,
	fadeDuration: number,
	deferCleanup: boolean?
): any
	if not tracerTemplate then
		return nil
	end

	local container = Instance.new("Folder")
	container.Name = "WeaponTracer"
	container.Parent = Workspace

	local startPart, attachment0 = createAnchorPart(origin, container, "TracerStart")
	local endPart, attachment1 = createAnchorPart(impactPosition, container, "TracerEnd")

	local tracerClone = tracerTemplate:Clone()
	tracerClone.Parent = container

	local sequenceTargets: {{instance: Instance, start: NumberSequence}} = {}
	local hasBoundTracer = false

	local function bindSequenceTarget(instance: Instance)
		if instance:IsA("Beam") or instance:IsA("Trail") then
			local current = instance.Transparency
			table.insert(sequenceTargets, {
				instance = instance,
				start = current,
			})
		end
	end

	if tracerClone:IsA("Beam") then
		tracerClone.Attachment0 = attachment0
		tracerClone.Attachment1 = attachment1
		hasBoundTracer = true
		bindSequenceTarget(tracerClone)
	elseif tracerClone:IsA("Trail") then
		tracerClone.Attachment0 = attachment0
		tracerClone.Attachment1 = attachment1
		hasBoundTracer = true
		bindSequenceTarget(tracerClone)
	else
		for _, descendant in ipairs(tracerClone:GetDescendants()) do
			if descendant:IsA("Beam") then
				descendant.Attachment0 = attachment0
				descendant.Attachment1 = attachment1
				hasBoundTracer = true
				bindSequenceTarget(descendant)
			elseif descendant:IsA("Trail") then
				descendant.Attachment0 = attachment0
				descendant.Attachment1 = attachment1
				hasBoundTracer = true
				bindSequenceTarget(descendant)
			end
		end
	end

	if not hasBoundTracer then
		warnOnce("MissingTracerType", "[WeaponVFXController] Tracer template has no Beam/Trail.")
	end

	local handle = {
		container = container,
		startPart = startPart,
		endPart = endPart,
		sequenceTargets = sequenceTargets,
		lifetime = lifetime,
		fadeDuration = fadeDuration,
	}

	if not deferCleanup then
		local fadeDelay = math.max(0, lifetime - fadeDuration)
		task.delay(fadeDelay, function()
			if not container.Parent then
				return
			end
			fadeSequenceObjects(sequenceTargets, fadeDuration)
		end)

		task.delay(lifetime, function()
			if startPart.Parent then
				startPart:Destroy()
			end
			if endPart.Parent then
				endPart:Destroy()
			end
			if container.Parent then
				container:Destroy()
			end
		end)
	end

	return handle
end

local function spawnImpactEffect(impactPosition: Vector3, impactNormal: Vector3, endpointTemplate: Instance?, hitEffectPath: string)
	if not endpointTemplate then
		return
	end

	local endpointClone = endpointTemplate:Clone()
	local normal = impactNormal.Magnitude > 1e-4 and impactNormal.Unit or Vector3.new(0, 1, 0)
	local targetCFrame = CFrame.lookAt(impactPosition, impactPosition + normal)

	if endpointClone:IsA("Model") then
		endpointClone:PivotTo(targetCFrame)
	elseif endpointClone:IsA("BasePart") then
		endpointClone.CFrame = targetCFrame
	end
	endpointClone.Parent = Workspace

	local hitEffect = InstancePath.findByPath(endpointClone, hitEffectPath)
	emitParticles(hitEffect or endpointClone, 1)

	task.delay(2, function()
		if endpointClone.Parent then
			endpointClone:Destroy()
		end
	end)
end

local function emitMuzzleFlashForShot(shooterUserId: number)
	local shooter = Players:GetPlayerByUserId(shooterUserId)
	if not shooter then
		return
	end
	local character = shooter.Character
	if not character then
		return
	end
	local muzzleFlash = InstancePath.findByPath(character, MUZZLE_FLASH_PATH)
	emitParticles(muzzleFlash, 1)
end

local function resolveLiveMuzzleOrigin(shooterUserId: number, fallbackOrigin: Vector3?): Vector3?
	local shooter = Players:GetPlayerByUserId(shooterUserId)
	if shooter and shooter.Character then
		local muzzle = InstancePath.findByPath(shooter.Character, WEAPON_MUZZLE_PART_PATH)
		if muzzle then
			if muzzle:IsA("Attachment") then
				return muzzle.WorldPosition
			end
			if muzzle:IsA("BasePart") then
				return muzzle.Position
			end
		end
	end
	return fallbackOrigin
end

local function computeDeferredHoldImpact(
	liveOrigin: Vector3,
	finalImpact: Vector3,
	requestedHoldDistance: number?
): Vector3
	local segment = finalImpact - liveOrigin
	local segLen = segment.Magnitude
	if segLen <= 1e-5 then
		return finalImpact
	end
	local holdDistance = DEFAULT_STASIS_VISUAL_HOLD_DISTANCE
	if typeof(requestedHoldDistance) == "number" then
		holdDistance = math.max(0, requestedHoldDistance)
	end
	local clamped = math.min(segLen, holdDistance)
	return liveOrigin + (segment.Unit * clamped)
end

local function consumePredictedShotId(predictedMap: {[number]: number}, clientShotId: number): boolean
	local expiresAt = predictedMap[clientShotId]
	if not expiresAt then
		return false
	end
	predictedMap[clientShotId] = nil
	return expiresAt >= tick()
end

local function rememberPredictedShotId(predictedMap: {[number]: number}, clientShotId: number)
	predictedMap[clientShotId] = tick() + PREDICTED_SHOT_ID_TTL
end

local function cleanupExpiredPredictedShotIds(predictedMap: {[number]: number})
	local now = tick()
	for shotId, expiresAt in pairs(predictedMap) do
		if expiresAt <= now then
			predictedMap[shotId] = nil
		end
	end
end

local function queueHeldTracer(sessionId: number?, entry: any)
	if typeof(sessionId) == "number" then
		local list = heldTracersBySession[sessionId]
		if not list then
			list = {}
			heldTracersBySession[sessionId] = list
		end
		table.insert(list, entry)
		return
	end
	table.insert(heldTracersNoSession, entry)
end

local function finalizeHeldTracer(entry: any)
	if typeof(entry) ~= "table" then
		return
	end
	local handle = entry.handle
	if typeof(handle) ~= "table" then
		return
	end
	local container = handle.container
	if not container or not container.Parent then
		return
	end

	local endPart = handle.endPart
	local finalImpact = entry.finalImpactPosition
	if endPart and endPart.Parent and typeof(finalImpact) == "Vector3" then
		endPart.CFrame = CFrame.new(finalImpact)
	end

	if typeof(finalImpact) == "Vector3" and typeof(entry.impactNormal) == "Vector3" and entry.endpointTemplate then
		spawnImpactEffect(finalImpact, entry.impactNormal, entry.endpointTemplate, entry.hitEffectPath)
	end

	local fadeDuration = typeof(handle.fadeDuration) == "number" and handle.fadeDuration or 0
	fadeSequenceObjects(handle.sequenceTargets or {}, fadeDuration)
	task.delay(math.max(0.05, fadeDuration), function()
		if handle.startPart and handle.startPart.Parent then
			handle.startPart:Destroy()
		end
		if handle.endPart and handle.endPart.Parent then
			handle.endPart:Destroy()
		end
		if container and container.Parent then
			container:Destroy()
		end
	end)
end

local function releaseHeldSession(sessionId: number)
	local list = heldTracersBySession[sessionId]
	if not list then
		return
	end
	heldTracersBySession[sessionId] = nil
	for _, entry in ipairs(list) do
		finalizeHeldTracer(entry)
	end
end

local function releaseAllHeldTracers()
	for sessionId in pairs(heldTracersBySession) do
		releaseHeldSession(sessionId)
	end
	for i = 1, #heldTracersNoSession do
		finalizeHeldTracer(heldTracersNoSession[i])
	end
	table.clear(heldTracersNoSession)
end

local function renderPrimaryShotVfx(payload: any, suppressCore: boolean)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.weaponId ~= WEAPON_ID then
		return
	end
	if typeof(payload.shooterUserId) ~= "number" then
		return
	end
	if typeof(payload.impactPosition) ~= "Vector3" then
		return
	end

	local shooterUserId = payload.shooterUserId
	local fallbackOrigin = if typeof(payload.origin) == "Vector3" then payload.origin else nil
	local liveOrigin = resolveLiveMuzzleOrigin(shooterUserId, fallbackOrigin)
	if not liveOrigin then
		return
	end

	local impactNormal = payload.impactNormal
	if typeof(impactNormal) ~= "Vector3" then
		impactNormal = Vector3.new(0, 1, 0)
	end

	local weaponFolder = getWeaponFolder()
	if not weaponFolder then
		warnOnce("MissingWeaponFolder", "[WeaponVFXController] Replicated Oathkeeper folder missing.")
		return
	end

	local tracerTemplate = InstancePath.findByPath(weaponFolder, "VFX.Tracer")
	local endpointTemplate = InstancePath.findByPath(weaponFolder, "VFX.Endpoint")
	local lifetime = typeof(payload.tracerLifetime) == "number" and payload.tracerLifetime or DEFAULT_TRACER_LIFETIME
	local fadeDuration = typeof(payload.tracerFadeDuration) == "number" and payload.tracerFadeDuration or DEFAULT_TRACER_FADE_DURATION
	local isDeferred = payload.timeStopDeferred == true
	local serverHoldImpact = if typeof(payload.holdImpactPosition) == "Vector3" then payload.holdImpactPosition else payload.impactPosition
	local finalImpact = if typeof(payload.finalImpactPosition) == "Vector3" then payload.finalImpactPosition else payload.impactPosition

	if suppressCore then
		return
	end

	emitMuzzleFlashForShot(shooterUserId)
	if isDeferred then
		local requestedHoldDistance: number? = nil
		if typeof(payload.timeStopHoldDistance) == "number" then
			requestedHoldDistance = payload.timeStopHoldDistance
		elseif typeof(payload.origin) == "Vector3" and typeof(serverHoldImpact) == "Vector3" then
			requestedHoldDistance = (serverHoldImpact - payload.origin).Magnitude
		end
		local holdImpact = computeDeferredHoldImpact(liveOrigin, finalImpact, requestedHoldDistance)
		local handle = spawnTracer(liveOrigin, holdImpact, tracerTemplate, lifetime, fadeDuration, true)
		if handle then
			queueHeldTracer(if typeof(payload.timeStopSessionId) == "number" then payload.timeStopSessionId else nil, {
				handle = handle,
				finalImpactPosition = finalImpact,
				impactNormal = impactNormal,
				endpointTemplate = endpointTemplate,
				hitEffectPath = M1_HIT_EFFECT_PATH,
			})
		end
		return
	end
	spawnTracer(liveOrigin, payload.impactPosition, tracerTemplate, lifetime, fadeDuration, false)
	spawnImpactEffect(payload.impactPosition, impactNormal, endpointTemplate, M1_HIT_EFFECT_PATH)
end

local function renderSecondaryShotVfx(payload: any, suppressCore: boolean)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.weaponId ~= WEAPON_ID then
		return
	end
	if typeof(payload.shooterUserId) ~= "number" then
		return
	end
	if typeof(payload.impactPosition) ~= "Vector3" then
		return
	end

	local shooterUserId = payload.shooterUserId
	local fallbackOrigin = if typeof(payload.origin) == "Vector3" then payload.origin else nil
	local liveOrigin = resolveLiveMuzzleOrigin(shooterUserId, fallbackOrigin)
	if not liveOrigin then
		return
	end

	local impactNormal = payload.impactNormal
	if typeof(impactNormal) ~= "Vector3" then
		impactNormal = Vector3.new(0, 1, 0)
	end

	local weaponFolder = getWeaponFolder()
	if not weaponFolder then
		warnOnce("MissingWeaponFolder", "[WeaponVFXController] Replicated Oathkeeper folder missing.")
		return
	end

	local tracerTemplate = InstancePath.findByPath(weaponFolder, "VFX.M2Tracer")
	local endpointTemplate = InstancePath.findByPath(weaponFolder, "VFX.Endpoint")
	local lifetime = typeof(payload.tracerLifetime) == "number" and payload.tracerLifetime or DEFAULT_TRACER_LIFETIME
	local fadeDuration = typeof(payload.tracerFadeDuration) == "number" and payload.tracerFadeDuration or DEFAULT_TRACER_FADE_DURATION
	local isDeferred = payload.timeStopDeferred == true
	local serverHoldImpact = if typeof(payload.holdImpactPosition) == "Vector3" then payload.holdImpactPosition else payload.impactPosition
	local finalImpact = if typeof(payload.finalImpactPosition) == "Vector3" then payload.finalImpactPosition else payload.impactPosition

	if not suppressCore then
		emitMuzzleFlashForShot(shooterUserId)
		if isDeferred then
			local requestedHoldDistance: number? = nil
			if typeof(payload.timeStopHoldDistance) == "number" then
				requestedHoldDistance = payload.timeStopHoldDistance
			elseif typeof(payload.origin) == "Vector3" and typeof(serverHoldImpact) == "Vector3" then
				requestedHoldDistance = (serverHoldImpact - payload.origin).Magnitude
			end
			local holdImpact = computeDeferredHoldImpact(liveOrigin, finalImpact, requestedHoldDistance)
			local handle = spawnTracer(liveOrigin, holdImpact, tracerTemplate, lifetime, fadeDuration, true)
			if handle then
				queueHeldTracer(if typeof(payload.timeStopSessionId) == "number" then payload.timeStopSessionId else nil, {
					handle = handle,
					finalImpactPosition = finalImpact,
					impactNormal = impactNormal,
					endpointTemplate = endpointTemplate,
					hitEffectPath = M2_HIT_EFFECT_PATH,
				})
			end
		else
			spawnTracer(liveOrigin, payload.impactPosition, tracerTemplate, lifetime, fadeDuration, false)
			spawnImpactEffect(payload.impactPosition, impactNormal, endpointTemplate, M2_HIT_EFFECT_PATH)
		end
	end

	local enemyHits = payload.enemyHits
	if typeof(enemyHits) == "table" then
		for _, hit in ipairs(enemyHits) do
			if typeof(hit) == "table" and typeof(hit.position) == "Vector3" then
				if hit.timeStopDeferred == true then
					continue
				end
				local hitNormal = if typeof(hit.normal) == "Vector3" then hit.normal else Vector3.new(0, 1, 0)
				spawnImpactEffect(hit.position, hitNormal, endpointTemplate, M2_HIT_EFFECT_PATH)
			end
		end
	end
end

primaryShotLocalEvent.Event:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.weaponId ~= WEAPON_ID or payload.shooterUserId ~= localPlayer.UserId then
		return
	end
	if typeof(payload.clientShotId) == "number" then
		rememberPredictedShotId(predictedPrimaryShotIds, math.floor(payload.clientShotId + 0.5))
	end
	renderPrimaryShotVfx(payload, false)
end)

primaryShotRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) == "table" and payload.weaponId == WEAPON_ID and payload.shooterUserId == localPlayer.UserId
		and typeof(payload.clientShotId) == "number" then
		cleanupExpiredPredictedShotIds(predictedPrimaryShotIds)
		local suppressCore = consumePredictedShotId(predictedPrimaryShotIds, math.floor(payload.clientShotId + 0.5))
		renderPrimaryShotVfx(payload, suppressCore)
		return
	end
	renderPrimaryShotVfx(payload, false)
end)

secondaryShotLocalEvent.Event:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.weaponId ~= WEAPON_ID or payload.shotKind ~= "M2" or payload.shooterUserId ~= localPlayer.UserId then
		return
	end
	if typeof(payload.clientShotId) == "number" then
		rememberPredictedShotId(predictedSecondaryShotIds, math.floor(payload.clientShotId + 0.5))
	end
	renderSecondaryShotVfx(payload, false)
end)

secondaryShotRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) == "table" and payload.weaponId == WEAPON_ID and payload.shotKind == "M2"
		and payload.shooterUserId == localPlayer.UserId and typeof(payload.clientShotId) == "number" then
		cleanupExpiredPredictedShotIds(predictedSecondaryShotIds)
		local suppressCore = consumePredictedShotId(predictedSecondaryShotIds, math.floor(payload.clientShotId + 0.5))
		renderSecondaryShotVfx(payload, suppressCore)
		return
	end
	renderSecondaryShotVfx(payload, false)
end)

timeStopStateRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.active == true then
		if typeof(payload.sessionId) == "number" then
			for sessionId in pairs(heldTracersBySession) do
				if sessionId ~= payload.sessionId then
					releaseHeldSession(sessionId)
				end
			end
		end
		return
	end
	releaseAllHeldTracers()
end)
