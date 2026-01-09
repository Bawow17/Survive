--!strict
-- BuffTrackerController - Displays active buff durations in the bottom-right HUD
-- Shows: Nuke, Magnet, Health, Invincibility, Cloak, ArcaneRune

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

-- Find existing BuffTracker container
local container = mainHUD:WaitForChild("BuffTracker") :: Frame
local templateFrame = container:WaitForChild("ExampleBuff") :: Frame

-- Hide the template
templateFrame.Visible = false

type BuffRow = {
	frame: Frame,
	buffLabel: TextLabel,
	timeLabel: TextLabel,
	remaining: number,
	duration: number,
	startedAt: number,
	buffId: string,
	displayName: string,
	isHealthPopup: boolean,
	healthPercent: number?,
	overhealPercent: number?,
}

local buffRows: {[string]: BuffRow} = {}

local function formatSeconds(seconds: number): string
	if seconds >= 60 then
		local mins = math.floor(seconds / 60)
		local secs = seconds % 60
		return string.format("%d:%02d", mins, math.floor(secs))
	else
		return string.format("%.1f", seconds)
	end
end

local function updateRowDisplay(row: BuffRow)
	-- Special display for Health powerup
	if row.isHealthPopup then
		local healthText = ""
		if row.healthPercent and row.healthPercent > 0 then
			healthText = string.format("+%d%% Health", row.healthPercent)
		end
		if row.overhealPercent and row.overhealPercent > 0 then
			if healthText ~= "" then
				healthText = healthText .. ", "
			end
			healthText = healthText .. string.format("+%d%% Overheal", row.overhealPercent)
		end
		if healthText == "" then
			healthText = "+45% Health"  -- Fallback
		end
		row.buffLabel.Text = healthText
		row.timeLabel.Text = ""  -- No time display for health
		
		-- Expand buffLabel to full width for Health popup (no time display)
		row.buffLabel.Size = UDim2.new(0.92, 0, 0.8, 0)  -- Use full width
		row.timeLabel.Visible = false
	else
		row.buffLabel.Text = row.displayName
		row.timeLabel.Text = formatSeconds(math.max(row.remaining, 0))
		
		-- Normal width for other buffs (with time display)
		row.buffLabel.Size = UDim2.new(0.7, 0, 0.8, 0)
		row.timeLabel.Visible = true
	end

	-- Keep constant transparency until 0.5s remaining, then fade out
	local fadeAlpha = 1
	if row.remaining < 0.5 and row.remaining > 0 then
		fadeAlpha = row.remaining / 0.5  -- Fade from 1.0 at 0.5s to 0.0 at 0s
	elseif row.remaining <= 0 then
		fadeAlpha = 0
	end

	-- Background: 0.4 transparency (constant), then fade out
	row.frame.BackgroundTransparency = 0.4 + (0.6 * (1 - fadeAlpha))

	-- Text: 0 transparency (constant), then fade out
	row.buffLabel.TextTransparency = 1 - fadeAlpha
	row.timeLabel.TextTransparency = 1 - fadeAlpha
end

local function createRow(buffId: string, displayName: string, duration: number, healthPercent: number?, overhealPercent: number?): BuffRow
	-- Clone the template frame
	local frame = templateFrame:Clone() :: Frame
	frame.Name = buffId .. "Buff"
	frame.Visible = true
	-- Use negative timestamp so newer buffs appear at bottom
	frame.LayoutOrder = -math.floor(tick() * 1000)
	frame.Parent = container

	-- Get the labels from the cloned frame
	local buffLabel = frame:FindFirstChild("BuffLabel") :: TextLabel
	local timeLabel = frame:FindFirstChild("TimeLabel") :: TextLabel
	
	-- Set initial text
	buffLabel.Text = displayName
	timeLabel.Text = "0.0"

	local isHealthPopup = buffId == "Health" and (healthPercent ~= nil or overhealPercent ~= nil)

	local row: BuffRow = {
		frame = frame,
		buffLabel = buffLabel,
		timeLabel = timeLabel,
		remaining = duration,
		duration = duration,
		startedAt = tick(),
		buffId = buffId,
		displayName = displayName,
		isHealthPopup = isHealthPopup,
		healthPercent = healthPercent,
		overhealPercent = overhealPercent,
	}

	buffRows[buffId] = row
	updateRowDisplay(row)
	return row
end

local function removeRow(buffId: string)
	local row = buffRows[buffId]
	if not row then
		return
	end
	buffRows[buffId] = nil
	if row.frame and row.frame.Parent then
		row.frame:Destroy()
	end
end

-- Listen for buff duration events
local buffDurationRemote = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("BuffDurationUpdate")

buffDurationRemote.OnClientEvent:Connect(function(data: any)
	local buffId = data.buffId
	local displayName = data.displayName or buffId
	local duration = data.duration or 0
	local healthPercent = data.healthPercent
	local overhealPercent = data.overhealPercent
	
	-- Remove old row if it exists
	if buffRows[buffId] then
		removeRow(buffId)
	end
	
	-- Handle duration = 0 as a removal signal (don't create new row)
	if duration <= 0 then
		return
	end
	
	-- Create new buff row
	createRow(buffId, displayName, duration, healthPercent, overhealPercent)
end)

-- Countdown and cleanup logic
RunService.RenderStepped:Connect(function(dt)
	-- Don't countdown while paused
	if isPaused then
		return
	end
	
	local toRemove = {}
	for buffId, row in pairs(buffRows) do
		if row.remaining > 0 then
			row.remaining = math.max(0, row.remaining - dt)
			updateRowDisplay(row)
		else
			-- Remove instantly when buff reaches 0
			table.insert(toRemove, buffId)
		end
	end

	for _, buffId in ipairs(toRemove) do
		removeRow(buffId)
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

