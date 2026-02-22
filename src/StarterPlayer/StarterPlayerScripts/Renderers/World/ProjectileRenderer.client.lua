--!strict
-- ProjectileRenderer - Client-side visuals for record-based projectiles (no ECS entities).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local projectileRemotesFolder = remotesFolder:WaitForChild("Projectiles")

local function waitForProjectileRemote(name: string): RemoteEvent
	local remote = projectileRemotesFolder:WaitForChild(name, 15)
	if not remote or not remote:IsA("RemoteEvent") then
		error(string.format("[ProjectileRenderer] Missing remote '%s' under RemoteEvents.Projectiles after timeout", name))
	end
	return remote
end

local ProjectilesSpawnBatch = waitForProjectileRemote("ProjectilesSpawnBatch")
local ProjectilesDespawnBatch = waitForProjectileRemote("ProjectilesDespawnBatch")
local ProjectilesImpactBatch = waitForProjectileRemote("ProjectilesImpactBatch")

local ModelPaths = require(ReplicatedStorage.Shared.ModelPaths)

local projectilesFolder: Instance = workspace:FindFirstChild("Projectiles") or Instance.new("Folder")
projectilesFolder.Name = "Projectiles"
projectilesFolder.Parent = workspace

local BASE_RENDER_DISTANCE = 300
local BASE_RENDER_DISABLE_DISTANCE = 340
local HOMING_UPDATE_INTERVAL = 0.1
local ENEMY_SNAPSHOT_INTERVAL = 0.2
local DEFAULT_HOMING_STRENGTH = 180
local EXPLOSION_STEPS = 10
local EXPLOSION_EXPAND_DURATION = 0.25
local EXPLOSION_FADE_DURATION = 0.25

local ATTR_PROJECTILE_OPACITY_SELF = "Setting_graphics_projectileOpacitySelf"
local ATTR_PROJECTILE_OPACITY_OTHERS = "Setting_graphics_projectileOpacityOthers"
local ATTR_OTHER_PLAYER_VFX_OPACITY = "Setting_graphics_otherPlayerVfxOpacity"
local ATTR_REDUCE_MOTION = "Setting_accessibility_reduceMotion"

local renderDistance = BASE_RENDER_DISTANCE
local renderDisableDistance = BASE_RENDER_DISABLE_DISTANCE
local projectileOpacitySelf = 1.0
local projectileOpacityOthers = 1.0
local otherPlayerVfxOpacity = 1.0
local reduceMotion = false

type HomingPayload = {
	acquireRadius: number?,
	strengthDeg: number?,
	maxAngleDeg: number?,
	maxTurnDeg: number?,
	stayHorizontal: boolean?,
	alwaysStayHorizontal: boolean?,
}

type OrbitPayload = {
	ownerUserId: number,
	radius: number,
	speedDeg: number,
	angle: number,
}

type PetalPayload = {
	maxRange: number?,
	ownerUserId: number?,
	homingStrength: number?,
	homingMaxAngle: number?,
	stayHorizontal: boolean?,
	alwaysStayHorizontal: boolean?,
	role: string?,
}

type BeamPayload = {
	length: number?,
	size: Vector3?,
	offset: Vector3?,
	rotation: CFrame?,
	lengthAxis: string?,
}

type ProjectileRecord = {
	id: number,
	kind: string,
	origin: Vector3,
	direction: Vector3,
	speed: number,
	spawnTime: number,
	lifetime: number?,
	expiresAt: number?,
	modelPath: string?,
	visualScale: number?,
	visualColor: Color3?,
	ownerUserId: number?,
	stayHorizontal: boolean?,
	alwaysStayHorizontal: boolean?,
	stickToPlayer: boolean?,
	orbit: OrbitPayload?,
	homing: HomingPayload?,
	petal: PetalPayload?,
	beam: BeamPayload?,
	beamVisual: {
		start: BasePart?,
		ending: BasePart?,
		hitbox: BasePart?,
		baseHitboxSize: Vector3?,
		parts: {BasePart}?,
	}?,
	beamEndJitter: number?,
	lastSimTime: number?,
	lastPos: Vector3?,
	lastHomingUpdate: number?,
	lastOwnerPos: Vector3?,
	stickOffset: Vector3?,
	isSplitChild: boolean?,
	model: Model?,
	parts: {BasePart}?,
	primary: BasePart?,
	renderEnabled: boolean?,
}

local activeProjectiles: {[number]: ProjectileRecord} = {}
local modelPoolByPath: {[string]: {Model}} = {}
local impactPoolByPath: {[string]: {Model}} = {}
local MAX_POOL_SIZE = 80
local MAX_IMPACT_POOL_SIZE = 20
local MAX_BEAM_POOL_SIZE = 40
local BEAM_END_EXTEND_MIN = -10
local BEAM_END_EXTEND_MAX = 10
local explosionTokenCounter = 0
local PETAL_COLOR_CLOSEST = Color3.fromRGB(255, 182, 193)
local PETAL_COLOR_TOUGHEST = Color3.fromRGB(173, 216, 230)
local PETAL_MIN_SEPARATION = 30
local PETAL_TARGET_REFRESH = 0.05
local petalTargetCache: {[number]: {time: number, range: number, closest: Vector3?, toughest: Vector3?}} = {}

local enemiesFolder: Folder? = workspace:FindFirstChild("Enemies") :: Folder?
local enemySnapshot: {{pos: Vector3}} = {}
local lastEnemySnapshot = 0

local refractionsTemplate: Instance? = nil
local beamPool: {Instance} = {}
local beamVisualsByModel: {[Instance]: {start: BasePart?, ending: BasePart?, hitbox: BasePart?, baseHitboxSize: Vector3?, parts: {BasePart}?}} = {}
local emitterTransparencyByInstance: {[ParticleEmitter]: NumberSequence} = setmetatable({}, { __mode = "k" }) :: any
local trailTransparencyByInstance: {[Trail]: NumberSequence} = setmetatable({}, { __mode = "k" }) :: any
local beamTransparencyByInstance: {[Beam]: NumberSequence} = setmetatable({}, { __mode = "k" }) :: any
local emitterColorByInstance: {[ParticleEmitter]: ColorSequence} = setmetatable({}, { __mode = "k" }) :: any
local trailColorByInstance: {[Trail]: ColorSequence} = setmetatable({}, { __mode = "k" }) :: any
local beamColorByInstance: {[Beam]: ColorSequence} = setmetatable({}, { __mode = "k" }) :: any

local function readNumberSetting(attributeName: string, fallback: number, minimum: number, maximum: number): number
	local raw = player:GetAttribute(attributeName)
	if typeof(raw) == "number" then
		return math.clamp(raw, minimum, maximum)
	end
	return fallback
end

local function readBoolSetting(attributeName: string, fallback: boolean): boolean
	local raw = player:GetAttribute(attributeName)
	if typeof(raw) == "boolean" then
		return raw
	end
	return fallback
end

local function toVector3(value: any): Vector3?
	if typeof(value) == "Vector3" then
		return value
	end
	if typeof(value) == "table" then
		local x = value.x or value.X
		local y = value.y or value.Y
		local z = value.z or value.Z
		if x and y and z then
			return Vector3.new(x, y, z)
		end
	end
	return nil
end

local function resolveModelPath(kind: string, provided: any): string?
	if typeof(provided) == "string" then
		return provided
	end
	return ModelPaths.getModelPath("Projectile", kind)
end

local function findModelByPath(modelPath: string): Model?
	local current: Instance? = game
	for _, partName in ipairs(string.split(modelPath, ".")) do
		if not current then
			return nil
		end
		if partName == "ReplicatedStorage" then
			current = ReplicatedStorage
		else
			current = current:FindFirstChild(partName)
		end
	end
	if current and current:IsA("Model") then
		return current
	end
	return nil
end

local function configureModel(model: Model): (BasePart?, {BasePart})
	local parts = {}
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if primary and not model.PrimaryPart then
		model.PrimaryPart = primary
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if descendant:GetAttribute("__OrigTransparency") == nil then
				descendant:SetAttribute("__OrigTransparency", descendant.Transparency)
			end
			if descendant:GetAttribute("__OrigSize") == nil then
				descendant:SetAttribute("__OrigSize", descendant.Size)
			end
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			table.insert(parts, descendant)
		end
	end
	return primary, parts
end

local function getRefractionsTemplate(): Instance?
	if refractionsTemplate and refractionsTemplate.Parent then
		return refractionsTemplate
	end
	local template = workspace:FindFirstChild("Refractions")
	if template then
		refractionsTemplate = template
		return template
	end
	return nil
end

local function configureBeamModel(model: Instance): {start: BasePart?, ending: BasePart?, hitbox: BasePart?, baseHitboxSize: Vector3?, parts: {BasePart}?}
	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if descendant:GetAttribute("__OrigTransparency") == nil then
				descendant:SetAttribute("__OrigTransparency", descendant.Transparency)
			end
			if descendant:GetAttribute("__OrigSize") == nil then
				descendant:SetAttribute("__OrigSize", descendant.Size)
			end
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			table.insert(parts, descendant)
		end
	end
	local startPart = model:FindFirstChild("Start", true)
	local endPart = model:FindFirstChild("End", true)
	local hitbox = model:FindFirstChild("Hitbox", true)
	local baseHitboxSize = nil
	if hitbox and hitbox:IsA("BasePart") then
		baseHitboxSize = hitbox.Size
	end
	return {
		start = startPart :: BasePart?,
		ending = endPart :: BasePart?,
		hitbox = hitbox :: BasePart?,
		baseHitboxSize = baseHitboxSize,
		parts = parts,
	}
end

local function acquireBeamModel(): (Instance?, {start: BasePart?, ending: BasePart?, hitbox: BasePart?, baseHitboxSize: Vector3?, parts: {BasePart}?}?)
	local model = #beamPool > 0 and table.remove(beamPool) or nil
	if model then
		model.Parent = projectilesFolder
		return model, beamVisualsByModel[model]
	end

	local template = getRefractionsTemplate()
	if not template then
		return nil, nil
	end
	model = template:Clone()
	model.Parent = projectilesFolder
	model:SetAttribute("RecordProjectile", true)
	local visual = configureBeamModel(model)
	beamVisualsByModel[model] = visual
	return model, visual
end

local function releaseBeamModel(record: ProjectileRecord)
	local model = record.model
	if not model then
		return
	end
	model.Parent = nil
	if #beamPool < MAX_BEAM_POOL_SIZE then
		table.insert(beamPool, model)
	end
	record.model = nil
	record.parts = nil
	record.primary = nil
	record.beamVisual = nil
	record.renderEnabled = false
end

local function acquireModel(modelPath: string?): (Model?, BasePart?, {BasePart}?)
	if not modelPath then
		return nil, nil, nil
	end
	local pool = modelPoolByPath[modelPath]
	local model = pool and table.remove(pool) or nil
	if not model then
		local template = findModelByPath(modelPath)
		if not template then
			return nil, nil, nil
		end
		model = template:Clone()
	end
	model.Parent = projectilesFolder
	model:SetAttribute("RecordProjectile", true)
	local primary, parts = configureModel(model)
	return model, primary, parts
end

local function acquireImpactModel(modelPath: string?): Model?
	if not modelPath then
		return nil
	end
	local pool = impactPoolByPath[modelPath]
	local model = pool and table.remove(pool) or nil
	if not model then
		local template = findModelByPath(modelPath)
		if not template then
			return nil
		end
		model = template:Clone()
	end
	model.Parent = projectilesFolder
	model:SetAttribute("RecordProjectile", true)
	configureModel(model)
	return model
end

local function releaseImpactModel(modelPath: string, model: Model)
	model.Parent = nil
	local pool = impactPoolByPath[modelPath]
	if not pool then
		pool = {}
		impactPoolByPath[modelPath] = pool
	end
	if #pool < MAX_IMPACT_POOL_SIZE then
		table.insert(pool, model)
	end
end

local function releaseModel(record: ProjectileRecord)
	local model = record.model
	if not model then
		return
	end
	if record.beam and record.beamVisual then
		releaseBeamModel(record)
		return
	end
	model.Parent = nil
	if record.modelPath then
		local pool = modelPoolByPath[record.modelPath]
		if not pool then
			pool = {}
			modelPoolByPath[record.modelPath] = pool
		end
		if #pool < MAX_POOL_SIZE then
			table.insert(pool, model)
		end
	end
	record.model = nil
	record.primary = nil
	record.parts = nil
	record.renderEnabled = false
end

local function getProjectileOpacity(record: ProjectileRecord): number
	if record.ownerUserId and record.ownerUserId ~= player.UserId then
		return projectileOpacityOthers
	end
	return projectileOpacitySelf
end

local function scaleTransparencyValue(original: number, opacityScale: number): number
	return original + (1 - original) * (1 - opacityScale)
end

local function scaleNumberSequenceTransparency(original: NumberSequence, opacityScale: number): NumberSequence
	local keypoints = table.create(#original.Keypoints)
	for index, keypoint in ipairs(original.Keypoints) do
		keypoints[index] = NumberSequenceKeypoint.new(
			keypoint.Time,
			scaleTransparencyValue(keypoint.Value, opacityScale),
			keypoint.Envelope
		)
	end
	return NumberSequence.new(keypoints)
end

local function applyProjectileVfxOpacity(record: ProjectileRecord, opacityScale: number)
	local model = record.model
	if not model then
		return
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			local original = emitterTransparencyByInstance[descendant]
			if not original then
				original = descendant.Transparency
				emitterTransparencyByInstance[descendant] = original
			end
			descendant.Transparency = scaleNumberSequenceTransparency(original, opacityScale)
		elseif descendant:IsA("Trail") then
			local original = trailTransparencyByInstance[descendant]
			if not original then
				original = descendant.Transparency
				trailTransparencyByInstance[descendant] = original
			end
			descendant.Transparency = scaleNumberSequenceTransparency(original, opacityScale)
		elseif descendant:IsA("Beam") then
			local original = beamTransparencyByInstance[descendant]
			if not original then
				original = descendant.Transparency
				beamTransparencyByInstance[descendant] = original
			end
			descendant.Transparency = scaleNumberSequenceTransparency(original, opacityScale)
		end
	end
end

local function colorizeSequence(original: ColorSequence, visualColor: Color3): ColorSequence
	local keypoints = table.create(#original.Keypoints)
	for index, keypoint in ipairs(original.Keypoints) do
		keypoints[index] = ColorSequenceKeypoint.new(keypoint.Time, visualColor)
	end
	return ColorSequence.new(keypoints)
end

local function applyProjectileVfxColor(record: ProjectileRecord)
	local model = record.model
	if not model or not record.visualColor then
		return
	end

	local visualColor = record.visualColor
	local petalEmitter: ParticleEmitter? = nil
	if not record.beam and record.petal and record.petal.role then
		local hitbox = model:FindFirstChild("Hitbox", true)
		if hitbox then
			local emitter = hitbox:FindFirstChild("Petals")
			if emitter and emitter:IsA("ParticleEmitter") then
				petalEmitter = emitter
			end
		end
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			local original = emitterColorByInstance[descendant]
			if not original then
				original = descendant.Color
				emitterColorByInstance[descendant] = original
			end
			if descendant ~= petalEmitter then
				descendant.Color = colorizeSequence(original, visualColor)
			end
		elseif descendant:IsA("Trail") then
			local original = trailColorByInstance[descendant]
			if not original then
				original = descendant.Color
				trailColorByInstance[descendant] = original
			end
			descendant.Color = colorizeSequence(original, visualColor)
		elseif descendant:IsA("Beam") then
			local original = beamColorByInstance[descendant]
			if not original then
				original = descendant.Color
				beamColorByInstance[descendant] = original
			end
			descendant.Color = colorizeSequence(original, visualColor)
		elseif descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
			descendant.Color = visualColor
		end
	end
end

local function applyProjectileOpacity(record: ProjectileRecord)
	local opacityScale = getProjectileOpacity(record)
	if record.parts then
		for _, part in ipairs(record.parts) do
			local originalTransparency = part:GetAttribute("__OrigTransparency")
			if typeof(originalTransparency) ~= "number" then
				originalTransparency = part.Transparency
				part:SetAttribute("__OrigTransparency", originalTransparency)
			end
			part.Transparency = scaleTransparencyValue(originalTransparency, opacityScale)
		end
	end
	applyProjectileVfxOpacity(record, opacityScale)
end

local function applyVisual(record: ProjectileRecord)
	local model = record.model
	if not model then
		return
	end
	if record.parts and record.visualColor then
		for _, part in ipairs(record.parts) do
			part.Color = record.visualColor
		end
	end
	applyProjectileVfxColor(record)
	if not record.beam then
		local scale = record.visualScale or 1
		pcall(function()
			model:ScaleTo(scale :: number)
		end)
	end
	if not record.beam and record.petal and record.petal.role then
		local hitbox = model:FindFirstChild("Hitbox", true)
		if hitbox then
			local emitter = hitbox:FindFirstChild("Petals")
			if emitter and emitter:IsA("ParticleEmitter") then
				if record.petal.role == "toughest" then
					emitter.Color = ColorSequence.new(PETAL_COLOR_TOUGHEST)
				else
					emitter.Color = ColorSequence.new(PETAL_COLOR_CLOSEST)
				end
			end
		end
	end
	applyProjectileOpacity(record)
end

local function updateModelTransform(record: ProjectileRecord, position: Vector3, direction: Vector3)
	if record.beam and record.beamVisual then
		return
	end
	local model = record.model
	if not model then
		return
	end
	if direction.Magnitude == 0 then
		model:PivotTo(CFrame.new(position))
		return
	end
	model:PivotTo(CFrame.lookAt(position, position + direction))
end

local function updateBeamTransform(record: ProjectileRecord, pivot: Vector3, direction: Vector3)
	local visual = record.beamVisual
	local beam = record.beam
	if not visual or not beam then
		return
	end
	if direction.Magnitude == 0 then
		direction = Vector3.new(0, 0, 1)
	end
	local beamSize = beam.size
	local beamOffset = beam.offset or Vector3.new(0, 0, 0)
	local beamRotation = beam.rotation
	local lengthAxis = beam.lengthAxis or "Z"
	local length = beam.length or 0
	if beamSize then
		if lengthAxis == "X" then
			length = beamSize.X
		elseif lengthAxis == "Y" then
			length = beamSize.Y
		else
			length = beamSize.Z
		end
	end
	if length <= 0 then
		length = 1
	end

	local cf = CFrame.lookAt(pivot, pivot + direction)
	if beamRotation then
		cf = cf * beamRotation
	end
	local center = cf:PointToWorldSpace(beamOffset)
	local axisDir = cf.LookVector
	if lengthAxis == "X" then
		axisDir = cf.RightVector
	elseif lengthAxis == "Y" then
		axisDir = cf.UpVector
	end
	local halfLen = length * 0.5
	local startPos = center - axisDir * halfLen
	local endPos = center + axisDir * halfLen
	if record.beamEndJitter == nil then
		record.beamEndJitter = (math.random() * (BEAM_END_EXTEND_MAX - BEAM_END_EXTEND_MIN)) + BEAM_END_EXTEND_MIN
	end
	endPos = endPos + axisDir * (record.beamEndJitter :: number)

	if visual.start then
		visual.start.CFrame = CFrame.lookAt(startPos, endPos)
	end
	if visual.ending then
		visual.ending.CFrame = CFrame.lookAt(endPos, endPos + axisDir)
	end
	if visual.hitbox then
		if beamSize then
			visual.hitbox.Size = beamSize
		elseif visual.baseHitboxSize then
			visual.hitbox.Size = visual.baseHitboxSize
		end
		local hitboxCf = CFrame.fromMatrix(center, cf.RightVector, cf.UpVector, cf.LookVector)
		visual.hitbox.CFrame = hitboxCf
	end
end

local function playExplosionVfx(model: Model, visibilityScale: number?)
	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	if #parts == 0 then
		return
	end
	explosionTokenCounter += 1
	local token = explosionTokenCounter
	model:SetAttribute("__ExplosionToken", token)
	local visibility = math.clamp(visibilityScale or 1, 0, 1)

	local startScale = 0.001
	for _, part in ipairs(parts) do
		local originalSize = part:GetAttribute("__OrigSize")
		if typeof(originalSize) ~= "Vector3" then
			originalSize = part.Size
			part:SetAttribute("__OrigSize", originalSize)
		end
		local originalTransparency = part:GetAttribute("__OrigTransparency")
		if typeof(originalTransparency) ~= "number" then
			originalTransparency = part.Transparency
			part:SetAttribute("__OrigTransparency", originalTransparency)
		end
		part.Size = Vector3.new(
			originalSize.X * startScale,
			originalSize.Y * startScale,
			originalSize.Z * startScale
		)
		part.Transparency = originalTransparency + (1 - originalTransparency) * (1 - visibility)
	end

	local expandStepDuration = EXPLOSION_STEPS > 0 and (EXPLOSION_EXPAND_DURATION / EXPLOSION_STEPS) or 0
	for step = 1, EXPLOSION_STEPS do
		local t = step / EXPLOSION_STEPS
		local sizeAlpha = startScale + (1 - startScale) * t
		local scheduledDelay = (step - 1) * expandStepDuration
		task.delay(scheduledDelay, function()
			if model:GetAttribute("__ExplosionToken") ~= token then
				return
			end
			for _, part in ipairs(parts) do
				if part and part.Parent then
					local originalSize = part:GetAttribute("__OrigSize")
					if typeof(originalSize) ~= "Vector3" then
						originalSize = part.Size
					end
					part.Size = originalSize * sizeAlpha
				end
			end
		end)
	end

	local fadeStepDuration = EXPLOSION_STEPS > 0 and (EXPLOSION_FADE_DURATION / EXPLOSION_STEPS) or 0
	for step = 1, EXPLOSION_STEPS do
		local fadeAlpha = step / EXPLOSION_STEPS
		local scheduledDelay = EXPLOSION_EXPAND_DURATION + (step - 1) * fadeStepDuration
		task.delay(scheduledDelay, function()
			if model:GetAttribute("__ExplosionToken") ~= token then
				return
			end
			for _, part in ipairs(parts) do
				if part and part.Parent then
					local originalTransparency = part:GetAttribute("__OrigTransparency")
					if typeof(originalTransparency) ~= "number" then
						originalTransparency = part.Transparency
					end
					local startTransparency = originalTransparency + (1 - originalTransparency) * (1 - visibility)
					local transparencyTarget = startTransparency + (1 - startTransparency) * fadeAlpha
					part.Transparency = transparencyTarget
				end
			end
		end)
	end

	task.delay(EXPLOSION_EXPAND_DURATION + EXPLOSION_FADE_DURATION + 0.05, function()
		if model:GetAttribute("__ExplosionToken") ~= token then
			return
		end
		for _, part in ipairs(parts) do
			if part and part.Parent then
				local originalSize = part:GetAttribute("__OrigSize")
				if typeof(originalSize) ~= "Vector3" then
					originalSize = part.Size
				end
				part.Transparency = 1
				part.Size = originalSize
			end
		end
	end)
end

local function spawnImpactEffect(effect: any, position: Vector3, ownerUserId: number?)
	if typeof(effect) ~= "table" then
		return
	end
	local modelPath = effect.modelPath
	if typeof(modelPath) ~= "string" then
		return
	end
	local isOtherPlayer = ownerUserId ~= nil and ownerUserId ~= player.UserId
	local visibility = if isOtherPlayer then otherPlayerVfxOpacity else 1.0
	if visibility <= 0 then
		return
	end
	local delayTime = typeof(effect.delay) == "number" and effect.delay or 0
	task.delay(delayTime, function()
		local model = acquireImpactModel(modelPath)
		if not model then
			return
		end
		local scale = typeof(effect.scale) == "number" and effect.scale or nil
		if scale and isOtherPlayer and reduceMotion then
			scale *= 0.8
		end
		if scale then
			pcall(function()
				model:ScaleTo(scale)
			end)
			for _, descendant in ipairs(model:GetDescendants()) do
				if descendant:IsA("BasePart") then
					descendant:SetAttribute("__OrigSize", descendant.Size)
				end
			end
		end
		model:PivotTo(CFrame.new(position))
		playExplosionVfx(model, visibility)

		local duration = typeof(effect.duration) == "number" and effect.duration or (EXPLOSION_EXPAND_DURATION + EXPLOSION_FADE_DURATION)
		if isOtherPlayer and reduceMotion then
			duration *= 0.55
		end
		local cleanupDelay = math.max(duration, EXPLOSION_EXPAND_DURATION + EXPLOSION_FADE_DURATION) + 0.1
		task.delay(cleanupDelay, function()
			if model and model.Parent then
				releaseImpactModel(modelPath, model)
			end
		end)
	end)
end

local function refreshEnemySnapshot(now: number)
	if now - lastEnemySnapshot < ENEMY_SNAPSHOT_INTERVAL then
		return
	end
	lastEnemySnapshot = now

	if not enemiesFolder then
		enemiesFolder = workspace:FindFirstChild("Enemies") :: Folder?
	end
	table.clear(enemySnapshot)
	if not enemiesFolder then
		return
	end
	for _, model in ipairs(enemiesFolder:GetChildren()) do
		if model:IsA("Model") then
			local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
			if primary then
				table.insert(enemySnapshot, {
					pos = primary.Position,
				})
			end
		end
	end
end

local function getOwnerRootPart(userId: number?): BasePart?
	if not userId then
		return nil
	end
	local owner = Players:GetPlayerByUserId(userId)
	if not owner then
		return nil
	end
	local character = owner.Character
	if not character then
		return nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function getOwnerLeftArmGripAttachment(userId: number?): Attachment?
	if not userId then
		return nil
	end
	local owner = Players:GetPlayerByUserId(userId)
	if not owner then
		return nil
	end
	local character = owner.Character
	if not character then
		return nil
	end

	local exact = character:FindFirstChild("LeftArmGripAttachment", true)
	if exact and exact:IsA("Attachment") then
		return exact
	end
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("Attachment") then
			local lowered = string.lower(descendant.Name)
			if string.find(lowered, "left", 1, true) and string.find(lowered, "grip", 1, true) then
				return descendant
			end
		end
	end
	return nil
end

local function resolveInitialVisualSpawnPosition(kind: string, ownerUserId: number?, isSplitChild: boolean, fallback: Vector3): Vector3
	if kind ~= "IceShardSpecial" then
		return fallback
	end
	if isSplitChild then
		return fallback
	end
	if ownerUserId ~= player.UserId then
		return fallback
	end
	local leftGripAttachment = getOwnerLeftArmGripAttachment(ownerUserId)
	if leftGripAttachment then
		return leftGripAttachment.WorldPosition
	end
	return fallback
end

local function findNearestEnemy(position: Vector3, radius: number): Vector3?
	local closest: Vector3? = nil
	local radiusSq = radius * radius
	for _, entry in ipairs(enemySnapshot) do
		local delta = entry.pos - position
		local distSq = delta:Dot(delta)
		if distSq <= radiusSq then
			radiusSq = distSq
			closest = entry.pos
		end
	end
	return closest
end

local function updateHoming(record: ProjectileRecord, dt: number, now: number)
	local homing = record.homing
	if not homing then
		return
	end
	if record.lastHomingUpdate and (now - record.lastHomingUpdate) < HOMING_UPDATE_INTERVAL then
		return
	end
	record.lastHomingUpdate = now

	local currentPos = record.lastPos or record.origin
	local acquireRadius = homing.acquireRadius or 80
	local targetPos = findNearestEnemy(currentPos, acquireRadius)
	if not targetPos then
		return
	end
	local desired = targetPos - currentPos
	if homing.stayHorizontal or homing.alwaysStayHorizontal then
		desired = Vector3.new(desired.X, 0, desired.Z)
	end
	if desired.Magnitude == 0 then
		return
	end
	desired = desired.Unit

	local currentDir = record.direction
	local dot = math.clamp(currentDir:Dot(desired), -1, 1)
	local angle = math.acos(dot)
	if homing.maxAngleDeg and angle > math.rad(homing.maxAngleDeg) then
		return
	end
	if angle <= 0.0001 then
		record.direction = desired
		return
	end

	local maxTurn = homing.maxTurnDeg and math.rad(homing.maxTurnDeg) or math.huge
	local maxStep = math.rad(homing.strengthDeg or DEFAULT_HOMING_STRENGTH) * dt
	local turn = math.min(angle, maxTurn, maxStep)
	local axis = currentDir:Cross(desired)
	if axis.Magnitude <= 0.0001 then
		record.direction = desired
		return
	end
	axis = axis.Unit
	local rotation = CFrame.fromAxisAngle(axis, turn)
	record.direction = rotation:VectorToWorldSpace(currentDir).Unit
end

local function updatePetal(record: ProjectileRecord, dt: number, now: number): boolean
	local petal = record.petal
	if not petal then
		return false
	end
	local ownerUserId = petal.ownerUserId or record.ownerUserId
	if not ownerUserId then
		return false
	end
	local ownerRoot = getOwnerRootPart(ownerUserId)
	if not ownerRoot then
		return false
	end
	local ownerPos = ownerRoot.Position
	local maxRange = petal.maxRange or 100
	local cache = petalTargetCache[ownerUserId]
	if not cache or (now - cache.time) > PETAL_TARGET_REFRESH or cache.range ~= maxRange then
		local radiusSq = maxRange * maxRange
		local closestPos: Vector3? = nil
		local closestDistSq = radiusSq
		local closestIndex: number? = nil
		local candidates: {{pos: Vector3, distSq: number}} = {}
		for index, entry in ipairs(enemySnapshot) do
			local delta = entry.pos - ownerPos
			local distSq = delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z
			if distSq <= radiusSq then
				table.insert(candidates, { pos = entry.pos, distSq = distSq })
				if distSq < closestDistSq then
					closestDistSq = distSq
					closestPos = entry.pos
					closestIndex = index
				end
			end
		end
		local toughestPos = closestPos
		if closestPos and #candidates > 1 then
			local minSepSq = PETAL_MIN_SEPARATION * PETAL_MIN_SEPARATION
			local bestSepPos: Vector3? = nil
			local bestSepSq = -math.huge
			local bestAnyPos: Vector3? = nil
			local bestAnyDistSq = -math.huge
			for idx, candidate in ipairs(candidates) do
				if idx ~= closestIndex then
					local sep = candidate.pos - closestPos
					local sepSq = sep.X * sep.X + sep.Y * sep.Y + sep.Z * sep.Z
					if sepSq >= minSepSq and sepSq > bestSepSq then
						bestSepSq = sepSq
						bestSepPos = candidate.pos
					end
					if candidate.distSq > bestAnyDistSq then
						bestAnyDistSq = candidate.distSq
						bestAnyPos = candidate.pos
					end
				end
			end
			toughestPos = bestSepPos or bestAnyPos or closestPos
		end

		cache = {
			time = now,
			range = maxRange,
			closest = closestPos,
			toughest = toughestPos,
		}
		petalTargetCache[ownerUserId] = cache
	end

	local targetPos = (petal.role == "toughest") and cache.toughest or cache.closest
	if not targetPos then
		return false
	end
	if (targetPos - ownerPos).Magnitude > maxRange then
		return false
	end
	local currentPos = record.lastPos or record.origin
	local desired = targetPos - currentPos
	if petal.stayHorizontal or petal.alwaysStayHorizontal then
		desired = Vector3.new(desired.X, 0, desired.Z)
	end
	if desired.Magnitude == 0 then
		return false
	end
	desired = desired.Unit

	local currentDir = record.direction
	local dot = math.clamp(currentDir:Dot(desired), -1, 1)
	local angle = math.acos(dot)
	local maxAngle = petal.homingMaxAngle and math.rad(petal.homingMaxAngle) or math.huge
	if maxAngle < math.pi and angle > maxAngle then
		return false
	end
	if angle <= 0.0001 then
		record.direction = desired
		return true
	end

	local strength = petal.homingStrength or DEFAULT_HOMING_STRENGTH
	local maxTurn = math.huge
	if record.homing and record.homing.maxTurnDeg then
		maxTurn = math.rad(record.homing.maxTurnDeg)
	end
	local maxStep = math.rad(strength) * dt
	local turn = math.min(angle, maxTurn, maxStep)
	local axis = currentDir:Cross(desired)
	if axis.Magnitude <= 0.0001 then
		record.direction = desired
		return true
	end
	axis = axis.Unit
	local rotation = CFrame.fromAxisAngle(axis, turn)
	record.direction = rotation:VectorToWorldSpace(currentDir).Unit
	return true
end

local function shouldRenderAt(position: Vector3, threshold: number): boolean
	local camera = workspace.CurrentCamera
	if not camera then
		return true
	end
	local delta = position - camera.CFrame.Position
	return delta:Dot(delta) <= threshold * threshold
end

local function ensureModel(record: ProjectileRecord, position: Vector3)
	if record.model then
		return
	end
	if not shouldRenderAt(position, renderDistance) then
		record.renderEnabled = false
		return
	end
	if record.beam then
		local model, visual = acquireBeamModel()
		if model and visual then
			record.model = model
			record.parts = visual.parts
			record.beamVisual = visual
			record.renderEnabled = true
			applyVisual(record)
		else
			local fallbackModel, _, parts = acquireModel(record.modelPath)
			if not fallbackModel then
				return
			end
			record.model = fallbackModel
			record.parts = parts
			record.renderEnabled = true
			applyVisual(record)
		end
	else
		local model, _, parts = acquireModel(record.modelPath)
		if not model then
			return
		end
		record.model = model
		record.parts = parts
		record.renderEnabled = true
		applyVisual(record)
	end
end

local function despawnProjectile(id: number)
	local record = activeProjectiles[id]
	if not record then
		return
	end
	releaseModel(record)
	activeProjectiles[id] = nil
end

local function applySettingsFromAttributes()
	projectileOpacitySelf = readNumberSetting(ATTR_PROJECTILE_OPACITY_SELF, 1.0, 0.25, 1.00)
	projectileOpacityOthers = readNumberSetting(ATTR_PROJECTILE_OPACITY_OTHERS, 1.0, 0.05, 1.00)
	otherPlayerVfxOpacity = readNumberSetting(ATTR_OTHER_PLAYER_VFX_OPACITY, 1.0, 0.00, 1.00)
	reduceMotion = readBoolSetting(ATTR_REDUCE_MOTION, false)

	for _, record in pairs(activeProjectiles) do
		if record.model then
			applyProjectileOpacity(record)
			local pos = record.lastPos or record.origin
			if not shouldRenderAt(pos, renderDisableDistance) then
				releaseModel(record)
			end
		end
	end
end

player:GetAttributeChangedSignal(ATTR_PROJECTILE_OPACITY_SELF):Connect(applySettingsFromAttributes)
player:GetAttributeChangedSignal(ATTR_PROJECTILE_OPACITY_OTHERS):Connect(applySettingsFromAttributes)
player:GetAttributeChangedSignal(ATTR_OTHER_PLAYER_VFX_OPACITY):Connect(applySettingsFromAttributes)
player:GetAttributeChangedSignal(ATTR_REDUCE_MOTION):Connect(applySettingsFromAttributes)
applySettingsFromAttributes()

ProjectilesSpawnBatch.OnClientEvent:Connect(function(payloads: any)
	if typeof(payloads) ~= "table" then
		return
	end
	local now = tick()
	for _, data in ipairs(payloads) do
		if typeof(data) ~= "table" then
			continue
		end
		local id = data.id
		if typeof(id) ~= "number" then
			continue
		end
		local origin = toVector3(data.origin)
		if not origin then
			continue
		end
		local direction = toVector3(data.dir) or Vector3.new(0, 0, 1)
		if direction.Magnitude == 0 then
			direction = Vector3.new(0, 0, 1)
		else
			direction = direction.Unit
		end

		local speed = typeof(data.speed) == "number" and data.speed or 0
		local spawnTime = typeof(data.spawnTime) == "number" and data.spawnTime or now
		local lifetime = typeof(data.lifetime) == "number" and data.lifetime or nil
		local ownerUserId = typeof(data.ownerUserId) == "number" and data.ownerUserId or nil
		local kind = typeof(data.kind) == "string" and data.kind or "Projectile"
		local isSplitChild = data.isSplitChild == true
		local age = math.max(now - spawnTime, 0)
		if lifetime then
			age = math.min(age, lifetime)
		end
		local simulatedPos = origin + direction * speed * age
		local initialPos = resolveInitialVisualSpawnPosition(kind, ownerUserId, isSplitChild, simulatedPos)

		local record = activeProjectiles[id]
		if not record then
			record = {
				id = id,
				kind = kind,
				origin = origin,
				direction = direction,
				speed = speed,
				spawnTime = spawnTime,
				lifetime = lifetime,
				expiresAt = lifetime and (spawnTime + lifetime) or nil,
				modelPath = resolveModelPath(kind, data.modelPath),
				visualScale = typeof(data.scale) == "number" and data.scale or nil,
				visualColor = typeof(data.color) == "Color3" and data.color or nil,
				ownerUserId = ownerUserId,
				stayHorizontal = data.stayHorizontal == true,
				alwaysStayHorizontal = data.alwaysStayHorizontal == true,
				stickToPlayer = data.stickToPlayer == true,
				orbit = typeof(data.orbit) == "table" and data.orbit or nil,
				homing = typeof(data.homing) == "table" and data.homing or nil,
				petal = typeof(data.petal) == "table" and data.petal or nil,
				beam = typeof(data.beam) == "table" and data.beam or nil,
				lastSimTime = now,
				lastPos = initialPos,
				lastOwnerPos = nil,
				stickOffset = nil,
				isSplitChild = isSplitChild,
			}
			activeProjectiles[id] = record
		else
			record.kind = kind
			record.origin = origin
			record.direction = direction
			record.speed = speed
			record.spawnTime = spawnTime
			record.lifetime = lifetime
			record.expiresAt = lifetime and (spawnTime + lifetime) or nil
			record.modelPath = resolveModelPath(record.kind, data.modelPath) or record.modelPath
			record.visualScale = typeof(data.scale) == "number" and data.scale or record.visualScale
			record.visualColor = typeof(data.color) == "Color3" and data.color or record.visualColor
			record.ownerUserId = ownerUserId or record.ownerUserId
			record.stayHorizontal = data.stayHorizontal == true
			record.alwaysStayHorizontal = data.alwaysStayHorizontal == true
			record.stickToPlayer = data.stickToPlayer == true
			record.orbit = typeof(data.orbit) == "table" and data.orbit or record.orbit
			record.homing = typeof(data.homing) == "table" and data.homing or record.homing
			record.petal = typeof(data.petal) == "table" and data.petal or record.petal
			record.beam = typeof(data.beam) == "table" and data.beam or record.beam
			record.lastSimTime = now
			record.lastPos = initialPos
			record.lastOwnerPos = nil
			record.stickOffset = nil
			record.isSplitChild = isSplitChild
		end

		if record.orbit and not record.orbit.ownerUserId then
			record.orbit.ownerUserId = record.ownerUserId
		end
		if record.petal and not record.petal.ownerUserId then
			record.petal.ownerUserId = record.ownerUserId
		end

		if record.stickToPlayer and record.ownerUserId then
			local ownerRoot = getOwnerRootPart(record.ownerUserId)
			if ownerRoot then
				record.lastOwnerPos = ownerRoot.Position
				if record.kind == "Refractions" then
					record.stickOffset = Vector3.new(0, 0, 0)
				else
					record.stickOffset = origin - ownerRoot.Position
				end
			end
		end

		ensureModel(record, initialPos)
		if record.beam and record.beamVisual then
			updateBeamTransform(record, initialPos, direction)
		else
			updateModelTransform(record, initialPos, direction)
		end
	end
end)

ProjectilesDespawnBatch.OnClientEvent:Connect(function(payloads: any)
	if typeof(payloads) ~= "table" then
		return
	end
	for _, entry in ipairs(payloads) do
		if typeof(entry) == "number" then
			despawnProjectile(entry)
		elseif typeof(entry) == "table" and typeof(entry.id) == "number" then
			despawnProjectile(entry.id)
		end
	end
end)

ProjectilesImpactBatch.OnClientEvent:Connect(function(payloads: any)
	if typeof(payloads) ~= "table" then
		return
	end
	for _, entry in ipairs(payloads) do
		if typeof(entry) ~= "table" then
			continue
		end
		local id = entry.id
		if typeof(id) ~= "number" then
			continue
		end
		local impactPos = toVector3(entry.pos)
		local record = activeProjectiles[id]
		if record and impactPos then
			if record.beam and record.beamVisual then
				updateBeamTransform(record, impactPos, record.direction)
			else
				updateModelTransform(record, impactPos, record.direction)
			end
		end
		if impactPos and entry.effect then
			local effectOwner = typeof(entry.ownerUserId) == "number" and entry.ownerUserId or nil
			spawnImpactEffect(entry.effect, impactPos, effectOwner)
		end
		if entry.despawn ~= false then
			despawnProjectile(id)
		end
	end
end)

local pauseProjectiles = false -- Projectiles keep moving during pause unless explicitly frozen.
local pauseStartTime = 0

local GamePaused = remotesFolder:WaitForChild("GamePaused") :: RemoteEvent
local GameUnpaused = remotesFolder:WaitForChild("GameUnpaused") :: RemoteEvent

GamePaused.OnClientEvent:Connect(function(data: any)
	if data and data.freezeProjectiles then
		pauseProjectiles = true
		pauseStartTime = tick()
	end
end)

GameUnpaused.OnClientEvent:Connect(function()
	if not pauseProjectiles then
		return
	end
	pauseProjectiles = false
	local pauseDuration = tick() - pauseStartTime

	for _, record in pairs(activeProjectiles) do
		if record.spawnTime then
			record.spawnTime += pauseDuration
		end
		if record.expiresAt then
			record.expiresAt += pauseDuration
		end
		if record.lastSimTime then
			record.lastSimTime += pauseDuration
		end
		if record.lastHomingUpdate then
			record.lastHomingUpdate += pauseDuration
		end
	end
end)

RunService.Heartbeat:Connect(function(dt: number)
	if pauseProjectiles then
		return
	end

	local now = tick()
	refreshEnemySnapshot(now)

	for id, record in pairs(activeProjectiles) do
		local lifetime = record.lifetime
		if lifetime and (now - record.spawnTime) > lifetime then
			despawnProjectile(id)
			continue
		end

		local pos = record.lastPos or record.origin
		local dtSim = now - (record.lastSimTime or now)
		if dtSim > 0 then
			if record.petal then
				local shouldMove = updatePetal(record, dtSim, now)
				if shouldMove then
					pos = pos + record.direction * record.speed * dtSim
				end
			elseif record.orbit then
				local ownerRoot = getOwnerRootPart(record.orbit.ownerUserId)
				if ownerRoot then
					local angle = (record.orbit.angle or 0) + math.rad(record.orbit.speedDeg or 0) * dtSim
					record.orbit.angle = angle
					pos = ownerRoot.Position + Vector3.new(math.cos(angle) * record.orbit.radius, 0, math.sin(angle) * record.orbit.radius)
					record.direction = Vector3.new(-math.sin(angle), 0, math.cos(angle)).Unit
				end
			elseif record.homing then
				updateHoming(record, dtSim, now)
				pos = pos + record.direction * record.speed * dtSim
			else
				pos = pos + record.direction * record.speed * dtSim
			end

			if record.stickToPlayer and record.ownerUserId then
				local ownerRoot = getOwnerRootPart(record.ownerUserId)
				if ownerRoot then
					if record.kind == "Refractions" then
						pos = ownerRoot.Position
					elseif record.stickOffset then
						pos = ownerRoot.Position + record.stickOffset
					elseif record.lastOwnerPos then
						pos = pos + (ownerRoot.Position - record.lastOwnerPos)
					end
					record.lastOwnerPos = ownerRoot.Position
				end
			end

			if record.alwaysStayHorizontal and not record.stickToPlayer then
				pos = Vector3.new(pos.X, record.origin.Y, pos.Z)
			elseif record.homing and record.homing.alwaysStayHorizontal then
				pos = Vector3.new(pos.X, record.origin.Y, pos.Z)
			end

			record.lastPos = pos
			record.lastSimTime = now
		end

		if record.model then
			if not shouldRenderAt(pos, renderDisableDistance) then
				releaseModel(record)
			end
		else
			ensureModel(record, pos)
		end

		if record.model then
			if record.beam and record.beamVisual then
				updateBeamTransform(record, pos, record.direction)
			else
				updateModelTransform(record, pos, record.direction)
			end
		end
	end
end)
