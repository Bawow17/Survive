--!strict
-- ExpOrbSpawner - Handles spawning exp orbs around players
-- Spawns orbs at intervals near players with different rarities

local Workspace = game:GetService("Workspace")
local ItemBalance = require(game.ServerScriptService.Balance.ItemBalance)
local PowerupBalance = require(game.ServerScriptService.Balance.PowerupBalance)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
local EasingUtils = require(game.ServerScriptService.Balance.EasingUtils)

local ExpOrbSpawner = {}

local world: any
local Components: any
local ECSWorldService: any
local ExpSinkSystem: any  -- Reference to sink system
local PickupService: any

local Position: any
local PlayerStats: any

local spawnAccumulator = 0
local initialDelayAccumulator = 0
local hasInitialDelayPassed = false
local spawnEnabled = true

-- Spawn check throttle (check every frame, use accumulator for actual spawning)
local spawnCheckAccumulator = 0

-- Use Random.new() for better randomization (matches old example pattern)
local RNG = Random.new()

-- Cached queries for performance
local orbCountQuery: any
local playerPositionQuery: any

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

-- Cache for player parts to avoid recreating tables every frame
-- Phase 4.4 optimization: Increased intervals since raycasts are for spawn validation (not critical)
local playerPartsCache = {}
local lastPlayerPartsUpdate = 0
local PLAYER_PARTS_CACHE_INTERVAL = 5.0  -- Increased from 1.0s to 5.0s

-- Function to get all player-related parts to exclude from ground detection
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
	
	-- Exclude exp orbs (though they shouldn't interfere with exp orb spawning)
	local expOrbsFolder = Workspace:FindFirstChild("ExpOrbs")
	if expOrbsFolder then
		for _, orbModel in pairs(expOrbsFolder:GetChildren()) do
			if orbModel:IsA("Model") then
				for _, part in pairs(orbModel:GetDescendants()) do
					if part:IsA("BasePart") then
						table.insert(playerPartsCache, part)
					end
				end
			end
		end
	end
	
	-- Exclude powerups
	local powerupsFolder = Workspace:FindFirstChild("Powerups")
	if powerupsFolder then
		for _, powerupModel in pairs(powerupsFolder:GetChildren()) do
			if powerupModel:IsA("Model") then
				for _, part in pairs(powerupModel:GetDescendants()) do
					if part:IsA("BasePart") then
						table.insert(playerPartsCache, part)
					end
				end
			end
		end
	end
	
	-- Exclude projectiles
	local projectilesFolder = Workspace:FindFirstChild("Projectiles")
	if projectilesFolder then
		for _, projectileModel in pairs(projectilesFolder:GetChildren()) do
			if projectileModel:IsA("Model") then
				for _, part in pairs(projectileModel:GetDescendants()) do
					if part:IsA("BasePart") then
						table.insert(playerPartsCache, part)
					end
				end
			end
		end
	end
	
	lastPlayerPartsUpdate = currentTime
	return playerPartsCache
end

-- Update raycast parameters to exclude player parts
local function updateRaycastParams()
	raycastParams.FilterDescendantsInstances = getPlayerPartsToExclude()
end

function ExpOrbSpawner.init(worldRef: any, components: any, ecsWorldService: any, expSinkSystem: any, pickupService: any)
	world = worldRef
	Components = components
	ECSWorldService = ecsWorldService
	ExpSinkSystem = expSinkSystem
	PickupService = pickupService

	Position = Components.Position
	PlayerStats = Components.PlayerStats
	
	-- Create cached queries
	orbCountQuery = world:query(Components.EntityType):cached()
	playerPositionQuery = world:query(Components.Position, Components.PlayerStats):cached()
end

-- Set ExpSinkSystem reference (called after it's initialized)
function ExpOrbSpawner.setExpSinkSystem(expSinkSystem: any)
	ExpSinkSystem = expSinkSystem
end

local function getGroundedPosition(position: Vector3, heightOffset: number): Vector3?
	updateRaycastParams()
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

local function getRandomSpawnPosition(playerPos: {x: number, y: number, z: number}): Vector3
	if not playerPos or not playerPos.x or not playerPos.y or not playerPos.z then
		warn("[ExpOrbSpawner] Invalid player position provided:", playerPos)
		return Vector3.new(0, 0, 0)
	end
	
	local angle = math.random() * math.pi * 2
	local minRadius = ItemBalance.MinSpawnRadius or 10
	local maxRadius = ItemBalance.MaxSpawnRadius or 30
	local distance = minRadius + math.random() * (maxRadius - minRadius)

	local offsetX = math.cos(angle) * distance
	local offsetZ = math.sin(angle) * distance

	return Vector3.new(playerPos.x + offsetX, playerPos.y, playerPos.z + offsetZ)
end

-- Pick random orb type based on ambient spawn weights (matches old example pattern)
local function pickOrbType(): string
	-- Calculate cumulative weights in order (CRITICAL: must be in order!)
	local cumulative = {}
	local totalWeight = 0
	
	for _, orbType in ipairs(ItemBalance.OrbTypesList) do
		local weight = ItemBalance.AmbientSpawnWeights[orbType]  -- Use ambient weights
		totalWeight = totalWeight + weight
		table.insert(cumulative, {type = orbType, threshold = totalWeight})
	end
	
	-- Normalize weights to 0-1 range
	for _, entry in ipairs(cumulative) do
		entry.threshold = entry.threshold / totalWeight
	end
	
	-- Pick based on random roll
	local roll = RNG:NextNumber()  -- Use Random.new() for better randomization
	
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

function ExpOrbSpawner.setEnabled(enabled: boolean)
	spawnEnabled = enabled
end

function ExpOrbSpawner.step(dt: number)
	if not world or not ItemBalance.SpawnEnabled or not spawnEnabled then
		return
	end

	-- Handle initial delay (if needed)
	if not hasInitialDelayPassed then
		initialDelayAccumulator += dt
		if initialDelayAccumulator >= 1.0 then  -- 1 second initial delay
			hasInitialDelayPassed = true
		else
			return
		end
	end

	-- Accumulate orbs to spawn based on scaled exp spawn rate (uses game time)
	-- Subtract initial delay so scaling starts from 0 when spawning actually begins
	local gameTime = GameTimeSystem.getGameTime()
	local adjustedTime = math.max(0, gameTime - 1.0)  -- 1 second initial delay
	local expSpawnRate = EasingUtils.evaluate(ItemBalance.ExpPerSecondScaling, adjustedTime)
	spawnAccumulator += expSpawnRate * dt

	-- Get player positions (only for IN-GAME players)
	local playerPositions = {}
	local GameStateManager = require(game.ServerScriptService.ECS.Systems.GameStateManager)
	
	for entity, position, playerStats in playerPositionQuery do
		if playerStats and playerStats.player and playerStats.player.Parent then
			-- Skip players not in the game (in menu or wipe screen)
			if not GameStateManager.isPlayerInGame(playerStats.player) then
				continue
			end
			
			table.insert(playerPositions, {
				entity = entity,
				position = position,
				stats = playerStats
			})
		end
	end

	if #playerPositions == 0 then
		spawnAccumulator = 0
		return
	end

	-- Spawn orbs while we have accumulated spawns
	-- Note: Don't check MaxOrbs here - let the sink system handle cap logic
	while spawnAccumulator >= 1 do
		spawnAccumulator = spawnAccumulator - 1

		-- Pick a random player to spawn near
		local targetPlayer = playerPositions[math.random(1, #playerPositions)]
		
		if not targetPlayer or not targetPlayer.position then
			continue
		end
		
		local spawnPosVector = getRandomSpawnPosition(targetPlayer.position)
		
		-- Roll for powerup spawn chance
		local shouldSpawnPowerup = ItemBalance.PowerupSpawnEnabled and (RNG:NextNumber() < PowerupBalance.AmbientPowerupChance)
		
		if shouldSpawnPowerup then
			-- Spawn powerup instead of exp orb
			local powerupType = pickPowerupType()
			-- Use powerup height offset
			local heightOffset = PowerupBalance.PowerupHeightOffset or 2.0
			spawnPosVector = getGroundedPosition(spawnPosVector, heightOffset)
			
			-- Skip spawn if no valid ground found within +/- 20 studs
			if not spawnPosVector then
				continue
			end
			
			-- MULTIPLAYER: Health powerups spawn one instance per player
			if powerupType == "Health" then
				for _, playerData in ipairs(playerPositions) do
					ECSWorldService.CreatePowerup(powerupType, spawnPosVector, playerData.entity)
				end
			else
				-- Other powerups: spawn once globally (no owner)
				ECSWorldService.CreatePowerup(powerupType, spawnPosVector, nil)
			end
		else
			-- MULTIPLAYER: Spawn exp orb for the target player (ambient orbs are per-player)
			local orbType = pickOrbType()
			local expAmount = ItemBalance.OrbTypes[orbType].expAmount
			local playerEntity = targetPlayer.entity
			
			-- Check if exp-sink should absorb this for this player
			-- This checks if we've reached MaxOrbs cap and creates/deposits into red orb
			if ExpSinkSystem and ExpSinkSystem.shouldAbsorb(playerEntity) then
				ExpSinkSystem.depositExp(expAmount, playerEntity)
				-- Don't spawn orb, exp absorbed into red sink
			else
				-- Spawn orb normally for this player
				-- Use configured height offset + 1 stud for pickups
				local heightOffset = (ItemBalance.OrbHeightOffset or 2.0) + 1.0
				spawnPosVector = getGroundedPosition(spawnPosVector, heightOffset)
				
				-- Skip spawn if no valid ground found within +/- 20 studs
				if not spawnPosVector then
					continue
				end

				if PickupService then
					PickupService.spawnExpPickup(orbType, spawnPosVector, playerEntity)
				end
			end
		end
	end
end

return ExpOrbSpawner
