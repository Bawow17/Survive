--!strict
-- SessionTimerDisplay - Updates MainHUD timer with session time (pause-aware)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local playerScripts = player:FindFirstChild("PlayerScripts")
if not playerScripts then
	playerScripts = player:WaitForChild("PlayerScripts", 10)
end
local scriptsContainer = playerScripts or script:FindFirstAncestor("StarterPlayerScripts")
if not scriptsContainer then
	warn("[SessionTimerDisplay] Could not locate StarterPlayerScripts ancestor")
	return
end
local localSharedFolder = scriptsContainer:WaitForChild("_Shared", 10)
if not localSharedFolder then
	warn("[SessionTimerDisplay] Could not locate _Shared folder")
	return
end
local TimeFormat = require(localSharedFolder:WaitForChild("TimeFormat"))

-- Wait for MainHUD
local mainHUD = playerGui:WaitForChild("MainHUD", 10)
if not mainHUD then
	warn("[SessionTimerDisplay] MainHUD not found")
	return
end

local topBarFrame = mainHUD:FindFirstChild("TopBarFrame")
if not topBarFrame then
	warn("[SessionTimerDisplay] MainHUD.TopBarFrame not found")
	return
end

local rightFrame = topBarFrame:FindFirstChild("RightFrame")
if not rightFrame then
	warn("[SessionTimerDisplay] MainHUD.TopBarFrame.RightFrame not found")
	return
end

local timerFrame = rightFrame:FindFirstChild("TimerFrame")
if not timerFrame then
	warn("[SessionTimerDisplay] MainHUD.TopBarFrame.RightFrame.TimerFrame not found")
	return
end

local timerLabelInstance = timerFrame:FindFirstChild("TimerLabel")
if not timerLabelInstance or not timerLabelInstance:IsA("TextLabel") then
	warn("[SessionTimerDisplay] MainHUD.TopBarFrame.RightFrame.TimerFrame.TimerLabel not found or not TextLabel")
	return
end

local timerShortLabelInstance = timerFrame:FindFirstChild("TimerShortLabel")
if not timerShortLabelInstance or not timerShortLabelInstance:IsA("TextLabel") then
	warn("[SessionTimerDisplay] MainHUD.TopBarFrame.RightFrame.TimerFrame.TimerShortLabel not found or not TextLabel")
	return
end

local timerLabel = timerLabelInstance :: TextLabel
local timerShortLabel = timerShortLabelInstance :: TextLabel

-- Wait for remotes
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local SessionTimerUpdate = remotesFolder:WaitForChild("SessionTimerUpdate") :: RemoteEvent
local GamePaused = remotesFolder:WaitForChild("GamePaused") :: RemoteEvent
local GameUnpaused = remotesFolder:WaitForChild("GameUnpaused") :: RemoteEvent

-- Timer state
local lastServerSessionTime = 0
local lastServerSyncClock = tick()
local frozenDisplayTime = 0
local isPaused = false
local hasServerSessionSync = false

local lastRenderedMain = ""
local lastRenderedShort = ""

-- Format time as MM:SS
local function formatTime(seconds: number): string
	return TimeFormat.formatMMSS(seconds)
end

local function formatCentiseconds(seconds: number): string
	local centiseconds = math.floor((seconds * 100) % 100)
	if centiseconds < 0 then
		centiseconds = 0
	end
	return string.format(":%02d", centiseconds)
end

local function canUpdateTimerText(): boolean
	if mainHUD:IsA("LayerCollector") then
		return mainHUD.Enabled
	end
	if mainHUD:IsA("GuiObject") then
		return mainHUD.Visible
	end
	return true
end

local function computeDisplayTime(now: number): number
	if isPaused then
		return frozenDisplayTime
	end
	if not hasServerSessionSync then
		return frozenDisplayTime
	end
	local elapsedSinceLastSync = math.max(0, now - lastServerSyncClock)
	return math.max(0, lastServerSessionTime + elapsedSinceLastSync)
end

local function renderTimerText(displayTime: number)
	local mainText = formatTime(displayTime)
	if mainText ~= lastRenderedMain then
		timerLabel.Text = mainText
		lastRenderedMain = mainText
	end

	local shortText = formatCentiseconds(displayTime)
	if shortText ~= lastRenderedShort then
		timerShortLabel.Text = shortText
		lastRenderedShort = shortText
	end
end

-- Update timer baseline from server sync
SessionTimerUpdate.OnClientEvent:Connect(function(sessionTime: number)
	if typeof(sessionTime) ~= "number" or sessionTime < 0 then
		return  -- Ignore invalid values
	end

	-- Keep both labels frozen while paused.
	if isPaused then
		return
	end

	local now = tick()
	local currentDisplayTime = computeDisplayTime(now)

	-- Validate: Don't allow timer to jump backwards (prevents flickering)
	-- Allow small decreases (< 1s) due to network timing, but reject large jumps
	if sessionTime < currentDisplayTime - 2 then
		return
	end

	lastServerSessionTime = sessionTime
	lastServerSyncClock = now
	hasServerSessionSync = true
end)

-- Pause timer display during level-ups
GamePaused.OnClientEvent:Connect(function(_data: any)
	local now = tick()
	frozenDisplayTime = computeDisplayTime(now)
	isPaused = true
end)

GameUnpaused.OnClientEvent:Connect(function()
	if not isPaused then
		return
	end
	isPaused = false
	if hasServerSessionSync then
		lastServerSessionTime = frozenDisplayTime
		lastServerSyncClock = tick()
	end
end)

-- Reset timer when cleanup completes (new game session)
local WipeCleanupCompleteRemote = remotesFolder:WaitForChild("WipeCleanupComplete") :: RemoteEvent
WipeCleanupCompleteRemote.OnClientEvent:Connect(function()
	-- Reset timer state for new session
	lastServerSessionTime = 0
	lastServerSyncClock = tick()
	frozenDisplayTime = 0
	isPaused = false
	hasServerSessionSync = false

	renderTimerText(0)
end)

RunService.RenderStepped:Connect(function()
	local displayTime = computeDisplayTime(tick())
	if not canUpdateTimerText() then
		return
	end
	renderTimerText(displayTime)
end)

-- Initialize timer display
renderTimerText(0)
