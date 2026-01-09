--!strict
-- DeathSystem - Handles custom player death state, spectating, and respawn

local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)

local DeathSystem = {}

local world: any
local Components: any
local DirtyService: any
local PauseSystem: any
local GameStateManager: any

-- Death state tracking
local playerDeathStates: {[number]: {
	deathTime: number,
	respawnTime: number,
	spectatingIndex: number,  -- Index in alive players list
}} = {}

-- Respawn timer control
local respawnTimersDisabled = false

function DeathSystem.init(worldRef, components, dirtyService)
	world = worldRef
	Components = components
	DirtyService = dirtyService
end

function DeathSystem.setPauseSystem(pauseSystem)
	PauseSystem = pauseSystem
end

function DeathSystem.setGameStateManager(gameStateManager)
	GameStateManager = gameStateManager
end

function DeathSystem.triggerPlayerDeath(playerEntity: number, player: Player)
	if not world or not Components or not DirtyService then
		warn("[DeathSystem] Not initialized properly")
		return
	end
	
	-- Track death in session stats
	local SessionStatsTracker = require(game.ServerScriptService.ECS.Systems.SessionStatsTracker)
	SessionStatsTracker.trackDeath(playerEntity)
	
	-- Calculate respawn time based on level
	local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
	local level = world:get(playerEntity, Components.Level)
	local playerLevel = level and level.current or 1
	
	local scaling = PlayerBalance.DeathRespawnScaling
	local respawnDelay = math.min(
		scaling.StartValue + (scaling.Slope * (playerLevel - 1)),
		scaling.MaxValue
	)
	
	print(string.format("[DeathSystem] Player %s died (level %d), respawn in %.1fs", player.Name, playerLevel, respawnDelay))
	
	-- Set death state (use tick() for respawn timer as it's real-world time)
	local deathTime = tick()
	playerDeathStates[playerEntity] = {
		deathTime = deathTime,
		respawnTime = deathTime + respawnDelay,
		spectatingIndex = 1,
	}
	
	-- Freeze player using pause system (this makes enemies ignore them)
	-- Use GameTimeSystem for pause start time (for consistency with pause duration calculations)
	local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
	world:set(playerEntity, Components.PlayerPauseState, {
		isPaused = true,
		pauseReason = "death",
		pauseStartTime = GameTimeSystem.getGameTime(),  -- Use game time for pause calculations
		pauseEndTime = math.huge,  -- No timeout
	})
	DirtyService.mark(playerEntity, "PlayerPauseState")
	
	-- Grant invincibility
	local StatusEffectSystem = require(game.ServerScriptService.ECS.Systems.StatusEffectSystem)
	StatusEffectSystem.grantInvincibility(playerEntity, math.huge, false, false, false)  -- Death freeze invincibility
	
	-- Freeze cooldowns
	player:SetAttribute("CooldownsFrozen", true)
	
	-- Set pickup range to 0 to prevent item collection
	local originalPickupRange = player:GetAttribute("PickupRange") or PlayerBalance.BasePickupRange
	player:SetAttribute("OriginalPickupRange", originalPickupRange)
	player:SetAttribute("PickupRange", 0)
	
	-- Fire GamePaused to client to trigger freeze (uses existing freeze system)
	local remotes = game.ReplicatedStorage:WaitForChild("RemoteEvents")
	local GamePaused = remotes:FindFirstChild("GamePaused")
	if GamePaused then
		GamePaused:FireClient(player, {
			reason = "death_freeze",  -- Triggers freezePlayer() without showing GUI
			showTimer = true,  -- Treat as individual pause (entities keep rendering)
		})
	end
	
	-- Anchor player body and play death animation
	if player.Character then
		local humanoidRootPart = player.Character:FindFirstChild("HumanoidRootPart")
		if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
			humanoidRootPart.Anchored = true
		end
		
		-- Hide player name and health from other players
		local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			-- Store original display settings
			player:SetAttribute("OriginalDisplayDistanceType", humanoid.DisplayDistanceType.Value)
			player:SetAttribute("OriginalHealthDisplayType", humanoid.HealthDisplayType.Value)
			player:SetAttribute("OriginalNameDisplayDistance", humanoid.NameDisplayDistance)
			player:SetAttribute("OriginalHealthDisplayDistance", humanoid.HealthDisplayDistance)
			
			-- Hide name and health
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			humanoid.NameDisplayDistance = 0
			humanoid.HealthDisplayDistance = 0
			
			-- Play death animation if configured
			if PlayerBalance.DeathAnimationId then
				local animator = humanoid:FindFirstChildOfClass("Animator")
				if not animator then
					animator = Instance.new("Animator")
					animator.Parent = humanoid
				end
				
				local deathAnimation = Instance.new("Animation")
				deathAnimation.AnimationId = PlayerBalance.DeathAnimationId
				
				local animationTrack = animator:LoadAnimation(deathAnimation)
				animationTrack:Play()
			end
		end
	end
	
	-- Get random death message
	local DeathMessages = require(game.ServerScriptService.Balance.DeathMessages)
	local randomIndex = math.random(1, #DeathMessages)
	local deathMessage = DeathMessages[randomIndex]
	
	-- Fire to client (UI will show death screen)
	local remotes = game.ReplicatedStorage:WaitForChild("RemoteEvents")
	local PlayerDied = remotes:FindFirstChild("PlayerDied")
	if not PlayerDied then
		PlayerDied = Instance.new("RemoteEvent")
		PlayerDied.Name = "PlayerDied"
		PlayerDied.Parent = remotes
	end
	
	PlayerDied:FireClient(player, {
		respawnTime = respawnDelay,
		deathMessage = deathMessage,
	})
	
	-- Initialize spectating to first alive player immediately
	local targetPlayer, targetName = DeathSystem.getCurrentSpectatorTarget(playerEntity)
	if targetName then
		-- Fire spectator update to client
		local SpectatorTargetChanged = remotes:FindFirstChild("SpectatorTargetChanged")
		if SpectatorTargetChanged then
			SpectatorTargetChanged:FireClient(player, targetName)
		end
	end
	
	-- Start server-side body fade (replicates to all clients)
	local DeathBodyFadeSystem = require(game.ServerScriptService.ECS.Systems.DeathBodyFadeSystem)
	DeathBodyFadeSystem.startFade(player)
	
	-- Team wipe is now handled by GameStateManager.step() at 3fps
end

function DeathSystem.changeSpectatorTarget(playerEntity: number, player: Player, direction: number): string?
	-- direction: 1 = forward, -1 = backward
	local deathState = playerDeathStates[playerEntity]
	if not deathState then return nil end
	
	-- Get list of alive players
	local alivePlayers = {}
	for entity, playerStats in world:query(Components.PlayerStats) do
		local pauseState = world:get(entity, Components.PlayerPauseState)
		local isDead = pauseState and pauseState.pauseReason == "death"
		if not isDead and entity ~= playerEntity then
			table.insert(alivePlayers, {entity = entity, player = playerStats.player})
		end
	end
	
	if #alivePlayers == 0 then
		return nil  -- No alive players to spectate
	end
	
	-- Cycle spectator index
	deathState.spectatingIndex = deathState.spectatingIndex + direction
	if deathState.spectatingIndex > #alivePlayers then
		deathState.spectatingIndex = 1
	elseif deathState.spectatingIndex < 1 then
		deathState.spectatingIndex = #alivePlayers
	end
	
	-- Return spectating target name
	local targetData = alivePlayers[deathState.spectatingIndex]
	return targetData and targetData.player.Name or nil
end

function DeathSystem.getCurrentSpectatorTarget(playerEntity: number): (Player?, string?)
	local deathState = playerDeathStates[playerEntity]
	if not deathState then return nil, nil end
	
	-- Get list of alive players
	local alivePlayers = {}
	for entity, playerStats in world:query(Components.PlayerStats) do
		local pauseState = world:get(entity, Components.PlayerPauseState)
		local isDead = pauseState and pauseState.pauseReason == "death"
		if not isDead and entity ~= playerEntity then
			table.insert(alivePlayers, {entity = entity, player = playerStats.player})
		end
	end
	
	if #alivePlayers == 0 then
		return nil, nil
	end
	
	-- Clamp index to valid range
	if deathState.spectatingIndex > #alivePlayers then
		deathState.spectatingIndex = #alivePlayers
	elseif deathState.spectatingIndex < 1 then
		deathState.spectatingIndex = 1
	end
	
	local targetData = alivePlayers[deathState.spectatingIndex]
	return targetData.player, targetData.player.Name
end

function DeathSystem.disableAllRespawnTimers()
	respawnTimersDisabled = true
	
	-- Fire remote to all clients to hide death timer
	local remotes = game.ReplicatedStorage:WaitForChild("RemoteEvents")
	local DisableRespawnTimerRemote = remotes:FindFirstChild("DisableRespawnTimer")
	if not DisableRespawnTimerRemote then
		DisableRespawnTimerRemote = Instance.new("RemoteEvent")
		DisableRespawnTimerRemote.Name = "DisableRespawnTimer"
		DisableRespawnTimerRemote.Parent = remotes
	end
	DisableRespawnTimerRemote:FireAllClients()
	
	print("[DeathSystem] All respawn timers disabled")
end

function DeathSystem.enableRespawnTimers()
	respawnTimersDisabled = false
	print("[DeathSystem] Respawn timers re-enabled")
end

function DeathSystem.clearAllDeathStates()
	-- Clear all death states (called after wipe cleanup)
	local stateCount = 0
	for _ in pairs(playerDeathStates) do
		stateCount = stateCount + 1
	end
	print(string.format("[DeathSystem] Clearing %d death states", stateCount))
	table.clear(playerDeathStates)
	print("[DeathSystem] All death states cleared")
end

function DeathSystem.step(dt: number)
	if respawnTimersDisabled then
		return  -- Don't process respawns during wipe
	end
	
	if not world then return end
	
	local currentTime = tick()
	local toRespawn = {}
	
	-- Check for players ready to respawn
	for playerEntity, deathState in pairs(playerDeathStates) do
		if currentTime >= deathState.respawnTime then
			table.insert(toRespawn, playerEntity)
		end
	end
	
	-- Respawn players
	for _, playerEntity in ipairs(toRespawn) do
		DeathSystem.respawnPlayer(playerEntity)
	end
end

function DeathSystem.respawnPlayer(playerEntity: number)
	print(string.format("[DeathSystem] respawnPlayer START for entity %d", playerEntity))
	
	-- Get player
	local playerStats = world:get(playerEntity, Components.PlayerStats)
	if not playerStats or not playerStats.player then
		warn("[DeathSystem] respawnPlayer FAILED - no playerStats")
		return
	end
	
	local player = playerStats.player
	print(string.format("[DeathSystem] respawnPlayer - player: %s", player.Name))
	
	-- Restore health to full
	local health = world:get(playerEntity, Components.Health)
	if health then
		health.current = health.max
		world:set(playerEntity, Components.Health, health)
		DirtyService.mark(playerEntity, "Health")
		
		-- Update humanoid health
		if player.Character then
			local humanoid = player.Character:FindFirstChild("Humanoid")
			if humanoid then
				humanoid.Health = health.max
			end
		end
	end
	
	-- Un-anchor player body and restore display settings
	if player.Character then
		local humanoidRootPart = player.Character:FindFirstChild("HumanoidRootPart")
		if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
			humanoidRootPart.Anchored = false
		end
		
		-- Restore player name and health display
		local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local originalDisplayType = player:GetAttribute("OriginalDisplayDistanceType")
			local originalHealthType = player:GetAttribute("OriginalHealthDisplayType")
			local originalNameDist = player:GetAttribute("OriginalNameDisplayDistance")
			local originalHealthDist = player:GetAttribute("OriginalHealthDisplayDistance")
			
			-- Restore original settings or use defaults
			if originalDisplayType then
				humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType:FromValue(originalDisplayType)
			else
				humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
			end
			
			if originalHealthType then
				humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType:FromValue(originalHealthType)
			else
				humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.DisplayWhenDamaged
			end
			
			if originalNameDist then
				humanoid.NameDisplayDistance = originalNameDist
			else
				humanoid.NameDisplayDistance = 100
			end
			
			if originalHealthDist then
				humanoid.HealthDisplayDistance = originalHealthDist
			else
				humanoid.HealthDisplayDistance = 100
			end
			
			-- Clean up attributes
			player:SetAttribute("OriginalDisplayDistanceType", nil)
			player:SetAttribute("OriginalHealthDisplayType", nil)
			player:SetAttribute("OriginalNameDisplayDistance", nil)
			player:SetAttribute("OriginalHealthDisplayDistance", nil)
		end
	end
	
	-- Restore original pickup range
	local originalPickupRange = player:GetAttribute("OriginalPickupRange")
	if originalPickupRange then
		player:SetAttribute("PickupRange", originalPickupRange)
		player:SetAttribute("OriginalPickupRange", nil)  -- Clean up
	else
		-- Fallback to balance value
		player:SetAttribute("PickupRange", PlayerBalance.BasePickupRange)
	end
	
	-- Teleport to spawn
	if player.Character and player.Character.PrimaryPart then
		local spawnLocation = workspace:FindFirstChild("SpawnLocation")
		if spawnLocation then
			player.Character:SetPrimaryPartCFrame(spawnLocation.CFrame + Vector3.new(0, 5, 0))
		else
			-- Fallback to origin if no spawn location
			player.Character:SetPrimaryPartCFrame(CFrame.new(0, 10, 0))
		end
	end
	
	-- Unpause
	if PauseSystem then
		PauseSystem.unpausePlayer(playerEntity, player)
	end
	
	-- Clear death invincibility (was infinite) before granting spawn protection
	local StatusEffectSystem = require(game.ServerScriptService.ECS.Systems.StatusEffectSystem)
	local statusEffects = world:get(playerEntity, Components.StatusEffects)
	if statusEffects and statusEffects.invincible then
		statusEffects.invincible.endTime = 0  -- Clear infinite invincibility
		DirtyService.setIfChanged(world, playerEntity, Components.StatusEffects, statusEffects, "StatusEffects")
	end
	
	-- Grant spawn invincibility (15 seconds, show in buff GUI, pause-aware, spawn protection)
	StatusEffectSystem.grantInvincibility(playerEntity, PlayerBalance.SpawnInvincibility, true, true, true)
	print(string.format("[DeathSystem] Granted %ds invincibility to respawned player %s", PlayerBalance.SpawnInvincibility, player.Name))
	
	-- Clear death state
	playerDeathStates[playerEntity] = nil
	
	-- Notify client
	local remotes = game.ReplicatedStorage:WaitForChild("RemoteEvents")
	local PlayerRespawned = remotes:FindFirstChild("PlayerRespawned")
	if not PlayerRespawned then
		PlayerRespawned = Instance.new("RemoteEvent")
		PlayerRespawned.Name = "PlayerRespawned"
		PlayerRespawned.Parent = remotes
	end
	PlayerRespawned:FireClient(player)
	
	-- Stop server-side body fade and restore visibility (replicates to all clients)
	local DeathBodyFadeSystem = require(game.ServerScriptService.ECS.Systems.DeathBodyFadeSystem)
	DeathBodyFadeSystem.stopFade(player)
	
	print(string.format("[DeathSystem] respawnPlayer COMPLETE for %s", player.Name))
end

-- Check if a player is currently dead
function DeathSystem.isPlayerDead(playerEntity: number): boolean
	return playerDeathStates[playerEntity] ~= nil
end

return DeathSystem

