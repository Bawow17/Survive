--!strict
-- MenuCameraController - Manages camera between menu and game states

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local inMenu = true

-- Wait for remotes
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local GameStartRemote = remotesFolder:WaitForChild("GameStart") :: RemoteEvent

-- Get blur effect
local mainMenuBlur = Lighting:WaitForChild("MainMenuBlur", 5)

local function setupMenuCamera()
	if not inMenu then return end
	
	camera.CameraType = Enum.CameraType.Scriptable
	
	-- Set camera CFrame (exact copy from Studio)
	-- Position: 277.621613, 1007.9491, 413.664886
	-- Rotation matrix captured from Studio camera
	camera.CFrame = CFrame.new(
		277.621613, 1007.9491, 413.664886,
		0.571366251, -0.489189893, 0.658964276,
		-0, 0.80293417, 0.596067727,
		-0.820695162, -0.340572983, 0.4587695
	)
	
	-- Enable menu blur
	if mainMenuBlur then
		mainMenuBlur.Enabled = true
	end
	
end

local function restoreGameCamera()
	if inMenu then return end
	
	camera.CameraType = Enum.CameraType.Custom
	
	-- Wait for character to load
	local character = player.Character or player.CharacterAdded:Wait()
	local humanoid = character:WaitForChild("Humanoid", 5)
	
	if humanoid then
		camera.CameraSubject = humanoid
	end
	
	-- Disable menu blur
	if mainMenuBlur then
		mainMenuBlur.Enabled = false
	end
end

-- Listen for game start
GameStartRemote.OnClientEvent:Connect(function()
	inMenu = false
	restoreGameCamera()
end)

-- Setup menu camera on spawn
player.CharacterAdded:Connect(function(character)
	if inMenu then
		-- Small delay to let character load
		task.wait(0.1)
		setupMenuCamera()
	end
end)

-- Initial setup
if player.Character then
	setupMenuCamera()
end


