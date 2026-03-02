--!strict

local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local warned = false

local function warnMissing(message: string)
	if warned then
		return
	end
	warned = true
	warn(message)
end

local function waitForNamedChild(parent: Instance, childName: string, className: string?): Instance?
	local child = parent:FindFirstChild(childName) or parent:WaitForChild(childName, 10)
	if not child then
		warnMissing(string.format("[TixDisplayController] Missing %s.%s", parent:GetFullName(), childName))
		return nil
	end
	if className and not child:IsA(className) then
		warnMissing(string.format(
			"[TixDisplayController] Expected %s.%s to be a %s",
			parent:GetFullName(),
			childName,
			className
		))
		return nil
	end
	return child
end

local mainHUD = playerGui:WaitForChild("MainHUD", 10)
if not mainHUD or not mainHUD:IsA("ScreenGui") then
	warnMissing("[TixDisplayController] PlayerGui.MainHUD not found or invalid")
	return
end

local topBarFrame = waitForNamedChild(mainHUD, "TopBarFrame", "GuiObject")
if not topBarFrame then
	return
end

local leftFrame = waitForNamedChild(topBarFrame, "LeftFrame", "GuiObject")
if not leftFrame then
	return
end

local tixFrame = waitForNamedChild(leftFrame, "TixFrame", "GuiObject")
if not tixFrame then
	return
end

local imageLabel = waitForNamedChild(tixFrame, "ImageLabel", "ImageLabel")
if not imageLabel then
	return
end

local tixLabel = waitForNamedChild(imageLabel, "TixLabel", "TextLabel")
if not tixLabel or not tixLabel:IsA("TextLabel") then
	return
end

local function render()
	local value = localPlayer:GetAttribute("Tix")
	local amount = if typeof(value) == "number" then math.max(0, math.floor(value)) else 0
	tixLabel.Text = tostring(amount)
end

localPlayer:GetAttributeChangedSignal("Tix"):Connect(render)
render()
