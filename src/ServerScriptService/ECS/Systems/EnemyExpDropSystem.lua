--!strict
-- EnemyExpDropSystem - Handles exp orb drops when enemies die
-- Exp amount scales with enemy max HP

local Workspace = game:GetService("Workspace")
local ItemBalance = require(game.ServerScriptService.Balance.ItemBalance)
local PowerupBalance = require(game.ServerScriptService.Balance.PowerupBalance)

local EnemyExpDropSystem = {}

local world: any
local Components: any
local ECSWorldService: any
local ExpSinkSystem: any
local PickupService: any

-- Use Random.new() for better randomization
local RNG = Random.new()

-- Raycast params for ground detection
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

-- Cache for player parts
local playerPartsCache = {}
local lastPlayerPartsUpdate = 0
local PLAYER_PARTS_CACHE_INTERVAL = 2.0

local function getPlayerPartsToExclude()
	local currentTime = tick()
	
	if currentTime - lastPlayerPartsUpdate < PLAYER_PARTS_CACHE_INTERVAL and #playerPartsCache > 0 then
		return playerPartsCache
	end
	
	table.clear(playerPartsCache)
	local Players = game:GetService("Players")
	
	for _, player in pairs(Players:GetPlayers()) do
		if player.Character then
			for _, part in pairs(player.Character:GetChildren()) do
				if part:IsA("BasePart") then
					table.insert(playerPartsCache, part)
				end
			end
			
			for _, accessory in pairs(player.Character:GetChildren()) do
				if accessory:IsA("Accessory") then
					local handle = accessory:FindFirstChild("Handle")
					if handle then
						table.insert(playerPartsCache, handle)
					end
				end
			end
		end
	end
	
	-- Exclude exp orbs folder
	local expOrbsFolder = Workspace:FindFirstChild("ExpOrbs")
	if expOrbsFolder then
		table.insert(playerPartsCache, expOrbsFolder)
	end
	
	lastPlayerPartsUpdate = currentTime
	return playerPartsCache
end

local function getGroundedPosition(position: Vector3, heightOffset: number): Vector3?
	raycastParams.FilterDescendantsInstances = getPlayerPartsToExclude()
	local origin = position + Vector3.new(0, 25, 0)
	local result = Workspace:Raycast(origin, Vector3.new(0, -200, 0), raycastParams)
	if result then
		local groundY = result.Position.Y
		local yDifference = math.abs(groundY - position.Y)
		
		-- Validate: Ground must be within +/- 20 studs of spawn position
		if yDifference > 20 then
			-- Ground too far above or below - reject this spawn position
			return nil
		end
		
		return Vector3.new(position.X, groundY + heightOffset, position.Z)
	end
	
	-- No ground found, reject spawn
	return nil
end

function EnemyExpDropSystem.init(worldRef: any, components: any, ecsWorldService: any, expSinkSystem: any, pickupService: any)
	world = worldRef
	Components = components
	ECSWorldService = ecsWorldService
	ExpSinkSystem = expSinkSystem
	PickupService = pickupService
end

-- Pick random orb type based on enemy drop weights
local function pickEnemyDropOrbType(): string
	-- Calculate cumulative weights in order
	local cumulative = {}
	local totalWeight = 0
	
	for _, orbType in ipairs(ItemBalance.OrbTypesList) do
		local weight = ItemBalance.EnemyDrops.DropWeights[orbType]  -- Use enemy drop weights
		totalWeight = totalWeight + weight
		table.insert(cumulative, {type = orbType, threshold = totalWeight})
	end
	
	-- Normalize weights to 0-1 range
	for _, entry in ipairs(cumulative) do
		entry.threshold = entry.threshold / totalWeight
	end
	
	-- Pick based on random roll
	local roll = RNG:NextNumber()
	
	for _, entry in ipairs(cumulative) do
		if roll <= entry.threshold then
			return entry.type
		end
	end
	
	-- Fallback to Blue
	return "Blue"
end

-- Pick random powerup type based on powerup weights
local function pickPowerupType(): string
	local cumulative = {}
	local totalWeight = 0
	
	for _, powerupType in ipairs(PowerupBalance.PowerupTypesList) do
		local weight = PowerupBalance.PowerupWeights[powerupType]
		totalWeight = totalWeight + weight
		table.insert(cumulative, {type = powerupType, threshold = totalWeight})
	end
	
	-- Normalize weights to 0-1 range
	for _, entry in ipairs(cumulative) do
		entry.threshold = entry.threshold / totalWeight
	end
	
	-- Pick based on random roll
	local roll = RNG:NextNumber()
	
	for _, entry in ipairs(cumulative) do
		if roll <= entry.threshold then
			return entry.type
		end
	end
	
	-- Fallback to Nuke
	return "Nuke"
end

-- Called when an enemy dies
-- nukeKill: if true, this death was caused by Nuke powerup (skip powerup roll)
function EnemyExpDropSystem.onEnemyDeath(enemyEntity: number, deathPosition: Vector3, maxHP: number, nukeKill: boolean?)
	if not world or not ItemBalance.EnemyDrops.Enabled then
		return
	end
	
	-- Roll for powerup drop chance (skip if nuke kill)
	local shouldDropPowerup = not nukeKill and ItemBalance.PowerupSpawnEnabled and (RNG:NextNumber() < PowerupBalance.EnemyDropPowerupChance)
	
	if shouldDropPowerup then
		-- Drop powerup instead of exp
		local powerupType = pickPowerupType()
		local groundedPosition = getGroundedPosition(deathPosition, PowerupBalance.PowerupHeightOffset or 2.0)
		
		-- Skip drop if no valid ground found within +/- 20 studs
		if not groundedPosition then
			return
		end
		
		-- MULTIPLAYER: Health powerups spawn one instance per player
		if powerupType == "Health" then
			local Players = game:GetService("Players")
			for _, player in ipairs(Players:GetPlayers()) do
				-- Find player entity
				local playerEntity = nil
				for entity, stats in world:query(Components.PlayerStats) do
					if stats.player == player then
						playerEntity = entity
						break
					end
				end
				
				if playerEntity then
					ECSWorldService.CreatePowerup(powerupType, groundedPosition, playerEntity)
				end
			end
		else
			-- Other powerups: spawn once globally (no owner)
			ECSWorldService.CreatePowerup(powerupType, groundedPosition, nil)
		end
	else
		-- Drop exp orb normally
		-- Calculate HP scaling multiplier (every 100 HP = 1.005x)
		local hpMultiplier = ItemBalance.EnemyDrops.HPScaling ^ (maxHP / 100)
		
		-- Pick random orb type based on enemy drop weights
		local orbType = pickEnemyDropOrbType()
		local baseExp = ItemBalance.OrbTypes[orbType].expAmount
		local scaledExp = math.floor(baseExp * hpMultiplier * ItemBalance.EnemyDrops.BaseExpMultiplier)
		
		-- Ground the drop position (same as ambient spawns: ground + 2 studs)
		local groundedPosition = getGroundedPosition(deathPosition, (ItemBalance.OrbHeightOffset or 2.0) + 1.0)
		
		-- Skip drop if no valid ground found within +/- 20 studs
		if not groundedPosition then
			return
		end
		
		-- MULTIPLAYER: Spawn one orb per player (each player sees their own orb)
		local Players = game:GetService("Players")
		for _, player in ipairs(Players:GetPlayers()) do
			local playerEntity = nil
			
			-- Find player entity from Components.PlayerStats
			for entity, stats in world:query(Components.PlayerStats) do
				if stats.player == player then
					playerEntity = entity
					break
				end
			end
			
			if playerEntity then
				-- Check if exp-sink should absorb this for this player
				if ExpSinkSystem.shouldAbsorb(playerEntity) then
					ExpSinkSystem.depositExp(scaledExp, playerEntity)
				else
					-- Spawn pickup for this specific player
					if PickupService then
						PickupService.spawnExpPickup(orbType, groundedPosition, playerEntity, scaledExp)
					end
				end
			end
		end
	end
end

return EnemyExpDropSystem
