--!strict
-- GameSessionTimer - Tracks session time using wall-clock baseline + additive offset.

local GameSessionTimer = {}

local sessionStartClock: number? = nil
local sessionTimeOffset = 0
local sessionPaused = false
local pausedAtClock: number? = nil
local function nowSeconds(): number
	return time()
end

function GameSessionTimer.startSession()
	sessionStartClock = nowSeconds()
	sessionTimeOffset = 0
	sessionPaused = false
	pausedAtClock = nil
end

function GameSessionTimer.pauseSession()
	if sessionPaused then
		return
	end
	local startClock = sessionStartClock
	if not startClock then
		return
	end
	sessionPaused = true
	pausedAtClock = nowSeconds()
end

function GameSessionTimer.resumeSession()
	if not sessionPaused then
		return
	end
	local startClock = sessionStartClock
	local pausedAt = pausedAtClock
	if startClock and pausedAt then
		-- Shift baseline forward by pause duration so elapsed time remains frozen while paused.
		sessionStartClock = startClock + (nowSeconds() - pausedAt)
	end
	sessionPaused = false
	pausedAtClock = nil
end

function GameSessionTimer.getSessionTime(): number
	local startClock = sessionStartClock
	if not startClock then
		return 0
	end

	local nowClock = nowSeconds()
	if sessionPaused and pausedAtClock then
		nowClock = pausedAtClock
	end
	local elapsed = (nowClock - startClock) + sessionTimeOffset
	return math.max(0, elapsed)
end

function GameSessionTimer.addTime(seconds: number)
	if typeof(seconds) ~= "number" or seconds <= 0 then
		return
	end
	if not sessionStartClock then
		sessionStartClock = nowSeconds()
	end
	sessionTimeOffset += seconds
end

function GameSessionTimer.resetSession()
	sessionStartClock = nil
	sessionTimeOffset = 0
	sessionPaused = false
	pausedAtClock = nil
end

return GameSessionTimer
