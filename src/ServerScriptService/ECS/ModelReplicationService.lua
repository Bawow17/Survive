--!strict
-- ModelReplicationService - Handles replicating models from ServerStorage to ReplicatedStorage
-- This allows server to control what models are available to clients

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)

local ModelReplicationService = {}

-- Cache of replicated models to avoid duplicates
local replicatedModels: {[string]: boolean} = {}

-- Cache of enemy hitbox data by type: { [enemyType]: { size: Vector3, offset: Vector3 } }
local enemyHitboxData: {[string]: {size: Vector3, offset: Vector3, rotation: CFrame?}} = {}
local enemyAttackboxData: {[string]: {size: Vector3, offset: Vector3, rotation: CFrame?}} = {}
local loggedCommonItemReplicationDebug: {[string]: boolean} = {}
local COMMON_ITEM_DIAGNOSTICS = GameOptions.Debug and GameOptions.Debug.CommonItemDiagnostics or false
local COMMON_ITEM_EXTRACTS: {[string]: {string}} = {
	TeddyBloxpin = { "Stuffing" },
}

local function normalizeLookupKey(value: string): string
	return string.lower((value:gsub("[%W_]+", "")))
end

local function getCommonItemsFolder(): Instance?
	local contentDrawer = ServerStorage:FindFirstChild("ContentDrawer")
	if not contentDrawer then
		return nil
	end
	local itemModels = contentDrawer:FindFirstChild("ItemModels")
	if not itemModels then
		return nil
	end
	return itemModels:FindFirstChild("CommonItems")
end

local function getReplicatedCommonItemsFolder(): Instance?
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

local function isCommonItemVisualInstance(instance: Instance?): boolean
	if not instance then
		return false
	end
	return instance:IsA("Model") or instance:IsA("BasePart")
end

local function ensureReplicatedPath(replicatedPath: string): Instance?
	local currentReplicated: Instance = ReplicatedStorage
	for _, part in ipairs(string.split(replicatedPath, ".")) do
		local child = currentReplicated:FindFirstChild(part)
		if not child then
			local folder = Instance.new("Folder")
			folder.Name = part
			folder.Parent = currentReplicated
			currentReplicated = folder
		else
			currentReplicated = child
		end
	end
	return currentReplicated
end

local function buildCommonItemDebugSummary(instance: Instance): string
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
		local summary = string.format("class=Model name=%s children=%d", instance.Name, #instance:GetChildren())
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("MeshPart") then
				return summary .. " preferred{" .. buildCommonItemDebugSummary(descendant) .. "}"
			end
		end
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("BasePart") and descendant:FindFirstChildWhichIsA("SpecialMesh") then
				return summary .. " preferred{" .. buildCommonItemDebugSummary(descendant) .. "}"
			end
		end
		return summary
	end

	return string.format("class=%s name=%s", instance.ClassName, instance.Name)
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
	local serverResolved = resolveCommonItemVisualNameInFolder(getCommonItemsFolder(), itemModelName)
	if serverResolved then
		return serverResolved
	end
	return resolveCommonItemVisualNameInFolder(getReplicatedCommonItemsFolder(), itemModelName)
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
	-- Always prefer explicit author-defined hurtbox from the model hierarchy.
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

	-- Fallback to model bounds so large meshes still get a large hurtbox.
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

local function resolveReplicatedModel(replicatedPath: string, modelName: string): Model?
	local current: Instance = ReplicatedStorage
	for _, part in ipairs(string.split(replicatedPath, ".")) do
		local nextFolder = current:FindFirstChild(part)
		if not nextFolder then
			return nil
		end
		current = nextFolder
	end

	local model = current:FindFirstChild(modelName)
	if model and model:IsA("Model") then
		return model
	end

	return nil
end

local function resolveReplicatedInstance(replicatedPath: string, childName: string): Instance?
	local current: Instance = ReplicatedStorage
	for _, part in ipairs(string.split(replicatedPath, ".")) do
		local nextFolder = current:FindFirstChild(part)
		if not nextFolder then
			return nil
		end
		current = nextFolder
	end

	return current:FindFirstChild(childName)
end

local function syncReplicatedInstance(source: Instance, target: Instance): Instance
	if source.ClassName ~= target.ClassName then
		local parent = target.Parent
		if parent then
			target:Destroy()
			local replacement = source:Clone()
			replacement.Parent = parent
			return replacement
		end
		return target
	end

	if source:IsA("Folder") or source:IsA("Model") then
		for _, sourceChild in ipairs(source:GetChildren()) do
			local targetChild = target:FindFirstChild(sourceChild.Name)
			if targetChild then
				syncReplicatedInstance(sourceChild, targetChild)
			else
				local clonedChild = sourceChild:Clone()
				clonedChild.Parent = target
			end
		end
		for _, targetChild in ipairs(target:GetChildren()) do
			if not source:FindFirstChild(targetChild.Name) then
				targetChild:Destroy()
			end
		end
		return target
	end

	local parent = target.Parent
	if parent then
		target:Destroy()
		local replacement = source:Clone()
		replacement.Parent = parent
		return replacement
	end

	return target
end

-- Replicate a model from ServerStorage to ReplicatedStorage
-- @param serverPath: Path in ServerStorage (e.g., "ContentDrawer.Enemies.Mobs.Zombie")
-- @param replicatedPath: Path in ReplicatedStorage (e.g., "ContentDrawer.Enemies.Mobs")
-- @return success: boolean, model: Instance?
function ModelReplicationService.replicateModel(serverPath: string, replicatedPath: string): (boolean, Instance?)
	-- Parse server path
	local serverParts = string.split(serverPath, ".")
	local modelName = serverParts[#serverParts]

	-- Check cache, but only if the replicated instance still exists.
	local cacheKey = serverPath .. " -> " .. replicatedPath
	if replicatedModels[cacheKey] then
		local existing = resolveReplicatedInstance(replicatedPath, modelName)
		if existing then
			return true, existing
		end
		replicatedModels[cacheKey] = nil
	end

	local currentServer = ServerStorage
	
	for i, part in ipairs(serverParts) do
		local child = currentServer:FindFirstChild(part)
		if not child then
			warn(string.format("[ModelReplicationService] Could not find server path: '%s' at part %d: '%s' (current: %s)", serverPath, i, part, currentServer:GetFullName()))
			return false, nil
		end
		currentServer = child
	end
	
	-- Parse replicated path and ensure folders exist
	local replicatedParts = string.split(replicatedPath, ".")
	local currentReplicated = ReplicatedStorage
	
	for _, part in ipairs(replicatedParts) do
		local child = currentReplicated:FindFirstChild(part)
		if not child then
			-- Create folder if it doesn't exist
			local folder = Instance.new("Folder")
			folder.Name = part
			folder.Parent = currentReplicated
			currentReplicated = folder
		else
			currentReplicated = child
		end
	end
	
	-- Check if model already exists in destination
	local existing = currentReplicated:FindFirstChild(modelName)
	if existing then
		existing = syncReplicatedInstance(currentServer, existing)
		replicatedModels[cacheKey] = true
		return true, existing
	end
	
	-- Clone the model to ReplicatedStorage
	local clonedModel = currentServer:Clone()
	clonedModel.Parent = currentReplicated
	
	replicatedModels[cacheKey] = true
	
	return true, clonedModel
end

-- Helper function to replicate enemy models
function ModelReplicationService.replicateEnemy(enemyType: string): boolean
	local serverPath = "ContentDrawer.Enemies.Mobs." .. enemyType
	local replicatedPath = "ContentDrawer.Enemies.Mobs"
	local success, model = ModelReplicationService.replicateModel(serverPath, replicatedPath)
	if success then
		if not model then
			model = resolveReplicatedModel(replicatedPath, enemyType)
		end
		-- Record Hitbox size and offset once for this enemy type
		if model and model:IsA("Model") then
			if not enemyHitboxData[enemyType] then
				local data = computeHitboxData(model)
				if data then
					enemyHitboxData[enemyType] = data
				end
			end
			if not enemyAttackboxData[enemyType] then
				local attackData = computeAttackboxData(model)
				if attackData then
					enemyAttackboxData[enemyType] = attackData
				end
			end
		end
	end
	return success
end

-- Helper function to replicate projectile models
function ModelReplicationService.replicateProjectile(projectileType: string): boolean
	local serverPath = "ContentDrawer.Spells." .. projectileType .. "." .. projectileType
	local replicatedPath = "ContentDrawer.Spells." .. projectileType
	local success, _ = ModelReplicationService.replicateModel(serverPath, replicatedPath)
	return success
end

-- Helper function to replicate ability models (MagicBolt, etc.)
function ModelReplicationService.replicateAbility(abilityType: string): boolean
	local serverPath = "ContentDrawer.Attacks.Abilties." .. abilityType .. "." .. abilityType
	local replicatedPath = "ContentDrawer.Attacks.Abilties." .. abilityType
	local success, model = ModelReplicationService.replicateModel(serverPath, replicatedPath)
	if not success then
		warn(string.format("[ModelReplicationService] Failed to replicate ability '%s'", abilityType))
	end
	
	-- For FireBall, also replicate the explosion model
	if abilityType == "FireBall" and success then
		local explosionServerPath = "ContentDrawer.Attacks.Abilties.FireBall.Explosion"
		local explosionReplicatedPath = "ContentDrawer.Attacks.Abilties.FireBall"
		local explosionSuccess, explosionModel = ModelReplicationService.replicateModel(explosionServerPath, explosionReplicatedPath)
		if not explosionSuccess then
			warn("[ModelReplicationService] Failed to replicate FireBall explosion model")
		end
	end
	
	return success
end

-- Helper function to replicate item models
function ModelReplicationService.replicateItem(itemType: string): boolean
	local serverPath = "ContentDrawer.ItemModels." .. itemType
	local replicatedPath = "ContentDrawer.ItemModels"
	local success, _ = ModelReplicationService.replicateModel(serverPath, replicatedPath)
	return success
end

function ModelReplicationService.replicateCommonItem(itemModelName: string): boolean
	return ModelReplicationService.replicateCommonItemVisual(itemModelName)
end

function ModelReplicationService.replicateCommonItemWithExtracts(itemModelName: string, extractChildNames: {string}?): boolean
	local resolvedName = ModelReplicationService.resolveCommonItemVisualName(itemModelName)
	if not resolvedName then
		warn(string.format(
			"[ModelReplicationService] Could not resolve common item model '%s' for extraction replication",
			tostring(itemModelName)
		))
		return false
	end

	local commonItems = getCommonItemsFolder()
	if not commonItems then
		warn("[ModelReplicationService] Missing ServerStorage.ContentDrawer.ItemModels.CommonItems")
		return false
	end

	local source = commonItems:FindFirstChild(resolvedName)
	if not source then
		warn(string.format(
			"[ModelReplicationService] Missing common item source 'ServerStorage.ContentDrawer.ItemModels.CommonItems.%s'",
			resolvedName
		))
		return false
	end
	if not isCommonItemVisualInstance(source) then
		warn(string.format(
			"[ModelReplicationService] Unsupported common item source '%s' of type '%s'",
			source:GetFullName(),
			source.ClassName
		))
		return false
	end

	local destinationParent = ensureReplicatedPath("ContentDrawer.ItemModels.CommonItems")
	if not destinationParent then
		return false
	end

	local existingReplicated = destinationParent:FindFirstChild(resolvedName)
	if isCommonItemVisualInstance(existingReplicated) then
		local extractsReady = true
		if extractChildNames and #extractChildNames > 0 then
			if existingReplicated:IsA("Model") then
				for _, childName in ipairs(extractChildNames) do
					local topLevelExtract = destinationParent:FindFirstChild(childName)
					local nestedExtract = existingReplicated:FindFirstChild(childName, true)
					if not isCommonItemVisualInstance(topLevelExtract) and isCommonItemVisualInstance(nestedExtract) then
						local extractedClone = nestedExtract:Clone()
						extractedClone.Name = childName
						extractedClone.Parent = destinationParent
						topLevelExtract = extractedClone
					end
					if nestedExtract then
						nestedExtract:Destroy()
					end
					if not isCommonItemVisualInstance(topLevelExtract) then
						extractsReady = false
					else
						replicatedModels["commonItem:" .. childName] = true
					end
				end
			else
				extractsReady = false
			end
		end

		if extractsReady then
			replicatedModels["commonItem:" .. resolvedName] = true
			return true
		end
	end

	local parentClone = source:Clone()
	local extractedClones = {}
	if extractChildNames and #extractChildNames > 0 then
		if parentClone:IsA("Model") then
			for _, childName in ipairs(extractChildNames) do
				local extracted = parentClone:FindFirstChild(childName, true)
				if extracted and isCommonItemVisualInstance(extracted) then
					local extractedClone = extracted:Clone()
					extractedClone.Name = childName
					table.insert(extractedClones, extractedClone)
					extracted:Destroy()
				else
					warn(string.format(
						"[ModelReplicationService] Missing extract child '%s' in common item '%s'",
						tostring(childName),
						resolvedName
					))
				end
			end
		else
			warn(string.format(
				"[ModelReplicationService] Cannot extract nested children from non-model common item '%s'",
				resolvedName
			))
		end
	end

	local existing = destinationParent:FindFirstChild(resolvedName)
	if existing then
		existing:Destroy()
	end
	parentClone.Parent = destinationParent

	for _, extractedClone in ipairs(extractedClones) do
		local existingExtract = destinationParent:FindFirstChild(extractedClone.Name)
		if existingExtract then
			existingExtract:Destroy()
		end
		extractedClone.Parent = destinationParent
		replicatedModels["commonItem:" .. extractedClone.Name] = true
	end

	if RunService:IsStudio() and COMMON_ITEM_DIAGNOSTICS and not loggedCommonItemReplicationDebug[resolvedName] then
		loggedCommonItemReplicationDebug[resolvedName] = true
		warn(string.format(
			"[ModelReplicationService] Common item debug '%s': source{%s} replicated{%s}",
			resolvedName,
			buildCommonItemDebugSummary(source),
			buildCommonItemDebugSummary(parentClone)
		))
	end

	replicatedModels["commonItem:" .. resolvedName] = true
	return true
end

function ModelReplicationService.replicateCommonItemVisual(itemModelName: string): boolean
	local resolvedName = ModelReplicationService.resolveCommonItemVisualName(itemModelName)
	if not resolvedName then
		local commonItems = getCommonItemsFolder()
		local available = {}
		if commonItems then
			for _, child in ipairs(commonItems:GetChildren()) do
				if isCommonItemVisualInstance(child) then
					table.insert(available, child.Name)
				end
			end
		end
		warn(string.format(
			"[ModelReplicationService] Could not resolve common item model '%s'. Available: %s",
			tostring(itemModelName),
			if #available > 0 then table.concat(available, ", ") else "(none)"
		))
		return false
	end

	local extracts = COMMON_ITEM_EXTRACTS[resolvedName]
	if extracts then
		return ModelReplicationService.replicateCommonItemWithExtracts(resolvedName, extracts)
	end

	local destinationParent = ensureReplicatedPath("ContentDrawer.ItemModels.CommonItems")
	if not destinationParent then
		return false
	end

	local existingReplicated = destinationParent:FindFirstChild(resolvedName)
	if isCommonItemVisualInstance(existingReplicated) then
		replicatedModels["commonItem:" .. resolvedName] = true
		return true
	end

	local commonItems = getCommonItemsFolder()
	if not commonItems then
		warn("[ModelReplicationService] Missing ServerStorage.ContentDrawer.ItemModels.CommonItems")
		return false
	end

	local source = commonItems:FindFirstChild(resolvedName)
	if not source then
		warn(string.format(
			"[ModelReplicationService] Missing common item source 'ServerStorage.ContentDrawer.ItemModels.CommonItems.%s'",
			resolvedName
		))
		return false
	end
	if not isCommonItemVisualInstance(source) then
		warn(string.format(
			"[ModelReplicationService] Unsupported common item source '%s' of type '%s'",
			source:GetFullName(),
			source.ClassName
		))
		return false
	end

	local existing = destinationParent:FindFirstChild(resolvedName)
	if existing then
		existing:Destroy()
	end

	local clone = source:Clone()
	clone.Parent = destinationParent
	if RunService:IsStudio() and COMMON_ITEM_DIAGNOSTICS and not loggedCommonItemReplicationDebug[resolvedName] then
		loggedCommonItemReplicationDebug[resolvedName] = true
		warn(string.format(
			"[ModelReplicationService] Common item debug '%s': source{%s} replicated{%s}",
			resolvedName,
			buildCommonItemDebugSummary(source),
			buildCommonItemDebugSummary(clone)
		))
	end
	replicatedModels["commonItem:" .. resolvedName] = true
	return true
end

function ModelReplicationService.replicateIceUtilityAssets(): boolean
	local branchSuccess = ModelReplicationService.replicateModel(
		"ContentDrawer.PlayerAbilities.Ice.Utility",
		"ContentDrawer.PlayerAbilities.Ice"
	)
	if branchSuccess then
		return true
	end

	local success = true
	local paths = {
		"ContentDrawer.PlayerAbilities.Ice.Utility.IceTracer.IcePath",
		"ContentDrawer.PlayerAbilities.Ice.Utility.IceTracer.IceLaser",
		"ContentDrawer.PlayerAbilities.Ice.Utility.IceTracer.IceLaser2",
		"ContentDrawer.PlayerAbilities.Ice.Utility.IceTracer.IceTracerAnimation",
	}

	for _, path in ipairs(paths) do
		local ok = ModelReplicationService.replicateMobilityModel(path)
		if not ok then
			success = false
			warn("[ModelReplicationService] Failed to replicate ice utility asset '" .. path .. "'")
		end
	end

	return success
end

function ModelReplicationService.replicateIceSpecialAssets(): boolean
	local success, _ = ModelReplicationService.replicateModel(
		"ContentDrawer.PlayerAbilities.Ice.Special.IceShard.IceShardModel",
		"ContentDrawer.PlayerAbilities.Ice.Special.IceShard"
	)
	if not success then
		warn("[ModelReplicationService] Failed to replicate ice special asset 'ContentDrawer.PlayerAbilities.Ice.Special.IceShard.IceShardModel'")
	end
	return success
end

-- Initialize by replicating commonly used models
function ModelReplicationService.init()
	
	-- Replicate zombie model (most common enemy)
	ModelReplicationService.replicateEnemy("Zombie")
	
	-- Replicate EXP orb model (used for starter orbs and ambient spawns)
	ModelReplicationService.replicateExpOrb()
	
	-- Replicate dash afterimage models (used for visual effects)
	ModelReplicationService.replicateModel(
		"ContentDrawer.PlayerAbilities.MobilityAbilities.Dash.Afterimage",
		"ContentDrawer.PlayerAbilities.MobilityAbilities.Dash"
	)
	ModelReplicationService.replicateModel(
		"ContentDrawer.PlayerAbilities.MobilityAbilities.BashShield.Afterimage",
		"ContentDrawer.PlayerAbilities.MobilityAbilities.BashShield"
	)

	-- Replicate starter ice mobility assets up-front because multiple client systems
	-- reference these paths directly before loadout data arrives.
	ModelReplicationService.replicateIceUtilityAssets()

	-- Replicate starter ice special projectile model up-front because the special
	-- now sources visuals from the PlayerAbilities branch directly.
	ModelReplicationService.replicateIceSpecialAssets()
	
	-- Note: Other ability models are replicated on-demand when they spawn/are unlocked
	-- This ensures models exist before rendering
	
end

-- Expose cached enemy hitbox data
function ModelReplicationService.getEnemyHitbox(enemyType: string): {size: Vector3, offset: Vector3, rotation: CFrame?}?
	return enemyHitboxData[enemyType]
end

function ModelReplicationService.getEnemyAttackbox(enemyType: string): {size: Vector3, offset: Vector3, rotation: CFrame?}?
	return enemyAttackboxData[enemyType]
end

-- Replicate exp orb model from ServerStorage to ReplicatedStorage
function ModelReplicationService.replicateExpOrb(): boolean
	local success, _ = ModelReplicationService.replicateModel(
		"ContentDrawer.ItemModels.OrbTemplate",
		"ContentDrawer.ItemModels"
	)
	return success
end

-- Get exp orb template from ReplicatedStorage
function ModelReplicationService.getExpOrbTemplate(): Model?
	return resolveReplicatedModel("ContentDrawer.ItemModels", "OrbTemplate")
end

-- Replicate a mobility ability model from ServerStorage to ReplicatedStorage
function ModelReplicationService.replicateMobilityModel(mobilityPath: string): boolean
	-- Expected format: "ContentDrawer.PlayerAbilities.MobilityAbilities.DoubleJumpPlatform.DoubleJumpPlatform"
	local pathParts = string.split(mobilityPath, ".")
	local modelName = pathParts[#pathParts]  -- Get the last part (DoubleJumpPlatform)
	local replicatedPath = table.concat(pathParts, ".", 1, #pathParts - 1)  -- Everything except model name
	
	local success, _ = ModelReplicationService.replicateModel(mobilityPath, replicatedPath)
	return success
end

return ModelReplicationService
