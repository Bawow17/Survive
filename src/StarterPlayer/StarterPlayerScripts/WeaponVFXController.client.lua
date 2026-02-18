--!strict
-- WeaponVFXController - renders replicated primary weapon muzzle/tracer/impact VFX.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local weaponRemotesFolder = remotesFolder:WaitForChild("Weapons")
local primaryShotRemote = weaponRemotesFolder:WaitForChild("PrimaryShot")

local WEAPON_ID = "Oathkeeper"
local DEFAULT_TRACER_LIFETIME = 2.0
local DEFAULT_TRACER_FADE_DURATION = 0.5
local MUZZLE_FLASH_PATH = "OathkeeperModel.Barrel.BarrelEnd.MuzzleFlash"

local warned: {[string]: boolean} = {}

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

local function getWeaponFolder(): Instance?
	return findByPath(ReplicatedStorage, "ContentDrawer.WeaponModels.HandCannons.Oathkeeper")
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

local function spawnTracer(origin: Vector3, impactPosition: Vector3, tracerTemplate: Instance?, lifetime: number, fadeDuration: number)
	if not tracerTemplate then
		return
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

local function spawnImpactEffect(impactPosition: Vector3, impactNormal: Vector3, endpointTemplate: Instance?)
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

	local hitEffect = findByPath(endpointClone, "HitEnd.HitEffect")
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
	local muzzleFlash = findByPath(character, MUZZLE_FLASH_PATH)
	emitParticles(muzzleFlash, 1)
end

primaryShotRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.weaponId ~= WEAPON_ID then
		return
	end
	if typeof(payload.shooterUserId) ~= "number" then
		return
	end
	if typeof(payload.origin) ~= "Vector3" or typeof(payload.impactPosition) ~= "Vector3" then
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

	local tracerTemplate = findByPath(weaponFolder, "VFX.Tracer")
	local endpointTemplate = findByPath(weaponFolder, "VFX.Endpoint")
	local lifetime = typeof(payload.tracerLifetime) == "number" and payload.tracerLifetime or DEFAULT_TRACER_LIFETIME
	local fadeDuration = typeof(payload.tracerFadeDuration) == "number" and payload.tracerFadeDuration or DEFAULT_TRACER_FADE_DURATION

	emitMuzzleFlashForShot(payload.shooterUserId)
	spawnTracer(payload.origin, payload.impactPosition, tracerTemplate, lifetime, fadeDuration)
	spawnImpactEffect(payload.impactPosition, impactNormal, endpointTemplate)
end)
