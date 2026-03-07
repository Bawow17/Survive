--!strict
-- LoopGameService - Spawns shared Loop minigame objective and manages lifecycle

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameStateManager = require(game.ServerScriptService.ECS.Systems.GameStateManager)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
local LoopGameService = {}

local world: any = nil
local Components: any = nil

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local loopRemotes = remotesFolder:FindFirstChild("LoopGame")
if not loopRemotes then
	loopRemotes = Instance.new("Folder")
	loopRemotes.Name = "LoopGame"
	loopRemotes.Parent = remotesFolder
end

local openRemote = loopRemotes:FindFirstChild("Open") :: RemoteEvent
if not openRemote then
	openRemote = Instance.new("RemoteEvent")
	openRemote.Name = "Open"
	openRemote.Parent = loopRemotes
end

local closeAllRemote = loopRemotes:FindFirstChild("CloseAll") :: RemoteEvent
if not closeAllRemote then
	closeAllRemote = Instance.new("RemoteEvent")
	closeAllRemote.Name = "CloseAll"
	closeAllRemote.Parent = loopRemotes
end

local closeRemote = loopRemotes:FindFirstChild("Close") :: RemoteEvent
if not closeRemote then
	closeRemote = Instance.new("RemoteEvent")
	closeRemote.Name = "Close"
	closeRemote.Parent = loopRemotes
end

local spawnRemote = loopRemotes:FindFirstChild("Spawn") :: RemoteEvent
if not spawnRemote then
	spawnRemote = Instance.new("RemoteEvent")
	spawnRemote.Name = "Spawn"
	spawnRemote.Parent = loopRemotes
end

local requestOpenRemote = loopRemotes:FindFirstChild("RequestOpen") :: RemoteEvent
if not requestOpenRemote then
	requestOpenRemote = Instance.new("RemoteEvent")
	requestOpenRemote.Name = "RequestOpen"
	requestOpenRemote.Parent = loopRemotes
end

local completeRemote = loopRemotes:FindFirstChild("Complete") :: RemoteEvent
if not completeRemote then
	completeRemote = Instance.new("RemoteEvent")
	completeRemote.Name = "Complete"
	completeRemote.Parent = loopRemotes
end

local objectiveFolder = Workspace:FindFirstChild("LoopObjectives")
if not objectiveFolder then
	objectiveFolder = Instance.new("Folder")
	objectiveFolder.Name = "LoopObjectives"
	objectiveFolder.Parent = Workspace
end

local activeObjective: {
	id: number,
	position: Vector3,
	seed: number,
	gridSize: number,
	requiredCompletions: number,
	completedCompletions: number,
	openPlayers: {[Player]: boolean},
}? = nil

local objectiveIdCounter = 0
local spawnInterval = 10
local spawnRadius = 50
local minSpawnRadius = 15
local lastSpawnTime = 0
local lastInGame = false

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local rng = Random.new()

local function getActivePlayers(): {Player}
	if GameStateManager.getCurrentState() ~= "InGame" then
		return {}
	end
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Parent and GameStateManager.isPlayerInGame(player) then
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				table.insert(list, player)
			end
		end
	end
	return list
end

local function getSpawnPosition(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end

	local ignore = {objectiveFolder}
	for _, other in ipairs(Players:GetPlayers()) do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	
	raycastParams.FilterDescendantsInstances = ignore

	for _ = 1, 6 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local radius = rng:NextNumber(minSpawnRadius, spawnRadius)
		local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local origin = root.Position + offset + Vector3.new(0, 50, 0)
		local result = Workspace:Raycast(origin, Vector3.new(0, -200, 0), raycastParams)
		if result then
			return Vector3.new(result.Position.X, result.Position.Y, result.Position.Z)
		end
	end

	return root.Position
end

local function computeGridSize(): number
	local roll = rng:NextInteger(1, 3)
	if roll == 1 then
		return 3
	elseif roll == 2 then
		return 4
	end
	return 5
end

local function clearObjective()
	activeObjective = nil
end

local function hasOpenPlayers(objective: {
	openPlayers: {[Player]: boolean},
}): boolean
	for openPlayer in pairs(objective.openPlayers) do
		if openPlayer and openPlayer.Parent == Players then
			return true
		end
		objective.openPlayers[openPlayer] = nil
	end
	return false
end

local function fireOpenPayload(player: Player)
	if not activeObjective then
		return
	end
	openRemote:FireClient(player, {
		objectiveId = activeObjective.id,
		seed = activeObjective.seed,
		gridSize = activeObjective.gridSize,
		position = activeObjective.position,
		completedCompletions = activeObjective.completedCompletions,
		requiredCompletions = activeObjective.requiredCompletions,
	})
end

local function spawnObjective()
	local players = getActivePlayers()
	if #players == 0 then
		return
	end

	local player = players[rng:NextInteger(1, #players)]
	local position = getSpawnPosition(player)
	if not position then
		return
	end

	objectiveIdCounter += 1

	local seed = rng:NextInteger(1, 2^31 - 1)
	local gridSize = computeGridSize()
	local requiredCompletions = rng:NextInteger(1, 5)

	activeObjective = {
		id = objectiveIdCounter,
		position = position,
		seed = seed,
		gridSize = gridSize,
		requiredCompletions = requiredCompletions,
		completedCompletions = 0,
		openPlayers = {},
	}

	spawnRemote:FireAllClients({
		objectiveId = activeObjective.id,
		seed = seed,
		gridSize = gridSize,
		position = position,
	})

	lastSpawnTime = GameTimeSystem.getGameTime()
end

closeRemote.OnServerEvent:Connect(function(player: Player, objectiveId: number?)
	if not activeObjective then
		return
	end
	if objectiveId and objectiveId ~= activeObjective.id then
		return
	end
	activeObjective.openPlayers[player] = nil
end)

requestOpenRemote.OnServerEvent:Connect(function(player: Player, objectiveId: number?)
	if not activeObjective then
		return
	end
	if objectiveId and objectiveId ~= activeObjective.id then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	if (root.Position - activeObjective.position).Magnitude > 24 then
		return
	end
	if not hasOpenPlayers(activeObjective) then
		activeObjective.seed = rng:NextInteger(1, 2^31 - 1)
	end
	activeObjective.openPlayers[player] = true
	fireOpenPayload(player)
end)

completeRemote.OnServerEvent:Connect(function(player: Player, objectiveId: number?)
	if not activeObjective then
		return
	end
	if objectiveId and objectiveId ~= activeObjective.id then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	if (root.Position - activeObjective.position).Magnitude > 24 then
		return
	end

	activeObjective.completedCompletions = math.min(
		activeObjective.requiredCompletions,
		activeObjective.completedCompletions + 1
	)

	if activeObjective.completedCompletions < activeObjective.requiredCompletions then
		activeObjective.seed = rng:NextInteger(1, 2^31 - 1)
		for openPlayer in pairs(activeObjective.openPlayers) do
			if openPlayer and openPlayer.Parent == Players then
				fireOpenPayload(openPlayer)
			else
				activeObjective.openPlayers[openPlayer] = nil
			end
		end
		return
	end

	closeAllRemote:FireAllClients({
		objectiveId = activeObjective.id,
		fullComplete = true,
		delaySeconds = 1,
	})
	clearObjective()
	lastSpawnTime = GameTimeSystem.getGameTime()
end)

Players.PlayerRemoving:Connect(function(player: Player)
	if activeObjective then
		activeObjective.openPlayers[player] = nil
	end
end)

Players.PlayerAdded:Connect(function(player: Player)
	if activeObjective then
		spawnRemote:FireClient(player, {
			objectiveId = activeObjective.id,
			seed = activeObjective.seed,
			gridSize = activeObjective.gridSize,
			position = activeObjective.position,
		})
	end
end)

function LoopGameService.init(worldRef: any?, componentsRef: any?, _expSystemRef: any?)
	world = worldRef
	Components = componentsRef

	lastSpawnTime = GameTimeSystem.getGameTime() - spawnInterval
	lastInGame = GameStateManager.getCurrentState() == "InGame"
end

function LoopGameService.step(_dt: number)
	local inGame = GameStateManager.getCurrentState() == "InGame"
	if inGame ~= lastInGame then
		lastInGame = inGame
		if inGame then
			lastSpawnTime = GameTimeSystem.getGameTime() - spawnInterval
		end
	end
	if not inGame then
		if activeObjective then
			clearObjective()
		end
		return
	end
	if activeObjective then
		return
	end

	local now = GameTimeSystem.getGameTime()
	if now - lastSpawnTime >= spawnInterval then
		spawnObjective()
	end
end

return LoopGameService
