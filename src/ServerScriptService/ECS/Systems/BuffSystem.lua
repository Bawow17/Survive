--!strict
-- BuffSystem - Manages temporary buffs that stack with passive effects
-- Buffs are multiplicative with passives and each other

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)

local BuffSystem = {}

local world: any
local Components: any
local DirtyService: any
local PassiveEffectSystem: any

local BuffState: any
local PlayerStats: any

-- Remote for buff duration updates
local BuffDurationUpdate: RemoteEvent

-- Cached query for players with buffs
local buffQuery: any

function BuffSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	BuffState = Components.BuffState
	PlayerStats = Components.PlayerStats
	
	-- Create cached query
	buffQuery = world:query(Components.BuffState, Components.PlayerStats):cached()
	
	-- Get remote
	local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
	BuffDurationUpdate = remotes:WaitForChild("BuffDurationUpdate")
end

-- Set PassiveEffectSystem reference (called after it's initialized)
function BuffSystem.setPassiveEffectSystem(passiveEffectSystem: any)
	PassiveEffectSystem = passiveEffectSystem
end

-- Helper to get or create BuffState component
local function getOrCreateBuffState(playerEntity: number)
	local buffState = world:get(playerEntity, BuffState)
	if not buffState then
		buffState = { buffs = {} }
		DirtyService.setIfChanged(world, playerEntity, BuffState, buffState, "BuffState")
	end
	return buffState
end

-- PUBLIC API: Add a buff to a player
function BuffSystem.addBuff(
	playerEntity: number, 
	buffId: string, 
	duration: number, 
	damageMultiplier: number?, 
	cooldownMultiplier: number?,
	homingMultiplier: number?,
	penetrationMultiplier: number?,
	durationMultiplier: number?,
	projectileSpeedMultiplier: number?
)
	local buffState = getOrCreateBuffState(playerEntity)
	local now = GameTimeSystem.getGameTime()
	
	buffState.buffs[buffId] = {
		endTime = now + duration,
		damageMultiplier = damageMultiplier or 1.0,
		cooldownMultiplier = cooldownMultiplier or 1.0,
		homingMultiplier = homingMultiplier or 1.0,
		penetrationMultiplier = penetrationMultiplier or 1.0,
		durationMultiplier = durationMultiplier or 1.0,
		projectileSpeedMultiplier = projectileSpeedMultiplier or 1.0,
	}
	
	DirtyService.setIfChanged(world, playerEntity, BuffState, buffState, "BuffState")
	
	-- Refresh player stats to apply buff
	if PassiveEffectSystem then
		PassiveEffectSystem.applyToPlayer(playerEntity)
	end
	
	-- Broadcast to buff duration tracker (only for Cloak and ArcaneRune from powerups)
	local playerStats = world:get(playerEntity, PlayerStats)
	if playerStats and playerStats.player and (buffId == "Cloak" or buffId == "ArcaneRune") then
		local PowerupBalance = require(game.ServerScriptService.Balance.PowerupBalance)
		local config = PowerupBalance.PowerupTypes[buffId]
		if config then
			BuffDurationUpdate:FireClient(playerStats.player, {
				buffId = buffId,
				displayName = config.displayName or buffId,
				duration = duration,
				healthPercent = nil,
				overhealPercent = nil,
			})
		end
	end
end

-- PUBLIC API: Remove a buff from a player
function BuffSystem.removeBuff(playerEntity: number, buffId: string)
	local buffState = world:get(playerEntity, BuffState)
	if not buffState or not buffState.buffs[buffId] then
		return
	end
	
	buffState.buffs[buffId] = nil
	
	-- Remove component if no buffs remain
	if next(buffState.buffs) == nil then
		world:remove(playerEntity, BuffState)
	else
		DirtyService.setIfChanged(world, playerEntity, BuffState, buffState, "BuffState")
	end
	
	-- Refresh player stats to remove buff
	if PassiveEffectSystem then
		PassiveEffectSystem.applyToPlayer(playerEntity)
	end
end

-- PUBLIC API: Check if player has a specific buff
function BuffSystem.hasBuff(playerEntity: number, buffId: string): boolean
	local buffState = world:get(playerEntity, BuffState)
	if not buffState then
		return false
	end
	
	local buff = buffState.buffs[buffId]
	return buff ~= nil and buff.endTime > GameTimeSystem.getGameTime()
end

-- PUBLIC API: Get combined damage multiplier from all active buffs
function BuffSystem.getDamageMultiplier(playerEntity: number): number
	local buffState = world:get(playerEntity, BuffState)
	if not buffState then
		return 1.0
	end
	
	local multiplier = 1.0
	local now = GameTimeSystem.getGameTime()
	
	for _, buff in pairs(buffState.buffs) do
		if buff.endTime > now then
			multiplier = multiplier * (buff.damageMultiplier or 1.0)
		end
	end
	
	return multiplier
end

-- PUBLIC API: Get combined cooldown multiplier from all active buffs
function BuffSystem.getCooldownMultiplier(playerEntity: number): number
	local buffState = world:get(playerEntity, BuffState)
	if not buffState then
		return 1.0
	end
	
	local multiplier = 1.0
	local now = GameTimeSystem.getGameTime()
	
	for _, buff in pairs(buffState.buffs) do
		if buff.endTime > now then
			multiplier = multiplier * (buff.cooldownMultiplier or 1.0)
		end
	end
	
	return multiplier
end

-- System step: Expire buffs and clean up
function BuffSystem.step(dt: number)
	local now = GameTimeSystem.getGameTime()
	
	for entity in buffQuery do
		-- Skip buff expiration if player is paused (levelup, NOT death)
		local pauseState = world:get(entity, Components.PlayerPauseState)
		if pauseState and pauseState.isPaused and pauseState.pauseReason ~= "death" then
			continue  -- Don't expire buffs for paused players (buffs continue for dead players)
		end
		
		local buffState = world:get(entity, BuffState)
		if not buffState then
			continue
		end
		
		local hasChanges = false
		local expiredBuffs = {}
		
		-- Check for expired buffs
		for buffId, buff in pairs(buffState.buffs) do
			if buff.endTime <= now then
				table.insert(expiredBuffs, buffId)
				hasChanges = true
			end
		end
		
		-- Remove expired buffs
		for _, buffId in ipairs(expiredBuffs) do
			buffState.buffs[buffId] = nil
		end
		
		-- Update component or remove if no buffs remain
		if hasChanges then
			if next(buffState.buffs) == nil then
				world:remove(entity, BuffState)
			else
				DirtyService.setIfChanged(world, entity, BuffState, buffState, "BuffState")
			end
			
			-- Refresh player stats when buffs expire
			if PassiveEffectSystem then
				PassiveEffectSystem.applyToPlayer(entity)
			end
		end
	end
end

return BuffSystem

