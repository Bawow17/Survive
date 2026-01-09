--!strict
-- AbilityRegistry.lua - Auto-discovers and registers all abilities
-- Scans the Abilities folder and loads Balance + System for each ability

local AbilityRegistry = {}

local abilitiesFolder = script.Parent
local registeredAbilities: {[string]: any} = {}

-- Validate that an ability has the required files
local function validateAbility(abilityId: string, abilityFolder: Instance): boolean
	-- Check for Config.lua (new unified format) or Balance.lua (legacy)
	local configLua = abilityFolder:FindFirstChild("Config") or abilityFolder:FindFirstChild("Balance")
	local systemLua = abilityFolder:FindFirstChild("System")
	
	if not configLua or not configLua:IsA("ModuleScript") then
		warn(string.format("[AbilityRegistry] Ability '%s' missing Config.lua or Balance.lua", abilityId))
		return false
	end
	
	if not systemLua or not systemLua:IsA("ModuleScript") then
		warn(string.format("[AbilityRegistry] Ability '%s' missing System.lua", abilityId))
		return false
	end
	
	return true
end

-- Load an ability's balance and system modules
local function loadAbility(abilityId: string, abilityFolder: Instance): any?
	if not validateAbility(abilityId, abilityFolder) then
		return nil
	end
	
	-- Try Config.lua first (new unified format), then fall back to Balance.lua (legacy)
	local configModule = abilityFolder:FindFirstChild("Config") or abilityFolder:FindFirstChild("Balance")
	
	local success, balanceModule = pcall(function()
		return require(configModule)
	end)
	
	if not success then
		warn(string.format("[AbilityRegistry] Failed to load Config/Balance for '%s': %s", abilityId, tostring(balanceModule)))
		return nil
	end
	
	local systemSuccess, systemModule = pcall(function()
		return require(abilityFolder.System)
	end)
	
	if not systemSuccess then
		warn(string.format("[AbilityRegistry] Failed to load System.lua for '%s': %s", abilityId, tostring(systemModule)))
		return nil
	end
	
	-- Validate balance has required fields
	if not balanceModule.Name then
		warn(string.format("[AbilityRegistry] Ability '%s' Config/Balance missing 'Name' field", abilityId))
		return nil
	end
	
	-- Validate system has required functions
	if type(systemModule.init) ~= "function" or type(systemModule.step) ~= "function" then
		warn(string.format("[AbilityRegistry] Ability '%s' System.lua missing init() or step() function", abilityId))
		return nil
	end
	
	return {
		id = abilityId,
		name = balanceModule.Name,
		balance = balanceModule,
		system = systemModule,
		init = systemModule.init,
		step = systemModule.step,
	}
end

-- Discover and register all abilities
local function discoverAbilities()
	for _, child in ipairs(abilitiesFolder:GetChildren()) do
		-- Skip non-folders and special folders
		if not child:IsA("Folder") then
			continue
		end
		
		-- Skip template folders
		if child.Name:sub(1, 1) == "_" then
			continue
		end
		
		local abilityId = child.Name
		local ability = loadAbility(abilityId, child)
		
		if ability then
			registeredAbilities[abilityId] = ability
		else
			warn(string.format("[AbilityRegistry] Failed to register ability: %s", abilityId))
		end
	end
end

-- Initialize the registry (call this once on startup)
function AbilityRegistry.init()
	discoverAbilities()
end

-- Get all registered abilities
function AbilityRegistry.getAll(): {[string]: any}
	return registeredAbilities
end

-- Get a specific ability by ID
function AbilityRegistry.get(abilityId: string): any?
	return registeredAbilities[abilityId]
end

-- Get ability balance config by ID
function AbilityRegistry.getBalance(abilityId: string): any?
	local ability = registeredAbilities[abilityId]
	return ability and ability.balance
end

-- Get ability system module by ID
function AbilityRegistry.getSystem(abilityId: string): any?
	local ability = registeredAbilities[abilityId]
	return ability and ability.system
end

-- Check if an ability is registered
function AbilityRegistry.isRegistered(abilityId: string): boolean
	return registeredAbilities[abilityId] ~= nil
end

-- Get list of all ability IDs
function AbilityRegistry.getAllIds(): {string}
	local ids = {}
	for id in pairs(registeredAbilities) do
		table.insert(ids, id)
	end
	return ids
end

-- Get all abilities that players should start with
function AbilityRegistry.getStartingAbilities(): {any}
	local startingAbilities = {}
	for _, ability in pairs(registeredAbilities) do
		if ability.balance.StartWith then
			table.insert(startingAbilities, ability)
		end
	end
	return startingAbilities
end

-- Get all abilities that can appear in random upgrade options
function AbilityRegistry.getUnlockableAbilities(): {any}
	local unlockableAbilities = {}
	for _, ability in pairs(registeredAbilities) do
		if ability.balance.Unlockable then
			table.insert(unlockableAbilities, ability)
		end
	end
	return unlockableAbilities
end

-- Get all abilities locked behind specific requirements (not random upgrades)
function AbilityRegistry.getLockedAbilities(): {any}
	local lockedAbilities = {}
	for _, ability in pairs(registeredAbilities) do
		if not ability.balance.StartWith and not ability.balance.Unlockable then
			table.insert(lockedAbilities, ability)
		end
	end
	return lockedAbilities
end

-- Runtime ability management functions (for use with ECS world)
-- These require world and Components to be passed in since AbilityRegistry doesn't have direct access

-- Check if a player entity has a specific ability
function AbilityRegistry.hasAbility(world: any, playerEntity: number, abilityId: string, AbilityData: any): boolean
	if not world or not playerEntity or not abilityId then
		return false
	end
	
	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or not abilityData.abilities then
		return false
	end
	
	local abilityRecord = abilityData.abilities[abilityId]
	return abilityRecord ~= nil and abilityRecord.enabled == true
end

-- Get list of all ability IDs that a player entity currently has
function AbilityRegistry.getPlayerAbilities(world: any, playerEntity: number, AbilityData: any): {string}
	local abilityIds = {}
	
	if not world or not playerEntity then
		return abilityIds
	end
	
	local abilityData = world:get(playerEntity, AbilityData)
	if not abilityData or not abilityData.abilities then
		return abilityIds
	end
	
	for abilityId, record in pairs(abilityData.abilities) do
		if record and record.enabled then
			table.insert(abilityIds, abilityId)
		end
	end
	
	return abilityIds
end

-- Grant an ability to a player entity (adds to their abilities table and sets up cooldown)
function AbilityRegistry.grantAbility(
	world: any,
	playerEntity: number,
	abilityId: string,
	Components: any,
	DirtyService: any,
	ModelReplicationService: any?
): boolean
	if not world or not playerEntity or not abilityId then
		return false
	end
	
	local ability = registeredAbilities[abilityId]
	if not ability then
		warn(string.format("[AbilityRegistry] Cannot grant unknown ability: %s", abilityId))
		return false
	end
	
	-- Replicate model to client if replication service provided
	if ModelReplicationService then
		ModelReplicationService.replicateAbility(abilityId)
	end
	
	-- Get or create abilities data
	local abilityData = world:get(playerEntity, Components.AbilityData)
	local abilities = abilityData and abilityData.abilities or {}
	
	-- Add new ability
	abilities[abilityId] = {
		enabled = true,
		level = 1,
		Name = ability.name,
		name = ability.name,
	}
	
	-- Update AbilityData component
	DirtyService.setIfChanged(world, playerEntity, Components.AbilityData, {
		abilities = abilities
	}, "AbilityData")
	
	-- Get or create cooldowns data
	local cooldownData = world:get(playerEntity, Components.AbilityCooldown)
	local cooldowns = cooldownData and cooldownData.cooldowns or {}
	
	-- Add cooldown for new ability
	cooldowns[abilityId] = {
		remaining = 0,
		max = ability.balance.cooldown,
	}
	
	-- Update AbilityCooldown component
	DirtyService.setIfChanged(world, playerEntity, Components.AbilityCooldown, {
		cooldowns = cooldowns
	}, "AbilityCooldown")
	
	return true
end

-- Remove an ability from a player entity
function AbilityRegistry.removeAbility(
	world: any,
	playerEntity: number,
	abilityId: string,
	Components: any,
	DirtyService: any
): boolean
	if not world or not playerEntity or not abilityId then
		return false
	end
	
	-- Get abilities data
	local abilityData = world:get(playerEntity, Components.AbilityData)
	if not abilityData or not abilityData.abilities then
		return false
	end
	
	local abilities = abilityData.abilities
	if not abilities[abilityId] then
		return false -- Ability not present
	end
	
	-- Remove ability
	abilities[abilityId] = nil
	
	-- Update AbilityData component
	DirtyService.setIfChanged(world, playerEntity, Components.AbilityData, {
		abilities = abilities
	}, "AbilityData")
	
	-- Remove cooldown
	local cooldownData = world:get(playerEntity, Components.AbilityCooldown)
	if cooldownData and cooldownData.cooldowns then
		local cooldowns = cooldownData.cooldowns
		cooldowns[abilityId] = nil
		
		-- Update AbilityCooldown component
		DirtyService.setIfChanged(world, playerEntity, Components.AbilityCooldown, {
			cooldowns = cooldowns
		}, "AbilityCooldown")
	end
	
	return true
end

-- Auto-initialize on require
AbilityRegistry.init()

return AbilityRegistry

