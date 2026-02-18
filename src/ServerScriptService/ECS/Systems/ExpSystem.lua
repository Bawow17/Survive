--!strict
-- ExpSystem - Manages player experience, leveling, and chunked exp gain

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemBalance = require(game.ServerScriptService.Balance.ItemBalance)
local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local StatusEffectSystem = require(game.ServerScriptService.ECS.Systems.StatusEffectSystem)
local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)

local ProfilingConfig = require(ReplicatedStorage.Shared.ProfilingConfig)
local Prof = ProfilingConfig.ENABLED and require(ReplicatedStorage.Shared.ProfilingServer) or require(ReplicatedStorage.Shared.ProfilingStub)
local PROFILING_ENABLED = ProfilingConfig.ENABLED

local function profGauge(name: string, value: number)
	if PROFILING_ENABLED then
		Prof.gauge(name, value)
	end
end

local ExpSystem = {}

local world: any
local Components: any
local DirtyService: any
local BankedHandsService: any

local Experience: any
local Level: any
local ExpChunks: any
local PlayerStats: any

-- Remote for broadcasting player stats to clients
local PlayerStatsUpdate: RemoteEvent?
local DebugGrantLevels: RemoteEvent?

-- Cached query for exp chunks processing
local expChunksQuery: any
local levelHistory: {[number]: {times: {number}}} = {}

local LEVEL_WINDOW_SECONDS = 120
local MAX_SAFE_EXP_REQUIRED = 2000000000

local function recordLevelTime(playerEntity: number, playerName: string?)
	if not playerName then
		return
	end
	local now = GameTimeSystem.getGameTime()
	local history = levelHistory[playerEntity]
	if not history then
		history = {times = {}}
	end
	table.insert(history.times, now)

	-- Prune to rolling window
	local cutoff = now - LEVEL_WINDOW_SECONDS
	while #history.times > 0 and history.times[1] < cutoff do
		table.remove(history.times, 1)
	end

	levelHistory[playerEntity] = history

	if #history.times >= 2 then
		local duration = history.times[#history.times] - history.times[1]
		local levelsGained = #history.times - 1
		if duration > 0 and levelsGained > 0 then
			local avgSeconds = duration / levelsGained
			profGauge("Exp.SecondsPerLevel." .. playerName, math.floor(avgSeconds * 1000 + 0.5))
		end
	end
end

function ExpSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	Experience = Components.Experience
	Level = Components.Level
	ExpChunks = Components.ExpChunks
	PlayerStats = Components.PlayerStats
	
	-- Create cached query
	expChunksQuery = world:query(Components.ExpChunks):cached()
	
	-- Get or create PlayerStatsUpdate remote
	local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
	local existingRemote = remotes:FindFirstChild("PlayerStatsUpdate")
	if existingRemote and existingRemote:IsA("RemoteEvent") then
		PlayerStatsUpdate = existingRemote
	else
		local newRemote = Instance.new("RemoteEvent")
		newRemote.Name = "PlayerStatsUpdate"
		newRemote.Parent = remotes
		PlayerStatsUpdate = newRemote
	end
	
	-- Debug-only repro helper: grant multiple levels quickly
	if GameOptions.Debug and GameOptions.Debug.Enabled then
		DebugGrantLevels = remotes:FindFirstChild("DebugGrantLevels") :: RemoteEvent
		if not DebugGrantLevels then
			DebugGrantLevels = Instance.new("RemoteEvent")
			DebugGrantLevels.Name = "DebugGrantLevels"
			DebugGrantLevels.Parent = remotes
		end
		
		DebugGrantLevels.OnServerEvent:Connect(function(player: Player, data: any)
			local levels = (data and data.levels) or 10
			if typeof(levels) ~= "number" then
				levels = 10
			end
			levels = math.clamp(math.floor(levels), 1, 20)
			
			local playerEntity: number? = nil
			for entity, stats in world:query(Components.PlayerStats) do
				if stats.player == player then
					playerEntity = entity
					break
				end
			end
			
			if playerEntity then
				ExpSystem.debugGrantLevels(playerEntity, levels)
			end
		end)
	end
end

function ExpSystem.setBankedHandsService(service: any)
	BankedHandsService = service
end

local function getRoR2CurveConfig(): (number, number)
	local cfg = ItemBalance.RoR2Exp or {}
	local base = typeof(cfg.BaseLevelExp) == "number" and cfg.BaseLevelExp or 20
	local growth = typeof(cfg.LevelGrowth) == "number" and cfg.LevelGrowth or 1.55
	base = math.max(1, base)
	growth = math.max(1.0001, growth)
	return base, growth
end

-- Calculate exp required for a level (RoR2-style geometric progression)
local function calculateExpRequired(level: number): number
	local normalizedLevel = math.max(1, math.floor(level))
	local base, growth = getRoR2CurveConfig()
	local raw = base * (growth ^ (normalizedLevel - 1))
	if typeof(raw) ~= "number" or raw ~= raw or raw == math.huge or raw == -math.huge then
		return MAX_SAFE_EXP_REQUIRED
	end
	raw = math.clamp(raw, 1, MAX_SAFE_EXP_REQUIRED)
	return math.floor(raw)
end

function ExpSystem.getExpRequired(level: number): number
	return calculateExpRequired(level)
end

-- Get highest player level in server (for catch-up system)
local function getHighestPlayerLevel(): number
	if not world or not Components then
		return 1
	end
	
	local highestLevel = 1
	for playerEntity, level, playerStats in world:query(Components.Level, Components.PlayerStats) do
		if playerStats and playerStats.player and playerStats.player.Parent then
			highestLevel = math.max(highestLevel, level.current or 1)
		end
	end
	
	return highestLevel
end

-- Check and activate catch-up boost (one-time only per server)
local function checkAndActivateCatchUp(playerEntity: number, player: Player, currentLevel: number)
	local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
	if GameOptions.GlobalPause then
		return  -- Only for multiplayer mode (individual pause)
	end
	
	-- Check if boost already used (one-time only per server)
	if player:GetAttribute("CatchUpUsed") then
		return  -- Already used this session
	end
	
	-- Get highest player level
	local highestLevel = getHighestPlayerLevel()
	if highestLevel <= 1 or highestLevel <= currentLevel then
		return  -- No higher-level players
	end
	
	-- Check if below activation threshold
	local levelRatio = currentLevel / highestLevel
	if levelRatio >= PlayerBalance.ExpCatchUp.ActivationThreshold then
		return  -- Above 60% of highest, no boost needed
	end
	
	-- ACTIVATE CATCH-UP BOOST (one-time only)
	print(string.format("[ExpSystem] Activating catch-up for %s (L%d vs L%d highest)", 
		player.Name, currentLevel, highestLevel))
	
	-- Calculate boost multiplier: 2.0 + (3.0 * ((highestLevel - playerLevel) / highestLevel))
	local levelGap = highestLevel - currentLevel
	local gapRatio = levelGap / highestLevel
	local boostMultiplier = PlayerBalance.ExpCatchUp.BaseMultiplier + 
	                       (PlayerBalance.ExpCatchUp.ScalingFactor * gapRatio)
	
	-- Calculate deactivation level (10% of activation level, minimum +1)
	local levelIncrease = math.ceil(currentLevel * PlayerBalance.ExpCatchUp.DeactivationPercent)
	local deactivationLevel = currentLevel + math.max(1, levelIncrease)
	
	-- Store boost data (server-authoritative, anti-cheat)
	player:SetAttribute("CatchUpUsed", true)  -- Permanent flag
	player:SetAttribute("CatchUpActive", true)  -- Currently active
	player:SetAttribute("CatchUpMultiplier", boostMultiplier)
	player:SetAttribute("CatchUpDeactivationLevel", deactivationLevel)
	player:SetAttribute("CatchUpActivationLevel", currentLevel)
	player:SetAttribute("CatchUpHighestLevelSnapshot", highestLevel)
	
	print(string.format("[ExpSystem] Boost: %.2fx EXP until L%d (gap: %d levels)", 
		boostMultiplier, deactivationLevel, levelGap))
end

-- Check and deactivate catch-up boost when target level reached
local function checkAndDeactivateCatchUp(playerEntity: number, player: Player, currentLevel: number)
	if not player:GetAttribute("CatchUpActive") then
		return  -- Not currently active
	end
	
	local deactivationLevel = player:GetAttribute("CatchUpDeactivationLevel")
	if not deactivationLevel then
		return  -- No deactivation level set
	end
	
	-- Check if reached deactivation level
	if currentLevel >= deactivationLevel then
		local activationLevel = player:GetAttribute("CatchUpActivationLevel") or 0
		print(string.format("[ExpSystem] Deactivating catch-up for %s (L%d → L%d, gained %d levels)", 
			player.Name, activationLevel, currentLevel, currentLevel - activationLevel))
		
		-- Deactivate boost (keep CatchUpUsed = true permanently)
		player:SetAttribute("CatchUpActive", false)
		player:SetAttribute("CatchUpMultiplier", nil)
		player:SetAttribute("CatchUpDeactivationLevel", nil)
		player:SetAttribute("CatchUpActivationLevel", nil)
		player:SetAttribute("CatchUpHighestLevelSnapshot", nil)
	end
end

-- Handle level up event
local function onLevelUp(playerEntity: number, newLevel: number, oldLevel: number)
	if BankedHandsService and BankedHandsService.enqueueHand then
		BankedHandsService.enqueueHand(playerEntity, oldLevel, newLevel)
	end
	-- Grant level-up buffs immediately (no level-up pause anymore)
	StatusEffectSystem.grantInvincibility(playerEntity, 2.0, true, false, false)
	StatusEffectSystem.grantSpeedBoost(playerEntity, 2.0, 1.15, "levelUp")
end

-- Apply exp directly to player (handles level ups)
local function applyExpDirect(playerEntity: number, amount: number)
	local exp = world:get(playerEntity, Experience)
	local level = world:get(playerEntity, Level)
	local playerStats = world:get(playerEntity, PlayerStats)
	
	if not exp or not level then
		warn("[ExpSystem] Player", playerEntity, "missing Experience or Level component")
		return
	end
	
	-- Apply catch-up multiplier if active (server-authoritative)
	local finalAmount = amount
	if playerStats and playerStats.player then
		local player = playerStats.player
		
		-- Check for catch-up activation (only if not already used)
		checkAndActivateCatchUp(playerEntity, player, level.current)
		
		-- Apply active catch-up multiplier
		if player:GetAttribute("CatchUpActive") then
			local multiplier = player:GetAttribute("CatchUpMultiplier") or 1.0
			finalAmount = amount * multiplier
		end
	end
	
	exp.current = exp.current + finalAmount
	exp.total = exp.total + finalAmount
	
	-- Collect all level ups for hand generation
	local levelUps = {}
	while exp.current >= exp.required and level.current < ItemBalance.MaxLevel do
		exp.current = exp.current - exp.required
		local oldLevel = level.current
		level.current = level.current + 1
		
		-- Calculate new exp required (scaling)
		exp.required = calculateExpRequired(level.current)
		
		-- Queue this level up
		table.insert(levelUps, {from = oldLevel, to = level.current})
		
		-- Update GameStateManager tracking table
		if playerStats and playerStats.player then
			local GameStateManager = require(game.ServerScriptService.ECS.Systems.GameStateManager)
			GameStateManager.updatePlayerLevel(playerStats.player, level.current)
		end
	end
	
	-- Generate banked hands for all level ups
	for _, levelUp in ipairs(levelUps) do
		onLevelUp(playerEntity, levelUp.to, levelUp.from)
		if playerStats and playerStats.player then
			recordLevelTime(playerEntity, playerStats.player.Name)
		end
	end
	
	-- Cap exp if at max level
	if level.current >= ItemBalance.MaxLevel then
		exp.current = math.min(exp.current, exp.required)
	end
	
	DirtyService.setIfChanged(world, playerEntity, Experience, exp, "Experience")
	DirtyService.setIfChanged(world, playerEntity, Level, level, "Level")
	
	-- Check for catch-up deactivation after leveling
	if playerStats and playerStats.player then
		checkAndDeactivateCatchUp(playerEntity, playerStats.player, level.current)
	end
	
	-- Broadcast to client immediately (dedicated remote for player stats)
	if playerStats and playerStats.player and PlayerStatsUpdate then
		PlayerStatsUpdate:FireClient(playerStats.player, {
			xp = exp.current,
			xpForNext = exp.required,
			level = level.current,
			totalExp = exp.total,
		})
	end
end

-- Debug-only: Grant a fixed number of levels instantly (bypasses chunking)
function ExpSystem.debugGrantLevels(playerEntity: number, levels: number)
	if not world or not Experience or not Level then
		return
	end
	
	local exp = world:get(playerEntity, Experience)
	local level = world:get(playerEntity, Level)
	if not exp or not level then
		return
	end
	
	local maxGrant = math.max(0, ItemBalance.MaxLevel - level.current)
	local grantCount = math.clamp(math.floor(levels), 1, maxGrant)
	if grantCount <= 0 then
		return
	end
	
	local totalExp = 0
	local currentLevel = level.current
	local currentExp = exp.current
	
	for i = 1, grantCount do
		local required = calculateExpRequired(currentLevel)
		if i == 1 then
			totalExp += math.max(0, required - currentExp)
		else
			totalExp += required
		end
		currentLevel += 1
	end
	
	applyExpDirect(playerEntity, totalExp)
	
	if GameOptions.Debug and GameOptions.Debug.Enabled then
		local playerStats = world:get(playerEntity, PlayerStats)
		local playerName = playerStats and playerStats.player and playerStats.player.Name or tostring(playerEntity)
		print(string.format("[ExpSystem] DebugGrantLevels: player=%s levels=%d", playerName, grantCount))
	end
end

-- PUBLIC API: Add experience to a player
function ExpSystem.addExperience(playerEntity: number, amount: number)
	if not world then
		warn("[ExpSystem] World not initialized")
		return
	end
	
	-- If amount is large enough and chunking is enabled, split into chunks
	if amount >= ItemBalance.ChunkThreshold and ItemBalance.EnableChunking then
		local experience = world:get(playerEntity, Experience)
		local level = world:get(playerEntity, Level)
		
		if not experience or not level then
			applyExpDirect(playerEntity, amount)
			return
		end
		
		local expChunks = world:get(playerEntity, ExpChunks)
		if not expChunks then
			expChunks = {queue = {}, nextChunkTime = tick(), pendingExp = 0}
			world:set(playerEntity, ExpChunks, expChunks)
		end
		
		-- Add to pending exp pool
		expChunks.pendingExp = (expChunks.pendingExp or 0) + amount
		
		-- Calculate TOTAL exp required for the entire current level
		-- This gives consistent chunk sizes throughout each level
		local expForNext = calculateExpRequired(level.current)
		
		-- Chunk the TOTAL exp required for the level, not just remaining
		-- This ensures consistent chunk sizes per level
		local chunkSize = math.max(1, math.floor(expForNext / ItemBalance.ChunkCount))
		
		-- Fill queue with chunks from pending exp
		while expChunks.pendingExp > 0 and #expChunks.queue < ItemBalance.ChunkCount do
			local thisChunk = math.min(chunkSize, expChunks.pendingExp)
			table.insert(expChunks.queue, {
				amount = thisChunk,
				timeAdded = tick()
			})
			expChunks.pendingExp = expChunks.pendingExp - thisChunk
		end
		
		world:set(playerEntity, ExpChunks, expChunks)
		DirtyService.mark(playerEntity, "ExpChunks")
	else
		-- Apply immediately for small amounts
		applyExpDirect(playerEntity, amount)
	end
end

-- PUBLIC API: Process next queued level up (returns true if more levels queued, false if complete)
function ExpSystem.processNextQueuedLevel(playerEntity: number): boolean
	local pendingLevels = world:get(playerEntity, Components.PendingLevelUps)
	if not pendingLevels or not pendingLevels.levels then
		return false  -- No queue
	end
	
	-- Move to next level in queue
	pendingLevels.currentIndex = pendingLevels.currentIndex + 1
	
	if pendingLevels.currentIndex <= #pendingLevels.levels then
		-- More levels to process
		local nextLevel = pendingLevels.levels[pendingLevels.currentIndex]
		world:set(playerEntity, Components.PendingLevelUps, pendingLevels)
		DirtyService.mark(playerEntity, "PendingLevelUps")
		
		-- Trigger next level up (will pause again)
		-- Pass true as isQueuedLevel to use atomic pause state update
		onLevelUp(playerEntity, nextLevel.to, nextLevel.from, true)
		return true  -- More levels queued
	else
		-- Queue complete, remove component
		world:remove(playerEntity, Components.PendingLevelUps)
		return false  -- No more levels
	end
end

-- PUBLIC API: Skip current level (demote and refund 40% exp)
-- refundBaseExp: optional exp value to base the 40% refund on (e.g., skipped hand level)
function ExpSystem.skipLevel(playerEntity: number, refundBaseExp: number?)
	if not world then
		warn("[ExpSystem] World not initialized")
		return
	end
	
	local exp = world:get(playerEntity, Experience)
	local level = world:get(playerEntity, Level)
	
	if not exp or not level then
		warn("[ExpSystem] Player", playerEntity, "missing Experience or Level component")
		return
	end
	
	-- Can't skip below level 1
	if level.current <= 1 then
		warn("[ExpSystem] Cannot skip level 1")
		return
	end
	
	-- Keep any pending exp chunks (don't discard, player keeps queued exp)
	-- The player keeps their current exp progress and chunked exp
	
	-- Demote to previous level
	level.current = level.current - 1
	
	-- Calculate exp requirement for the NEW (lower) level
	exp.required = calculateExpRequired(level.current)
	
	-- ADD 40% refund to current exp (don't reset, just add it back)
	-- This way player keeps any chunked/overflow exp and gets the 40% refund
	local refundBase = refundBaseExp or exp.required
	exp.current = exp.current + math.floor(refundBase * 0.4)
	
	-- Update components
	DirtyService.setIfChanged(world, playerEntity, Experience, exp, "Experience")
	DirtyService.setIfChanged(world, playerEntity, Level, level, "Level")
	
	-- Broadcast to client immediately
	local playerStats = world:get(playerEntity, PlayerStats)
	if playerStats and playerStats.player and PlayerStatsUpdate then
		PlayerStatsUpdate:FireClient(playerStats.player, {
			xp = exp.current,
			xpForNext = exp.required,
			level = level.current,
			totalExp = exp.total,
		})
	end
end

function ExpSystem.step(dt: number)
	if not world then
		return
	end
	
	-- Process exp chunks for all players
	for entity, expChunks in expChunksQuery do
		if not expChunks or not expChunks.queue then
			continue
		end
		
		-- Check if it's time to apply the next chunk
		if tick() >= expChunks.nextChunkTime and #expChunks.queue > 0 then
			local chunk = table.remove(expChunks.queue, 1)
			if chunk then
				applyExpDirect(entity, chunk.amount)
				expChunks.nextChunkTime = tick() + ItemBalance.ChunkInterval
				
				-- If queue is empty but we have pending exp, refill the queue
				-- This handles multiple level-ups from a single large exp gain
				if #expChunks.queue == 0 and expChunks.pendingExp and expChunks.pendingExp > 0 then
					local experience = world:get(entity, Experience)
					local level = world:get(entity, Level)
					
					if experience and level then
						-- Calculate TOTAL exp required for the entire new level
						local expForNext = calculateExpRequired(level.current)
						
						-- Chunk the TOTAL exp required for this level
						local chunkSize = math.max(1, math.floor(expForNext / ItemBalance.ChunkCount))
						
						-- Fill queue with new chunks for the next level
						while expChunks.pendingExp > 0 and #expChunks.queue < ItemBalance.ChunkCount do
							local thisChunk = math.min(chunkSize, expChunks.pendingExp)
							table.insert(expChunks.queue, {
								amount = thisChunk,
								timeAdded = tick()
							})
							expChunks.pendingExp = expChunks.pendingExp - thisChunk
						end
					end
				end
				
				world:set(entity, ExpChunks, expChunks)
				DirtyService.mark(entity, "ExpChunks")
			end
		end
	end
end

-- Debug: Print progression curve preview
function ExpSystem.printProgressionCurve()
	local base, growth = getRoR2CurveConfig()
	print("=== PROGRESSION CURVE PREVIEW ===")
	print(string.format("RoR2 curve: %.2f * %.4f^(level-1)", base, growth))
	print("\nSample EXP Requirements:")
	for _, level in ipairs({1, 2, 5, 10, 20, 30, 40, 50, 75, 100}) do
		print(string.format("  Level %d: %d exp", level, calculateExpRequired(level)))
	end
end

return ExpSystem
