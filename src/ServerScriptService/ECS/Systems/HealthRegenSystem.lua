--!strict
-- HealthRegenSystem - Handles player health regeneration with damage delay
-- Regenerates health after a delay following damage

local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)

local HealthRegenSystem = {}

local world: any
local Components: any
local DirtyService: any

local Health: any
local HealthRegen: any
local _PlayerStats: any

-- Cached query for players
local playerQuery: any

function HealthRegenSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	Health = Components.Health
	HealthRegen = Components.HealthRegen
	_PlayerStats = Components.PlayerStats
	
	-- Create cached query
	playerQuery = world:query(Components.Health, Components.HealthRegen, Components.PlayerStats):cached()
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
	
	-- Check if regen is enabled
	if PlayerBalance.HealthRegenRate <= 0 then
		return  -- No regen
	end
	
	local currentTime = GameTimeSystem.getGameTime()
	
	-- Process all players
	for playerEntity, health, healthRegen, playerStats in playerQuery do
		-- Validate player
		if not playerStats or not playerStats.player or not playerStats.player.Parent then
			continue
		end
		
		-- Skip health regen if player is dead
		local pauseState = world:get(playerEntity, Components.PlayerPauseState)
		if pauseState and pauseState.pauseReason == "death" then
			continue  -- Dead players don't regenerate health
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
		
		-- Calculate time since damage
		local timeSinceDamage = currentTime - healthRegen.lastDamageTime
		
		-- SCALING REGEN SYSTEM:
		-- First 1 second: No healing (0%)
		-- After 1 second: Scale from 0% to 100% over remaining delay time
		-- Example with 5s delay: 0-1s = 0%, 1-5s = scale 0→100%, 5s+ = 100%
		
		local INITIAL_NO_HEAL_DURATION = 1.0  -- No healing for first 1 second
		local regenMultiplier = 0
		
		if timeSinceDamage < INITIAL_NO_HEAL_DURATION then
			-- First 1 second: No healing
			regenMultiplier = 0
			if healthRegen.isRegenerating then
				healthRegen.isRegenerating = false
				DirtyService.setIfChanged(world, playerEntity, HealthRegen, healthRegen, "HealthRegen")
			end
			continue
		elseif timeSinceDamage < PlayerBalance.HealthRegenDelay then
			-- Scaling phase: scale from 0% to 100%
			local scalingDuration = PlayerBalance.HealthRegenDelay - INITIAL_NO_HEAL_DURATION
			local scalingElapsed = timeSinceDamage - INITIAL_NO_HEAL_DURATION
			regenMultiplier = scalingElapsed / scalingDuration  -- 0.0 to 1.0
			
			if not healthRegen.isRegenerating then
				healthRegen.isRegenerating = true
				DirtyService.setIfChanged(world, playerEntity, HealthRegen, healthRegen, "HealthRegen")
			end
		else
			-- Full delay passed: 100% regen rate
			regenMultiplier = 1.0
			
			if not healthRegen.isRegenerating then
				healthRegen.isRegenerating = true
				DirtyService.setIfChanged(world, playerEntity, HealthRegen, healthRegen, "HealthRegen")
			end
		end
		
		-- Apply regeneration with multiplier
		local regenAmount = PlayerBalance.HealthRegenRate * dt * regenMultiplier
		local newHealth = math.min(health.current + regenAmount, health.max)
		
		-- Update ECS health
		DirtyService.setIfChanged(world, playerEntity, Health, {
			current = newHealth,
			max = health.max
		}, "Health")
		
		-- Update Roblox Humanoid health
		local player = playerStats.player
		local character = player.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				humanoid.Health = math.min(humanoid.Health + regenAmount, humanoid.MaxHealth)
			end
		end
	end
end

return HealthRegenSystem

