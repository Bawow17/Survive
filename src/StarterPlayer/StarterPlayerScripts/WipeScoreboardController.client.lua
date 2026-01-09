--!strict
-- WipeScoreboardController - Handles team wipe scoreboard and menu return

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Wait for remotes
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local TeamWipeRemote = remotesFolder:WaitForChild("TeamWipe") :: RemoteEvent
local ReturnToMenuRemote = remotesFolder:WaitForChild("ReturnToMenu") :: RemoteEvent
local ContinuePurchasedRemote = remotesFolder:WaitForChild("ContinuePurchased") :: RemoteEvent
local ContinueSuccessRemote = remotesFolder:WaitForChild("ContinueSuccess") :: RemoteEvent

-- TODO: Wait for scoreboard GUI
-- For now, just handle the flow

local scoreboardVisible = false
local continueTimer = 30
local continueExpired = false

local function showScoreboard(wipeData: {canContinue: boolean, continueTimeLeft: number})
	scoreboardVisible = true
	continueTimer = wipeData.continueTimeLeft or 30
	continueExpired = false
	
	print(string.format("[WipeScoreboard] Team wiped - showing scoreboard (continue: %ds)", continueTimer))
	
	-- TODO: Show actual scoreboard GUI
	-- For now, just log
	
	-- Start countdown timer
	task.spawn(function()
		while continueTimer > 0 and scoreboardVisible do
			task.wait(1)
			continueTimer = continueTimer - 1
			
			if continueTimer <= 0 then
				continueExpired = true
				print("[WipeScoreboard] Continue expired")
				-- TODO: Update UI to show Continue expired
			end
		end
	end)
end

local function hideScoreboard()
	scoreboardVisible = false
	print("[WipeScoreboard] Scoreboard hidden")
	-- TODO: Hide actual scoreboard GUI
end

local function returnToMenu()
	print("[WipeScoreboard] Returning to menu")
	
	-- Fire to server
	ReturnToMenuRemote:FireServer()
	
	-- Hide scoreboard
	hideScoreboard()
	
	-- Show main menu (MainMenuController will handle this via remote)
	local mainMenuGui = playerGui:FindFirstChild("MainMenuGui")
	if mainMenuGui then
		local mainMenuFrame = mainMenuGui:FindFirstChild("MainMenuFrame")
		if mainMenuFrame then
			mainMenuFrame.Visible = true
		end
	end
end

local function attemptContinue()
	if continueExpired then
		warn("[WipeScoreboard] Continue expired - cannot continue")
		return
	end
	
	print("[WipeScoreboard] Attempting to purchase Continue")
	
	-- TODO: Trigger Robux purchase via MarketplaceService
	-- For now, just fire the remote (would normally be after successful purchase)
	ContinuePurchasedRemote:FireServer()
end

-- Listen for team wipe
TeamWipeRemote.OnClientEvent:Connect(function(wipeData: {canContinue: boolean, continueTimeLeft: number, scoreboardData: any?})
	showScoreboard(wipeData)
end)

-- Listen for continue success
ContinueSuccessRemote.OnClientEvent:Connect(function()
	print("[WipeScoreboard] Continue successful - returning to game")
	
	-- Hide scoreboard
	hideScoreboard()
	
	-- Hide menu (forced into game)
	local mainMenuGui = playerGui:FindFirstChild("MainMenuGui")
	if mainMenuGui then
		local mainMenuFrame = mainMenuGui:FindFirstChild("MainMenuFrame")
		if mainMenuFrame then
			mainMenuFrame.Visible = false
		end
	end
	
	-- Camera will be restored by MenuCameraController via GameStart event
end)

-- Listen for cleanup complete (hide scoreboard)
local HideWipeScoreboard = remotesFolder:WaitForChild("HideWipeScoreboard")
HideWipeScoreboard.OnClientEvent:Connect(function()
	print("[WipeScoreboard] Cleanup complete - hiding scoreboard")
	hideScoreboard()
end)

-- TODO: Connect to actual scoreboard GUI buttons when they exist
-- For now, expose functions for testing
_G.WipeScoreboardController = {
	returnToMenu = returnToMenu,
	attemptContinue = attemptContinue,
	isVisible = function() return scoreboardVisible end,
}


