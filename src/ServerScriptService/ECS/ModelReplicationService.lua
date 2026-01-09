--!strict
-- ModelReplicationService - Handles replicating models from ServerStorage to ReplicatedStorage
-- This allows server to control what models are available to clients

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModelReplicationService = {}

-- Cache of replicated models to avoid duplicates
local replicatedModels: {[string]: boolean} = {}

-- Cache of enemy hitbox data by type: { [enemyType]: { size: Vector3, offset: Vector3 } }
local enemyHitboxData: {[string]: {size: Vector3, offset: Vector3}} = {}
local enemyAttackboxData: {[string]: {size: Vector3, offset: Vector3}} = {}

local function getHitboxPart(model: Model): BasePart?
	-- Prefer explicitly named Hitbox
	local hitbox = model:FindFirstChild("Hitbox")
	if hitbox and hitbox:IsA("BasePart") then
		return hitbox
	end

	-- Next prefer PrimaryPart if it isn't the Attackbox
	local primary = model.PrimaryPart
	if primary and primary:IsA("BasePart") and primary.Name ~= "Attackbox" then
		return primary
	end

	-- Fallback: first BasePart that is not the Attackbox
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name ~= "Attackbox" then
			return descendant
		end
	end

	return nil
end

local function computeHitboxData(model: Model): {size: Vector3, offset: Vector3}?
	local part = getHitboxPart(model)
	if not part then
		return nil
	end

	local pivot = model:GetPivot()
	return {
		size = part.Size,
		offset = part.Position - pivot.Position,
	}
end

local function computeAttackboxData(model: Model): {size: Vector3, offset: Vector3}?
	local attackbox = model:FindFirstChild("Attackbox")
	if not attackbox or not attackbox:IsA("BasePart") then
		return nil
	end

	local pivot = model:GetPivot()
	return {
		size = attackbox.Size,
		offset = attackbox.Position - pivot.Position,
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

-- Replicate a model from ServerStorage to ReplicatedStorage
-- @param serverPath: Path in ServerStorage (e.g., "ContentDrawer.Enemies.Mobs.Zombie")
-- @param replicatedPath: Path in ReplicatedStorage (e.g., "ContentDrawer.Enemies.Mobs")
-- @return success: boolean, model: Instance?
function ModelReplicationService.replicateModel(serverPath: string, replicatedPath: string): (boolean, Instance?)
	-- Check cache
	local cacheKey = serverPath .. " -> " .. replicatedPath
	if replicatedModels[cacheKey] then
		-- Already replicated, just return success
		return true, nil
	end
	
	-- Parse server path
	local serverParts = string.split(serverPath, ".")
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
	local modelName = serverParts[#serverParts]
	if currentReplicated:FindFirstChild(modelName) then
		replicatedModels[cacheKey] = true
		return true, currentReplicated:FindFirstChild(modelName)
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
	
	-- Note: Other powerup and ability models are replicated on-demand when they spawn/are unlocked
	-- This ensures models exist before rendering
	
end

-- Expose cached enemy hitbox data
function ModelReplicationService.getEnemyHitbox(enemyType: string): {size: Vector3, offset: Vector3}?
	return enemyHitboxData[enemyType]
end

function ModelReplicationService.getEnemyAttackbox(enemyType: string): {size: Vector3, offset: Vector3}?
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

-- Replicate powerup model from ServerStorage to ReplicatedStorage
function ModelReplicationService.replicatePowerup(powerupType: string): boolean
	local serverPath = "ContentDrawer.ItemModels.Powerups." .. powerupType
	local replicatedPath = "ContentDrawer.ItemModels.Powerups"
	local success, _ = ModelReplicationService.replicateModel(serverPath, replicatedPath)
	return success
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
