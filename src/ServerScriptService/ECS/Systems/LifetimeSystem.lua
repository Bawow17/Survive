--!strict
-- LifetimeSystem - handles lifetime countdown and expiration

local LifetimeSystem = {}

local world
local Components
local DirtyService
local Lifetime

-- Cached query for performance
local lifetimeQuery: any

-- Batch dirty marking optimization (Phase 4.3)
local DIRTY_MARK_INTERVAL = 0.17  -- Mark dirty every 10th frame @ 60fps (client doesn't need real-time lifetime)
local dirtyMarkAccumulator = 0

function LifetimeSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	Lifetime = Components.Lifetime
	
	-- Create cached query for performance
	lifetimeQuery = world:query(Components.Lifetime):cached()
end

function LifetimeSystem.step(dt: number): {number}
	local expired = {}
	
	-- Accumulate time for batch dirty marking
	dirtyMarkAccumulator += dt
	local shouldMarkDirty = dirtyMarkAccumulator >= DIRTY_MARK_INTERVAL
	
	-- Check if any player is paused
	local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
	local anyPlayerPaused = false
	
	if not GameOptions.GlobalPause then
		-- Individual pause mode
		if world and Components.PlayerPauseState then
			for _ in world:query(Components.PlayerPauseState) do
				anyPlayerPaused = true
				break
			end
		end
	else
		-- Global pause mode
		local PauseSystem = require(game.ServerScriptService.ECS.Systems.PauseSystem)
		if PauseSystem and PauseSystem.isPaused() then
			anyPlayerPaused = true
		end
	end
	
	-- Use cached query for better performance
	for entity, lifetime in lifetimeQuery do
		-- Check if this is an enemy entity
		local entityType = world:get(entity, Components.EntityType)
		local isEnemy = entityType and entityType.type == "Enemy"
		
		-- Skip lifetime countdown for enemies during pause
		if anyPlayerPaused and isEnemy then
			continue  -- Don't countdown lifetime for enemies during pause
		end
		
		local remaining = lifetime.remaining - dt
		if remaining <= 0 then
			table.insert(expired, entity)
		else
			-- Update lifetime in-place (always apply countdown)
			lifetime.remaining = remaining
			
			-- Only mark dirty periodically (batch optimization - reduces network/dirty tracking overhead)
			if shouldMarkDirty and remaining ~= lifetime.remaining then
				DirtyService.setIfChanged(world, entity, Lifetime, {
					remaining = remaining,
					max = lifetime.max,
				}, "Lifetime")
			end
		end
	end
	
	-- Reset accumulator if we marked dirty this frame
	if shouldMarkDirty then
		dirtyMarkAccumulator = 0
	end
	
	return expired
end

return LifetimeSystem