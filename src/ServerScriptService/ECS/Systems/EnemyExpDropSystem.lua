--!strict
-- EnemyExpDropSystem - RoR2-style kill XP with visual-only orb drops

local Workspace = game:GetService("Workspace")

local ItemBalance = require(game.ServerScriptService.Balance.ItemBalance)
local EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)
local DifficultyCoeff = require(game.ServerScriptService.Balance.DifficultyCoeff)
local EnemyRegistry = require(game.ServerScriptService.Enemies.EnemyRegistry)
local ExpSystem = require(game.ServerScriptService.ECS.Systems.ExpSystem)
local GameStateManager = require(game.ServerScriptService.ECS.Systems.GameStateManager)

local EnemyExpDropSystem = {}

local world: any
local Components: any
local PickupService: any

local RNG = Random.new()

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

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

	local pickupsFolder = Workspace:FindFirstChild("Pickups")
	if pickupsFolder then
		table.insert(playerPartsCache, pickupsFolder)
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
		if math.abs(groundY - position.Y) > 20 then
			return nil
		end
		return Vector3.new(position.X, groundY + heightOffset, position.Z)
	end
	return nil
end

local function pickEnemyDropOrbType(): string
	local cumulative = {}
	local totalWeight = 0
	for _, orbType in ipairs(ItemBalance.OrbTypesList) do
		local weight = ItemBalance.EnemyDrops.DropWeights[orbType] or 0
		totalWeight += weight
		table.insert(cumulative, { type = orbType, threshold = totalWeight })
	end
	if totalWeight <= 0 then
		return "Blue"
	end
	for _, entry in ipairs(cumulative) do
		entry.threshold = entry.threshold / totalWeight
	end
	local roll = RNG:NextNumber()
	for _, entry in ipairs(cumulative) do
		if roll <= entry.threshold then
			return entry.type
		end
	end
	return "Blue"
end

local function pickWeightedOrbType(weights: {[string]: number}): string
	local total = 0
	local cumulative = {}
	for orbType, weight in pairs(weights) do
		if weight > 0 then
			total += weight
			table.insert(cumulative, { type = orbType, threshold = total })
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

local function getActivePlayers(): {{entity: number, player: Player}}
	local activePlayers = {}
	for playerEntity, stats in world:query(Components.PlayerStats) do
		if stats and stats.player and stats.player.Parent then
			local inGame = true
			if GameStateManager and GameStateManager.isPlayerInGame then
				inGame = GameStateManager.isPlayerInGame(stats.player)
			end
			if inGame then
				table.insert(activePlayers, {
					entity = playerEntity,
					player = stats.player,
				})
			end
		end
	end
	return activePlayers
end

local function resolveMonsterValue(enemyEntity: number): number
	local subtype = "Zombie"
	local entityType = world:get(enemyEntity, Components.EntityType)
	if entityType and typeof(entityType) == "table" and typeof(entityType.subtype) == "string" then
		subtype = entityType.subtype
	end

	local costs = (EnemyBalance.SpawnDirector and EnemyBalance.SpawnDirector.MonsterCosts) or {}
	local configuredCost = costs[subtype]
	if typeof(configuredCost) == "number" and configuredCost > 0 then
		return configuredCost
	end

	local config = EnemyRegistry.getEnemyConfig(subtype)
	local baseHealth = (config and typeof(config.baseHealth) == "number" and config.baseHealth > 0) and config.baseHealth or 80
	local baseDamage = (config and typeof(config.baseDamage) == "number" and config.baseDamage > 0) and config.baseDamage or 20
	local inferred = math.floor((baseHealth * 0.09) + (baseDamage * 0.55) + 0.5)
	return math.max(1, inferred)
end

local function getTierData(enemyEntity: number): (string, number)
	local tier = "Normal"
	local tierData = Components and Components.EnemyTier and world:get(enemyEntity, Components.EnemyTier) or nil
	if tierData and typeof(tierData) == "table" and typeof(tierData.tier) == "string" then
		tier = tierData.tier
	end

	local tierCfg = EnemyBalance.SuperElite or {}
	if tier == "Super" then
		return tier, math.max(1, tierCfg.SuperCreditCostMult or 6.0)
	end
	if tier == "Elite" then
		return tier, math.max(1, tierCfg.EliteCreditCostMult or 18.0)
	end
	return "Normal", 1.0
end

local function getKillXpForTeam(enemyEntity: number, activePlayerCount: number): number
	local cfg = ItemBalance.RoR2Exp or {}
	local rewardMultiplier = typeof(cfg.RewardMultiplier) == "number" and cfg.RewardMultiplier or 0.2
	local teamExtraPerPlayer = typeof(cfg.TeamXpExtraPerPlayer) == "number" and cfg.TeamXpExtraPerPlayer or 0.3
	rewardMultiplier = math.max(0.001, rewardMultiplier)

	local coeff = DifficultyCoeff.getCoeff()
	local monsterValue = resolveMonsterValue(enemyEntity)
	local _, tierCostMult = getTierData(enemyEntity)
	local scaledMonsterValue = monsterValue * tierCostMult

	local baseKillXp = math.floor(math.max(1, coeff * scaledMonsterValue * rewardMultiplier))
	local teamMult = 1 + teamExtraPerPlayer * math.max(0, activePlayerCount - 1)
	return math.floor(math.max(1, baseKillXp * teamMult))
end

local function spawnVisualDrops(enemyEntity: number, deathPosition: Vector3, activePlayers: {{entity: number, player: Player}})
	if not PickupService or #activePlayers == 0 then
		return
	end

	local groundedPosition = getGroundedPosition(deathPosition, (ItemBalance.OrbHeightOffset or 2.0) + 1.0)
	if not groundedPosition then
		return
	end

	local roR2ExpCfg = ItemBalance.RoR2Exp or {}
	local visualLifetime = typeof(roR2ExpCfg.VisualOrbLifetime) == "number" and roR2ExpCfg.VisualOrbLifetime or 1.25
	local seekOnSpawn = roR2ExpCfg.VisualOrbSeekOnSpawn ~= false

	local tierCfg = EnemyBalance.SuperElite or {}
	local tier, _ = getTierData(enemyEntity)
	local dropCount = 1

	for _, entry in ipairs(activePlayers) do
		if tier == "Elite" then
			dropCount = math.max(1, math.floor(tierCfg.EliteDropCount or 1))
		elseif tier == "Super" then
			dropCount = math.max(1, math.floor(tierCfg.SuperDropCount or 1))
		else
			dropCount = 1
		end

		for _ = 1, dropCount do
			local orbType = "Blue"
			if tier == "Elite" then
				orbType = tierCfg.EliteOrbType or "Purple"
			elseif tier == "Super" then
				orbType = pickWeightedOrbType(tierCfg.SuperOrbWeights or { Purple = 70, Orange = 30 })
			else
				orbType = pickEnemyDropOrbType()
			end
			PickupService.spawnExpPickup(orbType, groundedPosition, entry.entity, 0, {
				collectible = false,
				visualOnly = true,
				seekOnSpawn = seekOnSpawn,
				allowMerge = false,
				lifetime = visualLifetime,
			})
		end
	end
end

function EnemyExpDropSystem.init(worldRef: any, components: any, _ecsWorldService: any, _expSinkSystem: any, pickupService: any)
	world = worldRef
	Components = components
	PickupService = pickupService
end

function EnemyExpDropSystem.onEnemyDeath(enemyEntity: number, deathPosition: Vector3, _maxHP: number, _nukeKill: boolean?)
	if not world or not ItemBalance.EnemyDrops.Enabled then
		return
	end

	local activePlayers = getActivePlayers()
	if #activePlayers == 0 then
		return
	end

	local sharedKillXp = getKillXpForTeam(enemyEntity, #activePlayers)
	for _, entry in ipairs(activePlayers) do
		local expMult = entry.player:GetAttribute("ExpMultiplier") or 1.0
		local playerXp = math.floor(math.max(1, sharedKillXp * expMult))
		ExpSystem.addExperience(entry.entity, playerXp)
	end

	spawnVisualDrops(enemyEntity, deathPosition, activePlayers)
end

return EnemyExpDropSystem
