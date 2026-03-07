--!strict
-- ModelReplicationService - Provides enemy hitbox/attackbox data extracted from models in ReplicatedStorage.
-- ContentDrawer now lives in ReplicatedStorage natively; no replication is needed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModelReplicationService = {}

-- Cache of enemy hitbox/attackbox data by type
local enemyHitboxData: {[string]: {size: Vector3, offset: Vector3, rotation: CFrame?}} = {}
local enemyAttackboxData: {[string]: {size: Vector3, offset: Vector3, rotation: CFrame?}} = {}

local function normalizeLookupKey(value: string): string
	return string.lower((value:gsub("[%W_]+", "")))
end

local function isCommonItemVisualInstance(instance: Instance?): boolean
	if not instance then
		return false
	end
	return instance:IsA("Model") or instance:IsA("BasePart")
end

local function getCommonItemsFolder(): Instance?
	local contentDrawer = ReplicatedStorage:FindFirstChild("ContentDrawer")
	if not contentDrawer then
		return nil
	end
	local itemModels = contentDrawer:FindFirstChild("ItemModels")
	if not itemModels then
		return nil
	end
	return itemModels:FindFirstChild("CommonItems")
end

local function resolveCommonItemVisualNameInFolder(commonItems: Instance?, itemModelName: string): string?
	if not commonItems then
		return nil
	end

	local exact = commonItems:FindFirstChild(itemModelName)
	if isCommonItemVisualInstance(exact) then
		return exact.Name
	end

	local wanted = normalizeLookupKey(itemModelName)
	for _, child in ipairs(commonItems:GetChildren()) do
		if isCommonItemVisualInstance(child) and normalizeLookupKey(child.Name) == wanted then
			return child.Name
		end
	end

	return nil
end

function ModelReplicationService.resolveCommonItemVisualName(itemModelName: string): string?
	return resolveCommonItemVisualNameInFolder(getCommonItemsFolder(), itemModelName)
end

function ModelReplicationService.resolveCommonItemName(itemModelName: string): string?
	return ModelReplicationService.resolveCommonItemVisualName(itemModelName)
end

local function findNamedPart(model: Model, name: string): BasePart?
	local exact = model:FindFirstChild(name, true)
	if exact and exact:IsA("BasePart") then
		return exact
	end

	local lowered = string.lower(name)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and string.lower(descendant.Name) == lowered then
			return descendant
		end
	end

	return nil
end

local function computeHitboxData(model: Model): {size: Vector3, offset: Vector3, rotation: CFrame?}?
	local explicitHitbox = findNamedPart(model, "Hitbox")
	if explicitHitbox then
		local pivot = model:GetPivot()
		local localCf = pivot:ToObjectSpace(explicitHitbox.CFrame)
		local rotation = CFrame.fromMatrix(Vector3.new(0, 0, 0), localCf.RightVector, localCf.UpVector, localCf.LookVector)
		return {
			size = explicitHitbox.Size,
			offset = localCf.Position,
			rotation = rotation,
		}
	end

	local ok, bboxCFrame, bboxSize = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok and typeof(bboxCFrame) == "CFrame" and typeof(bboxSize) == "Vector3" then
		local pivot = model:GetPivot()
		local localCf = pivot:ToObjectSpace(bboxCFrame)
		local rotation = CFrame.fromMatrix(Vector3.new(0, 0, 0), localCf.RightVector, localCf.UpVector, localCf.LookVector)
		return {
			size = bboxSize,
			offset = localCf.Position,
			rotation = rotation,
		}
	end

	local primary = model.PrimaryPart
	if primary and primary:IsA("BasePart") then
		local pivot = model:GetPivot()
		local localCf = pivot:ToObjectSpace(primary.CFrame)
		local rotation = CFrame.fromMatrix(Vector3.new(0, 0, 0), localCf.RightVector, localCf.UpVector, localCf.LookVector)
		return {
			size = primary.Size,
			offset = localCf.Position,
			rotation = rotation,
		}
	end

	return {
		size = Vector3.new(5, 5, 5),
		offset = Vector3.new(0, 0, 0),
		rotation = CFrame.new(),
	}
end

local function computeAttackboxData(model: Model): {size: Vector3, offset: Vector3, rotation: CFrame?}?
	local attackbox = findNamedPart(model, "Attackbox")
	if not attackbox then
		return nil
	end

	local pivot = model:GetPivot()
	local localCf = pivot:ToObjectSpace(attackbox.CFrame)
	local rotation = CFrame.fromMatrix(Vector3.new(0, 0, 0), localCf.RightVector, localCf.UpVector, localCf.LookVector)
	return {
		size = attackbox.Size,
		offset = localCf.Position,
		rotation = rotation,
	}
end

-- Ensure hitbox/attackbox data is cached for an enemy type.
-- Reads the model directly from ReplicatedStorage (no replication needed).
-- Returns true if the model was found, false otherwise.
function ModelReplicationService.ensureEnemyHitbox(enemyType: string): boolean
	if enemyHitboxData[enemyType] then
		return true
	end

	local mobs = ReplicatedStorage:FindFirstChild("ContentDrawer")
		and ReplicatedStorage.ContentDrawer:FindFirstChild("Enemies")
		and ReplicatedStorage.ContentDrawer.Enemies:FindFirstChild("Mobs")
	if not mobs then
		warn(string.format("[ModelReplicationService] Could not find ReplicatedStorage.ContentDrawer.Enemies.Mobs"))
		return false
	end

	local model = mobs:FindFirstChild(enemyType)
	if not model or not model:IsA("Model") then
		warn(string.format("[ModelReplicationService] Could not find enemy model '%s' in ReplicatedStorage", enemyType))
		return false
	end

	local hitboxData = computeHitboxData(model)
	if hitboxData then
		enemyHitboxData[enemyType] = hitboxData
	end

	local attackData = computeAttackboxData(model)
	if attackData then
		enemyAttackboxData[enemyType] = attackData
	end

	return true
end

function ModelReplicationService.getEnemyHitbox(enemyType: string): {size: Vector3, offset: Vector3, rotation: CFrame?}?
	return enemyHitboxData[enemyType]
end

function ModelReplicationService.getEnemyAttackbox(enemyType: string): {size: Vector3, offset: Vector3, rotation: CFrame?}?
	return enemyAttackboxData[enemyType]
end

-- Pre-compute hitbox data for the most common enemy types at startup.
function ModelReplicationService.init()
	ModelReplicationService.ensureEnemyHitbox("Zombie")
end

return ModelReplicationService
