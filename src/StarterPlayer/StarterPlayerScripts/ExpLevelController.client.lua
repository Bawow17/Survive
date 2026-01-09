--!strict
-- ExpLevelController - Updates existing exp/level GUI with player data

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Wait for dedicated PlayerStatsUpdate remote (NOT EntityUpdate)
local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local PlayerStatsUpdate = remotes:WaitForChild("PlayerStatsUpdate")

-- Get pause remotes
local GamePaused = remotes:WaitForChild("GamePaused")
local GameUnpaused = remotes:WaitForChild("GameUnpaused")

-- Wait for existing GUI (DO NOT CREATE, JUST USE EXISTING)
local mainHUD = playerGui:WaitForChild("MainHUD", 10)
if not mainHUD then
	warn("[ExpLevelController] MainHUD not found!")
	return
end

local bottomBarFrame = mainHUD:WaitForChild("BottomBarFrame", 10)
if not bottomBarFrame then
	warn("[ExpLevelController] BottomBarFrame not found!")
	return
end

local expBarFrame = bottomBarFrame:WaitForChild("ExpBarFrame", 10)
if not expBarFrame then
	warn("[ExpLevelController] ExpBarFrame not found!")
	return
end

local levelLabel = expBarFrame:WaitForChild("LevelLabel", 10)
if not levelLabel then
	warn("[ExpLevelController] LevelLabel not found!")
	return
end

local expFill = expBarFrame:WaitForChild("ExpFill", 10)
if not expFill then
	warn("[ExpLevelController] ExpFill not found!")
	return
end

-- Ensure ExpFill has proper anchoring for left-to-right fill (matches old example)
expFill.AnchorPoint = Vector2.new(0, 0)  -- Anchor left side
expFill.Position = UDim2.new(0, 0, 0, 0)  -- Start at left
expFill.Size = UDim2.new(0, 0, 1, 0)  -- Initial: 0 width, full height

-- Store original exp fill color (before any pause effects)
local ORIGINAL_EXP_COLOR = expFill.BackgroundColor3
local PAUSE_PURPLE_COLOR = Color3.fromRGB(180, 100, 255)

-- Track current exp state for unpause restoration
local currentExpRatio = 0

-- Listen for player stats updates from dedicated remote
PlayerStatsUpdate.OnClientEvent:Connect(function(stats)
	if not stats then
		warn("[ExpLevelController] Received nil stats")
		return
	end
	
	-- Update from simple stats table
	local level = stats.level or 1
	local xp = stats.xp or 0
	local xpForNext = stats.xpForNext or 100
	
	-- Update level label
	levelLabel.Text = "Level " .. level
	
	-- Animate exp bar fill (left to right based on exp percentage)
	local fillRatio = math.clamp(xp / xpForNext, 0, 1)
	currentExpRatio = fillRatio  -- Store for unpause restoration
	
	local tween = TweenService:Create(expFill, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(fillRatio, 0, 1, 0)  -- Fill left to right, full height
	})
	tween:Play()
end)

-- Handle pause: turn exp bar purple and fill to 100%
GamePaused.OnClientEvent:Connect(function(data)
	-- Set to purple and fill completely (instant, no tween)
	expFill.BackgroundColor3 = PAUSE_PURPLE_COLOR
	expFill.Size = UDim2.new(1, 0, 1, 0)  -- 100% width
end)

-- Handle unpause: restore color and update to current exp
GameUnpaused.OnClientEvent:Connect(function()
	-- Restore original color (instant)
	expFill.BackgroundColor3 = ORIGINAL_EXP_COLOR
	
	-- Restore size based on current exp (instant, no tween)
	expFill.Size = UDim2.new(currentExpRatio, 0, 1, 0)
end)
