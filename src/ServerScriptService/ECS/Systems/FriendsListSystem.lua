--!strict
-- FriendsListSystem - Server-side friends list management with cross-server support
--
-- IMPLEMENTATION: Shows friends across ALL servers using DataStoreService
-- - Broadcasts server player list every 20 seconds
-- - Queries all active servers for friends
-- - 20-second update delay (acceptable for social features)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")

local FriendsListSystem = {}

local remotesFolder: Folder
local RequestFriendsListRemote: RemoteEvent
local FriendsListUpdateRemote: RemoteEvent

-- DataStores
local ServerPlayersStore = DataStoreService:GetDataStore("ServerPlayers")
local ServerListMap = MemoryStoreService:GetSortedMap("ActiveServers")

-- Server ID (use JobId in production, generate unique ID for Studio)
local SERVER_ID = game.JobId ~= "" and game.JobId or HttpService:GenerateGUID(false)

-- Broadcasting - Very frequent for consistent cross-server detection
local BROADCAST_INTERVAL = 10  -- Broadcast every 10 seconds (very frequent)
local broadcastAccumulator = 0

-- DataStore throttling - Less conservative for better responsiveness
local lastBroadcastOperation = 0
local lastHeartbeatOperation = 0
local lastQueryOperation = 0
local DATASTORE_COOLDOWN = 2  -- 2 seconds between DataStore operations (more responsive)

-- Friends list request throttling
local lastFriendsListRequest = 0
local FRIENDS_LIST_COOLDOWN = 3  -- 3 seconds between friends list requests per player (very fast)

-- Session cache for cross-server data
local cachedServerData = {}
local lastCacheUpdate = 0
local CACHE_DURATION = 3  -- Cache cross-server data for 3 seconds (extremely frequent updates)

-- Forward declaration
local handleFriendsListRequest: (player: Player) -> ()
local getAllActiveServers: (forceRefresh: boolean?) -> {{JobId: string, PlayerData: any, PlayerCount: number}}

-- Track active players and their game data
local activePlayersData: {[number]: {username: string, gameTime: number, jobId: string}} = {}

-- Track friends list request count for periodic refresh
local friendsListRequestCount = 0

-- Publish this server's player list to DataStore
local function broadcastServerPlayers()
	-- Throttle DataStore operations
	local now = tick()
	if now - lastBroadcastOperation < DATASTORE_COOLDOWN then
		return
	end
	lastBroadcastOperation = now
	
	local playerList = {}
	
	-- Build array of player data objects (ID + username + gameTime)
	for userId, data in pairs(activePlayersData) do
		table.insert(playerList, {
			UserId = tonumber(userId),
			Username = data.username,
			GameTime = data.gameTime
		})
	end
	
	-- MUST use JSON encoding for DataStore compatibility
	local jsonString = HttpService:JSONEncode(playerList)
	
	local success, err = pcall(function()
		-- Try without TTL first to see if that's the issue
		ServerPlayersStore:SetAsync(SERVER_ID, jsonString)
	end)
	
	if not success then
		warn("[FriendsListSystem] Failed to broadcast server data:", err)
	end
end

-- Update server heartbeat in MemoryStore
local function updateServerHeartbeat()
	-- Throttle DataStore operations
	local now = tick()
	if now - lastHeartbeatOperation < DATASTORE_COOLDOWN then
		return
	end
	lastHeartbeatOperation = now
	
	local currentTime = os.time()
	
	local success, err = pcall(function()
		-- Store with 300 second TTL (5 minutes - longer to prevent premature expiration)
		ServerListMap:SetAsync(SERVER_ID, currentTime, 300)
	end)
	
	if not success then
		warn("[FriendsListSystem] Failed to update heartbeat:", err)
	end
end

-- Get all active servers from DataStore with caching
getAllActiveServers = function(forceRefresh: boolean?)
	-- Check cache first (unless force refresh is requested)
	local now = tick()
	if not forceRefresh and now - lastCacheUpdate < CACHE_DURATION and #cachedServerData > 0 then
		return cachedServerData
	end
	
	local servers = {}
	
	-- Throttle DataStore operations
	if now - lastQueryOperation < DATASTORE_COOLDOWN then
		return cachedServerData  -- Return cached data if available
	end
	lastQueryOperation = now
	
	-- Get active servers from MemoryStore
	
	local success, entries = pcall(function()
		return ServerListMap:GetRangeAsync(Enum.SortDirection.Ascending, 50)
	end)
	
	if not success then
		warn("[FriendsListSystem] Failed to get server list from MemoryStore:", entries)
		return cachedServerData
	end
	
	local currentTime = os.time()
	
	for _, entry in ipairs(entries) do
		local jobId = entry.key
		local lastUpdate = entry.value
		local age = currentTime - lastUpdate
		
		-- Skip current server, get player data for others
		if jobId ~= SERVER_ID then
			if age < 120 then  -- More lenient - accept servers up to 2 minutes old
				local serverSuccess, serverData = pcall(function()
					return ServerPlayersStore:GetAsync(jobId)
				end)
			
			if serverSuccess and serverData then
				-- MUST use JSON decoding for DataStore compatibility
				local decodeSuccess, playerData = pcall(function()
					return HttpService:JSONDecode(serverData)
				end)
				
				if decodeSuccess and playerData and type(playerData) == "table" then
					local playerCount = #playerData
					table.insert(servers, {
						JobId = jobId,
						PlayerData = playerData,  -- Store full player data instead of just IDs
						PlayerCount = playerCount,
					})
				else
					warn(string.format("[FriendsListSystem] Failed to decode JSON for server %s", jobId:sub(1, 8)))
				end
			else
				warn(string.format("[FriendsListSystem] Failed to get data for server %s", jobId:sub(1, 8)))
			end
			end
		end
	end
	
	-- Update cache
	cachedServerData = servers
	lastCacheUpdate = now
	
	return servers
end

-- Define handler function before init
handleFriendsListRequest = function(player: Player)
	-- Throttle friends list requests
	local now = tick()
	if now - lastFriendsListRequest < FRIENDS_LIST_COOLDOWN then
		return
	end
	lastFriendsListRequest = now
	
	-- Build friends list data - query ALL servers
	local friendsData = {}
	
	-- Get player's friends list
	local success, friendPages = pcall(function()
		return Players:GetFriendsAsync(player.UserId)
	end)
	
	if not success then
		warn(string.format("[FriendsListSystem] Failed to get friends for %s", player.Name))
		FriendsListUpdateRemote:FireClient(player, {})
		return
	end
	
	-- Build friend UserId lookup (up to 200 friends)
	local friendUserIds = {}
	local count = 0
	while count < 200 do
		local friends = friendPages:GetCurrentPage()
		for _, friendInfo in ipairs(friends) do
			friendUserIds[friendInfo.Id] = friendInfo.Username
			count = count + 1
			if count >= 200 then
				break
			end
		end
		if friendPages.IsFinished or count >= 200 then
			break
		end
		
		pcall(function()
			friendPages:AdvanceToNextPageAsync()
		end)
	end
	
	-- Check current server first (instant, no DataStore query needed)
	local friendsInCurrentServer = 0
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= player and friendUserIds[otherPlayer.UserId] then
			local playerData = activePlayersData[otherPlayer.UserId]
			table.insert(friendsData, {
				username = otherPlayer.Name,
				gamemode = "Normal",
				gameTime = playerData and playerData.gameTime or 0,
				jobId = SERVER_ID,
			})
			friendsInCurrentServer = friendsInCurrentServer + 1
		end
	end
	
	-- Query ALL active servers from DataStore (force refresh every 2nd request)
	friendsListRequestCount = friendsListRequestCount + 1
	local forceRefresh = (friendsListRequestCount % 2 == 0)  -- Force refresh every 2nd request
	local activeServers = getAllActiveServers(forceRefresh)
	local friendsInOtherServers = 0
	
	for _, serverData in ipairs(activeServers) do
		if serverData.JobId ~= SERVER_ID then  -- Skip current server (already checked)
			for _, playerInfo in ipairs(serverData.PlayerData) do
				local userId = playerInfo.UserId
				-- Check if this user ID is a friend
				if friendUserIds[userId] then
					-- Get username from friends list (friendUserIds contains the actual usernames)
					local username = friendUserIds[userId]
					local gameTime = playerInfo.GameTime or 0
					table.insert(friendsData, {
						username = username,
						gamemode = "Normal",
						gameTime = gameTime,  -- Now we have actual game time from other servers!
						jobId = serverData.JobId,
					})
					friendsInOtherServers = friendsInOtherServers + 1
				end
			end
		end
	end
	
	FriendsListUpdateRemote:FireClient(player, friendsData)
end

function FriendsListSystem.init()
	remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	
	-- Create remotes if they don't exist
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
	
	-- Connect handler
	RequestFriendsListRemote.OnServerEvent:Connect(handleFriendsListRequest)
	
	-- Track players joining/leaving
	Players.PlayerAdded:Connect(function(player)
		activePlayersData[player.UserId] = {
			username = player.Name,
			gameTime = 0,
			jobId = SERVER_ID,
		}
	end)
	
	Players.PlayerRemoving:Connect(function(player)
		activePlayersData[player.UserId] = nil
	end)
	
	-- Cleanup on server close
	game:BindToClose(function()
		-- Remove from MemoryStore (auto-expires anyway)
		pcall(function()
			ServerListMap:RemoveAsync(SERVER_ID)
		end)
		
		-- Remove player data from DataStore
		pcall(function()
			ServerPlayersStore:RemoveAsync(SERVER_ID)
		end)
	end)
end

-- Step function - updates game time and broadcasts server data
function FriendsListSystem.step(dt: number)
	-- Update game time for all players
	for userId, data in pairs(activePlayersData) do
		data.gameTime = data.gameTime + dt
	end
	
	-- Broadcast server data every 60 seconds
	broadcastAccumulator = broadcastAccumulator + dt
	
	if broadcastAccumulator >= BROADCAST_INTERVAL then
		broadcastAccumulator = 0
		broadcastServerPlayers()
		updateServerHeartbeat()
	end
end

return FriendsListSystem

