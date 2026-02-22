--!strict
-- Simple handler for mobile mobility button
-- Shows button only on mobile and triggers mobility ability

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Get the button from PlayerGui (it gets cloned from StarterGui)
local mobileButtons = playerGui:WaitForChild("MobileButtons", 10)
if not mobileButtons then
	warn("[MobilityButton] MobileButtons not found in PlayerGui")
	return
end

local button = mobileButtons:WaitForChild("TextButton", 10)
if not button then
	warn("[MobilityButton] TextButton not found in MobileButtons")
	return
end

-- Check if device is mobile (touch enabled)
local isMobile = UserInputService.TouchEnabled

-- Hide button if not on mobile
if not isMobile then
	button.Visible = false
	return
else
	button.Visible = true
    mobileButtons.Enabled = true
end

-- Wait for MobilityController to create the trigger
local mobilityTrigger = ReplicatedStorage:WaitForChild("MobilityTrigger", 10)
if not mobilityTrigger then
	warn("[MobilityButton] MobilityTrigger not found - make sure MobilityController is running")
	return
end

-- Connect button press to mobility activation
button.MouseButton1Click:Connect(function()
	-- Fire the mobility trigger (same as pressing Q)
	mobilityTrigger:Fire()
end)

