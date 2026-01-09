--!strict
-- StatusEffectSystem - Manages timed buffs (invincibility, speed boosts, etc.)
-- Broadcasts status changes to clients for visual effects

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)

local StatusEffectSystem = {}

local world: any
local Components: any
local DirtyService: any
local PassiveEffectSystem: any

local StatusEffects: any
local PlayerStats: any

-- Remotes for notifying clients
local StatusEffectUpdate: RemoteEvent
local BuffDurationUpdate: RemoteEvent

-- Cached query for players with status effects
local statusEffectsQuery: any

function StatusEffectSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	StatusEffects = Components.StatusEffects
	PlayerStats = Components.PlayerStats
	
	-- Create cached query
	statusEffectsQuery = world:query(Components.StatusEffects, Components.PlayerStats):cached()
	
	-- Get or create remotes
	local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
	StatusEffectUpdate = remotes:FindFirstChild("StatusEffectUpdate")
	if not StatusEffectUpdate then
		StatusEffectUpdate = Instance.new("RemoteEvent")
		StatusEffectUpdate.Name = "StatusEffectUpdate"
		StatusEffectUpdate.Parent = remotes
	end
	
	BuffDurationUpdate = remotes:WaitForChild("BuffDurationUpdate")
end

-- Set PassiveEffectSystem reference for speed refresh callback
function StatusEffectSystem.setPassiveEffectSystem(passiveEffectSystem: any)
	PassiveEffectSystem = passiveEffectSystem
end

-- Helper to get or create status effects component
local function getOrCreateStatusEffects(playerEntity: number)
	local statusEffects = world:get(playerEntity, StatusEffects)
	if not statusEffects then
		statusEffects = {
			invincible = { endTime = 0 },
			speedBoost = { endTime = 0, multiplier = 1.0 }
		}
		DirtyService.setIfChanged(world, playerEntity, StatusEffects, statusEffects, "StatusEffects")
	end
	return statusEffects
end

-- Broadcast status effects to client
local function broadcastToClient(playerEntity: number, statusEffects: any)
	local playerStats = world:get(playerEntity, PlayerStats)
	if not playerStats or not playerStats.player then
		return
	end
	
	local currentTime = GameTimeSystem.getGameTime()
	local invincibleRemaining = math.max(0, statusEffects.invincible.endTime - currentTime)
	local speedBoostRemaining = math.max(0, statusEffects.speedBoost.endTime - currentTime)
	
	local effects = {
		invincible = invincibleRemaining > 0,
		invincibleDuration = invincibleRemaining,  -- Send remaining duration to client
		speedBoost = speedBoostRemaining > 0 and statusEffects.speedBoost.multiplier or 1.0,
		speedBoostDuration = speedBoostRemaining,
	}
	
	StatusEffectUpdate:FireClient(playerStats.player, effects)
end

-- Grant invincibility for a duration (stacks with existing invincibility buffs)
-- showInTracker: if true, shows in buff duration tracker (for level-up). false for Cloak powerup.
-- pauseAware: if true, duration pauses during player pause (levelup, not death)
-- isSpawnProtection: if true, enemies won't target this player
function StatusEffectSystem.grantInvincibility(playerEntity: number, duration: number, showInTracker: boolean?, pauseAware: boolean?, isSpawnProtection: boolean?)
	local statusEffects = getOrCreateStatusEffects(playerEntity)
	local newEndTime = GameTimeSystem.getGameTime() + duration
	
	local playerStats = world:get(playerEntity, PlayerStats)
	
	-- Preserve spawn protection flag (merge with new invincibility)
	local currentInvincible = statusEffects.invincible
	local wasSpawnProtected = currentInvincible and currentInvincible.isSpawnProtection or false
	local finalSpawnProtection = false
	if isSpawnProtection == true then
		finalSpawnProtection = true
	elseif isSpawnProtection == false then
		finalSpawnProtection = false
	else
		-- isSpawnProtection is nil, preserve old flag only if it was spawn protection
		finalSpawnProtection = wasSpawnProtected
	end
	
	-- Check if existing invincibility is still active
	local currentTime = GameTimeSystem.getGameTime()
	local hasActiveInvincibility = currentInvincible and currentInvincible.endTime > currentTime
	
	-- Keep the LONGEST endTime for actual invincibility effect
	-- But ALWAYS show the new buff in tracker if requested
	local actualEndTime = newEndTime
	if hasActiveInvincibility and currentInvincible.endTime > newEndTime then
		-- Existing invincibility is longer, keep it
		actualEndTime = currentInvincible.endTime
		-- Preserve the existing pauseAware and spawn protection flags
		statusEffects.invincible = {
			endTime = actualEndTime,
			pauseAware = currentInvincible.pauseAware,
			isSpawnProtection = currentInvincible.isSpawnProtection or finalSpawnProtection,
		}
	else
		-- New invincibility is longer (or no existing), use it
		statusEffects.invincible = { 
			endTime = actualEndTime,
			pauseAware = pauseAware or false,
			isSpawnProtection = finalSpawnProtection,
		}
	end
	
	DirtyService.setIfChanged(world, playerEntity, StatusEffects, statusEffects, "StatusEffects")
	broadcastToClient(playerEntity, statusEffects)
	
	-- ALWAYS show the new buff in tracker if requested (even if we kept the longer existing one)
	-- This allows both buffs to display simultaneously: "Spawn Protection 15s" + "Invincibility 2s"
	if showInTracker then
		if playerStats and playerStats.player then
			-- Use different buffId and displayName for spawn protection vs regular invincibility
			local buffId = "Invincibility"
			local displayName = "Invincibility"
			
			if isSpawnProtection then
				buffId = "SpawnProtection"
				displayName = "Spawn Protection"
			end
			
			-- Send the NEW duration (not the actual remaining) for tracker display
			BuffDurationUpdate:FireClient(playerStats.player, {
				buffId = buffId,
				displayName = displayName,
				duration = duration,  -- Use the NEW duration being granted
				healthPercent = nil,
				overhealPercent = nil,
			})
		end
	end
end

-- Grant speed boost for a duration (adds to activeSpeedBuffs for stacking)
-- This affects BOTH walkspeed AND mobility distances (Dash, Double Jump, Shield Bash)
-- buffId: unique identifier ("levelUp", "cloak", etc.) - allows multiple simultaneous buffs
function StatusEffectSystem.grantSpeedBoost(playerEntity: number, duration: number, multiplier: number, buffId: string)
	if not world or not Components then
		return
	end
	
	local newEndTime = GameTimeSystem.getGameTime() + duration
	
	-- Add to activeSpeedBuffs (allows multiple buffs to stack)
	local passiveEffects = world:get(playerEntity, Components.PassiveEffects)
	if passiveEffects then
		if not passiveEffects.activeSpeedBuffs then
			passiveEffects.activeSpeedBuffs = {}
		end
		
		-- Add or update this specific buff (doesn't overwrite others!)
		passiveEffects.activeSpeedBuffs[buffId] = {
			multiplier = multiplier,
			endTime = newEndTime
		}
		
		DirtyService.setIfChanged(world, playerEntity, Components.PassiveEffects, passiveEffects, "PassiveEffects")
		-- Force immediate sync to client (don't wait for next SyncSystem.step)
		DirtyService.mark(playerEntity, "PassiveEffects")
	end
	
	-- Also update StatusEffects for tracking (used by client visual effects)
	local statusEffects = getOrCreateStatusEffects(playerEntity)
	statusEffects.speedBoost = { endTime = newEndTime, multiplier = multiplier }
	DirtyService.setIfChanged(world, playerEntity, StatusEffects, statusEffects, "StatusEffects")
	broadcastToClient(playerEntity, statusEffects)
	
	-- Immediately apply to humanoid
	if PassiveEffectSystem then
		PassiveEffectSystem.applyToPlayer(playerEntity)
	end
end

-- Check if player entity has active invincibility
function StatusEffectSystem.hasInvincibility(playerEntity: number): boolean
	local statusEffects = world:get(playerEntity, StatusEffects)
	if not statusEffects or not statusEffects.invincible then
		return false
	end
	
	return statusEffects.invincible.endTime > GameTimeSystem.getGameTime()
end

-- Check if player entity has spawn protection (enemies don't target)
function StatusEffectSystem.hasSpawnProtection(playerEntity: number): boolean
	local statusEffects = world:get(playerEntity, StatusEffects)
	if not statusEffects or not statusEffects.invincible then
		return false
	end
	
	local currentTime = GameTimeSystem.getGameTime()
	return statusEffects.invincible.endTime > currentTime and statusEffects.invincible.isSpawnProtection
end

-- Get active speed multiplier (1.0 if none)
function StatusEffectSystem.getSpeedMultiplier(playerEntity: number): number
	local statusEffects = world:get(playerEntity, StatusEffects)
	if not statusEffects then
		return 1.0
	end
	
	if statusEffects.speedBoost.endTime > GameTimeSystem.getGameTime() then
		return statusEffects.speedBoost.multiplier
	end
	
	return 1.0
end

-- Extend pause-aware buffs when player is paused (called by PauseSystem)
function StatusEffectSystem.onPlayerPaused(playerEntity: number, pauseDuration: number)
	local statusEffects = world:get(playerEntity, StatusEffects)
	if not statusEffects then
		return
	end
	
	local currentTime = GameTimeSystem.getGameTime()
	
	-- Extend pause-aware invincibility (even if expired, as long as it was pause-aware)
	if statusEffects.invincible and statusEffects.invincible.pauseAware then
		-- Extend the endTime by the pause duration
		statusEffects.invincible.endTime = statusEffects.invincible.endTime + pauseDuration
		DirtyService.setIfChanged(world, playerEntity, StatusEffects, statusEffects, "StatusEffects")
		
		-- DON'T send BuffDurationUpdate here - it causes the buff UI to reset
		-- The BuffGui countdown will naturally pause during the level-up pause
		-- and resume after unpause, showing the correct remaining time
	end
end

-- Update effects, clean up expired, sync to clients
function StatusEffectSystem.step(dt: number)
	local currentTime = GameTimeSystem.getGameTime()
	
	for entity in statusEffectsQuery do
		local statusEffects = world:get(entity, StatusEffects)
		if not statusEffects then
			continue
		end
		
		local hasChanges = false
		
		-- Check if invincibility expired
		if statusEffects.invincible and statusEffects.invincible.endTime > 0 and statusEffects.invincible.endTime <= currentTime then
			-- Skip expiration if pause-aware and player is paused (levelup, not death)
			local shouldExpire = true
			if statusEffects.invincible.pauseAware then
				local pauseState = world:get(entity, Components.PlayerPauseState)
				if pauseState and pauseState.isPaused and pauseState.pauseReason ~= "death" then
					shouldExpire = false  -- Don't expire pause-aware invincibility during levelup
				end
			end
			
			if shouldExpire then
				statusEffects.invincible.endTime = 0
				hasChanges = true
				broadcastToClient(entity, statusEffects)
				
				-- Clear buff icons (both spawn protection and regular invincibility)
				local playerStats = world:get(entity, PlayerStats)
				if playerStats and playerStats.player then
					BuffDurationUpdate:FireClient(playerStats.player, {buffId = "SpawnProtection", duration = 0})
					BuffDurationUpdate:FireClient(playerStats.player, {buffId = "Invincibility", duration = 0})
				end
			end
		end
		
		-- Check if speed boost expired (cleanup handled by PassiveEffectSystem)
		if statusEffects.speedBoost and statusEffects.speedBoost.endTime > 0 and statusEffects.speedBoost.endTime <= currentTime then
			statusEffects.speedBoost.endTime = 0
			statusEffects.speedBoost.multiplier = 1.0
			hasChanges = true
			broadcastToClient(entity, statusEffects)
			-- Note: PassiveEffectSystem.step() handles cleaning up activeSpeedBuffs
		end
		
		-- Update component if there were changes
		if hasChanges then
			DirtyService.setIfChanged(world, entity, StatusEffects, statusEffects, "StatusEffects")
		end
	end
end

return StatusEffectSystem

