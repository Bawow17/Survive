--!strict
-- GameSessionTimer - Tracks session time (not server uptime)

local GameSessionTimer = {}

local sessionStartTime = 0
local sessionPaused = false
local pausedTime = 0
local totalPausedDuration = 0

function GameSessionTimer.startSession()
	sessionStartTime = tick()
	sessionPaused = false
	pausedTime = 0
	totalPausedDuration = 0
end

function GameSessionTimer.pauseSession()
	if not sessionPaused then
		sessionPaused = true
		pausedTime = tick()
	end
end

function GameSessionTimer.resumeSession()
	if sessionPaused then
		local pauseDuration = tick() - pausedTime
		totalPausedDuration = totalPausedDuration + pauseDuration
		sessionPaused = false
	end
end

function GameSessionTimer.getSessionTime(): number
	if sessionStartTime == 0 then
		return 0
	end
	
	local currentTime = tick()
	local elapsed = currentTime - sessionStartTime - totalPausedDuration
	
	-- Only account for wipe pauses (pauseSession), NOT level-up pauses
	if sessionPaused then
		elapsed = elapsed - (currentTime - pausedTime)
	end
	
	return math.max(0, elapsed)
end

function GameSessionTimer.resetSession()
	sessionStartTime = 0
	sessionPaused = false
	pausedTime = 0
	totalPausedDuration = 0
end

return GameSessionTimer

