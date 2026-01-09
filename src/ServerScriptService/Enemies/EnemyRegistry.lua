--!strict
-- EnemyRegistry.lua - Auto-discovers and registers all enemy types
-- Scans the Enemies folder and loads Balance for each enemy type

local EnemyRegistry = {}

local enemiesFolder = script.Parent
local registeredEnemies: {[string]: any} = {}

-- Validate that an enemy has the required files
local function validateEnemy(enemyId: string, enemyFolder: Instance): boolean
	local balanceLua = enemyFolder:FindFirstChild("Balance")
	
	if not balanceLua or not balanceLua:IsA("ModuleScript") then
		warn(string.format("[EnemyRegistry] Enemy '%s' missing Balance.lua", enemyId))
		return false
	end
	
	return true
end

-- Load an enemy's balance module
local function loadEnemy(enemyId: string, enemyFolder: Instance): any?
	if not validateEnemy(enemyId, enemyFolder) then
		return nil
	end
	
	local success, balanceModule = pcall(function()
		return require(enemyFolder.Balance)
	end)
	
	if not success then
		warn(string.format("[EnemyRegistry] Failed to load Balance.lua for '%s': %s", enemyId, tostring(balanceModule)))
		return nil
	end
	
	-- Validate balance has required fields
	if not balanceModule.Name then
		warn(string.format("[EnemyRegistry] Enemy '%s' Balance.lua missing 'Name' field", enemyId))
		return nil
	end
	
	if not balanceModule.baseHealth or not balanceModule.baseDamage or not balanceModule.baseSpeed then
		warn(string.format("[EnemyRegistry] Enemy '%s' Balance.lua missing required base stat fields", enemyId))
		return nil
	end
	
	return {
		id = enemyId,
		name = balanceModule.Name,
		balance = balanceModule,
	}
end

-- Discover and register all enemies
local function discoverEnemies()
	for _, child in ipairs(enemiesFolder:GetChildren()) do
		-- Skip non-folders and special files
		if not child:IsA("Folder") then
			continue
		end
		
		-- Skip template folders
		if child.Name:sub(1, 1) == "_" then
			continue
		end
		
		local enemyId = child.Name
		local enemy = loadEnemy(enemyId, child)
		
		if enemy then
			registeredEnemies[enemyId] = enemy
		else
			warn(string.format("[EnemyRegistry] Failed to register enemy: %s", enemyId))
		end
	end
end

-- Initialize the registry (call this once on startup)
function EnemyRegistry.init()
	discoverEnemies()
end

-- Get all registered enemies
function EnemyRegistry.getAll(): {[string]: any}
	return registeredEnemies
end

-- Get a specific enemy by ID
function EnemyRegistry.get(enemyId: string): any?
	return registeredEnemies[enemyId]
end

-- Get enemy balance config by ID (most commonly used)
function EnemyRegistry.getEnemyConfig(enemyId: string): any?
	local enemy = registeredEnemies[enemyId]
	if not enemy then
		warn(string.format("[EnemyRegistry] Unknown enemy type: %s", enemyId))
		return nil
	end
	return enemy.balance
end

-- Check if an enemy type is registered
function EnemyRegistry.isRegistered(enemyId: string): boolean
	return registeredEnemies[enemyId] ~= nil
end

-- Get list of all enemy IDs
function EnemyRegistry.getAllIds(): {string}
	local ids = {}
	for id in pairs(registeredEnemies) do
		table.insert(ids, id)
	end
	return ids
end

-- Auto-initialize on require
EnemyRegistry.init()

return EnemyRegistry

