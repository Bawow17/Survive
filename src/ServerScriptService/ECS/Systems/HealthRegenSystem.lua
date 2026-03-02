--!strict
-- HealthRegenSystem - Handles player health regeneration with damage delay
-- Regenerates health after a delay following damage

local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local RunItems = require(game.ServerScriptService.Balance.RunItems)
local RegenMath = require(game.ReplicatedStorage.Shared.RegenMath)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)

local HealthRegenSystem = {}

local world: any
local Components: any
local DirtyService: any
local ItemSystem: any

local Health: any
local HealthRegen: any
local PassiveEffects: any
local _PlayerStats: any
local Level: any

-- Cached query for players
local playerQuery: any

function HealthRegenSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService

	Health = Components.Health
	HealthRegen = Components.HealthRegen
	PassiveEffects = Components.PassiveEffects
	_PlayerStats = Components.PlayerStats
	Level = Components.Level

	-- Create cached query
	playerQuery = world:query(Components.Health, Components.HealthRegen, Components.PlayerStats, Components.PassiveEffects):cached()
end

function HealthRegenSystem.setItemSystem(itemSystemRef: any)
	ItemSystem = itemSystemRef
end

-- Call this when player takes damage to reset regen delay
function HealthRegenSystem.onPlayerDamaged(playerEntity: number)
	local currentTime = GameTimeSystem.getGameTime()

	-- Get or create HealthRegen component
	local healthRegen = world:get(playerEntity, HealthRegen)
	if not healthRegen then
		healthRegen = {
			lastDamageTime = currentTime,
			isRegenerating = false,
		}
	else
		healthRegen.lastDamageTime = currentTime
		healthRegen.isRegenerating = false
	end

	DirtyService.setIfChanged(world, playerEntity, HealthRegen, healthRegen, "HealthRegen")
end

function HealthRegenSystem.step(dt: number)
	if not world then
		return
	end

	local currentTime = GameTimeSystem.getGameTime()
	local coilCfg = RunItems.Definitions[RunItems.Ids.RegenerationCoil].regenCoil

	-- Process all players
	for playerEntity, health, healthRegen, playerStats, passiveEffects in playerQuery do
		-- Validate player
		if not playerStats or not playerStats.player or not playerStats.player.Parent then
			continue
		end

		-- Skip health regen if player is dead
		local pauseState = world:get(playerEntity, Components.PlayerPauseState)
		if pauseState and pauseState.pauseReason == "death" then
			continue
		end

		-- Don't regen if at max health
		if health.current >= health.max then
			continue
		end

		-- Initialize healthRegen if needed
		if not healthRegen or not healthRegen.lastDamageTime then
			healthRegen = {
				lastDamageTime = 0,
				isRegenerating = false,
			}
			DirtyService.setIfChanged(world, playerEntity, HealthRegen, healthRegen, "HealthRegen")
			continue
		end

		local timeSinceDamage = currentTime - healthRegen.lastDamageTime
		local regenDelay = RegenMath.getEffectiveRegenDelay(passiveEffects, PlayerBalance)
		local regenRampMultiplier = RegenMath.getRegenRampMultiplier(timeSinceDamage, regenDelay)
		local shouldBeRegenerating = regenRampMultiplier > 0
		if healthRegen.isRegenerating ~= shouldBeRegenerating then
			healthRegen.isRegenerating = shouldBeRegenerating
			DirtyService.setIfChanged(world, playerEntity, HealthRegen, healthRegen, "HealthRegen")
		end
		if regenRampMultiplier <= 0 then
			continue
		end

		local playerLevel = 1
		if Level then
			local levelComponent = world:get(playerEntity, Level)
			if levelComponent and typeof(levelComponent.current) == "number" then
				playerLevel = levelComponent.current
			end
		end

		local coilStacks = 0
		if ItemSystem and ItemSystem.getItemCount then
			coilStacks = ItemSystem.getItemCount(playerEntity, RunItems.Ids.RegenerationCoil)
		end

		local currentRegenPerSecond = RegenMath.getCurrentRegenPerSecond(playerLevel, passiveEffects, timeSinceDamage, {
			playerBalance = PlayerBalance,
			coilStacks = coilStacks,
			coilBasePerStack = coilCfg.baseFlatRegenPerStack,
			coilOutOfCombatPerStack = coilCfg.outOfCombatFlatRegenPerStack,
			coilOutOfCombatDelay = coilCfg.outOfCombatDelay,
		})
		if currentRegenPerSecond <= 0 then
			continue
		end

		local regenAmount = currentRegenPerSecond * dt
		local newHealth = math.min(health.current + regenAmount, health.max)

		DirtyService.setIfChanged(world, playerEntity, Health, {
			current = newHealth,
			max = health.max,
		}, "Health")

		local player = playerStats.player
		local character = player.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				humanoid.Health = math.min(newHealth, humanoid.MaxHealth)
			end
		end
	end
end

return HealthRegenSystem
