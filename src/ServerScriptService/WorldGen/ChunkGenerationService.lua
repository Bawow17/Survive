--!strict

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

local ChunkBiomeConfig = require(script.Parent:WaitForChild("ChunkBiomeConfig"))
local ChunkHeightField = require(script.Parent:WaitForChild("ChunkHeightField"))
local ChunkDecorationConfig = require(script.Parent:WaitForChild("ChunkDecorationConfig"))
local PlayerSettingsService = require(game.ServerScriptService.Services.PlayerSettingsService)

local ChunkGenerationService = {}

local WORLD_ORIGIN = Vector3.new(0, 1000, 0)
local SPAWN_POINT = WORLD_ORIGIN + Vector3.new(0, 10, 0)
local CHUNK_SIZE = 128
local LOAD_RADIUS = 5
local MAX_CHUNK_SPAWNS_PER_STEP = 3
local UPDATE_INTERVAL = 0.2

local MAX_NEIGHBOR_DELTA = 2
local MAX_GLOBAL_OFFSET = 4
local MAX_AXIS_OFFSET = 2

local PRIME_X = 73856093
local PRIME_Z = 19349663

local MAX_SEED_VALUE = 2_000_000_000

local REQUIRED_TEMPLATE_PATHS = {
	"Flatlands/FlatGrassChunk",
	"Flatlands/Grass/Grass1",
	"Flatlands/Grass/Grass2",
	"Flatlands/Grass/Grass3",
	"Forest/ForestChunk",
	"Forest/Trees/Tree",
	"Forest/Trees/Tree2",
	"Forest/Trees/Tree3",
	"Forest/Grass/Grass1",
	"Forest/Grass/Grass2",
	"Forest/Grass/Grass3",
	"Desert/SandChunk",
	"Desert/Cactus",
	"Desert/Tumbleweed",
	"Tundra/SnowChunk",
	"Tundra/Trees/Tree",
	"Tundra/Trees/Tree2",
	"Tundra/Trees/Tree3",
	"Tundra/Grass/Grass1",
	"Tundra/Grass/Grass2",
	"Tundra/Grass/Grass3",
	"Swamp/SwampChunk",
	"Swamp/Trees/Tree",
	"Swamp/Trees/Tree2",
	"Swamp/Trees/Tree3",
	"Swamp/Ponds/SwampPond1",
	"Swamp/Ponds/SwampPond2",
	"Swamp/Ponds/SwampPond3",
}

local MIN_CHUNK_RENDER_SCALE = 0.5
local MAX_CHUNK_RENDER_SCALE = 10.0
local DEFAULT_CHUNK_RENDER_SCALE = 1.0

type LoadedChunk = {
	model: Model,
	x: number,
	z: number,
	height: number,
	biome: string,
}

local initialized = false
local running = false

local templatesRoot: Folder? = nil
local chunksFolder: Folder? = nil
local masterSeed = 0

local heightField: any = nil
local loadedChunks: {[string]: LoadedChunk} = {}
local templateCache: {[string]: {Model}} = {}
local placedTreePositionsByChunk: {[string]: {Vector2}} = {}
local decorationRaycastParams = RaycastParams.new()
local debugFolder: Folder? = nil

decorationRaycastParams.FilterType = Enum.RaycastFilterType.Include
decorationRaycastParams.IgnoreWater = true

local DEBUG_FLOATING_ATTR = "ChunkDebugFloating"
local DEBUG_FLOAT_THRESHOLD_ATTR = "ChunkDebugFloatThreshold"
local DEBUG_SINK_THRESHOLD_ATTR = "ChunkDebugSinkThreshold"

local function ensureDebugFolder(): Folder
	if debugFolder and debugFolder.Parent then
		return debugFolder
	end

	local existing = Workspace:FindFirstChild("GeneratedWorldDebug")
	if existing and existing:IsA("Folder") then
		debugFolder = existing
		return existing
	end

	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "GeneratedWorldDebug"
	folder.Parent = Workspace
	debugFolder = folder
	return folder
end

local function getPartBottomY(part: BasePart): number
	local halfSize = part.Size * 0.5
	local right = part.CFrame.RightVector
	local up = part.CFrame.UpVector
	local look = part.CFrame.LookVector
	local projectedHalfHeight = math.abs(right.Y) * halfSize.X + math.abs(up.Y) * halfSize.Y + math.abs(look.Y) * halfSize.Z
	return part.Position.Y - projectedHalfHeight
end

local function getModelMinY(model: Model): number?
	local minY: number? = nil
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local bottomY = getPartBottomY(descendant)
			if minY == nil or bottomY < minY then
				minY = bottomY
			end
		end
	end
	return minY
end

local function normalizedSupportName(modelName: string): string
	local lower = string.lower(modelName)
	-- Tree2 -> tree, Grass3 -> grass, etc.
	lower = string.gsub(lower, "%d+$", "")
	-- Trim separators left by names like Tree_2 if ever used.
	lower = string.gsub(lower, "[_%-%s]+$", "")
	return lower
end

local function getSupportParts(model: Model): {BasePart}
	local supportParts: {BasePart} = {}
	local modelNameLower = string.lower(model.Name)
	local normalizedName = normalizedSupportName(model.Name)

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local descendantNameLower = string.lower(descendant.Name)
			if descendantNameLower == modelNameLower or descendantNameLower == normalizedName then
				table.insert(supportParts, descendant)
			end
		end
	end

	-- Fallback if no name-matched support parts exist.
	if #supportParts == 0 then
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				table.insert(supportParts, descendant)
			end
		end
	end

	return supportParts
end

local function getSupportMinY(model: Model): number?
	local supportParts = getSupportParts(model)
	if #supportParts == 0 then
		return nil
	end

	local minY = math.huge
	for _, part in ipairs(supportParts) do
		local bottomY = getPartBottomY(part)
		if bottomY < minY then
			minY = bottomY
		end
	end

	if minY == math.huge then
		return nil
	end
	return minY
end

local function shiftModelY(model: Model, deltaY: number)
	if math.abs(deltaY) < 1e-4 then
		return
	end
	local pivot = model:GetPivot()
	model:PivotTo(pivot + Vector3.new(0, deltaY, 0))
end

local function alignModelBottomToSurface(model: Model, surfaceY: number)
	local contactBottomY = getSupportMinY(model)
	if contactBottomY == nil then
		return
	end
	local deltaY = surfaceY - contactBottomY
	shiftModelY(model, deltaY)
end

local function alignModelPivotToSurface(model: Model, worldX: number, worldZ: number, surfaceY: number)
	local pivot = model:GetPivot()
	model:PivotTo(CFrame.fromMatrix(
		Vector3.new(worldX, surfaceY, worldZ),
		pivot.XVector,
		pivot.YVector,
		pivot.ZVector
	))
end

local function makeDebugMarker(position: Vector3, color: Color3, name: string, lifetime: number)
	local marker = Instance.new("Part")
	marker.Name = name
	marker.Shape = Enum.PartType.Ball
	marker.Material = Enum.Material.Neon
	marker.Size = Vector3.new(0.8, 0.8, 0.8)
	marker.CFrame = CFrame.new(position)
	marker.Color = color
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanTouch = false
	marker.CanQuery = false
	marker.Parent = ensureDebugFolder()
	Debris:AddItem(marker, lifetime)
end

local function debugDecorationVerticalError(chunkX: number, chunkZ: number, configPath: string, clone: Model, sampledSurfaceY: number)
	if Workspace:GetAttribute(DEBUG_FLOATING_ATTR) ~= true then
		return
	end
	-- Tumbleweed uses explicit pivot-to-surface placement; skip generic bottom-contact debug visuals/logs.
	if configPath == "Desert/Tumbleweed" or clone.Name == "Tumbleweed" then
		return
	end

	local contactBottomY = getSupportMinY(clone)
	if contactBottomY == nil then
		return
	end

	local floatThreshold = Workspace:GetAttribute(DEBUG_FLOAT_THRESHOLD_ATTR)
	if typeof(floatThreshold) ~= "number" then
		floatThreshold = 0.5
	end

	local sinkThreshold = Workspace:GetAttribute(DEBUG_SINK_THRESHOLD_ATTR)
	if typeof(sinkThreshold) ~= "number" then
		sinkThreshold = 0.5
	end

	local delta = contactBottomY - sampledSurfaceY
	if math.abs(delta) < math.max(floatThreshold, sinkThreshold) then
		return
	end

	local position = clone:GetPivot().Position
	makeDebugMarker(Vector3.new(position.X, sampledSurfaceY, position.Z), Color3.fromRGB(50, 255, 50), "SurfaceY", 20)
	if delta > 0 then
		makeDebugMarker(Vector3.new(position.X, contactBottomY, position.Z), Color3.fromRGB(255, 80, 80), "FloatingBottom", 20)
	else
		makeDebugMarker(Vector3.new(position.X, contactBottomY, position.Z), Color3.fromRGB(80, 170, 255), "SunkBottom", 20)
	end

	local absoluteMinY = getModelMinY(clone) or contactBottomY

	warn(string.format(
		"[ChunkGenerationService][Debug] Vertical offset chunk=(%d,%d) path=%s model=%s delta=%.2f (contactY=%.2f minY=%.2f surfaceY=%.2f)",
		chunkX,
		chunkZ,
		configPath,
		clone.Name,
		delta,
		contactBottomY,
		absoluteMinY,
		sampledSurfaceY
	))
end

local function chunkKey(cx: number, cz: number): string
	return tostring(cx) .. ":" .. tostring(cz)
end

local function worldToChunk(position: Vector3): (number, number)
	local dx = position.X - WORLD_ORIGIN.X
	local dz = position.Z - WORLD_ORIGIN.Z

	local cx = math.floor(dx / CHUNK_SIZE + 0.5)
	local cz = math.floor(dz / CHUNK_SIZE + 0.5)

	return cx, cz
end

local function chunkCenterWorldPosition(cx: number, cz: number, height: number): Vector3
	return Vector3.new(
		WORLD_ORIGIN.X + cx * CHUNK_SIZE,
		height,
		WORLD_ORIGIN.Z + cz * CHUNK_SIZE
	)
end

local function findInHierarchy(root: Instance, path: string): Instance?
	local current: Instance? = root
	for segment in string.gmatch(path, "[^/]+") do
		current = current and current:FindFirstChild(segment)
		if not current then
			return nil
		end
	end
	return current
end

local function anchorModel(instance: Instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
end

local function setModelCollidable(instance: Instance, isCollidable: boolean)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = isCollidable
			descendant.CanTouch = isCollidable
			descendant.CanQuery = isCollidable
		end
	end
end

local function locateTemplatesRoot(): Folder?
	local chunkTemplates = ServerStorage:FindFirstChild(ChunkBiomeConfig.TemplateRootName)
	if chunkTemplates and chunkTemplates:IsA("Folder") then
		return chunkTemplates
	end
	return nil
end

local function validateRequiredTemplates(root: Folder): (boolean, {string})
	local missing: {string} = {}
	for _, path in ipairs(REQUIRED_TEMPLATE_PATHS) do
		if not findInHierarchy(root, path) then
			table.insert(missing, path)
		end
	end
	return #missing == 0, missing
end

local function ensureChunksFolder(): Folder
	local existing = Workspace:FindFirstChild("GeneratedWorldChunks")
	if existing and existing:IsA("Folder") then
		return existing
	end

	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "GeneratedWorldChunks"
	folder.Parent = Workspace
	return folder
end

local function ensureSpawnLocation()
	local spawn = Workspace:FindFirstChild("SpawnLocation")
	local spawnPart: BasePart

	if spawn and spawn:IsA("BasePart") then
		spawnPart = spawn
	else
		local newSpawn = Instance.new("SpawnLocation")
		newSpawn.Name = "SpawnLocation"
		newSpawn.Parent = Workspace
		spawnPart = newSpawn
	end

	spawnPart.Anchored = true
	spawnPart.Size = Vector3.new(20, 1, 20)
	spawnPart.CFrame = CFrame.new(SPAWN_POINT)
	spawnPart.Transparency = 1
	spawnPart.CanCollide = false
	spawnPart.CanTouch = false
	spawnPart.CanQuery = false

	if spawnPart:IsA("SpawnLocation") then
		spawnPart.Neutral = true
		spawnPart.AllowTeamChangeOnTouch = false
	end
end

local function teleportPlayersToSpawn()
	local targetCFrame = CFrame.new(SPAWN_POINT)
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character then
			local root = character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				root.CFrame = targetCFrame
			end
		end
	end
end

local function generateMasterSeed(): number
	local entropy = DateTime.now().UnixTimestampMillis
	local jobId = game.JobId or ""
	for i = 1, #jobId do
		entropy = entropy + string.byte(jobId, i) * i
	end
	local rng = Random.new(entropy)
	return rng:NextInteger(1, MAX_SEED_VALUE)
end

local function getChunkHeight(cx: number, cz: number): number
	return heightField:getHeight(cx, cz)
end

local function getGroundHeightAt(worldX: number, worldZ: number): number
	local cx, cz = worldToChunk(Vector3.new(worldX, WORLD_ORIGIN.Y, worldZ))
	return getChunkHeight(cx, cz)
end

local function sampleSurfaceHeight(baseModel: Model, worldX: number, worldZ: number, fallbackY: number): number
	decorationRaycastParams.FilterDescendantsInstances = { baseModel }
	local origin = Vector3.new(worldX, fallbackY + 220, worldZ)
	local direction = Vector3.new(0, -520, 0)
	local hit = Workspace:Raycast(origin, direction, decorationRaycastParams)
	if hit then
		return hit.Position.Y
	end
	return fallbackY
end

local function getTemplatesForPath(path: string): {Model}
	local cached = templateCache[path]
	if cached then
		return cached
	end

	local root = templatesRoot
	if not root then
		templateCache[path] = {}
		return templateCache[path]
	end

	local node = findInHierarchy(root, path)
	local result: {Model} = {}

	if node then
		if node:IsA("Folder") then
			for _, child in ipairs(node:GetChildren()) do
				if child:IsA("Model") then
					table.insert(result, child)
				end
			end
		elseif node:IsA("Model") then
			table.insert(result, node)
		end
	end

	templateCache[path] = result
	return result
end

local function isTreeDecorationPath(path: string): boolean
	local lowerPath = string.lower(path)
	return string.find(lowerPath, "/trees", 1, true) ~= nil
end

local function getPlacedTreePositions(): {Vector2}
	local positions: {Vector2} = {}
	for _, chunkTreePositions in pairs(placedTreePositionsByChunk) do
		for _, position in ipairs(chunkTreePositions) do
			table.insert(positions, position)
		end
	end
	return positions
end

local function scatterDecorationsForChunk(baseModel: Model, chunkModel: Model, chunkX: number, chunkZ: number, center: Vector3, biomeName: string, decorationSeed: number): {Vector2}
	local configs = ChunkDecorationConfig.getForBiome(biomeName)
	if #configs == 0 then
		return {}
	end

	local decorationsFolder = Instance.new("Folder")
	decorationsFolder.Name = "Decorations"
	decorationsFolder.Parent = chunkModel

	local globalTreePositions = getPlacedTreePositions()
	local chunkTreePositions: {Vector2} = {}

	for _, config in ipairs(configs) do
		local templates = getTemplatesForPath(config.templatePath)
		if #templates == 0 then
			warn(string.format("[ChunkGenerationService] Missing decoration templates at path '%s'", config.templatePath))
			continue
		end

		local seed = decorationSeed + config.seedOffset + chunkX * PRIME_X + chunkZ * PRIME_Z
		local randomSource = Random.new(seed)
		local desiredCount = randomSource:NextInteger(config.countMin, config.countMax)
		local halfSize = CHUNK_SIZE * 0.5 - config.edgeMargin
		local placedPositions: {Vector2} = {}
		local maxAttempts = math.max(desiredCount * 15, 15)
		local attempts = 0
		local isTreeDecoration = isTreeDecorationPath(config.templatePath)

		while #placedPositions < desiredCount and attempts < maxAttempts do
			attempts += 1

			local offsetX = randomSource:NextNumber(-halfSize, halfSize)
			local offsetZ = randomSource:NextNumber(-halfSize, halfSize)
			local worldX = center.X + offsetX
			local worldZ = center.Z + offsetZ
			local estimatedHeight = getGroundHeightAt(worldX, worldZ)
			local height = sampleSurfaceHeight(baseModel, worldX, worldZ, estimatedHeight)
			local candidate2D = Vector2.new(worldX, worldZ)

			local tooClose = false
			for _, existing in ipairs(placedPositions) do
				if (existing - candidate2D).Magnitude < config.minSpacing then
					tooClose = true
					break
				end
			end

			if not tooClose and isTreeDecoration then
				for _, existing in ipairs(chunkTreePositions) do
					if (existing - candidate2D).Magnitude < config.minSpacing then
						tooClose = true
						break
					end
				end
			end

			if not tooClose and isTreeDecoration then
				for _, existing in ipairs(globalTreePositions) do
					if (existing - candidate2D).Magnitude < config.minSpacing then
						tooClose = true
						break
					end
				end
			end

			if tooClose then
				continue
			end

			local template = templates[randomSource:NextInteger(1, #templates)]
			local clone = template:Clone()
			anchorModel(clone)
			if config.collidable == false then
				setModelCollidable(clone, false)
			end

			local rotation = randomSource:NextNumber(0, math.pi * 2)
			-- Preserve the source model basis and apply only yaw rotation, matching old-game scatter behavior.
			local basePivot = template:GetPivot()
			local rotationCF = CFrame.Angles(0, rotation, 0)
			local xVector = rotationCF:VectorToWorldSpace(basePivot.XVector)
			local yVector = rotationCF:VectorToWorldSpace(basePivot.YVector)
			local zVector = rotationCF:VectorToWorldSpace(basePivot.ZVector)
			local finalCFrame = CFrame.fromMatrix(Vector3.new(worldX, height, worldZ) - Vector3.new(0, 0.1, 0), xVector, yVector, zVector)
			clone:PivotTo(finalCFrame)
			clone.Parent = decorationsFolder
			if config.templatePath == "Desert/Tumbleweed" or clone.Name == "Tumbleweed" then
				-- Design requirement: tumbleweed pivot should sit on chunk surface.
				alignModelPivotToSurface(clone, worldX, worldZ, height)
			else
				alignModelBottomToSurface(clone, height)
			end
			debugDecorationVerticalError(chunkX, chunkZ, config.templatePath, clone, height)

			table.insert(placedPositions, candidate2D)
			if isTreeDecoration then
				table.insert(chunkTreePositions, candidate2D)
			end
		end
	end

	return chunkTreePositions
end

local function spawnChunk(cx: number, cz: number, sourcePosition: Vector3?)
	local key = chunkKey(cx, cz)
	if loadedChunks[key] ~= nil then
		return
	end

	local root = templatesRoot
	local worldFolder = chunksFolder
	if not root or not worldFolder then
		return
	end

	local biome = ChunkBiomeConfig.getBiomeForChunk(cx, cz)
	local template = ChunkBiomeConfig.getTemplateForChunk(root, biome, cx, cz)
	if not template or not template:IsA("Model") then
		warn(string.format("[ChunkGenerationService] No base template found for chunk (%d, %d)", cx, cz))
		return
	end

	local height = getChunkHeight(cx, cz)
	local center = chunkCenterWorldPosition(cx, cz, height)

	local chunkModel = Instance.new("Model")
	chunkModel.Name = string.format("Chunk_%d_%d", cx, cz)
	chunkModel:SetAttribute("ChunkX", cx)
	chunkModel:SetAttribute("ChunkZ", cz)
	chunkModel:SetAttribute("Biome", biome.name)
	chunkModel:SetAttribute("Height", height)

	local baseClone = template:Clone()
	baseClone.Name = "Base"
	anchorModel(baseClone)
	-- Match old chunk placement behavior: chunk center only, no template-basis orientation override.
	baseClone:PivotTo(CFrame.new(center))
	baseClone.Parent = chunkModel
	chunkModel.Parent = worldFolder
	placedTreePositionsByChunk[key] = scatterDecorationsForChunk(baseClone, chunkModel, cx, cz, center, biome.name, masterSeed + 404)

	loadedChunks[key] = {
		model = chunkModel,
		x = cx,
		z = cz,
		height = height,
		biome = biome.name,
	}

	if sourcePosition then
		chunkModel:SetAttribute("LoadedForSourceDistance", (sourcePosition - center).Magnitude)
	end
end

local function unloadChunk(key: string)
	local data = loadedChunks[key]
	if not data then
		return
	end

	if data.model and data.model.Parent then
		data.model:Destroy()
	end

	placedTreePositionsByChunk[key] = nil
	loadedChunks[key] = nil
end

local function updateChunks()
	local desiredByKey: {[string]: {x: number, z: number, distSq: number, sourcePosition: Vector3?}} = {}
	local ordered: {{key: string, x: number, z: number, distSq: number, sourcePosition: Vector3?}} = {}

	local function enqueue(chunkX: number, chunkZ: number, distSq: number, sourcePosition: Vector3?)
		local key = chunkKey(chunkX, chunkZ)
		local existing = desiredByKey[key]
		if existing then
			if distSq < existing.distSq then
				existing.distSq = distSq
				existing.sourcePosition = sourcePosition
			end
			return
		end

		local entry = {
			key = key,
			x = chunkX,
			z = chunkZ,
			distSq = distSq,
			sourcePosition = sourcePosition,
		}
		desiredByKey[key] = entry
		table.insert(ordered, entry)
	end

	enqueue(0, 0, 0, Vector3.new(WORLD_ORIGIN.X, WORLD_ORIGIN.Y, WORLD_ORIGIN.Z))

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if not character then
			continue
		end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart or not rootPart:IsA("BasePart") then
			continue
		end

		local playerPosition = rootPart.Position
		local playerChunkX, playerChunkZ = worldToChunk(playerPosition)
		local chunkRenderScale = DEFAULT_CHUNK_RENDER_SCALE
		local playerSettings = PlayerSettingsService.getSettings(player)
		local graphicsSettings = (playerSettings and playerSettings.graphics) :: any
		if graphicsSettings and typeof(graphicsSettings.chunkRenderScale) == "number" then
			chunkRenderScale = graphicsSettings.chunkRenderScale
		elseif graphicsSettings and typeof(graphicsSettings.renderScale) == "number" then
			chunkRenderScale = graphicsSettings.renderScale
		end
		chunkRenderScale = math.clamp(chunkRenderScale, MIN_CHUNK_RENDER_SCALE, MAX_CHUNK_RENDER_SCALE)
		local playerLoadRadius = math.max(1, math.round(LOAD_RADIUS * chunkRenderScale))

		for dx = -playerLoadRadius, playerLoadRadius do
			for dz = -playerLoadRadius, playerLoadRadius do
				local chunkX = playerChunkX + dx
				local chunkZ = playerChunkZ + dz
				local chunkWorldX = WORLD_ORIGIN.X + chunkX * CHUNK_SIZE
				local chunkWorldZ = WORLD_ORIGIN.Z + chunkZ * CHUNK_SIZE
				local deltaX = playerPosition.X - chunkWorldX
				local deltaZ = playerPosition.Z - chunkWorldZ
				local distSq = deltaX * deltaX + deltaZ * deltaZ
				enqueue(chunkX, chunkZ, distSq, playerPosition)
			end
		end
	end

	table.sort(ordered, function(a, b)
		return a.distSq < b.distSq
	end)

	local spawned = 0
	for _, entry in ipairs(ordered) do
		if spawned >= MAX_CHUNK_SPAWNS_PER_STEP then
			break
		end
		if loadedChunks[entry.key] == nil then
			spawnChunk(entry.x, entry.z, entry.sourcePosition)
			spawned += 1
		end
	end

	for key in pairs(loadedChunks) do
		if desiredByKey[key] == nil then
			unloadChunk(key)
		end
	end
end

local function setWorkspaceAttributes()
	Workspace:SetAttribute("ChunkWorldSeed", masterSeed)
	Workspace:SetAttribute("ChunkOrigin", WORLD_ORIGIN)
	Workspace:SetAttribute("ChunkSize", CHUNK_SIZE)
	Workspace:SetAttribute("ChunkLoadRadius", LOAD_RADIUS)
	Workspace:SetAttribute("ChunkHeightCenterY", WORLD_ORIGIN.Y)
	Workspace:SetAttribute("ChunkHeightNeighborMaxDelta", MAX_NEIGHBOR_DELTA)
	Workspace:SetAttribute("ChunkHeightGlobalMaxOffset", MAX_GLOBAL_OFFSET)
	if Workspace:GetAttribute(DEBUG_FLOATING_ATTR) == nil then
		Workspace:SetAttribute(DEBUG_FLOATING_ATTR, true)
	end
	if Workspace:GetAttribute(DEBUG_FLOAT_THRESHOLD_ATTR) == nil then
		Workspace:SetAttribute(DEBUG_FLOAT_THRESHOLD_ATTR, 0.5)
	end
	if Workspace:GetAttribute(DEBUG_SINK_THRESHOLD_ATTR) == nil then
		Workspace:SetAttribute(DEBUG_SINK_THRESHOLD_ATTR, 0.5)
	end
end

local function startLoop()
	if running then
		return
	end

	running = true
	task.spawn(function()
		while running do
			updateChunks()
			task.wait(UPDATE_INTERVAL)
		end
	end)
end

function ChunkGenerationService.init()
	if initialized then
		return
	end

	templatesRoot = locateTemplatesRoot()
	if not templatesRoot then
		error("[ChunkGenerationService] Missing ServerStorage.ChunkTemplates in the Roblox place.")
	end

	local allPresent, missingPaths = validateRequiredTemplates(templatesRoot)
	if not allPresent then
		error(string.format(
			"[ChunkGenerationService] Missing required chunk templates: %s",
			table.concat(missingPaths, ", ")
		))
	end

	masterSeed = generateMasterSeed()
	local biomeSeed = masterSeed + 101
	local templateSeed = masterSeed + 202

	ChunkBiomeConfig.configureSeeds({
		BiomeRandomSeed = biomeSeed,
		TemplateRandomSeed = templateSeed,
	})

	heightField = ChunkHeightField.new({
		seed = masterSeed + 303,
		centerHeight = WORLD_ORIGIN.Y,
		maxNeighborDelta = MAX_NEIGHBOR_DELTA,
		maxAxisOffset = MAX_AXIS_OFFSET,
	})

	chunksFolder = ensureChunksFolder()
	table.clear(loadedChunks)
	table.clear(templateCache)
	table.clear(placedTreePositionsByChunk)

	setWorkspaceAttributes()
	ensureSpawnLocation()
	teleportPlayersToSpawn()

	spawnChunk(0, 0, Vector3.new(WORLD_ORIGIN.X, WORLD_ORIGIN.Y, WORLD_ORIGIN.Z))
	startLoop()

	initialized = true
end

function ChunkGenerationService.stop()
	running = false
end

return ChunkGenerationService
