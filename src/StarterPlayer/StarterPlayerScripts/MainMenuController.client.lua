--!strict
-- MainMenuController - Handles main menu UI interactions

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Wait for remotes
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local StartGameRemote = remotesFolder:WaitForChild("StartGame") :: RemoteEvent
local GameStartRemote = remotesFolder:WaitForChild("GameStart") :: RemoteEvent
local CheckGameStateRemote = remotesFolder:WaitForChild("CheckGameState") :: RemoteFunction
local RequestFriendsListRemote: RemoteEvent
local FriendsListUpdateRemote: RemoteEvent
local JoinPrivateGameRemote: RemoteEvent

-- Create remotes if they don't exist (friends list system)
if not remotesFolder:FindFirstChild("RequestFriendsList") then
	RequestFriendsListRemote = Instance.new("RemoteEvent")
	RequestFriendsListRemote.Name = "RequestFriendsList"
	RequestFriendsListRemote.Parent = remotesFolder
else
	RequestFriendsListRemote = remotesFolder:FindFirstChild("RequestFriendsList") :: RemoteEvent
end

if not remotesFolder:FindFirstChild("FriendsListUpdate") then
	FriendsListUpdateRemote = Instance.new("RemoteEvent")
	FriendsListUpdateRemote.Name = "FriendsListUpdate"
	FriendsListUpdateRemote.Parent = remotesFolder
else
	FriendsListUpdateRemote = remotesFolder:FindFirstChild("FriendsListUpdate") :: RemoteEvent
end

if not remotesFolder:FindFirstChild("JoinPrivateGame") then
	JoinPrivateGameRemote = Instance.new("RemoteEvent")
	JoinPrivateGameRemote.Name = "JoinPrivateGame"
	JoinPrivateGameRemote.Parent = remotesFolder
else
	JoinPrivateGameRemote = remotesFolder:FindFirstChild("JoinPrivateGame") :: RemoteEvent
end

-- Wait for GUI
local mainMenuGui = playerGui:WaitForChild("MainMenuGui", 10)
if not mainMenuGui then
	warn("[MainMenu] MainMenuGui not found in PlayerGui!")
	return
end

local mainMenuFrame = mainMenuGui:WaitForChild("MainMenuFrame")
local playButtonsFrame = mainMenuFrame:WaitForChild("PlayButtonsFrame")
local confirmationFrame = mainMenuFrame:WaitForChild("GameStartConfirmationFrame")
local friendsListFrame = mainMenuFrame:WaitForChild("FriendslistFrame")

-- Buttons
local playButton = playButtonsFrame:FindFirstChild("PlayButton")
if not playButton then
	warn("[MainMenu] PlayButton not found!")
	return
end

local confirmButton = confirmationFrame:WaitForChild("ConfirmButton")
local cancelButton = confirmationFrame:WaitForChild("CancelButton")
local confirmText = confirmationFrame:FindFirstChild("TextLabel")

-- Friends list
local friendsScrollingFrame = friendsListFrame:WaitForChild("FriendslistScrollingFrame")
local friendExampleFrame = friendsScrollingFrame:WaitForChild("FriendExampleFrame")
friendExampleFrame.Visible = false  -- Template

-- Private game frame
local privateGameFrame = friendsListFrame:FindFirstChild("PrivateGameFrame")
local codeTextBox: TextBox
local joinPrivateButton: TextButton

if privateGameFrame then
	codeTextBox = privateGameFrame:WaitForChild("GameCodeTextBox") :: TextBox
	joinPrivateButton = privateGameFrame:WaitForChild("JoinPrivateExampleButton") :: TextButton
end

-- Play button lockout state
local playButtonLocked = false

-- Functions
local function showMenu()
	mainMenuFrame.Visible = true
	
	-- Disable game UIs when returning to menu
	local mainHUD = playerGui:FindFirstChild("MainHUD")
	if mainHUD and mainHUD:IsA("ScreenGui") then
		mainHUD.Enabled = false
	end
	
	local gameGui = playerGui:FindFirstChild("GameGui")
	if gameGui and gameGui:IsA("ScreenGui") then
		gameGui.Enabled = false
	end
	
	local mobileButtons = playerGui:FindFirstChild("MobileButtons")
	if mobileButtons and mobileButtons:IsA("ScreenGui") then
		mobileButtons.Enabled = false
	end
end

local function hideMenu()
	mainMenuFrame.Visible = false
	
	-- Enable game UIs when entering game
	local mainHUD = playerGui:FindFirstChild("MainHUD")
	if mainHUD and mainHUD:IsA("ScreenGui") then
		mainHUD.Enabled = true
	end
	
	local gameGui = playerGui:FindFirstChild("GameGui")
	if gameGui and gameGui:IsA("ScreenGui") then
		gameGui.Enabled = true
	end
	
	local mobileButtons = playerGui:FindFirstChild("MobileButtons")
	if mobileButtons and mobileButtons:IsA("ScreenGui") then
		mobileButtons.Enabled = true
	end
end

local function formatTime(seconds: number): string
	local minutes = math.floor(seconds / 60)
	local secs = math.floor(seconds % 60)
	return string.format("%02d:%02d", minutes, secs)
end

-- Cache for friends data to prevent empty list flicker
local cachedFriendsData = {}
local isLoadingFriends = false
local loadingTimeout = nil

local function updateFriendsList()
	-- Don't clear existing entries if we're already loading
	if isLoadingFriends then
		return
	end
	
	-- Set loading state
	isLoadingFriends = true
	
	-- Clear any existing timeout
	if loadingTimeout then
		task.cancel(loadingTimeout)
	end
	
	-- Set timeout to prevent stuck loading state (10 seconds)
	loadingTimeout = task.delay(10, function()
		if isLoadingFriends then
			isLoadingFriends = false
			loadingTimeout = nil
		end
	end)
	
	-- Show loading indicator if we have cached data
	if #cachedFriendsData > 0 then
		-- Keep existing UI, just request new data
	else
		-- No cached data, show loading state
		-- Clear existing friend entries
		for _, child in ipairs(friendsScrollingFrame:GetChildren()) do
			if child:IsA("Frame") and child ~= friendExampleFrame then
				child:Destroy()
			end
		end
		
		-- Add loading indicator
		local loadingFrame = friendExampleFrame:Clone()
		loadingFrame.Visible = true
		loadingFrame.Name = "LoadingIndicator"
		
		local usernameLabel = loadingFrame:FindFirstChild("UsernameExampleLabel")
		if usernameLabel and usernameLabel:IsA("TextLabel") then
			usernameLabel.Text = "Loading friends..."
		end
		
		local gamemodeLabel = loadingFrame:FindFirstChild("GamemodeExampleLabel")
		if gamemodeLabel and gamemodeLabel:IsA("TextLabel") then
			gamemodeLabel.Text = "Please wait"
		end
		
		local gameTimeLabel = loadingFrame:FindFirstChild("GameTimeExampleLabel")
		if gameTimeLabel and gameTimeLabel:IsA("TextLabel") then
			gameTimeLabel.Text = "..."
		end
		
		-- Hide join button for loading indicator
		local joinButton = loadingFrame:FindFirstChild("JoinPublicExampleButton")
		if joinButton then
			joinButton.Visible = false
		end
		
		loadingFrame.Parent = friendsScrollingFrame
	end
	
	-- Request from server
	RequestFriendsListRemote:FireServer()
end

-- Play button clicked
playButton.MouseButton1Click:Connect(function()
	if playButtonLocked then
		return  -- Ignore clicks during lockout
	end
	
	-- Check if game is active
	local success, gameState = pcall(function()
		return CheckGameStateRemote:InvokeServer()
	end)
	
	if not success then
		warn("[MainMenu] Failed to check game state:", gameState)
		return
	end
	
	-- If game is active, bypass confirmation and join immediately
	if gameState == "IN_GAME" then
		StartGameRemote:FireServer()
		return
	end
	
	-- Only show confirmation for creating new session (LOBBY state)
	if confirmText then
		confirmText.Text = "There is currently no game in session, would you like to start a new one?"
	end
	
	confirmationFrame.Visible = true
end)

-- Confirm button clicked
confirmButton.MouseButton1Click:Connect(function()
	confirmationFrame.Visible = false
	StartGameRemote:FireServer()
end)

-- Cancel button clicked
cancelButton.MouseButton1Click:Connect(function()
	confirmationFrame.Visible = false
end)

-- Listen for game start
GameStartRemote.OnClientEvent:Connect(function()
	hideMenu()
end)

-- Receive friends data
FriendsListUpdateRemote.OnClientEvent:Connect(function(friendsData: {{username: string, gamemode: string?, gameTime: number?, jobId: string?}})
	
	-- Clear loading state
	isLoadingFriends = false
	
	-- Clear timeout
	if loadingTimeout then
		task.cancel(loadingTimeout)
		loadingTimeout = nil
	end
	
	-- Clear existing friend entries (including loading indicator)
	for _, child in ipairs(friendsScrollingFrame:GetChildren()) do
		if child:IsA("Frame") and child ~= friendExampleFrame then
			child:Destroy()
		end
	end
	
	-- Cache the new data
	cachedFriendsData = friendsData
	
	-- Only update UI if we have friends to show
	if #friendsData > 0 then
		
		for _, friendData in ipairs(friendsData) do
			local friendFrame = friendExampleFrame:Clone()
			friendFrame.Visible = true
			friendFrame.Name = friendData.username
			
			-- Set labels
			local usernameLabel = friendFrame:FindFirstChild("UsernameExampleLabel")
			if usernameLabel and usernameLabel:IsA("TextLabel") then
				usernameLabel.Text = friendData.username
			end
			
			local gamemodeLabel = friendFrame:FindFirstChild("GamemodeExampleLabel")
			if gamemodeLabel and gamemodeLabel:IsA("TextLabel") then
				gamemodeLabel.Text = friendData.gamemode or "Normal"
			end
			
			local gameTimeLabel = friendFrame:FindFirstChild("GameTimeExampleLabel")
			if gameTimeLabel and gameTimeLabel:IsA("TextLabel") then
				if friendData.gameTime then
					gameTimeLabel.Text = formatTime(friendData.gameTime)
				else
					gameTimeLabel.Text = "--:--"
				end
			end
			
			-- Join button
			local joinButton = friendFrame:FindFirstChild("JoinPublicExampleButton")
			if joinButton and joinButton:IsA("TextButton") and friendData.jobId then
				joinButton.MouseButton1Click:Connect(function()
					print(string.format("[MainMenu] Attempting to join %s's game", friendData.username))
					local placeId = game.PlaceId
					local success, err = pcall(function()
						TeleportService:TeleportToPlaceInstance(placeId, friendData.jobId, player)
					end)
					if not success then
						warn("[MainMenu] Teleport failed:", err)
					end
				end)
			end
			
			friendFrame.Parent = friendsScrollingFrame
		end
	else
		
		-- Show "no friends" message
		local emptyFrame = friendExampleFrame:Clone()
		emptyFrame.Visible = true
		emptyFrame.Name = "EmptyState"
		
		local usernameLabel = emptyFrame:FindFirstChild("UsernameExampleLabel")
		if usernameLabel and usernameLabel:IsA("TextLabel") then
			usernameLabel.Text = "No friends online"
		end
		
		local gamemodeLabel = emptyFrame:FindFirstChild("GamemodeExampleLabel")
		if gamemodeLabel and gamemodeLabel:IsA("TextLabel") then
			gamemodeLabel.Text = "Try again later"
		end
		
		local gameTimeLabel = emptyFrame:FindFirstChild("GameTimeExampleLabel")
		if gameTimeLabel and gameTimeLabel:IsA("TextLabel") then
			gameTimeLabel.Text = ""
		end
		
		-- Hide join button for empty state
		local joinButton = emptyFrame:FindFirstChild("JoinPublicExampleButton")
		if joinButton then
			joinButton.Visible = false
		end
		
		emptyFrame.Parent = friendsScrollingFrame
	end
end)

-- Private game code handling
if privateGameFrame and codeTextBox and joinPrivateButton then
	-- Make code text box selectable but not editable (for copy)
	codeTextBox.Focused:Connect(function()
		codeTextBox:CaptureFocus()
		codeTextBox.ClearTextOnFocus = false
		-- Select all text for easy copying
		task.wait()
		codeTextBox.CursorPosition = #codeTextBox.Text + 1
		codeTextBox.SelectionStart = 1
	end)
	
	-- Join private game
	joinPrivateButton.MouseButton1Click:Connect(function()
		local code = codeTextBox.Text
		if code and code ~= "" then
			JoinPrivateGameRemote:FireServer(code)
		end
	end)
end

-- Update friends list every 10 seconds
task.spawn(function()
	while true do
		task.wait(10)
		if mainMenuFrame.Visible then
			updateFriendsList()
		end
	end
end)

-- Initial friends list update
task.delay(1, function()
	if mainMenuFrame.Visible then
		updateFriendsList()
	end
end)

-- Listen for wipe cleanup complete to unlock Play button
local WipeCleanupCompleteRemote = remotesFolder:WaitForChild("WipeCleanupComplete") :: RemoteEvent
WipeCleanupCompleteRemote.OnClientEvent:Connect(function()
	-- Re-enable Play button after cleanup
	playButtonLocked = false
	print("[MainMenu] Play button unlocked after wipe cleanup")
end)

-- Listen for TeamWipe to lock Play button
local TeamWipeRemote = remotesFolder:WaitForChild("TeamWipe") :: RemoteEvent
TeamWipeRemote.OnClientEvent:Connect(function()
	-- Lock Play button during wipe sequence
	playButtonLocked = true
	print("[MainMenu] Play button locked during wipe")
end)

-- Show menu initially
showMenu()

