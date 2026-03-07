--!strict
-- GlacialPathRenderer - Renders replicated GlacialPath path/beams for other players.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local GlacialPathReplicate = remotes:WaitForChild("GlacialPathReplicate") :: RemoteEvent
local GamePaused = remotes:WaitForChild("GamePaused") :: RemoteEvent

local PATH_TEMPLATE_PATH = "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Utility.GlacialPath.IcePath"
local LEGACY_PATH_TEMPLATE_PATH = "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Utility.IceTracer.IcePath"
local BEAM1_TEMPLATE_PATH = "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Utility.GlacialPath.IceLaser"
local LEGACY_BEAM1_TEMPLATE_PATH = "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Utility.IceTracer.IceLaser"
local BEAM2_TEMPLATE_PATH = "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Utility.GlacialPath.IceLaser2"
local LEGACY_BEAM2_TEMPLATE_PATH = "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Utility.IceTracer.IceLaser2"
local PATH_PART_LIFETIME = 2.0
local PATH_FADE_DURATION = 0.35
local CAST_TIMEOUT = 1.5

type BeamEntry = {
	beam: Beam,
	container: Instance,
}

type CastState = {
	key: string,
	sourcePlayer: Player,
	lastAttachment: Attachment?,
	startAttachment: Attachment,
	startPart: BasePart,
	folder: Folder,
	beams: {BeamEntry},
	expiresAt: number,
}

local activeStates: {[string]: CastState} = {}

local function findInstanceByPath(path: string): Instance?
	local parts = string.split(path, ".")
	local current: any = game
	for _, part in ipairs(parts) do
		if part == "game" then
			continue
		end
		current = current:FindFirstChild(part)
		if not current then
			return nil
		end
	end
	return if typeof(current) == "Instance" then current else nil
end

local function resolveExistingPath(primaryPath: string, fallbackPath: string): string
	if findInstanceByPath(primaryPath) then
		return primaryPath
	end
	if findInstanceByPath(fallbackPath) then
		return fallbackPath
	end
	return primaryPath
end

local function getBasePartFromInstance(instance: Instance?): BasePart?
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function setInstanceWorldCFrame(instance: Instance?, targetCFrame: CFrame)
	if not instance then
		return
	end
	if instance:IsA("Model") then
		local primary = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			if not instance.PrimaryPart then
				instance.PrimaryPart = primary
			end
			instance:PivotTo(targetCFrame)
		end
	elseif instance:IsA("BasePart") then
		instance.CFrame = targetCFrame
	end
end

local function findAttachment(instance: Instance?, part: BasePart?): Attachment?
	if part then
		local direct = part:FindFirstChildOfClass("Attachment")
		if direct then
			return direct
		end
	end
	if not instance then
		return nil
	end
	if instance:IsA("Model") or instance:IsA("Folder") then
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("Attachment") then
				return descendant
			end
		end
	elseif instance:IsA("BasePart") then
		return instance:FindFirstChildOfClass("Attachment")
	end
	return nil
end

local function findBeam(instance: Instance?): Beam?
	if not instance then
		return nil
	end
	if instance:IsA("Beam") then
		return instance
	end
	if instance:IsA("Model") or instance:IsA("Folder") then
		return instance:FindFirstChildWhichIsA("Beam", true)
	end
	if instance:IsA("BasePart") then
		return instance:FindFirstChildOfClass("Beam")
	end
	return nil
end

local function lerpNumberSequenceToTransparent(sequence: NumberSequence, alpha: number): NumberSequence
	local keypoints = sequence.Keypoints
	local out = table.create(#keypoints)
	for i, kp in ipairs(keypoints) do
		local value = kp.Value + (1 - kp.Value) * alpha
		out[i] = NumberSequenceKeypoint.new(kp.Time, math.clamp(value, 0, 1), kp.Envelope)
	end
	return NumberSequence.new(out)
end

local function scheduleInstanceFadeAndDestroy(rootInstance: Instance?, lifetime: number, fadeDuration: number)
	if not rootInstance then
		return
	end

	local safeLifetime = math.max(0.05, lifetime)
	local safeFadeDuration = math.max(0, math.min(fadeDuration, safeLifetime))
	local partBaseTransparency: {[BasePart]: number} = {}
	local beamBaseTransparency: {[Beam]: NumberSequence} = {}

	local function capture(inst: Instance)
		if inst:IsA("BasePart") then
			partBaseTransparency[inst] = inst.Transparency
		elseif inst:IsA("Beam") then
			beamBaseTransparency[inst] = inst.Transparency
		end
	end

	capture(rootInstance)
	for _, descendant in ipairs(rootInstance:GetDescendants()) do
		capture(descendant)
	end

	task.delay(math.max(0, safeLifetime - safeFadeDuration), function()
		if safeFadeDuration <= 0 then
			return
		end
		local fadeStart = tick()
		local fadeConnection: RBXScriptConnection?
		fadeConnection = RunService.Heartbeat:Connect(function()
			local t = math.clamp((tick() - fadeStart) / safeFadeDuration, 0, 1)
			for part, baseTransparency in pairs(partBaseTransparency) do
				if part and part.Parent then
					part.Transparency = baseTransparency + (1 - baseTransparency) * t
				end
			end
			for beam, baseTransparency in pairs(beamBaseTransparency) do
				if beam and beam.Parent then
					beam.Transparency = lerpNumberSequenceToTransparent(baseTransparency, t)
				end
			end
			if t >= 1 and fadeConnection then
				fadeConnection:Disconnect()
			end
		end)
	end)

	task.delay(safeLifetime, function()
		if rootInstance and rootInstance.Parent then
			rootInstance:Destroy()
		end
	end)
end

local function findLeftArmGripAttachment(characterModel: Model?): Attachment?
	if not characterModel then
		return nil
	end
	local exact = characterModel:FindFirstChild("LeftArmGripAttachment", true)
	if exact and exact:IsA("Attachment") then
		return exact
	end
	local leftArm = characterModel:FindFirstChild("Left Arm")
	if leftArm and leftArm:IsA("BasePart") then
		local attachment = leftArm:FindFirstChildOfClass("Attachment")
		if attachment then
			return attachment
		end
	end
	return nil
end

local function createBeamFromTemplate(path: string, fallbackPath: string, name: string, startAttachment: Attachment, endAttachment: Attachment, parent: Instance): BeamEntry
	local template = findInstanceByPath(resolveExistingPath(path, fallbackPath))
	local container: Instance
	local beam: Beam?

	if template then
		container = template:Clone()
		container.Parent = parent
		beam = findBeam(container)
	else
		local fallback = Instance.new("Beam")
		fallback.FaceCamera = true
		fallback.Width0 = 0.25
		fallback.Width1 = 0.25
		fallback.Parent = startAttachment.Parent
		container = fallback
		beam = fallback
	end

	if not beam then
		beam = Instance.new("Beam")
		beam.FaceCamera = true
		beam.Width0 = 0.25
		beam.Width1 = 0.25
		beam.Parent = startAttachment.Parent
		container = beam
	end

	beam.Name = name
	beam.Attachment0 = startAttachment
	beam.Attachment1 = endAttachment
	beam.Enabled = true

	return {
		beam = beam,
		container = container,
	}
end

local function cleanupState(state: CastState)
	for _, beamEntry in ipairs(state.beams) do
		if beamEntry.beam and beamEntry.beam.Parent then
			beamEntry.beam.Enabled = false
		end
	end
	if state.folder and state.folder.Parent then
		state.folder:Destroy()
	end
	activeStates[state.key] = nil
end

local function getOrCreateState(sourcePlayer: Player, castId: number): CastState
	local key = tostring(sourcePlayer.UserId) .. ":" .. tostring(castId)
	local existing = activeStates[key]
	if existing then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "GlacialPath_" .. tostring(sourcePlayer.UserId) .. "_" .. tostring(castId)
	folder.Parent = Workspace

	local startPart = Instance.new("Part")
	startPart.Name = "Start"
	startPart.Anchored = true
	startPart.CanCollide = false
	startPart.CanTouch = false
	startPart.CanQuery = false
	startPart.Transparency = 1
	startPart.Size = Vector3.new(0.2, 0.2, 0.2)
	startPart.Parent = folder

	local startAttachment = Instance.new("Attachment")
	startAttachment.Name = "StartAttachment"
	startAttachment.Parent = startPart

	local endAttachment = Instance.new("Attachment")
	endAttachment.Name = "EndAttachment"
	endAttachment.Parent = startPart

	local state: CastState = {
		key = key,
		sourcePlayer = sourcePlayer,
		lastAttachment = nil,
		startAttachment = startAttachment,
		startPart = startPart,
		folder = folder,
		beams = {
			createBeamFromTemplate(BEAM1_TEMPLATE_PATH, LEGACY_BEAM1_TEMPLATE_PATH, "GlacialPathBeam1", startAttachment, endAttachment, folder),
			createBeamFromTemplate(BEAM2_TEMPLATE_PATH, LEGACY_BEAM2_TEMPLATE_PATH, "GlacialPathBeam2", startAttachment, endAttachment, folder),
		},
		expiresAt = tick() + CAST_TIMEOUT,
	}
	activeStates[key] = state
	return state
end

local function spawnPathSegment(state: CastState, position: Vector3, forward: Vector3, yawDeg: number)
	local template = findInstanceByPath(resolveExistingPath(PATH_TEMPLATE_PATH, LEGACY_PATH_TEMPLATE_PATH))
	if not template then
		return
	end

	local segment = template:Clone()
	segment.Parent = state.folder

	-- Keep replicated path segments physically usable as temporary platforms.
	if segment:IsA("Model") then
		for _, descendant in ipairs(segment:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = true
				descendant.CanTouch = true
				descendant.CanQuery = true
				descendant.CollisionGroup = "Default"
			end
		end
	elseif segment:IsA("BasePart") then
		segment.Anchored = true
		segment.CanCollide = true
		segment.CanTouch = true
		segment.CanQuery = true
		segment.CollisionGroup = "Default"
	end

	local normalizedForward = if forward.Magnitude > 1e-4 then forward.Unit else Vector3.new(0, 0, 1)
	local segmentCFrame = CFrame.lookAt(position, position + normalizedForward) * CFrame.Angles(0, math.rad(yawDeg), 0)
	setInstanceWorldCFrame(segment, segmentCFrame)

	local part = getBasePartFromInstance(segment)
	local attachment = findAttachment(segment, part)
	if not attachment and part then
		attachment = Instance.new("Attachment")
		attachment.Name = "PathAttachment"
		attachment.Parent = part
	end

	if attachment then
		state.lastAttachment = attachment
		for _, beamEntry in ipairs(state.beams) do
			if beamEntry.beam and beamEntry.beam.Parent then
				beamEntry.beam.Attachment1 = attachment
				beamEntry.beam.Enabled = true
			end
		end
	end

	scheduleInstanceFadeAndDestroy(segment, PATH_PART_LIFETIME, PATH_FADE_DURATION)
end

local function clearAllStates()
	for _, state in pairs(activeStates) do
		cleanupState(state)
	end
end

GlacialPathReplicate.OnClientEvent:Connect(function(sourcePlayer: Player, castId: number, segments: {any}, isFinal: boolean)
	if sourcePlayer == localPlayer then
		return
	end
	if typeof(sourcePlayer) ~= "Instance" or not sourcePlayer:IsA("Player") then
		return
	end
	if typeof(castId) ~= "number" then
		return
	end
	if typeof(segments) ~= "table" then
		return
	end

	local state = getOrCreateState(sourcePlayer, math.floor(castId + 0.5))
	state.expiresAt = tick() + CAST_TIMEOUT

	for _, segment in ipairs(segments) do
		if typeof(segment) == "table"
			and typeof(segment.position) == "Vector3"
			and typeof(segment.forward) == "Vector3"
			and typeof(segment.yawDeg) == "number" then
			spawnPathSegment(state, segment.position, segment.forward, segment.yawDeg)
		end
	end

	if isFinal then
		state.expiresAt = tick() + 0.2
	end
end)

GamePaused.OnClientEvent:Connect(function()
	clearAllStates()
end)

RunService.Heartbeat:Connect(function()
	local now = tick()
	for _, state in pairs(activeStates) do
		if now > state.expiresAt then
			cleanupState(state)
			continue
		end

		local sourceCharacter = state.sourcePlayer.Character
		local sourceAttachment = findLeftArmGripAttachment(sourceCharacter)
		if sourceAttachment then
			state.startPart.CFrame = sourceAttachment.WorldCFrame
			for _, beamEntry in ipairs(state.beams) do
				if beamEntry.beam and beamEntry.beam.Parent then
					beamEntry.beam.Attachment0 = state.startAttachment
					if state.lastAttachment then
						beamEntry.beam.Attachment1 = state.lastAttachment
					end
					beamEntry.beam.Enabled = true
				end
			end
		elseif sourceCharacter == nil then
			cleanupState(state)
		end
	end
end)
