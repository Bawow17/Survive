--!strict
-- GameTimeSystem - Tracks pause-aware game session time
-- Game time only increments when the game is not paused

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PauseSystem = require(script.Parent.PauseSystem)

local GameTimeSystem = {}

-- Game session time (pause-aware)
local gameTime = 0

-- Remote for syncing time to clients
local GameTimeUpdate: RemoteEvent

function GameTimeSystem.init()
	gameTime = 0
	
	-- Get or create GameTimeUpdate remote
	local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
	GameTimeUpdate = remotes:FindFirstChild("GameTimeUpdate")
	if not GameTimeUpdate then
		GameTimeUpdate = Instance.new("RemoteEvent")
		GameTimeUpdate.Name = "GameTimeUpdate"
		GameTimeUpdate.Parent = remotes
	end
end

-- Broadcast interval (don't spam clients every frame)
local broadcastAccumulator = 0
local BROADCAST_INTERVAL = 1.0  -- Sync to clients every 1 second

-- Step the game time (only when not paused)
-- Called from Bootstrap AFTER pause check
function GameTimeSystem.step(dt: number)
	-- Only increment if game is not paused
	if not PauseSystem.isPaused() then
		gameTime = gameTime + dt
	end
	
	-- Periodically broadcast to clients
	broadcastAccumulator = broadcastAccumulator + dt
	if broadcastAccumulator >= BROADCAST_INTERVAL and GameTimeUpdate then
		broadcastAccumulator = 0
		GameTimeUpdate:FireAllClients(gameTime)
	end
end

-- Get current game time (pause-aware)
function GameTimeSystem.getGameTime(): number
	return gameTime
end

-- Reset game time (for testing or game restart)
function GameTimeSystem.reset()
	gameTime = 0
	isPaused = false
	pauseStartTime = 0
	totalPausedTime = 0
	print("[GameTimeSystem] Fully reset to 0")
end

return GameTimeSystem

