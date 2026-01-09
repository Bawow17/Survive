--!strict
-- ProjectileRotationController - Client-side smooth rotation for homing projectiles
-- Updates projectile model rotation via RenderStepped based on Homing component data

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

-- Folders
local projectilesFolder: Folder? = workspace:FindFirstChild("Projectiles") :: Folder?
local enemiesFolder: Folder? = workspace:FindFirstChild("Enemies") :: Folder?

-- Remote events for ECS data
local EntityUpdate = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS"):WaitForChild("EntityUpdate")
local EntityDespawn = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS"):WaitForChild("EntityDespawn")

-- Track homing data per projectile entity
-- Structure: {[entityId] = {targetEntity: number?, lastUpdate: number}}
local homingData: {[string]: {targetEntity: number?, lastUpdate: number}} = {}

-- Track rendered enemy models for target position lookup
-- Structure: {[entityId] = Model}
local enemyModels: {[string]: Model} = {}

-- Helper to convert entity ID to consistent string key
local function entityKey(entityId: string | number): string
	if typeof(entityId) == "number" then
		return tostring(entityId)
	end
	return entityId
end

-- Update homing data from server
local function processEntityUpdate(message: any)
	if typeof(message) ~= "table" then
		return
	end
	
	local updates = message.updates
	if typeof(updates) ~= "table" then
		return
	end
	
	for _, updateData in ipairs(updates) do
		if typeof(updateData) == "table" and updateData.id then
			local key = entityKey(updateData.id)
			
			-- Check for Homing component update
			if updateData.Homing then
				local homingComponent = updateData.Homing
				if typeof(homingComponent) == "table" then
					homingData[key] = {
						targetEntity = homingComponent.targetEntity,
						lastUpdate = tick()
					}
				end
			end
			
			-- Track enemy models for target lookup
			if updateData.EntityType then
				local entityType = updateData.EntityType
				if typeof(entityType) == "table" and entityType.type == "Enemy" then
					-- Will be populated by finding model in enemiesFolder
				end
			end
		end
	end
end

-- Clean up homing data on entity despawn
local function handleEntityDespawn(despawns: any)
	if typeof(despawns) == "table" then
		for _, entityId in ipairs(despawns) do
			local key = entityKey(entityId)
			homingData[key] = nil
			enemyModels[key] = nil
		end
	elseif despawns then
		local key = entityKey(despawns)
		homingData[key] = nil
		enemyModels[key] = nil
	end
end

-- Update enemy model cache
local function refreshEnemyModels()
	if not enemiesFolder then
		enemiesFolder = workspace:FindFirstChild("Enemies") :: Folder?
		if not enemiesFolder then
			return
		end
	end
	
	-- Clear old cache
	table.clear(enemyModels)
	
	-- Rebuild from current enemies in workspace
	for _, enemyModel in ipairs(enemiesFolder:GetChildren()) do
		if enemyModel:IsA("Model") then
			local entityId = enemyModel:GetAttribute("ECS_EntityId")
			if entityId then
				local key = entityKey(entityId)
				enemyModels[key] = enemyModel
			end
		end
	end
end

-- Last refresh time for enemy models
local lastEnemyRefresh = 0
local ENEMY_REFRESH_INTERVAL = 0.5  -- Refresh enemy cache every 0.5s

-- Main rotation update loop (runs every frame on RenderStepped)
RunService.RenderStepped:Connect(function(dt)
	-- Ensure folders exist
	if not projectilesFolder then
		projectilesFolder = workspace:FindFirstChild("Projectiles") :: Folder?
		if not projectilesFolder then
			return
		end
	end
	
	-- Periodically refresh enemy model cache
	local now = tick()
	if now - lastEnemyRefresh >= ENEMY_REFRESH_INTERVAL then
		refreshEnemyModels()
		lastEnemyRefresh = now
	end
	
	-- Update rotation for all homing projectiles
	for _, projectileModel in ipairs(projectilesFolder:GetChildren()) do
		if not projectileModel:IsA("Model") then
			continue
		end
		
		local entityId = projectileModel:GetAttribute("ECS_EntityId")
		if not entityId then
			continue
		end
		
		local key = entityKey(entityId)
		local homing = homingData[key]
		
		if not homing or not homing.targetEntity then
			continue  -- Not a homing projectile or no target
		end
		
		-- Get target model
		local targetKey = entityKey(homing.targetEntity)
		local targetModel = enemyModels[targetKey]
		
		if not targetModel or not targetModel.Parent then
			continue  -- Target model not found or despawned
		end
		
		-- Calculate direction to target
		local currentCFrame = projectileModel:GetPivot()
		local currentPos = currentCFrame.Position
		local targetPos = targetModel:GetPivot().Position
		local direction = targetPos - currentPos
		
		if direction.Magnitude < 0.1 then
			continue  -- Too close to target
		end
		
		direction = direction.Unit
		
		-- Create target rotation (only rotation, preserve position)
		local targetRotation = CFrame.lookAt(Vector3.zero, direction)
		local currentRotation = currentCFrame - currentCFrame.Position  -- Extract rotation only
		
		-- Lerp rotation for smoothness (0.3 = smooth but responsive)
		local newRotation = currentRotation:Lerp(targetRotation, 0.3)
		
		-- Apply new rotation while preserving current position
		projectileModel:PivotTo(CFrame.new(currentPos) * newRotation)
	end
end)

-- Listen for entity updates
EntityUpdate.OnClientEvent:Connect(processEntityUpdate)
EntityDespawn.OnClientEvent:Connect(handleEntityDespawn)

