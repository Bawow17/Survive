--!strict
-- DeathAnimationSystem - Manages death animations and cleanup
-- Destroys entities after death fade animation completes

local DeathAnimationSystem = {}

local world: any
local Components: any
local ECSWorldService: any

-- Component references
local DeathAnimation: any

-- Cached query for performance
local deathQuery: any

function DeathAnimationSystem.init(worldRef: any, components: any, ecsWorldService: any)
	world = worldRef
	Components = components
	ECSWorldService = ecsWorldService
	
	DeathAnimation = Components.DeathAnimation
	
	-- Create cached query for performance (JECS best practice)
	deathQuery = world:query(DeathAnimation):cached()
end

function DeathAnimationSystem.step(_dt: number)
	if not world or not ECSWorldService then
		return
	end
	
	-- PAUSE CHECK: Skip destruction during any pause
	local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
	local shouldSkip = false
	
	if GameOptions.GlobalPause then
		local PauseSystem = require(game.ServerScriptService.ECS.Systems.PauseSystem)
		if PauseSystem and PauseSystem.isPaused() then
			shouldSkip = true
		end
	else
		-- Individual pause: skip if ANY player is paused
		if world and Components.PlayerPauseState then
			for _ in world:query(Components.PlayerPauseState) do
				shouldSkip = true
				break
			end
		end
	end
	
	if shouldSkip then
		return  -- Don't destroy any entities during pause
	end
	
	local currentTime = tick()
	
	-- Check for entities that have completed death animation using cached query
	for entity, deathAnim in deathQuery do
		-- Entity should be destroyed immediately after flash completes + fade duration
		local flashDuration = (deathAnim.flashEndTime - deathAnim.startTime)
		local fadeDuration = deathAnim.duration
		local totalDuration = flashDuration + fadeDuration -- No buffer, destroy immediately after fade
		local destroyTime = deathAnim.startTime + totalDuration
		
		if currentTime >= destroyTime then
			-- Return poolable entities to their pools instead of destroying
			local entityType = world:get(entity, Components.EntityType)
			local typeStr = entityType and entityType.type or "Unknown"
			
			if typeStr == "Enemy" then
				-- Import pools locally to avoid circular dependency
				local EnemyPool = require(game.ServerScriptService.ECS.EnemyPool)
				local SyncSystem = require(game.ServerScriptService.ECS.Systems.SyncSystem)
				SyncSystem.queueDespawn(entity)  -- Notify clients to remove visual
				EnemyPool.release(entity)
			elseif typeStr == "Projectile" then
				local ProjectilePool = require(game.ServerScriptService.ECS.ProjectilePool)
				local SyncSystem = require(game.ServerScriptService.ECS.Systems.SyncSystem)
				SyncSystem.queueDespawn(entity)  -- Notify clients to remove visual
				ProjectilePool.release(entity)
			elseif typeStr == "ExpOrb" then
				local ExpOrbPool = require(game.ServerScriptService.ECS.ExpOrbPool)
				local SyncSystem = require(game.ServerScriptService.ECS.Systems.SyncSystem)
				SyncSystem.queueDespawn(entity)  -- Notify clients to remove visual
				ExpOrbPool.release(entity)
			else
				-- Non-pooled entities are destroyed normally
				ECSWorldService.DestroyEntity(entity)
			end
		end
	end
end

return DeathAnimationSystem
