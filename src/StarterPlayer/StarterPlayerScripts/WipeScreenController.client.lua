--!strict
-- WipeScreenController - Handles team wipe screen display, camera transitions, and cleanup coordination

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

-- Wait for remotes
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local TeamWipeRemote = remotesFolder:WaitForChild("TeamWipe") :: RemoteEvent
local StartCleanupRemote: RemoteEvent
local WipeCleanupCompleteRemote: RemoteEvent
local ClearScoreboardRemote: RemoteEvent

-- Create StartCleanup remote if it doesn't exist
if not remotesFolder:FindFirstChild("StartCleanup") then
	StartCleanupRemote = Instance.new("RemoteEvent")
	StartCleanupRemote.Name = "StartCleanup"
	StartCleanupRemote.Parent = remotesFolder
else
	StartCleanupRemote = remotesFolder:FindFirstChild("StartCleanup") :: RemoteEvent
end

WipeCleanupCompleteRemote = remotesFolder:WaitForChild("WipeCleanupComplete") :: RemoteEvent

-- Create or get ClearScoreboard remote
if not remotesFolder:FindFirstChild("ClearScoreboard") then
	ClearScoreboardRemote = Instance.new("RemoteEvent")
	ClearScoreboardRemote.Name = "ClearScoreboard"
	ClearScoreboardRemote.Parent = remotesFolder
else
	ClearScoreboardRemote = remotesFolder:FindFirstChild("ClearScoreboard") :: RemoteEvent
end

-- Wait for GUIs
local wipeGui = playerGui:WaitForChild("WipeGui", 10)
if not wipeGui then
	warn("[WipeScreen] WipeGui not found!")
	return
end

local deathGui = playerGui:WaitForChild("DeathGui", 10)
local deathTimerLabel: TextLabel? = nil
if deathGui then
	local deathFrame = deathGui:FindFirstChild("DeathFrame")
	if deathFrame then
		deathTimerLabel = deathFrame:FindFirstChild("DeathTimerLabel") :: TextLabel
	end
end

local gameOverFrame = wipeGui:WaitForChild("GameOverFrame")
local restartTimerLabel = gameOverFrame:WaitForChild("RestartTimerLabel") :: TextLabel
local scoreFrame = gameOverFrame:WaitForChild("ScoreFrame")
local examplePlayerLabel = scoreFrame:WaitForChild("ExamplePlayerLabel")
examplePlayerLabel.Visible = false -- Template

-- Color correction
local wipeColorCorrection = Lighting:WaitForChild("WipeColorCorrection") :: ColorCorrectionEffect

-- Wipe camera position
local WIPE_CAMERA_CFRAME = CFrame.new(
	400.26059, 1322.35461, 465.605652,
	0.43969655, -0.676128745, 0.591199458,
	-1.4901163e-08, 0.658244014, 0.752804637,
	-0.898146391, -0.331005603, 0.289427578
)

-- Menu camera position (from MenuCameraController)
local MENU_CAMERA_CFRAME = CFrame.new(
	277.621613, 1007.9491, 413.664886,
	0.571366251, -0.489189893, 0.658964276,
	-0, 0.80293417, 0.596067727,
	-0.820695162, -0.340572983, 0.4587695
)

-- Format time as MM:SS
local function formatTime(seconds: number): string
	local minutes = math.floor(seconds / 60)
	local secs = math.floor(seconds % 60)
	return string.format("%02d:%02d", minutes, secs)
end

-- Populate scoreboard with player stats
local function populateScoreboard(statsPayload: {{username: string, level: number, kills: number, deaths: number, damage: number, surviveTime: number}})
	-- Clear existing entries (use pairs instead of ipairs for safety during iteration)
	local toDestroy = {}
	for _, child in pairs(scoreFrame:GetChildren()) do
		-- Skip UIListLayout and the template (by both reference AND name)
		if not child:IsA("UIListLayout") 
			and child ~= examplePlayerLabel 
			and child.Name ~= "ExamplePlayerLabel" then
			table.insert(toDestroy, child)
		end
	end
	for _, child in ipairs(toDestroy) do
		child:Destroy()
	end
	
	-- Create entry for each player
	for _, playerData in ipairs(statsPayload) do
		local playerFrame = examplePlayerLabel:Clone()
		playerFrame.Visible = true
		playerFrame.Name = playerData.username
		
		-- Populate labels
		local usernameLabel = playerFrame:FindFirstChild("UsernameLabel") :: TextLabel
		if usernameLabel then
			usernameLabel.Text = playerData.username
		end
		
		local surviveTimeLabel = playerFrame:FindFirstChild("SurviveTimeExampleLabel") :: TextLabel
		if surviveTimeLabel then
			surviveTimeLabel.Text = formatTime(playerData.surviveTime)
		end
		
		local levelLabel = playerFrame:FindFirstChild("LevelExampleLabel") :: TextLabel
		if levelLabel then
			levelLabel.Text = tostring(playerData.level)
		end
		
		local killLabel = playerFrame:FindFirstChild("KillExampleLabel") :: TextLabel
		if killLabel then
			killLabel.Text = tostring(playerData.kills)
		end
		
		local deathsLabel = playerFrame:FindFirstChild("DeathsExampleLabel") :: TextLabel
		if deathsLabel then
			deathsLabel.Text = tostring(playerData.deaths)
		end
		
		local damageLabel = playerFrame:FindFirstChild("DamageExampleLabel") :: TextLabel
		if damageLabel then
			damageLabel.Text = tostring(math.floor(playerData.damage))
		end
		
		playerFrame.Parent = scoreFrame
	end
end

-- Handle team wipe
TeamWipeRemote.OnClientEvent:Connect(function(statsPayload: {{username: string, level: number, kills: number, deaths: number, damage: number, surviveTime: number}}, finalSessionTime: number?)
	-- Update Game Session Label with final time
	if finalSessionTime and typeof(finalSessionTime) == "number" then
		local minutes = math.floor(finalSessionTime / 60)
		local secs = math.floor(finalSessionTime % 60)
		local timeStr = string.format("%02d:%02d", minutes, secs)
		
		local gameSessionLabel = gameOverFrame:FindFirstChild("GameSessionLabel") :: TextLabel
		if gameSessionLabel then
			gameSessionLabel.Text = string.format("Game Session: %s", timeStr)
		end
	end
	
	-- Hide death timer
	if deathTimerLabel then
		deathTimerLabel.Visible = false
	end
	
	-- Wait 3 seconds
	task.wait(3)
	
	-- Disable death GUI entirely before camera tween
	if deathGui then
		deathGui.Enabled = false
	end
	
	-- Disable MainHUD and GameGui before camera tween
	local mainHUD = playerGui:FindFirstChild("MainHUD")
	if mainHUD then
		mainHUD.Enabled = false
	end
	
	local gameGui = playerGui:FindFirstChild("GameGui")
	if gameGui then
		gameGui.Enabled = false
	end
	
	-- Switch camera to scriptable
	camera.CameraType = Enum.CameraType.Scriptable
	
	-- Tween camera to wipe view (2 seconds)
	local cameraTween = TweenService:Create(
		camera,
		TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{CFrame = WIPE_CAMERA_CFRAME}
	)
	cameraTween:Play()
	
	-- Enable and tween color correction brightness (2 seconds)
	wipeColorCorrection.Enabled = true
	wipeColorCorrection.Brightness = 0
	local colorTween = TweenService:Create(
		wipeColorCorrection,
		TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{Brightness = -0.6}
	)
	colorTween:Play()
	
	-- Wait for tweens to complete
	task.wait(2)
	
	-- Display wipe GUI with stats
	populateScoreboard(statsPayload)
	wipeGui.Enabled = true
	
	-- 20 second countdown timer
	for i = 20, 0, -1 do
		restartTimerLabel.Text = string.format("Restarting in %d...", i)
		task.wait(1)
	end
	
	-- Hide wipe GUI
	wipeGui.Enabled = false
	
	-- Fire cleanup to server
	StartCleanupRemote:FireServer()
	
	-- Tween camera back to menu view
	local menuCameraTween = TweenService:Create(
		camera,
		TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{CFrame = MENU_CAMERA_CFRAME}
	)
	menuCameraTween:Play()
	
	-- Tween color correction back to 0
	local colorResetTween = TweenService:Create(
		wipeColorCorrection,
		TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{Brightness = 0}
	)
	colorResetTween:Play()
	
	-- Wait for tweens to complete
	task.wait(2)
	
	-- Disable color correction
	wipeColorCorrection.Enabled = false
	
	-- Show main menu
	local mainMenuGui = playerGui:FindFirstChild("MainMenuGui")
	if mainMenuGui then
		local mainMenuFrame = mainMenuGui:FindFirstChild("MainMenuFrame")
		if mainMenuFrame then
			mainMenuFrame.Visible = true
		end
	end
end)

-- Re-enable death timer when cleanup is complete and new game can start
WipeCleanupCompleteRemote.OnClientEvent:Connect(function()
	-- Re-enable death timer
	if deathTimerLabel then
		deathTimerLabel.Visible = true
	end
	
	-- Re-enable death GUI
	if deathGui then
		deathGui.Enabled = true
	end
	
	-- Clear scoreboard for next session
	local toDestroy = {}
	for _, child in pairs(scoreFrame:GetChildren()) do
		-- Skip UIListLayout and the template (by both reference AND name)
		if not child:IsA("UIListLayout") 
			and child ~= examplePlayerLabel 
			and child.Name ~= "ExamplePlayerLabel" then
			table.insert(toDestroy, child)
		end
	end
	for _, child in ipairs(toDestroy) do
		child:Destroy()
	end
	
	-- DON'T re-enable MainHUD or GameGui - player is in menu now
	-- They will be enabled when player clicks Play button
end)

-- Listen for server-side scoreboard clear command
ClearScoreboardRemote.OnClientEvent:Connect(function()
	local toDestroy = {}
	for _, child in pairs(scoreFrame:GetChildren()) do
		-- Clear everything except UIListLayout and the template
		if not child:IsA("UIListLayout") 
			and child ~= examplePlayerLabel 
			and child.Name ~= "ExamplePlayerLabel" then
			table.insert(toDestroy, child)
		end
	end
	for _, child in ipairs(toDestroy) do
		child:Destroy()
	end
end)

