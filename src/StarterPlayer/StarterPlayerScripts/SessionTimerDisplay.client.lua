--!strict
-- SessionTimerDisplay - Updates MainHUD timer with session time (pause-aware)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Wait for MainHUD
local mainHUD = playerGui:WaitForChild("MainHUD", 10)
if not mainHUD then return end

local topBarFrame = mainHUD:FindFirstChild("TopBarFrame")
if not topBarFrame then return end

local timerLabel = topBarFrame:FindFirstChild("TimerLabel") :: TextLabel
if not timerLabel then return end

-- Wait for remotes
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local SessionTimerUpdate = remotesFolder:WaitForChild("SessionTimerUpdate") :: RemoteEvent
local GamePaused = remotesFolder:WaitForChild("GamePaused") :: RemoteEvent
local GameUnpaused = remotesFolder:WaitForChild("GameUnpaused") :: RemoteEvent

-- Timer state
local currentSessionTime = 0
local isPaused = false
local pauseStartTime = 0

-- Format time as MM:SS
local function formatTime(seconds: number): string
	local minutes = math.floor(seconds / 60)
	local secs = math.floor(seconds % 60)
	return string.format("%02d:%02d", minutes, secs)
end

-- Update timer display
SessionTimerUpdate.OnClientEvent:Connect(function(sessionTime: number)
	if typeof(sessionTime) ~= "number" or sessionTime < 0 then
		return  -- Ignore invalid values
	end
	
	-- Don't update if MainHUD is disabled (player is in menu)
	if not mainHUD.Enabled then
		return
	end
	
	-- Don't update if paused (keeps timer frozen during level-up)
	if isPaused then
		return
	end
	
	-- Validate: Don't allow timer to jump backwards (prevents flickering)
	-- Allow small decreases (< 1s) due to network timing, but reject large jumps
	if sessionTime < currentSessionTime - 2 then
		return
	end
	
	currentSessionTime = sessionTime
	timerLabel.Text = formatTime(sessionTime)
end)

-- Pause timer display during level-ups
GamePaused.OnClientEvent:Connect(function(data: any)
	isPaused = true
	pauseStartTime = tick()
	-- Timer stays frozen at current value
end)

GameUnpaused.OnClientEvent:Connect(function()
	isPaused = false
	-- Timer resumes updating
end)

-- Reset timer when cleanup completes (new game session)
local WipeCleanupCompleteRemote = remotesFolder:WaitForChild("WipeCleanupComplete") :: RemoteEvent
WipeCleanupCompleteRemote.OnClientEvent:Connect(function()
	-- Reset timer state for new session
	currentSessionTime = 0
	isPaused = false
	timerLabel.Text = formatTime(0)
end)

-- Initialize timer display to 00:00
timerLabel.Text = formatTime(0)
