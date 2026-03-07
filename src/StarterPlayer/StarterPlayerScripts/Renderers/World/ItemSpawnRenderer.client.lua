--!strict
-- ItemSpawnRenderer - client-side temporary arc VFX shown before a real pickup exists.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

type SpawnVisualRecord = {
	id: number,
	origin: Vector3,
	landingPos: Vector3,
	auraAttachmentOffset: Vector3,
	spawnedAt: number,
	landAt: number,
	despawnAt: number,
	arcHeight: number,
	anchor: BasePart,
}

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local itemSpawnRemotesFolder = remotesFolder:WaitForChild("ItemSpawns")
local ItemSpawnsSpawnBatch = itemSpawnRemotesFolder:WaitForChild("ItemSpawnsSpawnBatch") :: RemoteEvent
local ItemSpawnsDespawnBatch = itemSpawnRemotesFolder:WaitForChild("ItemSpawnsDespawnBatch") :: RemoteEvent

local effectsFolder = Workspace:FindFirstChild("ItemSpawnEffects")
if effectsFolder and not effectsFolder:IsA("Folder") then
	effectsFolder:Destroy()
	effectsFolder = nil
end
if not effectsFolder then
	effectsFolder = Instance.new("Folder")
	effectsFolder.Name = "ItemSpawnEffects"
	effectsFolder.Parent = Workspace
end

local activeSpawns: {[number]: SpawnVisualRecord} = {}
local warnedMissingVfxPaths: {[string]: boolean} = {}
local PICKUP_VISUAL_HEIGHT_OFFSET = 2.0 -- Keep in sync with PickupRenderer.PICKUP_VISUAL_HEIGHT_OFFSET.
local VFX_WARMUP_SECONDS = 5.0
local VFX_WARMUP_FPS = 60
local ITEM_SPAWN_WORLD_SPIN_PERIOD = 8.0

local function resolveInstanceByPath(path: string): Instance?
	local current: Instance? = game
	for _, segment in ipairs(string.split(path, ".")) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(segment)
	end
	return current
end

local function createAnchorPart(): BasePart
	local anchor = Instance.new("Part")
	anchor.Name = "ItemSpawnEffectAnchor"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	return anchor
end

local function attachVfx(template: Instance, anchor: BasePart, attachmentOffset: Vector3)
	if template:IsA("Attachment") then
		local clonedAttachment = template:Clone()
		clonedAttachment.Name = "CommonAura"
		clonedAttachment.Position = attachmentOffset
		clonedAttachment.Orientation = Vector3.zero
		clonedAttachment.Parent = anchor
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "CommonAura"
	attachment.Position = attachmentOffset
	attachment.Orientation = Vector3.zero
	attachment.Parent = anchor

	local clone = template:Clone()
	clone.Name = "CommonAuraVFX"
	clone.Parent = attachment
end

local function warmupVfx(root: Instance, emitParticles: boolean?)
	local instances = { root }
	for _, descendant in ipairs(root:GetDescendants()) do
		table.insert(instances, descendant)
	end

	for _, instance in ipairs(instances) do
		if instance:IsA("ParticleEmitter") then
			local maxLifetime = math.max(instance.Lifetime.Min, instance.Lifetime.Max)
			local frames = math.max(1, math.ceil(VFX_WARMUP_SECONDS * VFX_WARMUP_FPS))
			pcall(function()
				instance:FastForward(frames)
			end)
			if emitParticles ~= false then
				local emitCount = math.max(1, math.ceil(instance.Rate * maxLifetime))
				pcall(function()
					instance:Emit(emitCount)
				end)
			end
		end
	end
end

local function warmupVfxDeferred(root: Instance)
	warmupVfx(root, true)
	task.defer(function()
		if not root.Parent then
			return
		end
		RunService.Heartbeat:Wait()
		if not root.Parent then
			return
		end
		warmupVfx(root, false)
	end)
end

local function evaluateArcPosition(record: SpawnVisualRecord, now: number): Vector3
	if now <= record.spawnedAt then
		return record.origin
	end
	if now >= record.landAt then
		return record.landingPos
	end

	local duration = math.max(record.landAt - record.spawnedAt, 0.0001)
	local t = math.clamp((now - record.spawnedAt) / duration, 0, 1)
	local basePosition = record.origin:Lerp(record.landingPos, t)
	local arcOffset = 4 * record.arcHeight * t * (1 - t)
	return basePosition + Vector3.new(0, arcOffset, 0)
end

local function cleanupRecord(record: SpawnVisualRecord?)
	if not record then
		return
	end
	activeSpawns[record.id] = nil
	if record.anchor and record.anchor.Parent then
		record.anchor:Destroy()
	end
end

local function applyRecordPosition(record: SpawnVisualRecord, now: number)
	local worldPos = evaluateArcPosition(record, now) + Vector3.new(0, PICKUP_VISUAL_HEIGHT_OFFSET, 0)
	local angle = ((now + (record.id * 0.13)) / ITEM_SPAWN_WORLD_SPIN_PERIOD) * (math.pi * 2)
	record.anchor.CFrame = CFrame.new(worldPos) * CFrame.Angles(0, angle, 0)
end

ItemSpawnsSpawnBatch.OnClientEvent:Connect(function(payloads: any)
	if typeof(payloads) ~= "table" then
		return
	end

	local now = Workspace:GetServerTimeNow()
	for _, payload in ipairs(payloads) do
		if typeof(payload) ~= "table" then
			continue
		end

		local effectId = payload.id
		local origin = payload.origin
		local landingPos = payload.landingPos
		local auraAttachmentOffset = payload.auraAttachmentOffset
		local spawnedAt = payload.spawnedAt
		local landAt = payload.landAt
		local despawnAt = payload.despawnAt
		local vfxPath = if typeof(payload.vfxPath) == "string" then payload.vfxPath else nil

		if typeof(effectId) ~= "number"
			or typeof(origin) ~= "Vector3"
			or typeof(landingPos) ~= "Vector3"
			or typeof(auraAttachmentOffset) ~= "Vector3"
			or typeof(spawnedAt) ~= "number"
			or typeof(landAt) ~= "number"
			or typeof(despawnAt) ~= "number"
			or not vfxPath
		then
			continue
		end

		if despawnAt <= now then
			continue
		end

		local existing = activeSpawns[effectId]
		if existing then
			cleanupRecord(existing)
		end

		local template = resolveInstanceByPath(vfxPath)
		if not template then
			if not warnedMissingVfxPaths[vfxPath] then
				warnedMissingVfxPaths[vfxPath] = true
				warn(string.format("[ItemSpawnRenderer] Missing item spawn VFX at '%s'.", vfxPath))
			end
			continue
		end

		local distance = (landingPos - origin).Magnitude
		local anchor = createAnchorPart()
		local record: SpawnVisualRecord = {
			id = effectId,
			origin = origin,
			landingPos = landingPos,
			auraAttachmentOffset = auraAttachmentOffset,
			spawnedAt = spawnedAt,
			landAt = landAt,
			despawnAt = despawnAt,
			arcHeight = math.clamp(8.0 + (distance * 0.1), 8.0, 12.0),
			anchor = anchor,
		}

		applyRecordPosition(record, now)
		anchor.Parent = effectsFolder
		attachVfx(template, anchor, auraAttachmentOffset)
		warmupVfxDeferred(anchor)

		activeSpawns[effectId] = record
	end
end)

ItemSpawnsDespawnBatch.OnClientEvent:Connect(function(ids: any)
	if typeof(ids) ~= "table" then
		return
	end

	for _, effectId in ipairs(ids) do
		if typeof(effectId) ~= "number" then
			continue
		end
		cleanupRecord(activeSpawns[effectId])
	end
end)

RunService.RenderStepped:Connect(function()
	local now = Workspace:GetServerTimeNow()
	for _, record in pairs(activeSpawns) do
		if now >= record.despawnAt then
			cleanupRecord(record)
		else
			applyRecordPosition(record, now)
		end
	end
end)
