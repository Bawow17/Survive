--!strict
-- PickupRenderer - Client-side rendering + pickup requests for EXP pickups (no ECS entities).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local pickupRemotesFolder = remotesFolder:WaitForChild("Pickups")
local PickupsSpawnBatch = pickupRemotesFolder:WaitForChild("PickupsSpawnBatch") :: RemoteEvent
local PickupsDespawnBatch = pickupRemotesFolder:WaitForChild("PickupsDespawnBatch") :: RemoteEvent
local PickupsValueUpdate = pickupRemotesFolder:WaitForChild("PickupsValueUpdate") :: RemoteEvent
local PickupRequest = pickupRemotesFolder:WaitForChild("PickupRequest") :: RemoteEvent

local PowerupEffectUpdate = remotesFolder:WaitForChild("PowerupEffectUpdate") :: RemoteEvent

local pickupsFolder: Instance = workspace:FindFirstChild("Pickups") or Instance.new("Folder")
pickupsFolder.Name = "Pickups"
pickupsFolder.Parent = workspace

local BASE_SIZE = 1.1
local BOB_AMPLITUDE = 0.35
local BOB_FREQUENCY = 1.6
local SEEK_SPEED = 120
local CHECK_INTERVAL = 0.1
local REQUEST_RETRY_DELAY = 0.4
local MAGNET_RADIUS_MULTIPLIER = 6
local ORB_TEMPLATE_PATH = {"ContentDrawer", "ItemModels", "OrbTemplate"}

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
}

local activePickups: {[number]: PickupRecord} = {}
local partPool: {BasePart} = {}
local modelPool: {Model} = {}
local MAX_POOL_SIZE = 300
local orbTemplate: Model? = nil

local magnetActiveUntil = 0

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

local function acquireVisual(): (Instance, BasePart, {BasePart}?)
	local template = findOrbTemplate()
	if template then
		local model = table.remove(modelPool)
		if not model then
			model = template:Clone()
		end
		model.Parent = pickupsFolder
		local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
		if not primary then
			primary = Instance.new("Part")
			primary.Size = Vector3.new(0.5, 0.5, 0.5)
			primary.Anchored = true
			primary.CanCollide = false
			primary.CanTouch = false
			primary.CanQuery = false
			primary.Transparency = 1
			primary.Name = "PickupPivot"
			primary.Parent = model
		end
		if not model.PrimaryPart then
			model.PrimaryPart = primary
		end
		local parts = {}
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanTouch = false
				descendant.CanQuery = false
				table.insert(parts, descendant)
			end
		end
		return model, primary, parts
	end

	local part = table.remove(partPool)
	if not part then
		part = createPickupPart()
	end
	part.Parent = pickupsFolder
	return part, part, nil
end

local function releaseVisual(instance: Instance)
	instance.Parent = nil
	if instance:IsA("Model") then
		if #modelPool < MAX_POOL_SIZE then
			table.insert(modelPool, instance)
		end
	elseif instance:IsA("BasePart") then
		if #partPool < MAX_POOL_SIZE then
			table.insert(partPool, instance)
		end
	end
end

local function applyVisual(record: PickupRecord)
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

PowerupEffectUpdate.OnClientEvent:Connect(function(data: any)
	if data and data.powerupType == "Magnet" then
		local duration = data.duration or 0
		magnetActiveUntil = math.max(magnetActiveUntil, tick() + duration)
	end
end)

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

		local existing = activePickups[id]
		if existing then
			existing.position = pos
			existing.currentPos = pos
			existing.value = data.value or existing.value
			existing.kind = data.kind or existing.kind
			applyVisual(existing)
			existing.part.CFrame = CFrame.new(pos)
			continue
		end

		local instance, primary, parts = acquireVisual()
		if instance:IsA("Model") then
			(instance :: Model):PivotTo(CFrame.new(pos))
		else
			(primary :: BasePart).CFrame = CFrame.new(pos)
		end

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
		}
		activePickups[id] = record
		applyVisual(record)
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
			releaseVisual(record.instance)
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

local checkAccumulator = 0

RunService.Heartbeat:Connect(function(dt: number)
	local hrp = getCharacterRoot()
	if not hrp then
		return
	end

	local now = tick()
	local playerPos = hrp.Position
	local pickupRadius = getPickupRange()
	local pickupRadiusSq = pickupRadius * pickupRadius
	local magnetRadius = pickupRadius * MAGNET_RADIUS_MULTIPLIER
	local magnetRadiusSq = magnetRadius * magnetRadius
	local magnetActive = isMagnetActive(now)

	checkAccumulator += dt
	local doCheck = false
	if checkAccumulator >= CHECK_INTERVAL then
		checkAccumulator = 0
		doCheck = true
	end

	for _, record in pairs(activePickups) do
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

		local bob = 0
		if not record.seeking then
			bob = math.sin((now + record.seed) * BOB_FREQUENCY) * BOB_AMPLITUDE
		end
		if record.instance:IsA("Model") then
			(record.instance :: Model):PivotTo(CFrame.new(record.currentPos + Vector3.new(0, bob, 0)))
		else
			record.primary.CFrame = CFrame.new(record.currentPos + Vector3.new(0, bob, 0))
		end

		if doCheck then
			local delta = record.currentPos - playerPos
			local distSq = delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z

			if distSq <= pickupRadiusSq then
				if not record.lastRequestAt or (now - record.lastRequestAt) >= REQUEST_RETRY_DELAY then
					record.lastRequestAt = now
					record.seeking = true
					PickupRequest:FireServer(record.id)
				end
			elseif magnetActive and distSq <= magnetRadiusSq and record.kind ~= "expRed" then
				record.seeking = true
			elseif not record.lastRequestAt then
				record.seeking = false
			end
		end
	end
end)
