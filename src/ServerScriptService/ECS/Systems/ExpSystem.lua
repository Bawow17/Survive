--!strict
-- ExpSystem - Manages player experience, leveling, and chunked exp gain

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemBalance = require(game.ServerScriptService.Balance.ItemBalance)
local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local PauseSystem = require(game.ServerScriptService.ECS.Systems.PauseSystem)
local UpgradeSystem = require(game.ServerScriptService.ECS.Systems.UpgradeSystem)
local StatusEffectSystem = require(game.ServerScriptService.ECS.Systems.StatusEffectSystem)
local UpgradeCounter = require(game.ServerScriptService.Balance.UpgradeCounter)

local ExpSystem = {}

local world: any
local Components: any
local DirtyService: any

local Experience: any
local Level: any
local ExpChunks: any
local PlayerStats: any

-- Remote for broadcasting player stats to clients
local PlayerStatsUpdate: RemoteEvent?
local DebugGrantLevels: RemoteEvent?

-- Cached query for exp chunks processing
local expChunksQuery: any

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

-- Cache phase breakpoints
local phase1End, phase2End, phase3End = UpgradeCounter.getPhaseBreakpoints()

-- Calculate exp required for a level (dynamic three-phase system)
local function calculateExpRequired(level: number): number
	local phases = ItemBalance.ProgressionPhases
	
	-- Phase 1: Linear progression (fast leveling)
	if level <= phase1End then
		return math.floor(
			ItemBalance.BaseExpRequired + (level - 1) * phases.Phase1.expPerLevel
		)
	end
	
	-- Phase 2: Gentle exponential (medium grind)
	if level <= phase2End then
		local phase2StartLevel = phase1End + 1
		local phase2Index = level - phase2StartLevel
		local phase1EndExp = ItemBalance.BaseExpRequired + (phase1End - 1) * phases.Phase1.expPerLevel
		
		return math.floor(
			phase1EndExp * (phases.Phase2.scaling ^ phase2Index)
		)
	end
	
	-- Phase 3: Quadratic (steep grind)
	local phase3StartLevel = phase2End + 1
	local phase3Index = level - phase3StartLevel
	local phase2LastLevel = phase2End - phase1End
	local phase2EndExp = (ItemBalance.BaseExpRequired + (phase1End - 1) * phases.Phase1.expPerLevel) 
						* (phases.Phase2.scaling ^ phase2LastLevel)
	
	return math.floor(
		phase2EndExp * (phases.Phase3.baseMultiplier ^ phase3Index) * (1 + phase3Index * 0.1)
	)
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
local function onLevelUp(playerEntity: number, newLevel: number, oldLevel: number, isQueuedLevel: boolean?)
	-- Get player for pause trigger
	local playerStats = world:get(playerEntity, PlayerStats)
	if playerStats and playerStats.player then
		local player = playerStats.player
		
		-- Select upgrade choices (5 options with weighted selection)
		local upgradeChoices = UpgradeSystem.selectUpgradeChoices(playerEntity, newLevel, 5)
		
		-- If no upgrades available (all maxed and not a heal level), skip pause but still grant buffs
		if #upgradeChoices == 0 then
			StatusEffectSystem.grantInvincibility(playerEntity, 2.0, true, false, false)  -- Levelup invincibility (not spawn protection)
			-- Speed boost removed - Bootstrap handles this in unpause callback
			return
		end
		
		-- NOTE: Buffs are granted AFTER unpause (in the unpause callback in Bootstrap)
		-- to ensure the full 2-second duration is available after the pause ends
		
		-- For queued levels, PauseSystem.pause() updates existing pause state and increments pause token
		-- First level-up or not queued: PauseSystem.pause() creates new pause state normally
		PauseSystem.pause("levelup", player, oldLevel, newLevel, upgradeChoices)
	end
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
	
	-- Collect all level ups into a queue
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
	
	-- If we have level ups, either start queue or add to existing queue
	if #levelUps > 0 then
		local pendingLevels = world:get(playerEntity, Components.PendingLevelUps)
		if not pendingLevels then
			-- No queue exists, create and trigger first level
			world:set(playerEntity, Components.PendingLevelUps, {
				levels = levelUps,
				currentIndex = 1,
			})
			DirtyService.mark(playerEntity, "PendingLevelUps")
			
			-- Trigger first level up
			onLevelUp(playerEntity, levelUps[1].to, levelUps[1].from)
		else
			-- Queue exists, add to it (will be processed when current unpause finishes)
			for _, levelUp in ipairs(levelUps) do
				table.insert(pendingLevels.levels, levelUp)
			end
			world:set(playerEntity, Components.PendingLevelUps, pendingLevels)
			DirtyService.mark(playerEntity, "PendingLevelUps")
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
function ExpSystem.skipLevel(playerEntity: number)
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
	exp.current = exp.current + math.floor(exp.required * 0.4)
	
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
	local phase1, phase2, phase3 = UpgradeCounter.getPhaseBreakpoints()
	
	print("=== PROGRESSION CURVE PREVIEW ===")
	print(string.format("Total Upgrades: %d", UpgradeCounter.getTotalUpgrades()))
	print(string.format("Phase 1 (Fast Linear): Levels 1-%d", phase1))
	print(string.format("Phase 2 (Medium Exp): Levels %d-%d", phase1+1, phase2))
	print(string.format("Phase 3 (Grindy Quad): Levels %d+", phase2+1))
	print("\nSample EXP Requirements:")
	
	for _, level in ipairs({1, 5, 10, phase1, phase1+5, phase2, phase2+5, phase3, phase3+10}) do
		print(string.format("  Level %d: %d exp", level, calculateExpRequired(level)))
	end
end

return ExpSystem
