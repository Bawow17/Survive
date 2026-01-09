--!strict
-- DashAfterimageRenderer - Client-side rendering of dash afterimages
-- Renders afterimages for all players' dashes visible to all clients

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local _player = Players.LocalPlayer

-- Workspace folder for afterimages (use Trash folder)
local Workspace = game:GetService("Workspace")
local afterimagesFolder = Workspace.Trash

-- Remote event for receiving afterimage spawn data
local DashAfterimageRemote: RemoteEvent

-- Pause state tracking
local isPaused = false

-- Active fades (for pause handling)
local activeFades: {[Model]: {
	tweens: {Tween},
	startTime: number,
	duration: number,
	totalPausedTime: number,
	lastPauseCheckTime: number,
}} = {}

-- Helper function to find model by path
local function findModelByPath(path: string): Model?
	local parts = string.split(path, ".")
	local current: any = game
	
	for _, part in ipairs(parts) do
		if part == "game" then
			continue
		end
		
		-- Handle GetService calls
		if part:match("^GetService") then
			local serviceName = part:match('GetService%("(.+)"%)')
			if serviceName then
				current = game:GetService(serviceName)
			end
		else
			current = current:FindFirstChild(part)
			if not current then
				return nil
			end
		end
	end
	
	return if typeof(current) == "Instance" and current:IsA("Model") then current else nil
end

-- Copy R6 character pose to afterimage model
local function copyR6Pose(characterModel: Model, afterimageModel: Model)
	-- R6 body part names to copy
	local bodyParts = {"Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg"}
	
	-- Copy each body part's CFrame directly from character to afterimage
	for _, partName in ipairs(bodyParts) do
		local characterPart = characterModel:FindFirstChild(partName)
		local afterimagePart = afterimageModel:FindFirstChild(partName)
		
		if characterPart and characterPart:IsA("BasePart") and afterimagePart and afterimagePart:IsA("BasePart") then
			-- Directly copy the CFrame to match position and rotation
			afterimagePart.CFrame = characterPart.CFrame
		end
	end
end

-- Render an afterimage matching the character's current pose
local function renderAfterimage(characterModel: Model, mobilityType: string, fadeDuration: number, transparency: number)
	-- Determine which afterimage template to use
	local modelPath = ""
	if mobilityType == "Dash" then
		modelPath = "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.Dash.Afterimage"
	elseif mobilityType == "ShieldBash" then
		modelPath = "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.BashShield.Afterimage"
	else
		warn("[DashAfterimageRenderer] Unknown mobility type:", mobilityType)
		return
	end
	
	-- Load afterimage template
	local template = findModelByPath(modelPath)
	if not template then
		warn("[DashAfterimageRenderer] Could not find afterimage model at:", modelPath)
		-- Create a basic afterimage using the character model as template
		template = characterModel
		if not template then
			warn("[DashAfterimageRenderer] No character model available for fallback")
			return
		end
	end
	
	-- Clone the afterimage model
	local afterimage = template:Clone()
	if not afterimage then
		return
	end
	
	-- Copy character's R6 pose to afterimage (this positions all parts)
	copyR6Pose(characterModel, afterimage)
	
	-- Set initial properties for all parts (preserve original transparency from model)
	local partsToFade = {}
	for _, part in ipairs(afterimage:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.Massless = true
			part.CanQuery = false
			part.CanTouch = false
			
			-- Keep original transparency from the model (don't override it)
			-- The model parts already have their intended starting transparency
			
			table.insert(partsToFade, part)
		end
	end
	
	-- Parent to workspace
	afterimage.Parent = afterimagesFolder
	
	-- Create fade tweens for all parts (fade from current transparency to 1)
	local tweens = {}
	for _, part in ipairs(partsToFade) do
		local tween = TweenService:Create(
			part,
			TweenInfo.new(fadeDuration, Enum.EasingStyle.Linear),
			{Transparency = 1}
		)
		tween:Play()
		table.insert(tweens, tween)
	end
	
	-- Track fade for pause handling
	local fadeData = {
		tweens = tweens,
		startTime = tick(),
		duration = fadeDuration,
		totalPausedTime = 0,
		lastPauseCheckTime = tick(),
	}
	activeFades[afterimage] = fadeData
	
	-- Destroy afterimage after fade completes
	task.delay(fadeDuration, function()
		if afterimage and afterimage.Parent then
			afterimage:Destroy()
		end
		activeFades[afterimage] = nil
	end)
end

-- Handle afterimage spawn requests from server
local function handleAfterimageSpawn(characterModel: Model, mobilityType: string, fadeDuration: number, transparency: number)
	-- Validate inputs
	if not characterModel or not characterModel:IsA("Model") then
		warn("[DashAfterimageRenderer] Invalid character model")
		return
	end
	
	if typeof(mobilityType) ~= "string" then
		warn("[DashAfterimageRenderer] Invalid mobility type")
		return
	end
	
	-- Debug logging for Shield Bash
	if mobilityType == "ShieldBash" then
		print("[DashAfterimageRenderer] Shield Bash afterimage requested")
	end
	
	-- Render the afterimage
	renderAfterimage(characterModel, mobilityType, fadeDuration or 0.2, transparency or 0.7)
end

-- Process active fades (for pause handling)
local function processActiveFades()
	for afterimage, fadeData in pairs(activeFades) do
		local currentTime = tick()
		
		-- Handle pause/unpause
		if isPaused then
			-- Accumulate paused time
			fadeData.totalPausedTime = fadeData.totalPausedTime + (currentTime - fadeData.lastPauseCheckTime)
			
			-- Pause all tweens
			for _, tween in ipairs(fadeData.tweens) do
				if tween.PlaybackState == Enum.PlaybackState.Playing then
					tween:Pause()
				end
			end
		else
			-- Resume all tweens
			for _, tween in ipairs(fadeData.tweens) do
				if tween.PlaybackState == Enum.PlaybackState.Paused then
					tween:Play()
				end
			end
		end
		
		fadeData.lastPauseCheckTime = currentTime
		
		-- Check if fade completed (accounting for pause time)
		local elapsedRealTime = currentTime - fadeData.startTime - fadeData.totalPausedTime
		if elapsedRealTime >= fadeData.duration then
			-- Cleanup
			if afterimage and afterimage.Parent then
				afterimage:Destroy()
			end
			activeFades[afterimage] = nil
		end
	end
end

-- Update loop for pause handling
RunService.Heartbeat:Connect(function()
	if next(activeFades) then
		processActiveFades()
	end
end)

-- Pause/Unpause event listeners
local function setupPauseListeners()
	local remotes = ReplicatedStorage:FindFirstChild("RemoteEvents")
	if not remotes then
		warn("[DashAfterimageRenderer] RemoteEvents folder not found for pause listeners")
		return
	end
	
	local GamePaused = remotes:FindFirstChild("GamePaused")
	local GameUnpaused = remotes:FindFirstChild("GameUnpaused")
	
	if GamePaused then
		GamePaused.OnClientEvent:Connect(function()
			isPaused = true
		end)
	end
	
	if GameUnpaused then
		GameUnpaused.OnClientEvent:Connect(function()
			isPaused = false
		end)
	end
end

-- Initialize
local function init()
	-- Get remote event with timeout to prevent infinite yield
	local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
	if not remotes then
		warn("[DashAfterimageRenderer] RemoteEvents folder not found")
		return
	end
	
	DashAfterimageRemote = remotes:FindFirstChild("DashAfterimage")
	if not DashAfterimageRemote then
		warn("[DashAfterimageRenderer] DashAfterimage remote not found")
		return
	end
	
	-- Listen for afterimage spawn requests
	DashAfterimageRemote.OnClientEvent:Connect(handleAfterimageSpawn)
	
	-- Setup pause listeners
	setupPauseListeners()
end

init()

