--!strict
-- HitMarkerController
-- Shows ShiftLock.HitMarkerFrame when the local player deals applied damage.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local HOLD_DURATION = 0.12
local FADE_DURATION = 0.21
local HIT_MARKER_FRAME_NAME = "HitMarkerFrame"

local hitMarkerFrame: GuiObject? = nil
local fadeTweens: {Tween} = {}
local baselineTransparency: {[Instance]: {[string]: number}} = {}
local pulseToken = 0

local function clearFadeTweens()
	for _, tween in ipairs(fadeTweens) do
		tween:Cancel()
	end
	table.clear(fadeTweens)
end

local function recordTransparency(instance: Instance, propertyName: string, out: {[string]: number})
	local ok, value = pcall(function()
		return (instance :: any)[propertyName]
	end)
	if ok and typeof(value) == "number" then
		out[propertyName] = value
	end
end

local function cacheBaselineTransparency(frame: GuiObject)
	table.clear(baselineTransparency)

	local function cacheFor(instance: Instance)
		local props: {[string]: number} = {}
		if instance:IsA("GuiObject") then
			recordTransparency(instance, "BackgroundTransparency", props)
		end
		if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
			recordTransparency(instance, "ImageTransparency", props)
		end
		if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
			recordTransparency(instance, "TextTransparency", props)
		end
		if instance:IsA("UIStroke") then
			recordTransparency(instance, "Transparency", props)
		end
		if next(props) then
			baselineTransparency[instance] = props
		end
	end

	cacheFor(frame)
	for _, descendant in ipairs(frame:GetDescendants()) do
		cacheFor(descendant)
	end
end

local function applyBaselineTransparency()
	for instance, props in pairs(baselineTransparency) do
		if not instance.Parent then
			continue
		end
		for propertyName, value in pairs(props) do
			pcall(function()
				(instance :: any)[propertyName] = value
			end)
		end
	end
end

local function createFadeTweens()
	clearFadeTweens()
	local tweenInfo = TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

	for instance, props in pairs(baselineTransparency) do
		if not instance.Parent then
			continue
		end
		local goals: {[string]: number} = {}
		for propertyName in pairs(props) do
			goals[propertyName] = 1
		end
		if next(goals) then
			local tween = TweenService:Create(instance, tweenInfo, goals)
			table.insert(fadeTweens, tween)
		end
	end
end

local function bindHitMarkerFrame(frame: GuiObject)
	hitMarkerFrame = frame
	cacheBaselineTransparency(frame)
	clearFadeTweens()
	applyBaselineTransparency()
	frame.Visible = false
end

local function findHitMarkerFrame(): GuiObject?
	local shiftLock = playerGui:FindFirstChild("ShiftLock")
	if shiftLock then
		local direct = shiftLock:FindFirstChild(HIT_MARKER_FRAME_NAME, true)
		if direct and direct:IsA("GuiObject") then
			return direct
		end
	end

	local fallback = playerGui:FindFirstChild(HIT_MARKER_FRAME_NAME, true)
	if fallback and fallback:IsA("GuiObject") then
		return fallback
	end

	return nil
end

local function ensureBoundHitMarker()
	local frame = findHitMarkerFrame()
	if frame then
		if hitMarkerFrame ~= frame then
			bindHitMarkerFrame(frame)
		end
		return
	end
	hitMarkerFrame = nil
	table.clear(baselineTransparency)
	clearFadeTweens()
end

local function playHitMarkerPulse()
	ensureBoundHitMarker()
	local frame = hitMarkerFrame
	if not frame then
		return
	end

	pulseToken += 1
	local currentToken = pulseToken

	clearFadeTweens()
	applyBaselineTransparency()
	frame.Visible = true

	task.delay(HOLD_DURATION, function()
		if currentToken ~= pulseToken then
			return
		end
		if hitMarkerFrame ~= frame or not frame.Parent then
			return
		end

		createFadeTweens()
		for _, tween in ipairs(fadeTweens) do
			tween:Play()
		end

		task.delay(FADE_DURATION, function()
			if currentToken ~= pulseToken then
				return
			end
			if hitMarkerFrame ~= frame or not frame.Parent then
				return
			end
			frame.Visible = false
		end)
	end)
end

playerGui.DescendantAdded:Connect(function(descendant: Instance)
	if descendant.Name == HIT_MARKER_FRAME_NAME and descendant:IsA("GuiObject") then
		bindHitMarkerFrame(descendant)
	end
end)

playerGui.DescendantRemoving:Connect(function(descendant: Instance)
	if hitMarkerFrame and descendant == hitMarkerFrame then
		hitMarkerFrame = nil
		table.clear(baselineTransparency)
		clearFadeTweens()
	end
end)

ensureBoundHitMarker()

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local playerHitMarkerRemote = remotesFolder:WaitForChild("PlayerHitMarker")
if playerHitMarkerRemote:IsA("RemoteEvent") then
	playerHitMarkerRemote.OnClientEvent:Connect(playHitMarkerPulse)
end
