--!strict
-- PickupRenderer - Client-side rendering + pickup requests for EXP orbs and interactable item drops.

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerScripts = player:FindFirstChild("PlayerScripts")
if not playerScripts then
	playerScripts = player:WaitForChild("PlayerScripts", 10)
end
local scriptsContainer = playerScripts or script:FindFirstAncestor("StarterPlayerScripts")
local PickupPromptState: any = nil
if scriptsContainer then
	local localSharedFolder = scriptsContainer:WaitForChild("_Shared", 10)
	if localSharedFolder then
		PickupPromptState = require(localSharedFolder:WaitForChild("PickupPromptState"))
	else
		warn("[PickupRenderer] Could not locate _Shared folder; item pickup prompt disabled")
	end
else
	warn("[PickupRenderer] Could not locate PlayerScripts container; item pickup prompt disabled")
end

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local pickupRemotesFolder = remotesFolder:WaitForChild("Pickups")
local PickupsSpawnBatch = pickupRemotesFolder:WaitForChild("PickupsSpawnBatch") :: RemoteEvent
local PickupsDespawnBatch = pickupRemotesFolder:WaitForChild("PickupsDespawnBatch") :: RemoteEvent
local PickupsValueUpdate = pickupRemotesFolder:WaitForChild("PickupsValueUpdate") :: RemoteEvent
local PickupRequest = pickupRemotesFolder:WaitForChild("PickupRequest") :: RemoteEvent
local debugFlags = ReplicatedStorage:FindFirstChild("DebugFlags") or ReplicatedStorage:WaitForChild("DebugFlags", 10)
local enableCommonItemDiagnostics = debugFlags and (debugFlags:FindFirstChild("CommonItemDiagnostics") or debugFlags:WaitForChild("CommonItemDiagnostics", 10))

local pickupsFolder: Instance = workspace:FindFirstChild("Pickups") or Instance.new("Folder")
pickupsFolder.Name = "Pickups"
pickupsFolder.Parent = workspace

local BASE_SIZE = 1.1
local BOB_AMPLITUDE = 0.35
local BOB_FREQUENCY = 1.6
local SEEK_SPEED = 120
local CHECK_INTERVAL = 0.1
local REQUEST_RETRY_DELAY = 0.4
local SEEK_TIMEOUT = 1.5
local CONTACT_DESPAWN_DISTANCE = 2.0
local CONTACT_DESPAWN_DISTANCE_SQ = CONTACT_DESPAWN_DISTANCE * CONTACT_DESPAWN_DISTANCE
local ORB_TEMPLATE_PATH = {"ContentDrawer", "ItemModels", "OrbTemplate"}
local DEFAULT_INTERACT_RADIUS = 20
local DEFAULT_AUTO_PICKUP_RADIUS = 5
local DEFAULT_SPIN_PERIOD = 8
local ITEM_WORLD_SPIN_PERIOD = 15
local PICKUP_VISUAL_HEIGHT_OFFSET = 2.0
local COMMON_ITEM_AURA_PATH = "ReplicatedStorage.ContentDrawer.ItemModels.VFX.CommonAura"
local VFX_WARMUP_SECONDS = 5.0
local VFX_WARMUP_FPS = 60

local COLOR_BY_KIND = {
	expBlue = Color3.fromRGB(100, 150, 255),
	expOrange = Color3.fromRGB(255, 165, 0),
	expPurple = Color3.fromRGB(180, 100, 255),
	expRed = Color3.fromRGB(255, 60, 60),
}

local SCALE_BY_KIND = {
	expRed = 1.5,
}

type PickupRecord = {
	id: number,
	kind: string,
	value: number,
	position: Vector3,
	currentPos: Vector3,
	instance: Instance,
	primary: BasePart,
	parts: {BasePart}?,
	seed: number,
	lastRequestAt: number?,
	seeking: boolean?,
	seekStartAt: number?,
	collectible: boolean?,
	seekOnSpawn: boolean?,
	visualOnly: boolean?,
	modelPath: string?,
	itemId: string?,
	itemDisplayName: string?,
	itemDescription: string?,
	requiresInteract: boolean?,
	interactionRadius: number?,
	autoPickupRadius: number?,
	spinPeriod: number?,
	bobAmplitude: number?,
	visualKind: "part" | "orbModel" | "customModel" | "missingCustom",
	baseRotation: CFrame?,
}

local activePickups: {[number]: PickupRecord} = {}
local partPool: {BasePart} = {}
local modelPool: {Model} = {}
local MAX_POOL_SIZE = 300
local orbTemplate: Model? = nil
local commonItemAuraTemplate: Instance? = nil
local warnedMissingCustomPaths: {[string]: boolean} = {}
local loggedCustomVisualDebugByPath: {[string]: boolean} = {}
local warnedMissingCommonItemAura = false
-- Legacy common-item meshes are inconsistent: some SpecialMesh shells render inside-out, some lose
-- texture unless we clone only the shell part and normalize its old asset URLs. Future fixes should
-- be made here instead of changing the general pickup path:
-- 1) If an item is inverted, add its itemId to MIRRORED_SPECIAL_MESH_ITEM_AXES and choose the axis
--    that makes it face correctly ("x" is the common default; "z" fixed Teddy/Laser orientation).
-- 2) If an item has texture issues only, prefer a shell-only normalized clone path first.
-- 3) Compat paths clone only the corrected shell, so we copy the source Highlight back onto it.
-- Keep all non-problem items on the normal full-root clone path.
local MIRRORED_SPECIAL_MESH_ITEM_AXES: {[string]: "x" | "y" | "z"} = {
	adurite_cape = "x",
	apple = "x",
	bloxiade = "x",
	bloxy_cola = "x",
	cake = "x",
	cheezburger = "x",
	delete_tool = "x",
	energy_sword = "x",
	fuse_bomb = "x",
	magic_8_ball = "x",
	hot_sauce = "x",
	silver_ninja_star_of_the_brilliant_light = "x",
	speed_coil = "x",
	teddy_bloxpin = "z",
	regeneration_coil = "x",
	builders_club_hard_hat = "x",
	laser_electrocutor = "z",
	historic_timmy_gun = "x",
	healing_potion = "x",
	pepperoni_pizza = "y",
	survival_knife = "y",
	witches_brew = "x",
}
local COMMON_ITEM_ROTATION_OFFSETS: {[string]: CFrame} = {
	energy_sword = CFrame.Angles(math.pi, 0, 0),
	healing_potion = CFrame.Angles(0, 0, math.pi),
	magic_8_ball = CFrame.Angles(math.pi, 0, 0),
	pepperoni_pizza = CFrame.Angles(math.pi, 0, 0),
	survival_knife = CFrame.Angles(math.pi, 0, 0),
}
local NORMALIZE_ONLY_ITEM_IDS: {[string]: boolean} = {
}

local function setPickupPrompt(promptData: any)
	if PickupPromptState and PickupPromptState.setPrompt then
		PickupPromptState.setPrompt(promptData)
	end
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

local function createPickupPart(): BasePart
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(BASE_SIZE, BASE_SIZE, BASE_SIZE)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Name = "Pickup"
	return part
end

local function findOrbTemplate(): Model?
	if orbTemplate and orbTemplate.Parent then
		return orbTemplate
	end
	local current: Instance = ReplicatedStorage
	for _, name in ipairs(ORB_TEMPLATE_PATH) do
		local nextInstance = current:FindFirstChild(name)
		if not nextInstance then
			return nil
		end
		current = nextInstance
	end
	if current and current:IsA("Model") then
		orbTemplate = current
	end
	return orbTemplate
end

local function resolveInstanceByPath(path: string): Instance?
	local current: Instance? = game
	for _, partName in ipairs(string.split(path, ".")) do
		if not current then
			return nil
		end
		if partName == "ReplicatedStorage" then
			current = ReplicatedStorage
		else
			current = current:FindFirstChild(partName)
		end
	end
	return current
end

local function findVisualInstanceByPath(modelPath: string): Instance?
	local current = resolveInstanceByPath(modelPath)
	if current and (current:IsA("Model") or current:IsA("BasePart")) then
		return current
	end
	return nil
end

local function findCommonItemAuraTemplate(): Instance?
	if commonItemAuraTemplate and commonItemAuraTemplate.Parent then
		return commonItemAuraTemplate
	end
	local current = resolveInstanceByPath(COMMON_ITEM_AURA_PATH)
	if current then
		commonItemAuraTemplate = current
	end
	return commonItemAuraTemplate
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

local function isStuffingModelPath(modelPath: string?): boolean
	if typeof(modelPath) ~= "string" then
		return false
	end
	if modelPath == "ReplicatedStorage.ContentDrawer.ItemModels.CommonItems.Stuffing" then
		return true
	end
	return string.find(modelPath, ".TeddyBloxpin.Stuffing", 1, true) ~= nil
end

local function isCommonItemModelPath(modelPath: string?): boolean
	if typeof(modelPath) ~= "string" then
		return false
	end
	return string.find(modelPath, "ReplicatedStorage.ContentDrawer.ItemModels.CommonItems.", 1, true) == 1
end

local function buildVisualDebugSummary(instance: Instance): string
	if instance:IsA("MeshPart") then
		return string.format(
			"class=MeshPart name=%s texture=%s mesh=%s doubleSided=%s transparency=%.2f",
			instance.Name,
			tostring(instance.TextureID),
			tostring(instance.MeshId),
			tostring(instance.DoubleSided),
			instance.Transparency
		)
	end

	if instance:IsA("BasePart") then
		local specialMesh = instance:FindFirstChildWhichIsA("SpecialMesh")
		if specialMesh then
			return string.format(
				"class=%s name=%s specialMesh=%s mesh=%s texture=%s transparency=%.2f",
				instance.ClassName,
				instance.Name,
				specialMesh.Name,
				tostring(specialMesh.MeshId),
				tostring(specialMesh.TextureId),
				instance.Transparency
			)
		end
		return string.format(
			"class=%s name=%s transparency=%.2f",
			instance.ClassName,
			instance.Name,
			instance.Transparency
		)
	end

	if instance:IsA("Model") then
		return string.format("class=Model name=%s children=%d", instance.Name, #instance:GetChildren())
	end

	return string.format("class=%s name=%s", instance.ClassName, instance.Name)
end

local function normalizeLegacyAssetUrl(contentValue: string): string
	local assetId = string.match(contentValue, "[?&]id=(%d+)")
	if assetId then
		return "rbxassetid://" .. assetId
	end
	return contentValue
end

local function normalizeVisualAssetIds(instance: Instance)
	if instance:IsA("MeshPart") then
		local meshPart = instance :: MeshPart
		local meshId = tostring(meshPart.MeshId)
		local textureId = tostring(meshPart.TextureID)
		local normalizedMeshId = normalizeLegacyAssetUrl(meshId)
		local normalizedTextureId = normalizeLegacyAssetUrl(textureId)
		if normalizedMeshId ~= meshId then
			meshPart.MeshId = normalizedMeshId
		end
		if normalizedTextureId ~= textureId then
			meshPart.TextureID = normalizedTextureId
		end
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("MeshPart") then
			local meshPart = descendant :: MeshPart
			local meshId = tostring(meshPart.MeshId)
			local textureId = tostring(meshPart.TextureID)
			local normalizedMeshId = normalizeLegacyAssetUrl(meshId)
			local normalizedTextureId = normalizeLegacyAssetUrl(textureId)
			if normalizedMeshId ~= meshId then
				meshPart.MeshId = normalizedMeshId
			end
			if normalizedTextureId ~= textureId then
				meshPart.TextureID = normalizedTextureId
			end
		elseif descendant:IsA("SpecialMesh") then
			local meshId = tostring(descendant.MeshId)
			local textureId = tostring(descendant.TextureId)
			local normalizedMeshId = normalizeLegacyAssetUrl(meshId)
			local normalizedTextureId = normalizeLegacyAssetUrl(textureId)
			if normalizedMeshId ~= meshId then
				descendant.MeshId = normalizedMeshId
			end
			if normalizedTextureId ~= textureId then
				descendant.TextureId = normalizedTextureId
			end
		elseif descendant:IsA("FileMesh") then
			local meshId = tostring(descendant.MeshId)
			local textureId = tostring(descendant.TextureId)
			local normalizedMeshId = normalizeLegacyAssetUrl(meshId)
			local normalizedTextureId = normalizeLegacyAssetUrl(textureId)
			if normalizedMeshId ~= meshId then
				descendant.MeshId = normalizedMeshId
			end
			if normalizedTextureId ~= textureId then
				descendant.TextureId = normalizedTextureId
			end
		end
	end
end

local function findLegacyMesh(part: BasePart): Instance?
	return part:FindFirstChildWhichIsA("SpecialMesh") or part:FindFirstChildWhichIsA("FileMesh")
end

local function findLargestSpecialMeshPart(instance: Instance): BasePart?
	if instance:IsA("BasePart") and findLegacyMesh(instance) then
		return instance
	end
	if not instance:IsA("Model") then
		return nil
	end

	local bestPart: BasePart? = nil
	local bestScore = -math.huge
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") and findLegacyMesh(descendant) then
			local size = descendant.Size
			local score = size.X * size.Y * size.Z
			if score > bestScore then
				bestScore = score
				bestPart = descendant
			end
		end
	end
	return bestPart
end

local function buildMirroredSpecialMeshVisual(template: Instance, mirrorAxis: "x" | "y" | "z"): BasePart?
	local sourcePart = findLargestSpecialMeshPart(template)
	if not sourcePart then
		return nil
	end

	local clone = sourcePart:Clone()
	normalizeVisualAssetIds(clone)

	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("SpecialMesh") or descendant:IsA("FileMesh") then
			local scale = descendant.Scale
			local mirroredX = scale.X
			local mirroredY = scale.Y
			local mirroredZ = scale.Z
			if mirroredX == 0 then
				mirroredX = 1
			end
			if mirroredY == 0 then
				mirroredY = 1
			end
			if mirroredZ == 0 then
				mirroredZ = 1
			end
			if mirrorAxis == "x" then
				descendant.Scale = Vector3.new(-mirroredX, mirroredY, mirroredZ)
			elseif mirrorAxis == "y" then
				descendant.Scale = Vector3.new(mirroredX, -mirroredY, mirroredZ)
			else
				descendant.Scale = Vector3.new(mirroredX, mirroredY, -mirroredZ)
			end
		end
	end

	return clone
end

local function buildNormalizedSpecialMeshShellVisual(template: Instance): BasePart?
	local sourcePart = findLargestSpecialMeshPart(template)
	if not sourcePart then
		return nil
	end

	local clone = sourcePart:Clone()
	normalizeVisualAssetIds(clone)
	return clone
end

local function applyTemplateHighlight(template: Instance, visual: Instance)
	local sourceHighlight = template:FindFirstChildWhichIsA("Highlight", true)
	if not sourceHighlight then
		return
	end
	if visual:FindFirstChildWhichIsA("Highlight", true) then
		return
	end

	local clonedHighlight = sourceHighlight:Clone()
	if visual:IsA("Model") then
		clonedHighlight.Adornee = visual
		clonedHighlight.Parent = visual
	else
		clonedHighlight.Adornee = visual
		clonedHighlight.Parent = visual
	end
end

local function getMirroredSpecialMeshAxis(itemId: string?, modelPath: string?): ("x" | "y" | "z")?
	if typeof(itemId) ~= "string" then
		return nil
	end
	if not isCommonItemModelPath(modelPath) then
		return nil
	end
	return MIRRORED_SPECIAL_MESH_ITEM_AXES[itemId]
end

local function shouldNormalizeOnly(itemId: string?, modelPath: string?): boolean
	if typeof(itemId) ~= "string" then
		return false
	end
	if not isCommonItemModelPath(modelPath) then
		return false
	end
	return NORMALIZE_ONLY_ITEM_IDS[itemId] == true
end

local function getCommonItemRotationOffset(itemId: string?, modelPath: string?): CFrame?
	if typeof(itemId) ~= "string" then
		return nil
	end
	if not isCommonItemModelPath(modelPath) then
		return nil
	end
	return COMMON_ITEM_ROTATION_OFFSETS[itemId]
end

local function createMissingCustomVisualPart(): BasePart
	local part = Instance.new("Part")
	part.Name = "MissingPickupVisual"
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	return part
end

local function configureVisualInstance(instance: Instance, modelPath: string?): (BasePart, {BasePart})
	local forceOpaque = isStuffingModelPath(modelPath)

	if instance:IsA("Model") then
		local primary = instance:FindFirstChildWhichIsA("BasePart", true)
		if not primary then
			primary = Instance.new("Part")
			primary.Name = "PickupPivot"
			primary.Size = Vector3.new(0.5, 0.5, 0.5)
			primary.Transparency = 1
			primary.Anchored = true
			primary.CanCollide = false
			primary.CanTouch = false
			primary.CanQuery = false
			primary.Parent = instance
		end

		local parts = {}
		for _, desc in ipairs(instance:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.Anchored = true
				desc.CanCollide = false
				desc.CanTouch = false
				desc.CanQuery = false
				if forceOpaque then
					desc.Transparency = 0
					desc.LocalTransparencyModifier = 0
				end
				table.insert(parts, desc)
			end
		end

		if instance.PrimaryPart ~= primary then
			pcall(function()
				(instance :: Model).PrimaryPart = primary :: BasePart
			end)
		end

		return primary :: BasePart, parts
	end

	local part = instance :: BasePart
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	if forceOpaque then
		part.Transparency = 0
		part.LocalTransparencyModifier = 0
	end
	return part, { part }
end

local function attachCommonItemAura(visual: Instance, primary: BasePart, modelPath: string?)
	if not isCommonItemModelPath(modelPath) then
		return
	end

	local auraTemplate = findCommonItemAuraTemplate()
	if not auraTemplate then
		if not warnedMissingCommonItemAura then
			warnedMissingCommonItemAura = true
			warn(string.format(
				"[PickupRenderer] Missing common item aura at '%s'. Common item ground aura disabled until the asset is replicated.",
				COMMON_ITEM_AURA_PATH
			))
		end
		return
	end

	local attachmentOffset = Vector3.zero
	if visual:IsA("Model") then
		local boundsCFrame = select(1, visual:GetBoundingBox())
		attachmentOffset = primary.CFrame:PointToObjectSpace(boundsCFrame.Position)
	end

	if auraTemplate:IsA("Attachment") then
		local auraAttachment = auraTemplate:Clone()
		auraAttachment.Name = "CommonAura"
		auraAttachment.Position = attachmentOffset
		auraAttachment.Orientation = Vector3.zero
		auraAttachment.Parent = primary
		warmupVfxDeferred(auraAttachment)
		return
	end

	local auraAttachment = Instance.new("Attachment")
	auraAttachment.Name = "CommonAura"
	auraAttachment.Position = attachmentOffset
	auraAttachment.Orientation = Vector3.zero
	auraAttachment.Parent = primary

	local auraInstance = auraTemplate:Clone()
	auraInstance.Name = "CommonAuraVFX"
	auraInstance.Parent = auraAttachment
	warmupVfxDeferred(auraAttachment)
end

local function extractRotation(cf: CFrame): CFrame
	return CFrame.fromMatrix(Vector3.zero, cf.RightVector, cf.UpVector, cf.LookVector)
end

local function acquireVisual(modelPath: string?, itemId: string?): (Instance, BasePart, {BasePart}?, "part" | "orbModel" | "customModel" | "missingCustom", CFrame?)
	if typeof(modelPath) == "string" and modelPath ~= "" then
		local template = findVisualInstanceByPath(modelPath)
		if template then
			local visual: Instance = template:Clone()
			local mirroredAxis = getMirroredSpecialMeshAxis(itemId, modelPath)
			if mirroredAxis then
				local compatVisual = buildMirroredSpecialMeshVisual(template, mirroredAxis)
				if compatVisual then
					visual:Destroy()
					visual = compatVisual
				end
			elseif shouldNormalizeOnly(itemId, modelPath) then
				local compatVisual = buildNormalizedSpecialMeshShellVisual(template)
				if compatVisual then
					visual:Destroy()
					visual = compatVisual
				else
					normalizeVisualAssetIds(visual)
				end
			end
			applyTemplateHighlight(template, visual)
			if not visual.Parent then
				visual.Parent = pickupsFolder
			end
			visual.Parent = pickupsFolder
			local primary, parts = configureVisualInstance(visual, modelPath)
			attachCommonItemAura(visual, primary, modelPath)
			if RunService:IsStudio() and enableCommonItemDiagnostics and enableCommonItemDiagnostics.Value and isCommonItemModelPath(modelPath) then
				if not loggedCustomVisualDebugByPath[modelPath] then
					loggedCustomVisualDebugByPath[modelPath] = true
					warn(string.format(
						"[PickupRenderer] Common item visual debug '%s': template{%s} cloneRoot{%s}",
						modelPath,
						buildVisualDebugSummary(template),
						buildVisualDebugSummary(visual)
					))
				end
			end
			local baseRotation: CFrame
			if visual:IsA("Model") then
				baseRotation = extractRotation(primary:GetPivot())
			else
				baseRotation = extractRotation(primary.CFrame)
			end
			local rotationOffset = getCommonItemRotationOffset(itemId, modelPath)
			if rotationOffset then
				baseRotation = baseRotation * rotationOffset
			end
			return visual, primary, parts, "customModel", baseRotation
		end

		if not warnedMissingCustomPaths[modelPath] then
			warnedMissingCustomPaths[modelPath] = true
			local rawResolved = resolveInstanceByPath(modelPath)
			if rawResolved then
				warn(string.format(
					"[PickupRenderer] Unsupported pickup visual at '%s' (class '%s'). Expected Model or BasePart.",
					modelPath,
					rawResolved.ClassName
				))
			else
				warn(string.format(
					"[PickupRenderer] Missing pickup visual at '%s'. Custom pickup will render invisible until the path exists.",
					modelPath
				))
			end
		end

		local missingVisual = createMissingCustomVisualPart()
		missingVisual.Parent = pickupsFolder
		return missingVisual, missingVisual, { missingVisual }, "missingCustom", nil
	end

	local template = findOrbTemplate()
	if template then
		local model = table.remove(modelPool)
		if not model then
			model = template:Clone()
		end
		model.Parent = pickupsFolder
		local primary, parts = configureVisualInstance(model, nil)
		return model, primary, parts, "orbModel", extractRotation(primary:GetPivot())
	end

	local part = table.remove(partPool)
	if not part then
		part = createPickupPart()
	end
	part.Parent = pickupsFolder
	return part, part, nil, "part", nil
end

local function releaseVisual(record: PickupRecord)
	local instance = record.instance
	instance.Parent = nil

	if record.visualKind == "orbModel" and instance:IsA("Model") then
		if #modelPool < MAX_POOL_SIZE then
			table.insert(modelPool, instance)
		end
		return
	end

	if record.visualKind == "part" and instance:IsA("BasePart") then
		if #partPool < MAX_POOL_SIZE then
			table.insert(partPool, instance)
		end
	end
end

local function applyVisual(record: PickupRecord)
	if record.modelPath then
		return
	end

	local color = COLOR_BY_KIND[record.kind] or COLOR_BY_KIND.expBlue
	local scale = SCALE_BY_KIND[record.kind] or 1.0

	if record.parts then
		for _, part in ipairs(record.parts) do
			part.Color = color
		end
		if record.instance:IsA("Model") and record.instance.ScaleTo then
			pcall(function()
				(record.instance :: Model):ScaleTo(scale)
			end)
		end
	else
		local part = record.primary
		part.Color = color
		part.Size = Vector3.new(BASE_SIZE * scale, BASE_SIZE * scale, BASE_SIZE * scale)
	end
end

local function setRecordCFrame(record: PickupRecord, cf: CFrame, now: number)
	cf = cf + Vector3.new(0, PICKUP_VISUAL_HEIGHT_OFFSET, 0)
	local finalCf = cf
	local spinAngle = 0
	if record.itemId
		or record.visualKind == "customModel"
		or record.visualKind == "missingCustom"
		or record.modelPath
	then
		local spinPhase = math.fmod(now + record.seed, ITEM_WORLD_SPIN_PERIOD)
		if spinPhase < 0 then
			spinPhase += ITEM_WORLD_SPIN_PERIOD
		end
		spinAngle = (spinPhase / ITEM_WORLD_SPIN_PERIOD) * (math.pi * 2)
		finalCf = finalCf * CFrame.Angles(0, spinAngle, 0)
	end
	if record.baseRotation then
		finalCf = finalCf * record.baseRotation
	end
	if record.instance:IsA("Model") then
		(record.instance :: Model):PivotTo(finalCf)
	else
		record.primary.CFrame = finalCf
	end
end

local function getPickupRange(): number
	local baseRange = player:GetAttribute("BasePickupRange")
	if typeof(baseRange) ~= "number" then
		baseRange = 20
	end
	local mult = player:GetAttribute("PickupRangeMultiplier")
	if typeof(mult) ~= "number" then
		mult = 1
	end
	return baseRange * mult
end

PickupsSpawnBatch.OnClientEvent:Connect(function(payloads: any)
	if typeof(payloads) ~= "table" then
		return
	end

	for _, data in ipairs(payloads) do
		if typeof(data) ~= "table" then
			continue
		end
		local id = data.id
		if typeof(id) ~= "number" then
			continue
		end
		local pos = toVector3(data.pos)
		if not pos then
			continue
		end

		local modelPath = if typeof(data.modelPath) == "string" then data.modelPath else nil
		local itemId = if typeof(data.itemId) == "string" then data.itemId else nil

		local existing = activePickups[id]
		if existing and existing.modelPath ~= modelPath then
			releaseVisual(existing)
			activePickups[id] = nil
			existing = nil
		end

		if existing then
			existing.position = pos
			existing.currentPos = pos
			existing.value = data.value or existing.value
			existing.kind = data.kind or existing.kind
			existing.collectible = data.collectible ~= false
			existing.seekOnSpawn = data.seekOnSpawn == true
			existing.visualOnly = data.visualOnly == true
			existing.itemId = itemId or existing.itemId
			existing.itemDisplayName = if typeof(data.itemDisplayName) == "string" then data.itemDisplayName else existing.itemDisplayName
			existing.itemDescription = if typeof(data.itemDescription) == "string" then data.itemDescription else existing.itemDescription
			existing.requiresInteract = data.requiresInteract == true
			existing.interactionRadius = if typeof(data.interactionRadius) == "number" then data.interactionRadius else existing.interactionRadius
			existing.autoPickupRadius = if typeof(data.autoPickupRadius) == "number" then data.autoPickupRadius else existing.autoPickupRadius
			existing.spinPeriod = if typeof(data.spinPeriod) == "number" then data.spinPeriod else existing.spinPeriod
			existing.bobAmplitude = if typeof(data.bobAmplitude) == "number" then data.bobAmplitude else existing.bobAmplitude
			if existing.seekOnSpawn and not existing.requiresInteract then
				existing.seeking = true
			end
			applyVisual(existing)
			setRecordCFrame(existing, CFrame.new(pos), tick())
			continue
		end

		local instance, primary, parts, visualKind, baseRotation = acquireVisual(modelPath, itemId)
		local record: PickupRecord = {
			id = id,
			kind = data.kind or "expBlue",
			value = data.value or 0,
			position = pos,
			currentPos = pos,
			instance = instance,
			primary = primary,
			parts = parts,
			seed = (id % 100) * 0.13,
			collectible = data.collectible ~= false,
			seekOnSpawn = data.seekOnSpawn == true,
			visualOnly = data.visualOnly == true,
			modelPath = modelPath,
			itemId = itemId,
			itemDisplayName = if typeof(data.itemDisplayName) == "string" then data.itemDisplayName else nil,
			itemDescription = if typeof(data.itemDescription) == "string" then data.itemDescription else nil,
			requiresInteract = data.requiresInteract == true,
			interactionRadius = if typeof(data.interactionRadius) == "number" then data.interactionRadius else DEFAULT_INTERACT_RADIUS,
			autoPickupRadius = if typeof(data.autoPickupRadius) == "number" then data.autoPickupRadius else DEFAULT_AUTO_PICKUP_RADIUS,
			spinPeriod = if typeof(data.spinPeriod) == "number" then data.spinPeriod else DEFAULT_SPIN_PERIOD,
			bobAmplitude = if typeof(data.bobAmplitude) == "number" then data.bobAmplitude else BOB_AMPLITUDE,
			visualKind = visualKind,
			baseRotation = baseRotation,
		}
		if record.seekOnSpawn and not record.requiresInteract then
			record.seeking = true
		end

		activePickups[id] = record
		applyVisual(record)
		setRecordCFrame(record, CFrame.new(pos), tick())
	end
end)

PickupsDespawnBatch.OnClientEvent:Connect(function(ids: any)
	if typeof(ids) ~= "table" then
		if typeof(ids) == "number" then
			ids = { ids }
		else
			return
		end
	end
	for _, id in ipairs(ids) do
		if typeof(id) ~= "number" then
			continue
		end
		local record = activePickups[id]
		if record then
			releaseVisual(record)
			activePickups[id] = nil
		end
	end
end)

PickupsValueUpdate.OnClientEvent:Connect(function(updates: any)
	if typeof(updates) ~= "table" then
		return
	end
	for _, data in ipairs(updates) do
		if typeof(data) ~= "table" then
			continue
		end
		local id = data.id
		if typeof(id) ~= "number" then
			continue
		end
		local record = activePickups[id]
		if record then
			if typeof(data.value) == "number" then
				record.value = data.value
			end
			if data.kind then
				record.kind = data.kind
				applyVisual(record)
			end
		end
	end
end)

local function getCharacterRoot(): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function requestPickup(record: PickupRecord, now: number)
	if record.collectible == false or record.visualOnly == true then
		return
	end
	if record.lastRequestAt and (now - record.lastRequestAt) < REQUEST_RETRY_DELAY then
		return
	end
	record.lastRequestAt = now
	PickupRequest:FireServer(record.id)
end

local function getCursorViewportPosition(): Vector2
	local insetTopLeft = GuiService:GetGuiInset()
	return UserInputService:GetMouseLocation() - insetTopLeft
end

local function getCursorDistanceSqToWorldPoint(worldPos: Vector3, cursorPos: Vector2): number?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local viewportPoint, onScreen = camera:WorldToViewportPoint(worldPos)
	if not onScreen or viewportPoint.Z <= 0 then
		return nil
	end
	local dx = viewportPoint.X - cursorPos.X
	local dy = viewportPoint.Y - cursorPos.Y
	return (dx * dx) + (dy * dy)
end

local function findPickupHighlightColor(record: PickupRecord): Color3?
	local instance = record.instance
	if not instance then
		return nil
	end

	local highlight = instance:FindFirstChildWhichIsA("Highlight", true)
	if not highlight then
		return nil
	end

	local outlineColor = highlight.OutlineColor
	if typeof(outlineColor) == "Color3" then
		return outlineColor
	end

	local fillColor = highlight.FillColor
	if typeof(fillColor) == "Color3" then
		return fillColor
	end

	return nil
end

local function color3ToHex(color: Color3): string
	local r = math.clamp(math.floor((color.R * 255) + 0.5), 0, 255)
	local g = math.clamp(math.floor((color.G * 255) + 0.5), 0, 255)
	local b = math.clamp(math.floor((color.B * 255) + 0.5), 0, 255)
	return string.format("#%02X%02X%02X", r, g, b)
end

local function findBestInteractRecord(playerPos: Vector3, cursorPos: Vector2?): (PickupRecord?, number)
	local bestCursorRecord: PickupRecord? = nil
	local bestCursorScreenDistSq = math.huge
	local bestCursorWorldDistSq = math.huge
	local bestFallbackRecord: PickupRecord? = nil
	local bestFallbackDistSq = math.huge

	for _, record in pairs(activePickups) do
		if not record.requiresInteract then
			continue
		end
		if record.collectible == false or record.visualOnly == true then
			continue
		end
		local radius = record.interactionRadius or DEFAULT_INTERACT_RADIUS
		local delta = record.currentPos - playerPos
		local distSq = delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z
		if distSq > radius * radius then
			continue
		end
		if distSq < bestFallbackDistSq then
			bestFallbackRecord = record
			bestFallbackDistSq = distSq
		end
		if cursorPos then
			local cursorDistSq = getCursorDistanceSqToWorldPoint(record.currentPos, cursorPos)
			if cursorDistSq then
				if cursorDistSq < bestCursorScreenDistSq
					or (cursorDistSq == bestCursorScreenDistSq and distSq < bestCursorWorldDistSq)
				then
					bestCursorRecord = record
					bestCursorScreenDistSq = cursorDistSq
					bestCursorWorldDistSq = distSq
				end
			end
		end
	end

	local bestRecord = bestCursorRecord or bestFallbackRecord
	local bestDistSq = if bestCursorRecord then bestCursorWorldDistSq else bestFallbackDistSq
	return bestRecord, bestDistSq
end

local function requestNearestInteractPickup(playerPos: Vector3, now: number, cursorPos: Vector2?)
	local bestRecord = select(1, findBestInteractRecord(playerPos, cursorPos))
	if bestRecord then
		requestPickup(bestRecord :: PickupRecord, now)
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode ~= Enum.KeyCode.E then
		return
	end
	local hrp = getCharacterRoot()
	if not hrp then
		return
	end
	requestNearestInteractPickup(hrp.Position, tick(), getCursorViewportPosition())
end)

local checkAccumulator = 0

RunService.Heartbeat:Connect(function(dt: number)
	local hrp = getCharacterRoot()
	if not hrp then
		setPickupPrompt(nil)
		return
	end

	local now = tick()
	local playerPos = hrp.Position
	local pickupRadius = getPickupRange()
	local pickupRadiusSq = pickupRadius * pickupRadius

	checkAccumulator += dt
	local doCheck = false
	if checkAccumulator >= CHECK_INTERVAL then
		checkAccumulator = 0
		doCheck = true
	end

	local instantDespawnIds = {}
	local promptCursorPos = getCursorViewportPosition()

	for _, record in pairs(activePickups) do
		local isInteractItem = record.requiresInteract == true

		if not isInteractItem then
			if record.seeking then
				local dir = playerPos - record.currentPos
				local dist = dir.Magnitude
				if dist > 0 then
					local step = math.min(dist, SEEK_SPEED * dt)
					record.currentPos = record.currentPos + dir.Unit * step
				end
			else
				record.currentPos = record.position
			end
		else
			record.currentPos = record.position
		end

		local bobAmplitude = isInteractItem and (record.bobAmplitude or BOB_AMPLITUDE) or BOB_AMPLITUDE
		local bob = 0
		if not record.seeking then
			bob = math.sin((now + record.seed) * BOB_FREQUENCY) * bobAmplitude
		end

		if isInteractItem and not record.modelPath then
			local spinPeriod = math.max(0.1, record.spinPeriod or DEFAULT_SPIN_PERIOD)
			local angle = ((now + record.seed) / spinPeriod) * (math.pi * 2)
			setRecordCFrame(record, CFrame.new(record.currentPos + Vector3.new(0, bob, 0)) * CFrame.Angles(0, angle, 0), now)
		else
			setRecordCFrame(record, CFrame.new(record.currentPos + Vector3.new(0, bob, 0)), now)
		end

		if isInteractItem then
			local radius = record.interactionRadius or DEFAULT_INTERACT_RADIUS
			local delta = record.currentPos - playerPos
			local distSq = delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z
			if doCheck and record.collectible ~= false and record.visualOnly ~= true then
				local autoRadius = record.autoPickupRadius or DEFAULT_AUTO_PICKUP_RADIUS
				if autoRadius > 0 and distSq <= autoRadius * autoRadius then
					requestPickup(record, now)
				end
			end
			continue
		end

		-- Despawn locally as soon as a seeking orb reaches the player.
		local contactDelta = record.currentPos - playerPos
		local contactDistSq = contactDelta.X * contactDelta.X + contactDelta.Y * contactDelta.Y + contactDelta.Z * contactDelta.Z
		if record.seeking and contactDistSq <= CONTACT_DESPAWN_DISTANCE_SQ then
			if record.collectible ~= false then
				requestPickup(record, now)
			end
			table.insert(instantDespawnIds, record.id)
			continue
		end

		if doCheck then
			local delta = record.currentPos - playerPos
			local distSq = delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z
			local allowedPickupRadiusSq = pickupRadiusSq
			if record.kind == "teddyStuffing" then
				local autoRadius = record.autoPickupRadius or DEFAULT_AUTO_PICKUP_RADIUS
				allowedPickupRadiusSq = autoRadius * autoRadius
			end

			if record.collectible ~= false and distSq <= allowedPickupRadiusSq then
				if not record.lastRequestAt or (now - record.lastRequestAt) >= REQUEST_RETRY_DELAY then
					record.lastRequestAt = now
					record.seeking = true
					record.seekStartAt = now
					PickupRequest:FireServer(record.id)
				end
			elseif record.seekOnSpawn then
				record.seeking = true
			elseif not record.lastRequestAt then
				record.seeking = false
			end
		end

		if record.seeking and record.lastRequestAt and record.seekStartAt then
			if (now - record.seekStartAt) > SEEK_TIMEOUT then
				record.seeking = false
				record.lastRequestAt = nil
				record.seekStartAt = nil
				record.currentPos = record.position
			end
		end
	end

	local nearestPromptRecord, nearestPromptDistSq = findBestInteractRecord(playerPos, promptCursorPos)
	for _, pickupId in ipairs(instantDespawnIds) do
		local record = activePickups[pickupId]
		if record then
			releaseVisual(record)
			activePickups[pickupId] = nil
		end
	end

	if nearestPromptRecord and nearestPromptRecord.itemId then
		local highlightColor = findPickupHighlightColor(nearestPromptRecord)
		setPickupPrompt({
			pickupId = nearestPromptRecord.id,
			itemId = nearestPromptRecord.itemId,
			displayName = nearestPromptRecord.itemDisplayName,
			description = nearestPromptRecord.itemDescription,
			nameColorHex = if highlightColor then color3ToHex(highlightColor) else "#000000",
			distance = math.sqrt(nearestPromptDistSq),
			canPickup = true,
		})
	else
		setPickupPrompt(nil)
	end
end)
