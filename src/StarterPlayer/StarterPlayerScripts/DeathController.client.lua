--!strict
-- DeathController - Client-side death screen, spectating, and body fade

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Get RemoteEvents
local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local PlayerDied = remotes:WaitForChild("PlayerDied")
local PlayerRespawned = remotes:WaitForChild("PlayerRespawned")

-- Create spectator remote
local ChangeSpectatorTarget = remotes:FindFirstChild("ChangeSpectatorTarget")
if not ChangeSpectatorTarget then
	ChangeSpectatorTarget = Instance.new("RemoteEvent")
	ChangeSpectatorTarget.Name = "ChangeSpectatorTarget"
	ChangeSpectatorTarget.Parent = remotes
end

-- Get GUI elements
local deathGui = playerGui:WaitForChild("DeathGui")
local deathFrame = deathGui:WaitForChild("DeathFrame")
local spectateLabel = deathFrame:WaitForChild("SpectateLabel")
local deathMessageLabel = deathFrame:WaitForChild("DeathMessageLabel")
local deathTimerLabel = deathFrame:WaitForChild("DeathTimerLabel")
local backwardSpectateButton = deathFrame:WaitForChild("BackwardSpectateButton")
local forwardSpectateButton = deathFrame:WaitForChild("ForwardSpectateButton")

-- Get lighting effects
local deathBlur = Lighting:WaitForChild("DeathBlur")
local deathColorCorrection = Lighting:WaitForChild("DeathColorCorrection")

-- State tracking
local isDead = false
local respawnTime = 0
local deathStartTime = 0
local currentSpectatingName = ""
local timerUpdateConnection: RBXScriptConnection?
-- Body fade is now handled server-side (DeathBodyFadeSystem) for replication to all clients

-- Enable lighting effects (just enable the existing effects configured in Studio)
local function enableLightingEffects()
	if deathBlur then
		deathBlur.Enabled = true
	end
	
	if deathColorCorrection then
		deathColorCorrection.Enabled = true
	end
end

-- Disable lighting effects
local function disableLightingEffects()
	if deathBlur then
		deathBlur.Enabled = false
	end
	
	if deathColorCorrection then
		deathColorCorrection.Enabled = false
	end
end

-- Body fade is now handled server-side (see DeathBodyFadeSystem.lua)
-- This ensures fade is visible to ALL clients, not just the dead player

-- Update spectator camera
local function updateSpectatorCamera()
	-- Find player by name
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer.Name == currentSpectatingName and otherPlayer.Character then
			local camera = workspace.CurrentCamera
			local hrp = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
			if hrp then
				camera.CameraSubject = hrp
				return
			end
		end
	end
	
	-- Fallback: reset to local player
	if player.Character then
		local camera = workspace.CurrentCamera
		local humanoid = player.Character:FindFirstChild("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
end

-- Request spectator target change
local function changeSpectatorTarget(direction: number)
	ChangeSpectatorTarget:FireServer(direction)
end

-- Handle death event
PlayerDied.OnClientEvent:Connect(function(data)
	print("[DeathController] Player died, showing death screen")
	
	isDead = true
	respawnTime = data.respawnTime
	deathStartTime = tick()
	
	-- Show death screen
	deathFrame.Visible = true
	deathMessageLabel.Text = data.deathMessage or "You have fallen..."
	
	-- Disable GameGui to prevent level-up overlay while dead
	local gameGui = playerGui:FindFirstChild("GameGui")
	if gameGui and gameGui:IsA("ScreenGui") then
		gameGui.Enabled = false
	end
	
	-- Enable lighting effects
	enableLightingEffects()
	
	-- Start timer update
	if timerUpdateConnection then
		timerUpdateConnection:Disconnect()
	end
	
	timerUpdateConnection = RunService.RenderStepped:Connect(function()
		if not isDead then
			if timerUpdateConnection then
				timerUpdateConnection:Disconnect()
				timerUpdateConnection = nil
			end
			return
		end
		
		local elapsed = tick() - deathStartTime
		local remaining = math.max(0, respawnTime - elapsed)
		deathTimerLabel.Text = string.format("%d", math.ceil(remaining))
	end)
	
	-- Body fade is handled server-side (DeathBodyFadeSystem) and replicates to all clients
	
	-- Auto-spectate will be set by server via SpectatorTargetChanged event
	-- Request initial target immediately
	changeSpectatorTarget(1)  -- Request forward (to first alive player)
end)

-- Body fade and restore is now handled server-side (DeathBodyFadeSystem)
-- No client-side listeners needed for body transparency

-- Handle respawn event
PlayerRespawned.OnClientEvent:Connect(function()
	print("[DeathController] Player respawned, hiding death screen")
	
	isDead = false
	
	-- Hide death screen
	deathFrame.Visible = false
	
	-- Re-enable GameGui when respawning (only if in-game, not in menu)
	local gameGui = playerGui:FindFirstChild("GameGui")
	if gameGui and gameGui:IsA("ScreenGui") then
		-- Only re-enable if MainHUD is also enabled (indicates we're in-game)
		local mainHUD = playerGui:FindFirstChild("MainHUD")
		if mainHUD and mainHUD:IsA("ScreenGui") and mainHUD.Enabled then
			gameGui.Enabled = true
		end
	end
	
	-- Disable lighting effects
	disableLightingEffects()
	
	-- Disconnect timers
	if timerUpdateConnection then
		timerUpdateConnection:Disconnect()
		timerUpdateConnection = nil
	end
	
	-- Restore camera to local player
	if player.Character then
		local camera = workspace.CurrentCamera
		local humanoid = player.Character:FindFirstChild("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
		
		-- Body visibility is restored server-side by DeathBodyFadeSystem (no client-side needed)
	end
end)

-- Spectator target response
local SpectatorTargetChanged = remotes:FindFirstChild("SpectatorTargetChanged")
if not SpectatorTargetChanged then
	SpectatorTargetChanged = Instance.new("RemoteEvent")
	SpectatorTargetChanged.Name = "SpectatorTargetChanged"
	SpectatorTargetChanged.Parent = remotes
end

SpectatorTargetChanged.OnClientEvent:Connect(function(targetName: string?)
	if targetName then
		currentSpectatingName = targetName
		spectateLabel.Text = "Spectating: " .. targetName
		updateSpectatorCamera()
	else
		spectateLabel.Text = "No players to spectate"
	end
end)

-- Button connections
backwardSpectateButton.Activated:Connect(function()
	if isDead then
		changeSpectatorTarget(-1)
	end
end)

forwardSpectateButton.Activated:Connect(function()
	if isDead then
		changeSpectatorTarget(1)
	end
end)

-- Keyboard shortcuts (Q and E)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not isDead then return end
	
	if input.KeyCode == Enum.KeyCode.Q then
		changeSpectatorTarget(-1)
	elseif input.KeyCode == Enum.KeyCode.E then
		changeSpectatorTarget(1)
	end
end)

-- Ensure lighting effects start disabled
disableLightingEffects()

-- Hide death screen initially
deathFrame.Visible = false


