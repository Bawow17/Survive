--!strict
-- LoopGameController - Client-side Loop minigame UI + generator

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local loopGui = playerGui:WaitForChild("LoopGameGui", 5) :: ScreenGui?
if not loopGui then
	local starterGui = game:GetService("StarterGui")
	local template = starterGui:FindFirstChild("LoopGameGui") :: ScreenGui?
	if template then
		loopGui = template:Clone()
		loopGui.Parent = playerGui
	end
end
if not loopGui then
	warn("[LoopGame] LoopGameGui not found")
	return
end

loopGui.Enabled = false
loopGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
loopGui.DisplayOrder = 1000

local frame = loopGui:WaitForChild("LoopGameFrame")
local frameContainer = frame:WaitForChild("Frame") :: Frame
local gridContainer = frameContainer:WaitForChild("Frame") :: Frame
local gridLayout = gridContainer:FindFirstChildOfClass("UIGridLayout")
if not gridLayout then
	warn("[LoopGame] UIGridLayout missing in LoopGameGui")
end

local function setNonBlocking(gui: GuiObject)
	gui.Active = false
	gui.Selectable = false
end

setNonBlocking(frame)
setNonBlocking(frameContainer)
setNonBlocking(gridContainer)

local templateFolder = Instance.new("Folder")
templateFolder.Name = "Templates"
templateFolder.Parent = loopGui

local templateNames = {
	"1NConnector",
	"2NConnector",
	"3NConnector",
	"3EConnector",
	"3SConnector",
	"3WConnector",
	"4NConnector",
}

local templates: {[string]: GuiObject} = {}
for _, name in ipairs(templateNames) do
	local template = gridContainer:FindFirstChild(name) :: GuiObject?
	if template then
		templates[name] = template
		template.Visible = false
		template.Parent = templateFolder
	else
		warn("[LoopGame] Missing template:", name)
	end
end

local loopRemotes = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("LoopGame")
local openRemote = loopRemotes:WaitForChild("Open") :: RemoteEvent
local closeAllRemote = loopRemotes:WaitForChild("CloseAll") :: RemoteEvent
local closeRemote = loopRemotes:WaitForChild("Close") :: RemoteEvent
local spawnRemote = loopRemotes:WaitForChild("Spawn") :: RemoteEvent
local requestOpenRemote = loopRemotes:WaitForChild("RequestOpen") :: RemoteEvent
local completeRemote = loopRemotes:WaitForChild("Complete") :: RemoteEvent

-- Forward declarations for functions referenced before definition
local openPuzzleForObjective: (objectiveId: number) -> ()
local buildPuzzle: (seed: number, size: number) -> ()

local AUTO_CLOSE_DIST = 22

local DIRS = {
	{dx = 0, dy = -1, rot = 0}, -- N
	{dx = 1, dy = 0, rot = 90}, -- E
	{dx = 0, dy = 1, rot = 180}, -- S
	{dx = -1, dy = 0, rot = 270}, -- W
}

local function bitFor(dirIndex: number): number
	return bit32.lshift(1, dirIndex - 1)
end

local function hasEdge(mask: number, dirIndex: number): boolean
	return bit32.band(mask, bitFor(dirIndex)) ~= 0
end

local function edgeCount(mask: number): number
	local count = 0
	for i = 1, 4 do
		if hasEdge(mask, i) then
			count += 1
		end
	end
	return count
end

local function rotateMask(mask: number, steps: number): number
	local result = 0
	for dir = 1, 4 do
		if hasEdge(mask, dir) then
			local newDir = ((dir - 1 + steps) % 4) + 1
			result = bit32.bor(result, bitFor(newDir))
		end
	end
	return result
end

local function maskFromMissing(missingDir: number): number
	local mask = 0
	for dir = 1, 4 do
		if dir ~= missingDir then
			mask = bit32.bor(mask, bitFor(dir))
		end
	end
	return mask
end

local function isStraight(mask: number): boolean
	return mask == bit32.bor(bitFor(1), bitFor(3)) or mask == bit32.bor(bitFor(2), bitFor(4))
end

local function randomDirection(rng: Random, directions: {number}): number
	return directions[rng:NextInteger(1, #directions)]
end

local function clearGrid()
	for _, child in ipairs(gridContainer:GetChildren()) do
		if child:IsA("GuiObject") and not child:IsA("UIGridLayout") then
			child:Destroy()
		end
	end
end

local function generateSolvedGrid(size: number, rng: Random): {{number}}
	local grid: {{number}} = table.create(size)
	for r = 1, size do
		grid[r] = table.create(size)
		for c = 1, size do
			grid[r][c] = 0
		end
	end

	local function maxNeighbors(r: number, c: number): number
		local count = 0
		for dir = 1, 4 do
			local nr = r + DIRS[dir].dy
			local nc = c + DIRS[dir].dx
			if nr >= 1 and nr <= size and nc >= 1 and nc <= size then
				count += 1
			end
		end
		return count
	end

	local function addEdge(r: number, c: number, dir: number): boolean
		local nr = r + DIRS[dir].dy
		local nc = c + DIRS[dir].dx
		if nr < 1 or nr > size or nc < 1 or nc > size then
			return false
		end
		if hasEdge(grid[r][c], dir) then
			return false
		end
		if edgeCount(grid[r][c]) >= maxNeighbors(r, c) then
			return false
		end
		if edgeCount(grid[nr][nc]) >= maxNeighbors(nr, nc) then
			return false
		end
		local opp = ((dir + 1) % 4) + 1
		grid[r][c] = bit32.bor(grid[r][c], bitFor(dir))
		grid[nr][nc] = bit32.bor(grid[nr][nc], bitFor(opp))
		return true
	end

	local function removeEdge(r: number, c: number, dir: number)
		local nr = r + DIRS[dir].dy
		local nc = c + DIRS[dir].dx
		if nr < 1 or nr > size or nc < 1 or nc > size then
			return
		end
		if not hasEdge(grid[r][c], dir) then
			return
		end
		local opp = ((dir + 1) % 4) + 1
		grid[r][c] = bit32.band(grid[r][c], bit32.bnot(bitFor(dir)))
		grid[nr][nc] = bit32.band(grid[nr][nc], bit32.bnot(bitFor(opp)))
	end

	local function fixCornersPass(): boolean
		local changed = false
		for r = 1, size do
			for c = 1, size do
				local mask = grid[r][c]
				if edgeCount(mask) == 2 and not isStraight(mask) then
					local addDirs = {}
					for dir = 1, 4 do
						local nr = r + DIRS[dir].dy
						local nc = c + DIRS[dir].dx
						if nr >= 1 and nr <= size and nc >= 1 and nc <= size then
							if not hasEdge(mask, dir) then
								table.insert(addDirs, dir)
							end
						end
					end
					if #addDirs > 0 then
						addEdge(r, c, randomDirection(rng, addDirs))
						changed = true
					else
						local existing = {}
						for dir = 1, 4 do
							if hasEdge(mask, dir) then
								table.insert(existing, dir)
							end
						end
						if #existing > 0 then
							removeEdge(r, c, randomDirection(rng, existing))
							changed = true
						end
					end
				end
			end
		end
		return changed
	end

	local function ensureNonEmpty()
		for r = 1, size do
			for c = 1, size do
				if edgeCount(grid[r][c]) == 0 then
					local dirs = {}
					for dir = 1, 4 do
						local nr = r + DIRS[dir].dy
						local nc = c + DIRS[dir].dx
						if nr >= 1 and nr <= size and nc >= 1 and nc <= size then
							table.insert(dirs, dir)
						end
					end
					if #dirs > 0 then
						addEdge(r, c, randomDirection(rng, dirs))
					end
				end
			end
		end
	end

	-- Ensure each cell has at least one connection
	for r = 1, size do
		for c = 1, size do
			if edgeCount(grid[r][c]) == 0 then
				local dirs = {}
				for dir = 1, 4 do
					local nr = r + DIRS[dir].dy
					local nc = c + DIRS[dir].dx
					if nr >= 1 and nr <= size and nc >= 1 and nc <= size then
						table.insert(dirs, dir)
					end
				end
				if #dirs > 0 then
					addEdge(r, c, randomDirection(rng, dirs))
				end
			end
		end
	end

	-- Add extra edges to increase complexity
	for _ = 1, 2 do
		for r = 1, size do
			for c = 1, size do
				if rng:NextNumber() < 0.35 and edgeCount(grid[r][c]) < 4 then
					if edgeCount(grid[r][c]) >= maxNeighbors(r, c) then
						continue
					end
					local dirs = {}
					for dir = 1, 4 do
						local nr = r + DIRS[dir].dy
						local nc = c + DIRS[dir].dx
						if nr >= 1 and nr <= size and nc >= 1 and nc <= size then
							table.insert(dirs, dir)
						end
					end
					if #dirs > 0 then
						addEdge(r, c, randomDirection(rng, dirs))
					end
				end
			end
		end
	end

	for _ = 1, 8 do
		local changed = fixCornersPass()
		ensureNonEmpty()
		if not changed then
			break
		end
	end

	for r = 1, size do
		for c = 1, size do
			local mask = grid[r][c]
			local deg = edgeCount(mask)
			if deg > maxNeighbors(r, c) then
				local existing = {}
				for dir = 1, 4 do
					if hasEdge(mask, dir) then
						table.insert(existing, dir)
					end
				end
				while edgeCount(grid[r][c]) > maxNeighbors(r, c) and #existing > 0 do
					removeEdge(r, c, randomDirection(rng, existing))
				end
			elseif deg == 2 and not isStraight(mask) then
				local existing = {}
				for dir = 1, 4 do
					if hasEdge(mask, dir) then
						table.insert(existing, dir)
					end
				end
				if #existing > 0 then
					removeEdge(r, c, randomDirection(rng, existing))
				end
			elseif deg == 0 then
				local dirs = {}
				for dir = 1, 4 do
					local nr = r + DIRS[dir].dy
					local nc = c + DIRS[dir].dx
					if nr >= 1 and nr <= size and nc >= 1 and nc <= size then
						table.insert(dirs, dir)
					end
				end
				if #dirs > 0 then
					addEdge(r, c, randomDirection(rng, dirs))
				end
			end
		end
	end

	for _ = 1, 4 do
		local changed = fixCornersPass()
		if not changed then
			break
		end
	end

	-- Enforce no 3-way on corners (variety reduction for solvability)
	for r = 1, size do
		for c = 1, size do
			local maxDeg = maxNeighbors(r, c)
			if maxDeg == 2 and edgeCount(grid[r][c]) >= 3 then
				local existing = {}
				for dir = 1, 4 do
					if hasEdge(grid[r][c], dir) then
						table.insert(existing, dir)
					end
				end
				while edgeCount(grid[r][c]) > 2 and #existing > 0 do
					removeEdge(r, c, randomDirection(rng, existing))
				end
				if edgeCount(grid[r][c]) == 0 then
					local dirs = {}
					for dir = 1, 4 do
						local nr = r + DIRS[dir].dy
						local nc = c + DIRS[dir].dx
						if nr >= 1 and nr <= size and nc >= 1 and nc <= size then
							table.insert(dirs, dir)
						end
					end
					if #dirs > 0 then
						addEdge(r, c, randomDirection(rng, dirs))
					end
				end
			end
		end
	end

	-- Final boundary enforcement: corners <=2, edges <=3
	for r = 1, size do
		for c = 1, size do
			local maxDeg = maxNeighbors(r, c)
			while edgeCount(grid[r][c]) > maxDeg do
				local existing = {}
				for dir = 1, 4 do
					if hasEdge(grid[r][c], dir) then
						table.insert(existing, dir)
					end
				end
				if #existing == 0 then
					break
				end
				removeEdge(r, c, randomDirection(rng, existing))
			end
		end
	end

	return grid
end

local function createPlaceholderButton(layoutOrder: number): TextButton
	local button = Instance.new("TextButton")
	button.Text = ""
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
	button.BorderColor3 = Color3.fromRGB(20, 20, 20)
	button.BorderSizePixel = 1
	button.AutoButtonColor = false
	button.Active = true
	button.Selectable = true
	button.Modal = false
	button.ZIndex = 10
	button.LayoutOrder = layoutOrder
	return button
end

local function configureTileButton(button: GuiObject, layoutOrder: number)
	button.Visible = true
	button.Size = UDim2.fromScale(1, 1)
	button.Position = UDim2.fromScale(0, 0)
	button.AnchorPoint = Vector2.new(0, 0)
	button.ZIndex = 10
	button.LayoutOrder = layoutOrder
	if button:IsA("GuiButton") then
		button.AutoButtonColor = false
		button.Active = true
		button.Selectable = true
		button.Modal = false
	end
	for _, descendant in ipairs(button:GetDescendants()) do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex = 9
		end
	end
end

local THREE_TEMPLATES = {
	"3NConnector",
	"3EConnector",
	"3SConnector",
	"3WConnector",
}

local function threeDirFromMissing(missingDir: number): number
	return ((missingDir + 1) % 4) + 1
end

local function missingDirFromThree(threeDir: number): number
	return ((threeDir + 1) % 4) + 1
end

local function getBaseRotation(frame: GuiObject?): number
	if frame and frame:IsA("GuiObject") then
		return frame.Rotation
	end
	return 0
end

local function rotationStepsFromDegrees(deg: number): number
	local steps = math.floor((deg + 45) / 90) % 4
	return steps
end

local function updateTileMaskAndVisual(tile: any)
	if tile.kind == 1 then
		local baseDir = ((1 - 1 + tile.baseRotSteps) % 4) + 1
		local currentDir = ((baseDir - 1 + tile.rotation) % 4) + 1
		tile.currentMask = bitFor(currentDir)
		if tile.frame then
			tile.frame.Rotation = tile.baseRotation + tile.rotation * 90
		end
	elseif tile.kind == 2 then
		local baseMask = rotateMask(bit32.bor(bitFor(1), bitFor(3)), tile.baseRotSteps)
		tile.currentMask = rotateMask(baseMask, tile.rotation)
		if tile.frame then
			tile.frame.Rotation = tile.baseRotation + tile.rotation * 90
		end
	elseif tile.kind == 3 then
		tile.currentMask = maskFromMissing(tile.missingDir)
		-- 3-way uses preset templates; no extra rotation
	elseif tile.kind == 4 then
		tile.currentMask = bit32.bor(bitFor(1), bitFor(2), bitFor(3), bitFor(4))
	end
end

local activeObjectiveId: number? = nil
local objectivePosition: Vector3? = nil
local objectiveSeed: number? = nil
local objectiveGridSize: number? = nil
local distanceConn: RBXScriptConnection? = nil
local promptConn: RBXScriptConnection? = nil
local puzzleSolved = false
local objectiveModel: Model? = nil
local objectivePrompt: ProximityPrompt? = nil
local fadeToken = 0

local tiles: {{any}} = {}
local gridSize = 0

local function closeUI(sendClose: boolean)
	local objectiveId = activeObjectiveId
	loopGui.Enabled = false
	puzzleSolved = false
	if not sendClose then
		activeObjectiveId = nil
		objectivePosition = nil
		objectiveSeed = nil
		objectiveGridSize = nil
	end
	if distanceConn then
		distanceConn:Disconnect()
		distanceConn = nil
	end
	clearGrid()
	if sendClose then
		closeRemote:FireServer(objectiveId)
	end
end

local function getPlayerRoot(): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function clearObjectiveModel()
	fadeToken += 1
	if promptConn then
		promptConn:Disconnect()
		promptConn = nil
	end
	if objectivePrompt then
		objectivePrompt:Destroy()
		objectivePrompt = nil
	end
	if objectiveModel then
		objectiveModel:Destroy()
		objectiveModel = nil
	end
end

local function fadeAndClearObjectiveModel()
	if not objectiveModel then
		return
	end
	if objectivePrompt then
		objectivePrompt.Enabled = false
	end
	fadeToken += 1
	local token = fadeToken
	local model = objectiveModel
	task.delay(3, function()
		if token ~= fadeToken then
			return
		end
		if not model or not model.Parent then
			return
		end
		local tweens = {}
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				local tween = TweenService:Create(descendant, TweenInfo.new(1), {Transparency = 1})
				table.insert(tweens, tween)
				tween:Play()
			elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
				local tween = TweenService:Create(descendant, TweenInfo.new(1), {Transparency = 1})
				table.insert(tweens, tween)
				tween:Play()
			end
		end
		if #tweens > 0 then
			tweens[#tweens].Completed:Wait()
		end
		if token ~= fadeToken then
			return
		end
		if model and model.Parent then
			model:Destroy()
		end
		if objectiveModel == model then
			objectiveModel = nil
		end
		if objectivePrompt then
			objectivePrompt:Destroy()
			objectivePrompt = nil
		end
	end)
end

local function spawnObjectiveModel(position: Vector3, objectiveId: number)
	clearObjectiveModel()
	local template = ReplicatedStorage:FindFirstChild("ContentDrawer")
		and ReplicatedStorage.ContentDrawer:FindFirstChild("Structures")
		and ReplicatedStorage.ContentDrawer.Structures:FindFirstChild("LoopPuzzleStatue")
	if not template or not template:IsA("Model") then
		warn("[LoopGame] Replicated LoopPuzzleStatue missing")
		return
	end

	local model = template:Clone()
	model.Name = "LoopObjective"
	model.Parent = workspace

	local primary = model.PrimaryPart
	if not primary then
		primary = model:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			model.PrimaryPart = primary
		end
	end
	if not primary then
		warn("[LoopGame] LoopPuzzleStatue missing BasePart for prompt")
		model:Destroy()
		return
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
		end
	end

	model:PivotTo(CFrame.new(position))

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Play"
	prompt.ObjectText = "Loop"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0.4
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 20
	prompt.Parent = primary

	objectiveModel = model
	objectivePrompt = prompt

	promptConn = ProximityPromptService.PromptTriggered:Connect(function(p, triggerPlayer)
		if triggerPlayer ~= player then
			return
		end
		if p ~= prompt then
			return
		end
		openPuzzleForObjective(objectiveId)
		requestOpenRemote:FireServer(objectiveId)
	end)
end

local function startDistanceCheck()
	if distanceConn then
		distanceConn:Disconnect()
	end
	local accumulator = 0
	distanceConn = RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.2 then
			return
		end
		accumulator = 0
		if not objectivePosition then
			return
		end
		local root = getPlayerRoot()
		if root then
			if (root.Position - objectivePosition).Magnitude > AUTO_CLOSE_DIST then
				closeUI(true)
			end
		end
	end)
end

local function isSolved(): boolean
	for r = 1, gridSize do
		for c = 1, gridSize do
			local tile = tiles[r][c]
			local mask = tile.currentMask
			for dir = 1, 4 do
				local nr = r + DIRS[dir].dy
				local nc = c + DIRS[dir].dx
				local has = hasEdge(mask, dir)
				if nr < 1 or nr > gridSize or nc < 1 or nc > gridSize then
					if has then
						return false
					end
				else
					local neighbor = tiles[nr][nc]
					local opp = ((dir + 1) % 4) + 1
					local neighborHas = hasEdge(neighbor.currentMask, opp)
					if has ~= neighborHas then
						return false
					end
				end
			end
		end
	end
	return true
end

local function tryCompletePuzzle()
	if puzzleSolved then
		return
	end
	if not isSolved() then
		return
	end
	puzzleSolved = true
	if activeObjectiveId then
		completeRemote:FireServer(activeObjectiveId)
	end
	closeUI(false)
end

openPuzzleForObjective = function(objectiveId: number)
	activeObjectiveId = objectiveId
	loopGui.Enabled = true
	frame.Visible = true
	gridContainer.Visible = true
	puzzleSolved = false

	local size = objectiveGridSize
	if typeof(size) ~= "number" then
		size = 4
	end

	-- Randomize each time UI opens (ignore static objective seed)
	local randomizedSeed = Random.new():NextInteger(1, 2^31 - 1)
	buildPuzzle(randomizedSeed, math.clamp(size, 3, 5))
	startDistanceCheck()
	task.defer(tryCompletePuzzle)
end

local function rotateTile(tile: any, direction: number)
	if tile.kind == 4 then
		return
	end
	if tile.kind == 3 then
		tile.threeIndex = ((tile.threeIndex - 1 + direction) % 4) + 1
		tile.threeDir = tile.threeIndex
		tile.missingDir = missingDirFromThree(tile.threeDir)
		tile.currentMask = maskFromMissing(tile.missingDir)
		local templateName = THREE_TEMPLATES[tile.threeIndex]
		local template = templates[templateName]
		local parent = tile.button.Parent
		local layoutOrder = tile.button.LayoutOrder
		if template then
			local newButton = template:Clone()
			configureTileButton(newButton, layoutOrder)
			newButton.Parent = parent
			tile.button:Destroy()
			tile.button = newButton
			tile.frame = newButton:FindFirstChild("Frame") :: GuiObject?
			tile.baseRotation = getBaseRotation(tile.frame)
			tile.baseRotSteps = rotationStepsFromDegrees(tile.baseRotation)
		else
			tile.button.Text = ""
		end
		updateTileMaskAndVisual(tile)
		if tile.onBind then
			tile.onBind(tile)
		end
		return
	end

	local mod = tile.kind == 2 and 2 or 4
	tile.rotation = ((tile.rotation + direction) % mod + mod) % mod
	updateTileMaskAndVisual(tile)
end

buildPuzzle = function(seed: number, size: number)
	clearGrid()
	gridSize = size
	if gridLayout then
		gridLayout.CellPadding = UDim2.new(0, 0, 0, 0)
		gridLayout.CellSize = UDim2.fromScale(1 / size, 1 / size)
		gridLayout.FillDirection = Enum.FillDirection.Horizontal
		gridLayout.FillDirectionMaxCells = size
		gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	end
	gridContainer.ClipsDescendants = true

	local rng = Random.new(seed)
	local solution = generateSolvedGrid(size, rng)
	local attempts = 0
	while attempts < 5 do
		local hasInvalid = false
		for r = 1, size do
			for c = 1, size do
				local mask = solution[r][c]
				if edgeCount(mask) == 2 and not isStraight(mask) then
					hasInvalid = true
					break
				end
				local maxNeighbors = 0
				for dir = 1, 4 do
					local nr = r + DIRS[dir].dy
					local nc = c + DIRS[dir].dx
					if nr >= 1 and nr <= size and nc >= 1 and nc <= size then
						maxNeighbors += 1
					end
				end
				if edgeCount(mask) > maxNeighbors then
					hasInvalid = true
					break
				end
			end
			if hasInvalid then
				break
			end
		end
		if not hasInvalid then
			break
		end
		attempts += 1
		solution = generateSolvedGrid(size, rng)
	end

	tiles = table.create(size)
	for r = 1, size do
		tiles[r] = table.create(size)
		for c = 1, size do
			local mask = solution[r][c]
			local degree = edgeCount(mask)
			local kind = degree
			local layoutOrder = (r - 1) * size + c
			local tileButton: GuiObject?

			local tile = {
				solutionMask = mask,
				currentMask = mask,
				kind = kind,
				rotation = 0,
				missingDir = nil,
				threeDir = nil,
				threeIndex = nil,
				baseRotation = 0,
				baseRotSteps = 0,
				button = nil :: GuiObject?,
				frame = nil :: GuiObject?,
				onBind = nil :: ((any) -> ())?,
				lastClickTime = 0,
			}

			if degree == 1 then
				local dirIndex = 1
				for d = 1, 4 do
					if hasEdge(mask, d) then
						dirIndex = d
						break
					end
				end
				local rotation = rng:NextInteger(0, 3)
				tile.rotation = rotation
				tile.currentMask = rotateMask(mask, rotation)
				local template = templates["1NConnector"]
				if template then
					local button = template:Clone()
					configureTileButton(button, layoutOrder)
					tileButton = button
					tile.frame = button:FindFirstChild("Frame") :: GuiObject?
					tile.baseRotation = getBaseRotation(tile.frame)
					tile.baseRotSteps = rotationStepsFromDegrees(tile.baseRotation)
				else
					local button = createPlaceholderButton(layoutOrder)
					tileButton = button
				end
				updateTileMaskAndVisual(tile)
			elseif degree == 2 then
				local rotation = rng:NextInteger(0, 1)
				tile.rotation = rotation
				local template = templates["2NConnector"]
				if template then
					local button = template:Clone()
					configureTileButton(button, layoutOrder)
					tileButton = button
					tile.frame = button:FindFirstChild("Frame") :: GuiObject?
					tile.baseRotation = getBaseRotation(tile.frame)
					tile.baseRotSteps = rotationStepsFromDegrees(tile.baseRotation)
				else
					local button = createPlaceholderButton(layoutOrder)
					tileButton = button
				end
				updateTileMaskAndVisual(tile)
			elseif degree == 3 then
				local missingDir = 1
				for d = 1, 4 do
					if not hasEdge(mask, d) then
						missingDir = d
						break
					end
				end
				local threeDir = threeDirFromMissing(missingDir)
				local rotation = rng:NextInteger(0, 3)
				threeDir = ((threeDir - 1 + rotation) % 4) + 1
				tile.threeDir = threeDir
				tile.threeIndex = threeDir
				tile.missingDir = missingDirFromThree(threeDir)
				tile.currentMask = maskFromMissing(tile.missingDir)
				local templateName = THREE_TEMPLATES[tile.threeIndex]
				local template = templates[templateName]
				if template then
					local button = template:Clone()
					configureTileButton(button, layoutOrder)
					tileButton = button
					tile.frame = button:FindFirstChild("Frame") :: GuiObject?
					tile.baseRotation = getBaseRotation(tile.frame)
					tile.baseRotSteps = rotationStepsFromDegrees(tile.baseRotation)
				else
					local button = createPlaceholderButton(layoutOrder)
					tileButton = button
				end
				updateTileMaskAndVisual(tile)
			elseif degree == 4 then
				local template = templates["4NConnector"]
				if template then
					local button = template:Clone()
					configureTileButton(button, layoutOrder)
					tileButton = button
					tile.frame = button:FindFirstChild("Frame") :: GuiObject?
					tile.baseRotation = getBaseRotation(tile.frame)
					tile.baseRotSteps = rotationStepsFromDegrees(tile.baseRotation)
				else
					local button = createPlaceholderButton(layoutOrder)
					tileButton = button
				end
				updateTileMaskAndVisual(tile)
			end

			tile.button = tileButton
			if tileButton then
				tileButton.Parent = gridContainer
			end

			local function handleRotate(direction: number)
				if not loopGui.Enabled then
					return
				end
				local now = os.clock()
				if now - (tile.lastClickTime or 0) < 0.05 then
					return
				end
				tile.lastClickTime = now
				rotateTile(tile, direction)
				tryCompletePuzzle()
			end

			local function bindHandlers(currentTile: any)
				local button = currentTile.button
				if not button or not button:IsA("GuiButton") then
					return
				end
				button.MouseButton1Click:Connect(function()
					handleRotate(1)
				end)

				button.MouseButton2Click:Connect(function()
					handleRotate(-1)
				end)
			end

			tile.onBind = bindHandlers
			bindHandlers(tile)

			tiles[r][c] = tile
		end
	end

	-- Ensure puzzle is not already solved after scrambling
	if isSolved() then
		for _ = 1, size * size do
			local rr = rng:NextInteger(1, size)
			local cc = rng:NextInteger(1, size)
			local t = tiles[rr][cc]
			if t and t.kind ~= 4 then
				rotateTile(t, 1)
				if not isSolved() then
					break
				end
			end
		end
	end
end

openRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local objectiveId = payload.objectiveId
	if typeof(objectiveId) ~= "number" then
		return
	end

	activeObjectiveId = objectiveId
	objectivePosition = payload.position
	objectiveSeed = payload.seed
	objectiveGridSize = payload.gridSize
	openPuzzleForObjective(objectiveId)
end)

closeAllRemote.OnClientEvent:Connect(function(payload: any)
	if payload and typeof(payload) == "table" then
		local objectiveId = payload.objectiveId
		if activeObjectiveId and typeof(objectiveId) == "number" and objectiveId ~= activeObjectiveId then
			return
		end
	end
	closeUI(false)
	fadeAndClearObjectiveModel()
end)

spawnRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local objectiveId = payload.objectiveId
	local position = payload.position
	if typeof(objectiveId) ~= "number" or typeof(position) ~= "Vector3" then
		return
	end
	objectivePosition = position
	objectiveSeed = payload.seed
	objectiveGridSize = payload.gridSize
	spawnObjectiveModel(position, objectiveId)
end)

