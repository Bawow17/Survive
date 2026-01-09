--!strict
-- SessionStatsTracker - Tracks per-player session statistics for wipe scoreboard

local SessionStatsTracker = {}

-- Session stats per player entity
local sessionStats: {[number]: {
	totalDamage: number,
	kills: number,
	deaths: number,
	joinTime: number,
}} = {}

-- Frozen survive times (captured at wipe detection to prevent time drift)
local frozenSurviveTimes: {[number]: number} = {}

function SessionStatsTracker.init(worldRef, components, dirtyService)
	-- No world/component references needed for simple tracking
end

-- Initialize stats tracking when player joins game
function SessionStatsTracker.onPlayerAdded(playerEntity: number)
	sessionStats[playerEntity] = {
		totalDamage = 0,
		kills = 0,
		deaths = 0,
		joinTime = tick(),
	}
end

-- Remove stats tracking when player leaves game
function SessionStatsTracker.onPlayerRemoved(playerEntity: number)
	sessionStats[playerEntity] = nil
end

-- Track damage dealt by a player
function SessionStatsTracker.trackDamage(playerEntity: number, damageAmount: number)
	if not sessionStats[playerEntity] then
		sessionStats[playerEntity] = {
			totalDamage = 0,
			kills = 0,
			deaths = 0,
			joinTime = tick(),
		}
	end
	
	sessionStats[playerEntity].totalDamage = sessionStats[playerEntity].totalDamage + damageAmount
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
end

return SessionStatsTracker

