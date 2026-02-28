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

local PowerupEffectUpdate = remotesFolder:FindFirstChild("PowerupEffectUpdate")

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
local MAGNET_RADIUS_MULTIPLIER = 6
local GLOBAL_MAGNET_RADIUS = 1000
local ORB_TEMPLATE_PATH = {"ContentDrawer", "ItemModels", "OrbTemplate"}
local DEFAULT_INTERACT_RADIUS = 20
local DEFAULT_AUTO_PICKUP_RADIUS = 5
local DEFAULT_SPIN_PERIOD = 8

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
	visualKind: "part" | "orbModel" | "customModel",
}

local activePickups: {[number]: PickupRecord} = {}
local partPool: {BasePart} = {}
local modelPool: {Model} = {}
local modelPoolByPath: {[string]: {Model}} = {}
local MAX_POOL_SIZE = 300
local orbTemplate: Model? = nil

local magnetActiveUntil = 0

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

local function configureModel(model: Model): (BasePart, {BasePart})
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not primary then
		primary = Instance.new("Part")
		primary.Name = "PickupPivot"
		primary.Size = Vector3.new(0.5, 0.5, 0.5)
		primary.Transparency = 1
		primary.Anchored = true
		primary.CanCollide = false
		primary.CanTouch = false
		primary.CanQuery = false
		primary.Parent = model
	end
	if not model.PrimaryPart then
		model.PrimaryPart = primary
	end

	local parts = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = false
			desc.CanTouch = false
			desc.CanQuery = false
			table.insert(parts, desc)
		end
	end

	return model.PrimaryPart :: BasePart, parts
end

local function acquireVisual(modelPath: string?): (Instance, BasePart, {BasePart}?, "part" | "orbModel" | "customModel")
	if typeof(modelPath) == "string" and modelPath ~= "" then
		local pool = modelPoolByPath[modelPath]
		local model = pool and table.remove(pool) or nil
		if not model then
			local template = findModelByPath(modelPath)
			if template then
				model = template:Clone()
			end
		end
		if model then
			model.Parent = pickupsFolder
			local primary, parts = configureModel(model)
			return model, primary, parts, "customModel"
		end
	end

	local template = findOrbTemplate()
	if template then
		local model = table.remove(modelPool)
		if not model then
			model = template:Clone()
		end
		model.Parent = pickupsFolder
		local primary, parts = configureModel(model)
		return model, primary, parts, "orbModel"
	end

	local part = table.remove(partPool)
	if not part then
		part = createPickupPart()
	end
	part.Parent = pickupsFolder
	return part, part, nil, "part"
end

local function releaseVisual(record: PickupRecord)
	local instance = record.instance
	instance.Parent = nil

	if record.visualKind == "customModel" and record.modelPath and instance:IsA("Model") then
		local pool = modelPoolByPath[record.modelPath]
		if not pool then
			pool = {}
			modelPoolByPath[record.modelPath] = pool
		end
		if #pool < MAX_POOL_SIZE then
			table.insert(pool, instance)
		end
		return
	end

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

local function setRecordCFrame(record: PickupRecord, cf: CFrame)
	if record.instance:IsA("Model") then
		(record.instance :: Model):PivotTo(cf)
	else
		record.primary.CFrame = cf
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

local function isMagnetActive(now: number): boolean
	return now < magnetActiveUntil
end

if PowerupEffectUpdate and PowerupEffectUpdate:IsA("RemoteEvent") then
	PowerupEffectUpdate.OnClientEvent:Connect(function(data: any)
		if data and data.powerupType == "Magnet" then
			local duration = data.duration or 0
			magnetActiveUntil = math.max(magnetActiveUntil, tick() + duration)
		end
	end)
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
			existing.itemId = if typeof(data.itemId) == "string" then data.itemId else existing.itemId
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
			setRecordCFrame(existing, CFrame.new(pos))
			continue
		end

		local instance, primary, parts, visualKind = acquireVisual(modelPath)
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
			itemId = if typeof(data.itemId) == "string" then data.itemId else nil,
			itemDisplayName = if typeof(data.itemDisplayName) == "string" then data.itemDisplayName else nil,
			itemDescription = if typeof(data.itemDescription) == "string" then data.itemDescription else nil,
			requiresInteract = data.requiresInteract == true,
			interactionRadius = if typeof(data.interactionRadius) == "number" then data.interactionRadius else DEFAULT_INTERACT_RADIUS,
			autoPickupRadius = if typeof(data.autoPickupRadius) == "number" then data.autoPickupRadius else DEFAULT_AUTO_PICKUP_RADIUS,
			spinPeriod = if typeof(data.spinPeriod) == "number" then data.spinPeriod else DEFAULT_SPIN_PERIOD,
			bobAmplitude = if typeof(data.bobAmplitude) == "number" then data.bobAmplitude else BOB_AMPLITUDE,
			visualKind = visualKind,
		}
		if record.seekOnSpawn and not record.requiresInteract then
			record.seeking = true
		end

		activePickups[id] = record
		applyVisual(record)
		setRecordCFrame(record, CFrame.new(pos))
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
	local magnetRadius = pickupRadius * MAGNET_RADIUS_MULTIPLIER
	local magnetRadiusSq = magnetRadius * magnetRadius
	local magnetActive = isMagnetActive(now)
	if magnetActive then
		magnetRadius = GLOBAL_MAGNET_RADIUS
		magnetRadiusSq = magnetRadius * magnetRadius
	end

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

		if isInteractItem then
			local spinPeriod = math.max(0.1, record.spinPeriod or DEFAULT_SPIN_PERIOD)
			local angle = ((now + record.seed) / spinPeriod) * (math.pi * 2)
			setRecordCFrame(record, CFrame.new(record.currentPos + Vector3.new(0, bob, 0)) * CFrame.Angles(0, angle, 0))
		else
			setRecordCFrame(record, CFrame.new(record.currentPos + Vector3.new(0, bob, 0)))
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

			if record.collectible ~= false and distSq <= pickupRadiusSq then
				if not record.lastRequestAt or (now - record.lastRequestAt) >= REQUEST_RETRY_DELAY then
					record.lastRequestAt = now
					record.seeking = true
					record.seekStartAt = now
					PickupRequest:FireServer(record.id)
				end
			elseif magnetActive and distSq <= magnetRadiusSq and record.kind ~= "expRed" then
				record.seeking = true
			elseif record.seekOnSpawn then
				record.seeking = true
			elseif not record.lastRequestAt then
				record.seeking = false
			end
		end

		if record.seeking and record.lastRequestAt and record.seekStartAt and not magnetActive then
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
