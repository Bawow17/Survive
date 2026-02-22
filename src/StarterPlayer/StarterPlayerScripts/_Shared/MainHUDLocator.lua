--!strict

local MainHUDLocator = {}

function MainHUDLocator.waitForMainHUD(playerGui: PlayerGui): ScreenGui | Frame
	while true do
		local hud = playerGui:FindFirstChild("MainHUD")
		if hud and (hud:IsA("ScreenGui") or hud:IsA("Frame")) then
			return hud
		end
		local added = playerGui.ChildAdded:Wait()
		if added.Name == "MainHUD" and (added:IsA("ScreenGui") or added:IsA("Frame")) then
			return added
		end
	end
end

return MainHUDLocator
