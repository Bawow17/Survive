--!strict
-- PauseSystem - Server-authoritative pause system
-- Supports both global pause (entire game) and per-player pause (multiplayer)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)

local PauseSystem = {}

-- System references
local world: any
local Components: any
local DirtyService: any
local StatusEffectSystem: any
local ZombieAISystem: any
local ChargerAISystem: any

-- Pause state
local isPausedState = false
local pauseMetadata: {
	reason: string?,
	triggeringPlayer: Player?,
	fromLevel: number?,
	toLevel: number?,
	upgradeChoices: {any}?,
} = {}

-- Remote events
local GamePaused: RemoteEvent
local GameUnpaused: RemoteEvent
local RequestUnpause: RemoteEvent

-- Callback for handling unpause requests
local unpauseCallback: ((action: string, player: Player) -> ())?

function PauseSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	-- Get or create remote events
	local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
	
	GamePaused = remotes:FindFirstChild("GamePaused") :: RemoteEvent
	if not GamePaused then
		GamePaused = Instance.new("RemoteEvent")
		GamePaused.Name = "GamePaused"
		GamePaused.Parent = remotes
	end
	
	GameUnpaused = remotes:FindFirstChild("GameUnpaused") :: RemoteEvent
	if not GameUnpaused then
		GameUnpaused = Instance.new("RemoteEvent")
		GameUnpaused.Name = "GameUnpaused"
		GameUnpaused.Parent = remotes
	end
	
	RequestUnpause = remotes:FindFirstChild("RequestUnpause") :: RemoteEvent
	if not RequestUnpause then
		RequestUnpause = Instance.new("RemoteEvent")
		RequestUnpause.Name = "RequestUnpause"
		RequestUnpause.Parent = remotes
	end
	
	-- Listen for unpause requests from clients
	RequestUnpause.OnServerEvent:Connect(function(player: Player, data: any)
		-- In individual pause mode, check if this player is paused
		if not GameOptions.GlobalPause then
			-- Find player entity
			local playerEntity = nil
			if world and Components then
				for entity, stats in world:query(Components.PlayerStats) do
					if stats.player == player then
						playerEntity = entity
						break
					end
				end
			end
			
			if playerEntity then
				local pauseState = world:get(playerEntity, Components.PlayerPauseState)
				if not pauseState or not pauseState.isPaused then
					return  -- This player is not paused
				end
			else
				return
			end
		else
			-- Global pause mode
			if not isPausedState then
				return
			end
		end
		
		local action = data and data.action or "unknown"
		local upgradeId = data and data.upgradeId
		
		-- Invoke callback if set
		if unpauseCallback then
			unpauseCallback(action, player, upgradeId)
		end
	end)
end

-- Set StatusEffectSystem reference
function PauseSystem.setStatusEffectSystem(statusEffectSystem: any)
	StatusEffectSystem = statusEffectSystem
end

-- Set ZombieAISystem reference
function PauseSystem.setZombieAISystem(zombieAI: any)
	ZombieAISystem = zombieAI
end

-- Set ChargerAISystem reference
function PauseSystem.setChargerAISystem(chargerAI: any)
	ChargerAISystem = chargerAI
end

-- Check if game is currently paused (global)
function PauseSystem.isPaused(): boolean
	return isPausedState
end

-- Helper: Pause an individual player (multiplayer mode)
local function pausePlayerIndividually(playerEntity: number, player: Player, reason: string, fromLevel: number?, toLevel: number?, upgradeChoices: {any}?)
	if not world or not Components or not DirtyService then
		warn("[PauseSystem] Cannot pause player individually - missing references")
		return
	end
	
	-- Set PlayerPauseState component (use GameTimeSystem for consistency)
	local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
	local pauseStartTime = GameTimeSystem.getGameTime()
	
	world:set(playerEntity, Components.PlayerPauseState, {
		isPaused = true,
		pauseReason = reason,
		pauseStartTime = pauseStartTime,
		pauseEndTime = pauseStartTime + GameOptions.IndividualPauseTimeout,
		upgradeChoices = upgradeChoices,
	})
	DirtyService.mark(playerEntity, "PlayerPauseState")
	
	-- Note: No invincibility needed during pause - enemies are already frozen
	-- Level-up invincibility (2s) is granted in Bootstrap after unpause
	
	-- Freeze cooldowns (set attribute for AbilityCooldownSystem to check)
	player:SetAttribute("CooldownsFrozen", true)
	
	-- Note: Session timer continues during level-up pauses (independent timer)
	
	-- Notify client to freeze player
	GamePaused:FireClient(player, {
		reason = reason,
		fromLevel = fromLevel,
		toLevel = toLevel,
		upgradeChoices = upgradeChoices,
		timeout = GameOptions.IndividualPauseTimeout,
		showTimer = true,
	})
	
	-- Trigger enemy pause transition for both AI systems
	if ZombieAISystem then
		ZombieAISystem.onPlayerPaused(playerEntity)
	end
	if ChargerAISystem then
		ChargerAISystem.onPlayerPaused(playerEntity)
	end
end

-- Helper: Unpause an individual player (multiplayer mode)
local function unpausePlayerIndividually(playerEntity: number, player: Player)
	if not world or not Components then
		return
	end
	
	-- Calculate pause duration and extend pause-aware buffs
	if world:contains(playerEntity) then
		local pauseState = world:get(playerEntity, Components.PlayerPauseState)
		if pauseState and pauseState.pauseStartTime then
			local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
			local pauseDuration = GameTimeSystem.getGameTime() - pauseState.pauseStartTime
			
			-- Extend pause-aware buffs (spawn protection, etc.)
			if StatusEffectSystem then
				StatusEffectSystem.onPlayerPaused(playerEntity, pauseDuration)
			end
		end
		
		-- Remove PlayerPauseState component
		world:remove(playerEntity, Components.PlayerPauseState)
	end
	
	-- Unfreeze cooldowns
	player:SetAttribute("CooldownsFrozen", false)
	
	-- Note: Session timer continues during level-up pauses (independent timer)
	
	-- Notify client to unfreeze player
	GameUnpaused:FireClient(player)
	
	-- Trigger enemy resume for both AI systems
	if ZombieAISystem then
		ZombieAISystem.onPlayerUnpaused(playerEntity)
	end
	if ChargerAISystem then
		ChargerAISystem.onPlayerUnpaused(playerEntity)
	end
end

-- Pause the game (global or individual based on GameOptions.GlobalPause)
function PauseSystem.pause(reason: string, triggeringPlayer: Player?, fromLevel: number?, toLevel: number?, upgradeChoices: {any}?)
	-- Check if using individual pause mode
	if not GameOptions.GlobalPause then
		-- Individual pause: only pause the triggering player
		if triggeringPlayer and world and Components then
			-- Find player entity
			local playerEntity = nil
			for entity, stats in world:query(Components.PlayerStats) do
				if stats.player == triggeringPlayer then
					playerEntity = entity
					break
				end
			end
			
			if playerEntity then
				pausePlayerIndividually(playerEntity, triggeringPlayer, reason, fromLevel, toLevel, upgradeChoices)
			end
		end
		return
	end
	
	-- Global pause mode (original behavior)
	if isPausedState then
		warn("[PauseSystem] Already paused, ignoring pause request")
		return
	end
	
	isPausedState = true
	pauseMetadata = {
		reason = reason,
		triggeringPlayer = triggeringPlayer,
		fromLevel = fromLevel,
		toLevel = toLevel,
		upgradeChoices = upgradeChoices,
	}
	
	-- Send GUI data to the player who leveled up
	if triggeringPlayer then
		GamePaused:FireClient(triggeringPlayer, {
			reason = reason,
			fromLevel = fromLevel,
			toLevel = toLevel,
			upgradeChoices = upgradeChoices,
		})
	end
	
	-- Send freeze-only event to all OTHER players (no GUI data)
	local Players = game:GetService("Players")
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= triggeringPlayer then
			GamePaused:FireClient(player, {
				reason = "freeze_only",  -- Different reason so client doesn't show GUI
			})
		end
	end
end

-- Unpause the game
function PauseSystem.unpause()
	if not isPausedState then
		return
	end
	
	isPausedState = false
	pauseMetadata = {}
	
	-- Broadcast unpause to all clients
	GameUnpaused:FireAllClients()
	
	-- CRITICAL: Force walkspeed restoration for all players immediately after unpause
	-- This prevents "frozen player" bug from pause/unpause cycles
	-- The unpause callback in Bootstrap handles applying PassiveEffects
end

-- Get current pause metadata
function PauseSystem.getMetadata()
	return pauseMetadata
end

-- Set callback for handling unpause requests
function PauseSystem.setUnpauseCallback(callback: (action: string, player: Player, upgradeId: string?) -> ())
	unpauseCallback = callback
end

-- Step function for individual pause timeout checking
function PauseSystem.step(dt: number)
	if GameOptions.GlobalPause then
		return  -- Global pause doesn't need stepping
	end
	
	if not world or not Components then
		return
	end
	
	-- Check for individual pause timeouts
	local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
	local currentTime = GameTimeSystem.getGameTime()
	
	local pauseQuery = world:query(Components.PlayerPauseState, Components.PlayerStats)
	for playerEntity, pauseState, playerStats in pauseQuery do
		if pauseState.isPaused and currentTime >= pauseState.pauseEndTime then
			-- GUARD: Check if player has queued levels before auto-unpausing
			-- If they do, extend the timeout instead of unpausing to prevent movement during queued level-ups
			local pendingLevels = world:get(playerEntity, Components.PendingLevelUps)
			if pendingLevels and pendingLevels.levels and pendingLevels.currentIndex and #pendingLevels.levels > pendingLevels.currentIndex then
				-- Player has more levels queued, extend the timeout instead of unpausing
				print(string.format("[PauseSystem] Player has %d queued levels remaining, extending timeout", 
					#pendingLevels.levels - pendingLevels.currentIndex))
				pauseState.pauseEndTime = currentTime + GameOptions.IndividualPauseTimeout
				world:set(playerEntity, Components.PlayerPauseState, pauseState)
				continue  -- Skip unpause, let the queued level system handle it
			end
			
			-- Timeout reached, auto-select random upgrade
			if pauseState.upgradeChoices and #pauseState.upgradeChoices > 0 then
				local randomIndex = math.random(1, #pauseState.upgradeChoices)
				local randomUpgrade = pauseState.upgradeChoices[randomIndex]
				
				-- Apply the upgrade (call unpause callback)
				if unpauseCallback then
					unpauseCallback("upgrade", playerStats.player, randomUpgrade.id)
				end
			else
				-- No upgrades available, just unpause
				unpausePlayerIndividually(playerEntity, playerStats.player)
			end
		end
	end
end

-- Check if a specific player is paused (works for both global and individual pause)
function PauseSystem.isPlayerPaused(playerEntity: number): boolean
	if GameOptions.GlobalPause then
		return isPausedState  -- Global pause affects all players
	else
		if not world or not Components then
			return false
		end
		local pauseState = world:get(playerEntity, Components.PlayerPauseState)
		return pauseState and pauseState.isPaused or false
	end
end

-- Public API: Unpause a specific player (wrapper for unpausePlayerIndividually)
function PauseSystem.unpausePlayer(playerEntity: number, player: Player)
	unpausePlayerIndividually(playerEntity, player)
end

return PauseSystem

