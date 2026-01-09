--!strict
-- GameStateManager - Manages main menu, lobby, game start, and team wipe flow

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameSessionTimer = require(game.ServerScriptService.ECS.Systems.GameSessionTimer)

local GameStateManager = {}

-- Game States
local GameState = {
	LOBBY = "Lobby",
	IN_GAME = "InGame",
	WIPED = "Wiped",
}

-- Module state
local currentState = GameState.LOBBY
local playersInGame: {[Player]: {entity: number?, level: number, exp: number, upgrades: any?}} = {}
local gameStartTime = 0
local privateGameCode: string? = nil
local wipeData: {[Player]: {level: number, exp: number}}? = nil
local continueExpiration: number? = nil
local lastWipeCheck = 0
local WIPE_CHECK_INTERVAL = 0.33  -- ~3fps

-- System references (set via init)
local world: any
local Components: any
local DirtyService: any
local ECSWorldService: any
local StatusEffectSystem: any
local PauseSystem: any
local ExpSystem: any

-- Lobby spawn position (near camera view)
local LOBBY_SPAWN_POSITION = Vector3.new(220, 609, 400)

-- Remote events
local remotesFolder: Folder
local StartGameRemote: RemoteEvent
local GameStartRemote: RemoteEvent
local CheckGameStateRemote: RemoteFunction
local ReturnToMenuRemote: RemoteEvent
local ContinuePurchasedRemote: RemoteEvent
local ContinueSuccessRemote: RemoteEvent
local TeamWipeRemote: RemoteEvent
local StartCleanupRemote: RemoteEvent
local WipeCleanupCompleteRemote: RemoteEvent

function GameStateManager.init(worldRef, components, dirtyService, ecsWorldService)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService
	
	-- Create remotes
	remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	
	if not remotesFolder:FindFirstChild("StartGame") then
		StartGameRemote = Instance.new("RemoteEvent")
		StartGameRemote.Name = "StartGame"
		StartGameRemote.Parent = remotesFolder
	else
		StartGameRemote = remotesFolder:FindFirstChild("StartGame") :: RemoteEvent
	end
	
	if not remotesFolder:FindFirstChild("GameStart") then
		GameStartRemote = Instance.new("RemoteEvent")
		GameStartRemote.Name = "GameStart"
		GameStartRemote.Parent = remotesFolder
	else
		GameStartRemote = remotesFolder:FindFirstChild("GameStart") :: RemoteEvent
	end
	
	if not remotesFolder:FindFirstChild("CheckGameState") then
		CheckGameStateRemote = Instance.new("RemoteFunction")
		CheckGameStateRemote.Name = "CheckGameState"
		CheckGameStateRemote.Parent = remotesFolder
	else
		CheckGameStateRemote = remotesFolder:FindFirstChild("CheckGameState") :: RemoteFunction
	end
	
	if not remotesFolder:FindFirstChild("ReturnToMenu") then
		ReturnToMenuRemote = Instance.new("RemoteEvent")
		ReturnToMenuRemote.Name = "ReturnToMenu"
		ReturnToMenuRemote.Parent = remotesFolder
	else
		ReturnToMenuRemote = remotesFolder:FindFirstChild("ReturnToMenu") :: RemoteEvent
	end
	
	if not remotesFolder:FindFirstChild("ContinuePurchased") then
		ContinuePurchasedRemote = Instance.new("RemoteEvent")
		ContinuePurchasedRemote.Name = "ContinuePurchased"
		ContinuePurchasedRemote.Parent = remotesFolder
	else
		ContinuePurchasedRemote = remotesFolder:FindFirstChild("ContinuePurchased") :: RemoteEvent
	end
	
	if not remotesFolder:FindFirstChild("ContinueSuccess") then
		ContinueSuccessRemote = Instance.new("RemoteEvent")
		ContinueSuccessRemote.Name = "ContinueSuccess"
		ContinueSuccessRemote.Parent = remotesFolder
	else
		ContinueSuccessRemote = remotesFolder:FindFirstChild("ContinueSuccess") :: RemoteEvent
	end
	
	if not remotesFolder:FindFirstChild("TeamWipe") then
		TeamWipeRemote = Instance.new("RemoteEvent")
		TeamWipeRemote.Name = "TeamWipe"
		TeamWipeRemote.Parent = remotesFolder
	else
		TeamWipeRemote = remotesFolder:FindFirstChild("TeamWipe") :: RemoteEvent
	end
	
	if not remotesFolder:FindFirstChild("StartCleanup") then
		StartCleanupRemote = Instance.new("RemoteEvent")
		StartCleanupRemote.Name = "StartCleanup"
		StartCleanupRemote.Parent = remotesFolder
	else
		StartCleanupRemote = remotesFolder:FindFirstChild("StartCleanup") :: RemoteEvent
	end
	
	if not remotesFolder:FindFirstChild("WipeCleanupComplete") then
		WipeCleanupCompleteRemote = Instance.new("RemoteEvent")
		WipeCleanupCompleteRemote.Name = "WipeCleanupComplete"
		WipeCleanupCompleteRemote.Parent = remotesFolder
	else
		WipeCleanupCompleteRemote = remotesFolder:FindFirstChild("WipeCleanupComplete") :: RemoteEvent
	end
	
	-- Connect remote handlers
	StartGameRemote.OnServerEvent:Connect(handleStartGame)
	CheckGameStateRemote.OnServerInvoke = handleCheckGameState
	ReturnToMenuRemote.OnServerEvent:Connect(handleReturnToMenu)
	ContinuePurchasedRemote.OnServerEvent:Connect(handleContinuePurchased)
	StartCleanupRemote.OnServerEvent:Connect(handleStartCleanup)
	
end

function GameStateManager.setStatusEffectSystem(statusEffectSystem)
	StatusEffectSystem = statusEffectSystem
end

function GameStateManager.setPauseSystem(pauseSystem)
	PauseSystem = pauseSystem
end

function GameStateManager.setExpSystem(expSystem)
	ExpSystem = expSystem
end

-- Handle player joining server (spawn in lobby)
function GameStateManager.onPlayerJoin(player: Player)
	
	-- Player will spawn via CharacterAdded in Bootstrap
	-- Just ensure they start in lobby state
	if currentState == GameState.IN_GAME then
		print(string.format("[GameStateManager] Game in progress - %s will see 'Join Active Game' option", player.Name))
	elseif currentState == GameState.WIPED then
		print(string.format("[GameStateManager] Game wiped - %s can only spectate until restart", player.Name))
	end
end

-- Handle Start Game button click
function handleStartGame(player: Player)
	if currentState == GameState.LOBBY then
		-- First player, start fresh game
		currentState = GameState.IN_GAME
		gameStartTime = tick()
		GameSessionTimer.startSession()
		GameStateManager.addPlayerToGame(player)
	elseif currentState == GameState.IN_GAME then
		-- Game active, join in progress
		GameStateManager.addPlayerToGame(player)
	elseif currentState == GameState.WIPED then
		-- Team wiped, can't join until restart
		warn(string.format("[GameStateManager] %s tried to join wiped game - rejecting", player.Name))
		-- Could fire a "Game Over" message to client here
		return
	end
end

-- Check game state for client
function handleCheckGameState(player: Player): string
	return currentState
end

-- Add player to active game
function GameStateManager.addPlayerToGame(player: Player)
	if not player.Character then
		warn(string.format("[GameStateManager] Can't add %s to game - no character", player.Name))
		return
	end
	
	local humanoidRootPart = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart
	local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
	if not humanoidRootPart then
		warn(string.format("[GameStateManager] Can't add %s to game - no HumanoidRootPart", player.Name))
		return
	end
	
	
	-- Teleport to game spawn
	local spawnLocation = workspace:FindFirstChild("SpawnLocation")
	if spawnLocation and spawnLocation:IsA("SpawnLocation") then
		humanoidRootPart.CFrame = spawnLocation.CFrame + Vector3.new(0, 5, 0)
	else
		-- Fallback spawn
		humanoidRootPart.CFrame = CFrame.new(0, 5, 0)
	end
	
	-- CRITICAL: Reset player physics after teleport
	local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
	humanoid.WalkSpeed = PlayerBalance.BaseWalkSpeed
	humanoid.JumpPower = 50  -- Reset to default
	humanoidRootPart.Anchored = false
	humanoidRootPart.Velocity = Vector3.zero
	humanoidRootPart.AssemblyLinearVelocity = Vector3.zero
	
	-- Create ECS entity
	local playerEntity = ECSWorldService.CreatePlayer(player, humanoidRootPart.Position)
	
	if not playerEntity then
		warn(string.format("[GameStateManager] Failed to create entity for %s", player.Name))
		return
	end
	
	-- Re-enable ambient spawning now that player is in game
	local ExpOrbSpawner = require(game.ServerScriptService.ECS.Systems.ExpOrbSpawner)
	local EnemySpawner = require(game.ServerScriptService.ECS.Systems.EnemySpawner)
	ExpOrbSpawner.setEnabled(true)
	EnemySpawner.setEnabled(true)
	
	-- Initialize session stats tracking for this player
	local SessionStatsTracker = require(game.ServerScriptService.ECS.Systems.SessionStatsTracker)
	SessionStatsTracker.onPlayerAdded(playerEntity)
	
	-- Grant spawn protection
	if StatusEffectSystem then
		local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
		StatusEffectSystem.grantInvincibility(playerEntity, PlayerBalance.SpawnInvincibility, true, true, true)
	end
	
	-- Apply passive effects
	task.wait(0.1)
	if ECSWorldService.PassiveEffectSystem then
		local PassiveEffectSystem = require(game.ServerScriptService.ECS.Systems.PassiveEffectSystem)
		PassiveEffectSystem.applyToPlayer(playerEntity)
	end
	
	-- Spawn starter exp (use configured delay)
	local ItemBalance = require(game.ServerScriptService.Balance.ItemBalance)
	local spawnDelay = (ItemBalance.SpawnExps and ItemBalance.SpawnExps.SpawnDelay) or 0.5
	
	task.delay(spawnDelay, function()
		if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
			local hrp = player.Character:FindFirstChild("HumanoidRootPart")
			if ItemBalance.SpawnExps.Enabled then
				ECSWorldService.SpawnStarterExps(player, hrp.Position, playerEntity)
			end
		end
	end)
	
	-- Track player in game
	playersInGame[player] = {
		entity = playerEntity,
		level = 1,
		exp = 0,
		upgrades = {},
	}
	
	-- Notify client that game started
	GameStartRemote:FireClient(player)
	
	
end

-- Forward declaration
local triggerTeamWipe: () -> ()

-- Check for team wipe (called at 3fps)
local function checkForTeamWipe()
	local hasAlivePlayer = false
	
	-- Check all players in game
	for player, data in pairs(playersInGame) do
		if data.entity then
			-- Check if player is alive (not dead, has entity)
			local DeathSystem = require(game.ServerScriptService.ECS.Systems.DeathSystem)
			if not DeathSystem.isPlayerDead(data.entity) then
				hasAlivePlayer = true
				break
			end
		end
	end
	
	-- Trigger wipe if no alive players
	if not hasAlivePlayer and next(playersInGame) ~= nil then
		triggerTeamWipe()
	end
end

-- Trigger team wipe (all players dead)
function triggerTeamWipe()
	if currentState == GameState.WIPED then
		return  -- Already wiped
	end
	
	print("[GameStateManager] TEAM WIPE DETECTED")
	currentState = GameState.WIPED
	
	-- Pause session timer
	GameSessionTimer.pauseSession()
	
	-- Get all session stats
	local SessionStatsTracker = require(game.ServerScriptService.ECS.Systems.SessionStatsTracker)
	
	-- CRITICAL: Freeze all player survive times at this exact moment (prevents time drift during wipe sequence)
	SessionStatsTracker.freezeSurviveTimes()
	
	-- Get final session time
	local finalSessionTime = GameSessionTimer.getSessionTime()
	local allStats = SessionStatsTracker.getAllStats()
	
	-- Build stats payload for each player with INDIVIDUAL survive times
	local statsPayload = {}
	for player, data in pairs(playersInGame) do
		local playerEntity = data.entity
		local stats = allStats[playerEntity]
		
		if stats then
			-- Calculate individual player's survive time (from when they joined)
			local playerSurviveTime = SessionStatsTracker.getPlayerSurviveTime(playerEntity)
			
			table.insert(statsPayload, {
				username = player.Name,
				level = data.level or 1,
				kills = stats.kills or 0,
				deaths = stats.deaths or 0,
				damage = stats.totalDamage or 0,
				surviveTime = playerSurviveTime,  -- Individual time, not session time
			})
		end
	end
	
	-- Sort by totalDamage descending
	table.sort(statsPayload, function(a, b)
		return (a.damage or 0) > (b.damage or 0)
	end)
	
	-- Fire wipe remote to all clients with final session time (for GameSessionLabel)
	TeamWipeRemote:FireAllClients(statsPayload, finalSessionTime)
	
	-- Disable all respawn timers
	local DeathSystem = require(game.ServerScriptService.ECS.Systems.DeathSystem)
	DeathSystem.disableAllRespawnTimers()
end

-- Handle Continue purchase (Robux)
function handleContinuePurchased(player: Player)
	if currentState ~= GameState.WIPED then
		warn(string.format("[GameStateManager] %s tried to continue but state is %s", player.Name, currentState))
		return
	end
	
	if not wipeData then
		warn("[GameStateManager] Continue triggered but no wipe data")
		return
	end
	
	-- Check if continue expired
	if continueExpiration and tick() > continueExpiration then
		warn("[GameStateManager] Continue expired")
		-- TODO: Notify client
		return
	end
	
	print(string.format("[GameStateManager] %s purchased Continue - respawning all players", player.Name))
	
	-- Respawn all players with stored levels
	for targetPlayer, data in pairs(wipeData) do
		if targetPlayer.Parent and targetPlayer.Character then
			local hrp = targetPlayer.Character:FindFirstChild("HumanoidRootPart")
			if hrp then
				-- Teleport to game spawn
				local spawnLocation = workspace:FindFirstChild("SpawnLocation")
				if spawnLocation and spawnLocation:IsA("SpawnLocation") then
					hrp.CFrame = spawnLocation.CFrame + Vector3.new(0, 5, 0)
				end
				
				-- Create entity with stored level
				local playerEntity = ECSWorldService.CreatePlayer(targetPlayer, hrp.Position)
				if playerEntity then
					-- Restore level and exp
					if data.level > 1 then
						world:set(playerEntity, Components.Level, {
							current = data.level,
							max = 999,
						})
						DirtyService.mark(playerEntity, "Level")
					end
					
					if data.exp > 0 then
						world:set(playerEntity, Components.Experience, {
							current = data.exp,
							required = 100,  -- Will be recalculated by ExpSystem
							total = data.exp,
						})
						DirtyService.mark(playerEntity, "Experience")
					end
					
					-- Grant spawn protection
					if StatusEffectSystem then
						local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
						StatusEffectSystem.grantInvincibility(playerEntity, PlayerBalance.SpawnInvincibility, true, true, true)
					end
					
					-- Update tracking
					playersInGame[targetPlayer] = {
						entity = playerEntity,
						level = data.level,
						exp = data.exp,
						upgrades = {},
					}
					
					-- Notify client
					ContinueSuccessRemote:FireClient(targetPlayer)
				end
			end
		end
	end
	
	-- Clear wipe state
	currentState = GameState.IN_GAME
	wipeData = nil
	continueExpiration = nil
	gameStartTime = tick()  -- Reset game timer
	
	print("[GameStateManager] Continue complete - game resumed")
end

-- Handle individual player returning to menu (after wipe or manual)
function handleReturnToMenu(player: Player)
	print(string.format("[GameStateManager] %s returning to menu", player.Name))
	
	-- Remove from active game
	if playersInGame[player] then
		local data = playersInGame[player]
		if data.entity then
			ECSWorldService.DestroyEntity(data.entity)
		end
		playersInGame[player] = nil
	end
	
	-- Teleport to lobby
	if player.Character then
		local hrp = player.Character:FindFirstChild("HumanoidRootPart")
		if hrp then
			hrp.CFrame = CFrame.new(LOBBY_SPAWN_POSITION)
		end
	end
	
	-- If all players returned to menu, reset game state
	local activeCount = 0
	for p in pairs(playersInGame) do
		if p.Parent then
			activeCount = activeCount + 1
		end
	end
	
	if activeCount == 0 and currentState ~= GameState.LOBBY then
		GameStateManager.resetGame()
	end
end

-- Reset game to lobby state
function GameStateManager.resetGame()
	print("[GameStateManager] Resetting game to LOBBY state")
	
	-- Despawn all entities (enemies, projectiles, items)
	-- This would need to be implemented more thoroughly
	
	-- Clear player entities
	for player, data in pairs(playersInGame) do
		if data.entity then
			ECSWorldService.DestroyEntity(data.entity)
		end
	end
	
	-- Reset state
	currentState = GameState.LOBBY
	playersInGame = {}
	wipeData = nil
	continueExpiration = nil
	gameStartTime = 0
	
	print("[GameStateManager] Game reset complete")
end

-- Handle cleanup request from client after wipe countdown
function handleStartCleanup(player: Player)
	
	-- CRITICAL: Disable ALL ambient spawning immediately
	local ExpOrbSpawner = require(game.ServerScriptService.ECS.Systems.ExpOrbSpawner)
	local EnemySpawner = require(game.ServerScriptService.ECS.Systems.EnemySpawner)
	ExpOrbSpawner.setEnabled(false)
	EnemySpawner.setEnabled(false)
	
	-- Set state to LOBBY
	currentState = GameState.LOBBY
	
	local PauseSystem = require(game.ServerScriptService.ECS.Systems.PauseSystem)
	
	-- Collect all entities to destroy by type
	local entitiesToDestroy = {
		enemies = {},
		projectiles = {},
		expOrbs = {},
		powerups = {},
		afterimageClones = {},
	}
	
	local entityQuery = world:query(Components.EntityType)
	local totalScanned = 0
	for entity, entityType in entityQuery do
		totalScanned = totalScanned + 1
		if entityType.type == "Enemy" then
			table.insert(entitiesToDestroy.enemies, entity)
		elseif entityType.type == "Projectile" then
			table.insert(entitiesToDestroy.projectiles, entity)
		elseif entityType.type == "ExpOrb" then
			table.insert(entitiesToDestroy.expOrbs, entity)
		elseif entityType.type == "Powerup" then
			table.insert(entitiesToDestroy.powerups, entity)
		elseif entityType.type == "AfterimageClone" then
			table.insert(entitiesToDestroy.afterimageClones, entity)
		end
	end
	
	
	-- Destroy all collected entities
	for _, entity in ipairs(entitiesToDestroy.enemies) do
		ECSWorldService.DestroyEntity(entity)
	end
	for _, entity in ipairs(entitiesToDestroy.projectiles) do
		ECSWorldService.DestroyEntity(entity)
	end
	for _, entity in ipairs(entitiesToDestroy.expOrbs) do
		ECSWorldService.DestroyEntity(entity)
	end
	for _, entity in ipairs(entitiesToDestroy.powerups) do
		ECSWorldService.DestroyEntity(entity)
	end
	for _, entity in ipairs(entitiesToDestroy.afterimageClones) do
		ECSWorldService.DestroyEntity(entity)
	end
	
	-- Manually fire despawn events to all clients to ensure they're removed
	local EntityDespawn = remotesFolder:WaitForChild("ECS"):FindFirstChild("EntityDespawn")
	if EntityDespawn then
		local allEntityIds = {}
		for _, entity in ipairs(entitiesToDestroy.enemies) do
			table.insert(allEntityIds, entity)
		end
		for _, entity in ipairs(entitiesToDestroy.projectiles) do
			table.insert(allEntityIds, entity)
		end
		for _, entity in ipairs(entitiesToDestroy.expOrbs) do
			table.insert(allEntityIds, entity)
		end
		for _, entity in ipairs(entitiesToDestroy.powerups) do
			table.insert(allEntityIds, entity)
		end
		for _, entity in ipairs(entitiesToDestroy.afterimageClones) do
			table.insert(allEntityIds, entity)
		end
		
		if #allEntityIds > 0 then
			EntityDespawn:FireAllClients(allEntityIds)
		end
	end
	
	-- Wait for clients to process despawns
	task.wait(2.0)  -- Increased from 1.0 to 2.0 seconds
	
	-- Double-check: Count remaining entities
	local remainingCounts = {enemies = 0, projectiles = 0, expOrbs = 0, powerups = 0, afterimageClones = 0}
	local recheckQuery = world:query(Components.EntityType)
	for entity, entityType in recheckQuery do
		if entityType.type == "Enemy" then
			remainingCounts.enemies = remainingCounts.enemies + 1
		elseif entityType.type == "Projectile" then
			remainingCounts.projectiles = remainingCounts.projectiles + 1
		elseif entityType.type == "ExpOrb" then
			remainingCounts.expOrbs = remainingCounts.expOrbs + 1
		elseif entityType.type == "Powerup" then
			remainingCounts.powerups = remainingCounts.powerups + 1
		elseif entityType.type == "AfterimageClone" then
			remainingCounts.afterimageClones = remainingCounts.afterimageClones + 1
		end
	end
	
	-- Clean up any stragglers
	if remainingCounts.expOrbs > 0 or remainingCounts.enemies > 0 or remainingCounts.projectiles > 0 or remainingCounts.powerups > 0 or remainingCounts.afterimageClones > 0 then
		for entity, entityType in recheckQuery do
			if entityType.type == "Enemy" or entityType.type == "Projectile" or entityType.type == "ExpOrb" or entityType.type == "Powerup" or entityType.type == "AfterimageClone" then
				ECSWorldService.DestroyEntity(entity)
			end
		end
		local EntityDespawn = remotesFolder:WaitForChild("ECS"):FindFirstChild("EntityDespawn")
		if EntityDespawn then
			EntityDespawn:FireAllClients({})  -- Force client refresh
		end
		task.wait(0.5)
	end
	
	-- Destroy all player entities
	for targetPlayer, data in pairs(playersInGame) do
		if data.entity then
			ECSWorldService.DestroyEntity(data.entity)
			data.entity = nil
		end
	end
	
	-- Reset session stats
	local SessionStatsTracker = require(game.ServerScriptService.ECS.Systems.SessionStatsTracker)
	SessionStatsTracker.reset()
	
	-- Reset all time systems
	local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
	GameTimeSystem.reset()
	GameSessionTimer.resetSession()
	
	-- Force respawn all players to alive state at lobby spawn
	local DeathSystem = require(game.ServerScriptService.ECS.Systems.DeathSystem)
	DeathSystem.clearAllDeathStates()
	DeathSystem.enableRespawnTimers()
	
	local allPlayers = Players:GetPlayers()
	
	for _, targetPlayer in ipairs(allPlayers) do
		if targetPlayer.Character then
			local humanoid = targetPlayer.Character:FindFirstChildOfClass("Humanoid")
			local hrp = targetPlayer.Character:FindFirstChild("HumanoidRootPart") :: BasePart
			
			if humanoid and hrp then
				
				-- Restore body parts transparency and unanchor ALL parts
				for _, descendant in ipairs(targetPlayer.Character:GetDescendants()) do
					if descendant:IsA("BasePart") then
						if descendant.Name == "HumanoidRootPart" then
							descendant.Transparency = 1
						else
							descendant.Transparency = 0
						end
						descendant.CanCollide = true
						descendant.Anchored = false
					elseif descendant:IsA("Decal") then
						descendant.Transparency = 0
					end
				end
				
				-- Restore full health
				humanoid.Health = humanoid.MaxHealth
				
				-- Reset physics
				local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
				humanoid.WalkSpeed = PlayerBalance.BaseWalkSpeed
				humanoid.JumpPower = 50
				hrp.Anchored = false
				hrp.Velocity = Vector3.zero
				hrp.AssemblyLinearVelocity = Vector3.zero
				
				-- Teleport to lobby spawn
				hrp.CFrame = CFrame.new(LOBBY_SPAWN_POSITION)
				
				-- Fire PlayerRespawned to hide death screen
				local PlayerRespawned = remotesFolder:FindFirstChild("PlayerRespawned")
				if PlayerRespawned then
					PlayerRespawned:FireClient(targetPlayer)
				end
			else
				warn(string.format("[GameStateManager] %s - Missing humanoid or HRP", targetPlayer.Name))
			end
		else
			warn(string.format("[GameStateManager] %s - No character", targetPlayer.Name))
		end
	end
	
	-- Clear ALL player attributes for fresh state
	for _, targetPlayer in ipairs(allPlayers) do
		local attrs = targetPlayer:GetAttributes()
		for attrName, _ in pairs(attrs) do
			targetPlayer:SetAttribute(attrName, nil)
		end
	end
	
	-- Clear pause states and unfreeze cooldowns
	-- CRITICAL: Unpause the server-side PauseSystem first
	local PauseSystem = require(game.ServerScriptService.ECS.Systems.PauseSystem)
	if PauseSystem.isPaused() then
		PauseSystem.unpause()
	end
	
	for _, targetPlayer in ipairs(allPlayers) do
		-- CRITICAL: Fire GameUnpaused (not GamePaused with "unpause")
		local GameUnpaused = remotesFolder:FindFirstChild("GameUnpaused")
		if GameUnpaused then
			GameUnpaused:FireClient(targetPlayer)
		end
	end
	
	-- Reset game state
	playersInGame = {}
	currentState = GameState.LOBBY
	gameStartTime = 0
	wipeData = nil
	continueExpiration = nil
	
	-- Wait 5 seconds grace period, then signal clients
	task.wait(5)
	
	-- Clear scoreboards for all players
	local ClearScoreboardRemote = remotesFolder:FindFirstChild("ClearScoreboard")
	if not ClearScoreboardRemote then
		ClearScoreboardRemote = Instance.new("RemoteEvent")
		ClearScoreboardRemote.Name = "ClearScoreboard"
		ClearScoreboardRemote.Parent = remotesFolder
	end
	ClearScoreboardRemote:FireAllClients()
	print("[GameStateManager] Fired ClearScoreboard to all clients")
	
	WipeCleanupCompleteRemote:FireAllClients()
	
	-- Hide wipe scoreboard
	local HideWipeScoreboard = remotesFolder:FindFirstChild("HideWipeScoreboard")
	if not HideWipeScoreboard then
		HideWipeScoreboard = Instance.new("RemoteEvent")
		HideWipeScoreboard.Name = "HideWipeScoreboard"
		HideWipeScoreboard.Parent = remotesFolder
	end
	HideWipeScoreboard:FireAllClients()
end

-- Step function (check wipe and continue timer)
function GameStateManager.step(dt: number)
	if currentState == GameState.IN_GAME then
		-- Wipe check throttled to 3fps
		local now = tick()
		if now - lastWipeCheck >= WIPE_CHECK_INTERVAL then
			lastWipeCheck = now
			checkForTeamWipe()
		end
	elseif currentState == GameState.WIPED and continueExpiration then
		if tick() >= continueExpiration then
			print("[GameStateManager] Continue expired - clearing wipe data")
			wipeData = nil
			continueExpiration = nil
		end
	end
end

-- Getters
function GameStateManager.getCurrentState(): string
	return currentState
end

-- Update player level in tracking table (called from ExpSystem)
function GameStateManager.updatePlayerLevel(player: Player, newLevel: number)
	if playersInGame[player] then
		playersInGame[player].level = newLevel
	end
end

function GameStateManager.getPlayersInGame(): {[Player]: any}
	return playersInGame
end

function GameStateManager.isPlayerInGame(player: Player): boolean
	return playersInGame[player] ~= nil
end

-- Private game code system
function GameStateManager.generatePrivateCode(): string
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	local code = ""
	for i = 1, 6 do
		local idx = math.random(1, #chars)
		code = code .. chars:sub(idx, idx)
	end
	return code
end

function GameStateManager.createPrivateGame(player: Player)
	privateGameCode = GameStateManager.generatePrivateCode()
	print(string.format("[GameStateManager] Private game created with code: %s", privateGameCode))
	return privateGameCode
end

function GameStateManager.validatePrivateCode(player: Player, code: string): boolean
	return code == privateGameCode
end

return GameStateManager

