--!strict
-- SessionStatsTracker - Tracks per-player session statistics for wipe scoreboard

local SessionStatsTracker = {}

local world: any = nil
local Components: any = nil
local DirtyService: any = nil

-- Session stats per player entity
local sessionStats: {[number]: {
	totalDamage: number,
	kills: number,
	deaths: number,
	joinTime: number,
	perAbility: {[string]: number},
}} = {}

-- Frozen survive times (captured at wipe detection to prevent time drift)
local frozenSurviveTimes: {[number]: number} = {}

local function setSessionStatsComponent(playerEntity: number)
	if not world or not Components or not DirtyService then
		return
	end
	local stats = sessionStats[playerEntity]
	if not stats then
		return
	end
	local perAbilityCopy = {}
	for key, value in pairs(stats.perAbility) do
		perAbilityCopy[key] = value
	end
	DirtyService.setIfChanged(world, playerEntity, Components.SessionStats, {
		totalDamage = stats.totalDamage,
		kills = stats.kills,
		deaths = stats.deaths,
		perAbility = perAbilityCopy,
	}, "SessionStats")
end

function SessionStatsTracker.init(worldRef, components, dirtyService)
	world = worldRef
	Components = components
	DirtyService = dirtyService
end

-- Initialize stats tracking when player joins game
function SessionStatsTracker.onPlayerAdded(playerEntity: number)
	sessionStats[playerEntity] = {
		totalDamage = 0,
		kills = 0,
		deaths = 0,
		joinTime = tick(),
		perAbility = {},
	}
	setSessionStatsComponent(playerEntity)
end

-- Remove stats tracking when player leaves game
function SessionStatsTracker.onPlayerRemoved(playerEntity: number)
	sessionStats[playerEntity] = nil
	if world and Components and DirtyService then
		DirtyService.setIfChanged(world, playerEntity, Components.SessionStats, nil, "SessionStats")
	end
end

-- Track damage dealt by a player
function SessionStatsTracker.trackDamage(playerEntity: number, damageAmount: number, abilityId: string?)
	if not sessionStats[playerEntity] then
		sessionStats[playerEntity] = {
			totalDamage = 0,
			kills = 0,
			deaths = 0,
			joinTime = tick(),
			perAbility = {},
		}
	end
	
	sessionStats[playerEntity].totalDamage = sessionStats[playerEntity].totalDamage + damageAmount
	if abilityId then
		local perAbility = sessionStats[playerEntity].perAbility
		perAbility[abilityId] = (perAbility[abilityId] or 0) + damageAmount
	end
	setSessionStatsComponent(playerEntity)
end

-- Track enemy kill by a player
function SessionStatsTracker.trackKill(playerEntity: number)
	if not sessionStats[playerEntity] then
		sessionStats[playerEntity] = {
			totalDamage = 0,
			kills = 0,
			deaths = 0,
			joinTime = tick(),
		}
	end
	
	sessionStats[playerEntity].kills = sessionStats[playerEntity].kills + 1
	setSessionStatsComponent(playerEntity)
end

-- Track player death
function SessionStatsTracker.trackDeath(playerEntity: number)
	if not sessionStats[playerEntity] then
		sessionStats[playerEntity] = {
			totalDamage = 0,
			kills = 0,
			deaths = 0,
			joinTime = tick(),
		}
	end
	
	sessionStats[playerEntity].deaths = sessionStats[playerEntity].deaths + 1
	setSessionStatsComponent(playerEntity)
end

-- Get stats for a specific player
function SessionStatsTracker.getPlayerStats(playerEntity: number): {totalDamage: number, kills: number, deaths: number, joinTime: number}?
	return sessionStats[playerEntity]
end

-- Get player's individual survive time (from when they joined)
function SessionStatsTracker.getPlayerSurviveTime(playerEntity: number): number
	-- Return frozen time if available (captured at wipe)
	if frozenSurviveTimes[playerEntity] then
		return frozenSurviveTimes[playerEntity]
	end
	
	if sessionStats[playerEntity] then
		return tick() - sessionStats[playerEntity].joinTime
	end
	return 0
end

-- Freeze all player survive times at wipe detection (prevents time drift during wipe sequence)
function SessionStatsTracker.freezeSurviveTimes()
	for playerEntity, stats in pairs(sessionStats) do
		frozenSurviveTimes[playerEntity] = tick() - stats.joinTime
	end
end

-- Get all player stats (for scoreboard)
function SessionStatsTracker.getAllStats(): {[number]: {totalDamage: number, kills: number, deaths: number, joinTime: number}}
	return sessionStats
end

-- Reset all stats (called when starting new game session)
function SessionStatsTracker.reset()
	table.clear(sessionStats)
	table.clear(frozenSurviveTimes)
	-- SessionStats component will be reinitialized on player join
end

return SessionStatsTracker
