--!strict
-- EnemyExpDropSystem - Handles exp orb drops when enemies die
-- Exp amount scales with enemy max HP

local Workspace = game:GetService("Workspace")
local ItemBalance = require(game.ServerScriptService.Balance.ItemBalance)
local EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)
local PowerupBalance = require(game.ServerScriptService.Balance.PowerupBalance)
local DifficultyCoeff = require(game.ServerScriptService.Balance.DifficultyCoeff)

local EnemyExpDropSystem = {}

local world: any
local Components: any
local ECSWorldService: any
local ExpSinkSystem: any
local PickupService: any
local EnemyAggro: any
local PassiveEffects: any

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
	EnemyAggro = Components.EnemyAggro
	PassiveEffects = Components.PassiveEffects
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

local function pickWeightedOrbType(weights: {[string]: number}): string
	local total = 0
	local cumulative = {}
	for orbType, weight in pairs(weights) do
		if weight and weight > 0 then
			total += weight
			table.insert(cumulative, {type = orbType, threshold = total})
		end
	end
	if total <= 0 then
		return "Purple"
	end
	local roll = RNG:NextNumber(0, total)
	for _, entry in ipairs(cumulative) do
		if roll <= entry.threshold then
			return entry.type
		end
	end
	return cumulative[#cumulative].type
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

	local tierData = Components and Components.EnemyTier and world:get(enemyEntity, Components.EnemyTier) or nil
	local tier = tierData and tierData.tier or "Normal"

	-- Tiered enemies: always drop shared EXP (no powerup substitution)
	if tier ~= "Normal" then
		local tierCfg = EnemyBalance.SuperElite or {}
		local tierExpMult = (tier == "Elite" and tierCfg.EliteExpMult) or (tier == "Super" and tierCfg.SuperExpMult) or 1.0
		local dropCount = (tier == "Elite" and tierCfg.EliteDropCount) or (tier == "Super" and tierCfg.SuperDropCount) or 1
		local superWeights = tierCfg.SuperOrbWeights or { Purple = 70, Orange = 30 }
		local eliteOrbType = tierCfg.EliteOrbType or "Purple"

		-- Calculate HP scaling multiplier (every 100 HP = 1.005x)
		local hpMultiplier = ItemBalance.EnemyDrops.HPScaling ^ (maxHP / 100)
		local coeff = DifficultyCoeff.getCoeff()
		local rewardCfg = ItemBalance.ExpRewardScaling or {}
		local xpCoeffExp = rewardCfg.CoeffExp or 1.0
		if typeof(xpCoeffExp) ~= "number" then
			xpCoeffExp = 1.0
		end
		local coeffScale = 1.0
		if typeof(coeff) == "number" and coeff == coeff and coeff > 0 then
			coeffScale = coeff ^ xpCoeffExp
		end

		-- Ground the drop position (same as ambient spawns: ground + 2 studs)
		local groundedPosition = getGroundedPosition(deathPosition, (ItemBalance.OrbHeightOffset or 2.0) + 1.0)
		if not groundedPosition then
			return
		end

		-- Build player list from ECS (all players get full exp)
		local playersByEntity = {}
		for entity, stats in world:query(Components.PlayerStats) do
			if stats and stats.player then
				playersByEntity[entity] = stats.player
			end
		end

		for playerEntity, _ in pairs(playersByEntity) do
			local totalExp = 0
			local orbPayloads = table.create(dropCount)
			for i = 1, dropCount do
				local orbType = eliteOrbType
				if tier == "Super" then
					orbType = pickWeightedOrbType(superWeights)
				end
				local baseExp = ItemBalance.OrbTypes[orbType] and ItemBalance.OrbTypes[orbType].expAmount or 0
				local orbExp = math.floor(baseExp * hpMultiplier * ItemBalance.EnemyDrops.BaseExpMultiplier * coeffScale * tierExpMult)
				totalExp += orbExp
				orbPayloads[i] = { type = orbType, value = orbExp }
			end

			if totalExp > 0 then
				if ExpSinkSystem.shouldAbsorb(playerEntity) then
					ExpSinkSystem.depositExp(totalExp, playerEntity)
				else
					for _, payload in ipairs(orbPayloads) do
						if payload.value > 0 then
							PickupService.spawnExpPickup(payload.type, groundedPosition, playerEntity, payload.value)
						end
					end
				end
			end
		end
		return
	end
	
	-- Roll for powerup drop chance (skip if nuke kill)
	local baseChance = PowerupBalance.EnemyDropPowerupChance
	local bonusChance = 0
	if EnemyAggro then
		local aggro = world:get(enemyEntity, EnemyAggro)
		local ownerEntity = aggro and aggro.owner or nil
		if ownerEntity and PassiveEffects then
			local effects = world:get(ownerEntity, PassiveEffects)
			if effects and effects.powerupChance then
				bonusChance = effects.powerupChance
			end
		elseif aggro and aggro.damageByPlayer then
			local topPlayer = nil
			local topDamage = 0
			for playerEntity, dmg in pairs(aggro.damageByPlayer) do
				if dmg > topDamage then
					topDamage = dmg
					topPlayer = playerEntity
				end
			end
			if topPlayer and PassiveEffects then
				local effects = world:get(topPlayer, PassiveEffects)
				if effects and effects.powerupChance then
					bonusChance = effects.powerupChance
				end
			end
		end
	end
	local finalChance = math.clamp(baseChance + bonusChance, 0, 1)
	local shouldDropPowerup = not nukeKill and ItemBalance.PowerupSpawnEnabled and (RNG:NextNumber() < finalChance)
	
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
		-- Drop exp orb normally (owner + eligible contributors)
		-- Calculate HP scaling multiplier (every 100 HP = 1.005x)
		local hpMultiplier = ItemBalance.EnemyDrops.HPScaling ^ (maxHP / 100)
		
		-- Pick random orb type based on enemy drop weights
		local orbType = pickEnemyDropOrbType()
		local baseExp = ItemBalance.OrbTypes[orbType].expAmount
		local coeff = DifficultyCoeff.getCoeff()
		local rewardCfg = ItemBalance.ExpRewardScaling or {}
		local xpCoeffExp = rewardCfg.CoeffExp or 1.0
		if typeof(xpCoeffExp) ~= "number" then
			xpCoeffExp = 1.0
		end
		local coeffScale = 1.0
		if typeof(coeff) == "number" and coeff == coeff and coeff > 0 then
			coeffScale = coeff ^ xpCoeffExp
		end
		local scaledExp = math.floor(baseExp * hpMultiplier * ItemBalance.EnemyDrops.BaseExpMultiplier * coeffScale)
		
		-- Ground the drop position (same as ambient spawns: ground + 2 studs)
		local groundedPosition = getGroundedPosition(deathPosition, (ItemBalance.OrbHeightOffset or 2.0) + 1.0)
		
		-- Skip drop if no valid ground found within +/- 20 studs
		if not groundedPosition then
			return
		end

		local aggro = EnemyAggro and world:get(enemyEntity, EnemyAggro) or nil
		local ownerEntity = aggro and aggro.owner or nil
		local damageByPlayer = aggro and aggro.damageByPlayer or {}

		-- Build player list from ECS
		local playersByEntity = {}
		for entity, stats in world:query(Components.PlayerStats) do
			if stats and stats.player then
				playersByEntity[entity] = stats.player
			end
		end

		-- If owner missing or invalid, fall back to top damage dealer
		if ownerEntity and not playersByEntity[ownerEntity] then
			ownerEntity = nil
		end
		if ownerEntity == nil then
			local topPlayer = nil
			local topDamage = 0
			for playerEntity, dmg in pairs(damageByPlayer) do
				if dmg > topDamage then
					topDamage = dmg
					topPlayer = playerEntity
				end
			end
			ownerEntity = topPlayer
		end

		-- Owner gets 100% exp
		if ownerEntity and playersByEntity[ownerEntity] then
			if ExpSinkSystem.shouldAbsorb(ownerEntity) then
				ExpSinkSystem.depositExp(scaledExp, ownerEntity)
			else
				if PickupService then
					PickupService.spawnExpPickup(orbType, groundedPosition, ownerEntity, scaledExp)
				end
			end
		end

		-- Other contributors: 25% -> 75% based on % damage (>=30%)
		for playerEntity, dmg in pairs(damageByPlayer) do
			if playerEntity ~= ownerEntity and playersByEntity[playerEntity] then
				if maxHP > 0 then
					local ratio = dmg / maxHP
					if ratio >= 0.30 then
						local clamped = math.clamp(ratio, 0.30, 1.0)
						local bonus = 0.25 + ((clamped - 0.30) / 0.70) * 0.50
						local bonusExp = math.floor(scaledExp * bonus)
						if bonusExp > 0 then
							if ExpSinkSystem.shouldAbsorb(playerEntity) then
								ExpSinkSystem.depositExp(bonusExp, playerEntity)
							else
								if PickupService then
									PickupService.spawnExpPickup(orbType, groundedPosition, playerEntity, bonusExp)
								end
							end
						end
					end
				end
			end
		end
	end
end

return EnemyExpDropSystem
