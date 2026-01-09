--!strict
-- CooldownController - Displays active ability cooldowns in the bottom-left HUD
-- Simplified event-based approach

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- Track pause state
local isPaused = false

local function waitForMainHUD(): Instance
	while true do
		local hud = playerGui:FindFirstChild("MainHUD")
		if hud and (hud:IsA("ScreenGui") or hud:IsA("Frame")) then
			return hud
		end
		local guiAdded = playerGui.ChildAdded:Wait()
		if guiAdded.Name == "MainHUD" and (guiAdded:IsA("ScreenGui") or guiAdded:IsA("Frame")) then
			return guiAdded
		end
	end
end

local mainHUD = waitForMainHUD()

-- Find existing CooldownTracker container
local container = mainHUD:WaitForChild("CooldownTracker") :: Frame
local templateFrame = container:WaitForChild("ExampleCooldown") :: Frame

-- Hide the template
templateFrame.Visible = false

type CooldownRow = {
	frame: Frame,
	abilityLabel: TextLabel,
	timeLabel: TextLabel,
	remaining: number,
	duration: number,
	startedAt: number,
	abilityId: string,
	displayName: string,
	isMobility: boolean,
}

local cooldownRows: {[string]: CooldownRow} = {}

local function formatSeconds(seconds: number): string
	if seconds >= 60 then
		local mins = math.floor(seconds / 60)
		local secs = seconds % 60
		return string.format("%d:%02d", mins, math.floor(secs))
	else
		return string.format("%.1f", seconds)
	end
end

local function updateRowDisplay(row: CooldownRow)
	row.abilityLabel.Text = row.displayName
	row.timeLabel.Text = formatSeconds(math.max(row.remaining, 0))

	-- Keep constant transparency until 0.5s remaining, then fade out
	local fadeAlpha = 1
	if row.remaining < 0.5 and row.remaining > 0 then
		fadeAlpha = row.remaining / 0.5  -- Fade from 1.0 at 0.5s to 0.0 at 0s
	elseif row.remaining <= 0 then
		fadeAlpha = 0
	end

	-- Background: 0.4 transparency (constant), then fade out
	row.frame.BackgroundTransparency = 0.4 + (0.6 * (1 - fadeAlpha))

	-- Set text color based on ability type
	if row.isMobility then
		-- Light blue for mobility abilities
		row.abilityLabel.TextColor3 = Color3.fromRGB(100, 200, 255)
		row.timeLabel.TextColor3 = Color3.fromRGB(100, 200, 255)
	else
		-- White for normal abilities
		row.abilityLabel.TextColor3 = Color3.new(1, 1, 1)
		row.timeLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
	end

	-- Text: 0 transparency (constant), then fade out
	row.abilityLabel.TextTransparency = 1 - fadeAlpha
	row.timeLabel.TextTransparency = 1 - fadeAlpha
end

local function createRow(abilityId: string, displayName: string, duration: number): CooldownRow
	-- Clone the template frame
	local frame = templateFrame:Clone() :: Frame
	frame.Name = abilityId .. "Cooldown"
	frame.Visible = true
	-- Use negative timestamp so newer abilities appear at bottom
	frame.LayoutOrder = -math.floor(tick() * 1000)
	frame.Parent = container

	-- Get the labels from the cloned frame
	local abilityLabel = frame:FindFirstChild("CooldownLabel") :: TextLabel
	local timeLabel = frame:FindFirstChild("TimeLabel") :: TextLabel
	
	-- Set initial text
	abilityLabel.Text = displayName
	timeLabel.Text = "0.0"

	-- Check if this is a mobility ability
	local isMobility = string.sub(abilityId, 1, 9) == "Mobility_"

	local row: CooldownRow = {
		frame = frame,
		abilityLabel = abilityLabel,
		timeLabel = timeLabel,
		remaining = duration,
		duration = duration,
		startedAt = tick(),
		abilityId = abilityId,
		displayName = displayName,
		isMobility = isMobility,
	}

	cooldownRows[abilityId] = row
	updateRowDisplay(row)
	return row
end

local function removeRow(abilityId: string)
	local row = cooldownRows[abilityId]
	if not row then
		return
	end
	cooldownRows[abilityId] = nil
	if row.frame and row.frame.Parent then
	row.frame:Destroy()
end
end

-- Listen for ability cast events
local abilityCastRemote = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("AbilityCast")

abilityCastRemote.OnClientEvent:Connect(function(abilityId: string, cooldownDuration: number, abilityName: string?)
	local displayName = abilityName or abilityId
	
	-- Remove old row if it exists
	if cooldownRows[abilityId] then
			removeRow(abilityId)
	end
	
	-- Create new cooldown row
	createRow(abilityId, displayName, cooldownDuration)
end)

-- Countdown and cleanup logic
RunService.RenderStepped:Connect(function(dt)
	-- Don't countdown while paused
	if isPaused then
		return
	end

	local toRemove = {}
	for abilityId, row in pairs(cooldownRows) do
		if row.remaining > 0 then
			row.remaining = math.max(0, row.remaining - dt)
			updateRowDisplay(row)
		else
			-- Remove instantly when cooldown reaches 0
				table.insert(toRemove, abilityId)
		end
	end

	for _, abilityId in ipairs(toRemove) do
		removeRow(abilityId)
	end
end)

-- Listen for pause/unpause events
local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local gamePaused = remotes:WaitForChild("GamePaused")
local gameUnpaused = remotes:WaitForChild("GameUnpaused")

gamePaused.OnClientEvent:Connect(function()
	isPaused = true
end)

gameUnpaused.OnClientEvent:Connect(function()
	isPaused = false
end)
