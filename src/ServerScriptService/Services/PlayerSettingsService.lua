--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local PlayerSettingsSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerSettingsSchema"))
type SettingsV1 = PlayerSettingsSchema.SettingsV1

local PlayerSettingsService = {}

local SETTINGS_STORE_NAME = "PlayerSettings_v1"
local UPDATE_COOLDOWN_SECONDS = 0.1
local SAVE_DEBOUNCE_SECONDS = 5.0
local MIN_SAVE_INTERVAL_SECONDS = 10.0

local settingsStore = DataStoreService:GetDataStore(SETTINGS_STORE_NAME)
local initialized = false

local settingsByUserId: {[number]: SettingsV1} = {}
local dirtyByUserId: {[number]: boolean} = {}
local updateReadyAtByUserId: {[number]: number} = {}
local lastSaveAtByUserId: {[number]: number} = {}
local pendingSaveTaskByUserId: {[number]: thread} = {}

local GetSettingsRemote: RemoteFunction
local UpdateSettingsRemote: RemoteEvent
local SettingsChangedRemote: RemoteEvent

local function getStoreKey(userId: number): string
	return "u_" .. tostring(userId)
end

local function jsonSafeEncode(value: any): string?
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(value)
	end)
	return if ok then encoded else nil
end

local function settingsChanged(before: SettingsV1, after: SettingsV1): boolean
	local encodedBefore = jsonSafeEncode(before)
	local encodedAfter = jsonSafeEncode(after)
	if encodedBefore and encodedAfter then
		return encodedBefore ~= encodedAfter
	end
	return true
end

local function getCachedOrDefault(userId: number): SettingsV1
	local cached = settingsByUserId[userId]
	if cached then
		return PlayerSettingsSchema.sanitize(cached)
	end
	return PlayerSettingsSchema.createDefault()
end

local function fireSettingsChanged(player: Player, settings: SettingsV1)
	if SettingsChangedRemote then
		SettingsChangedRemote:FireClient(player, settings)
	end
end

local function clearPendingSave(userId: number)
	local existing = pendingSaveTaskByUserId[userId]
	if existing then
		task.cancel(existing)
		pendingSaveTaskByUserId[userId] = nil
	end
end

local function saveForUserId(userId: number): boolean
	local settings = settingsByUserId[userId]
	if not settings then
		dirtyByUserId[userId] = nil
		return true
	end
	if not dirtyByUserId[userId] then
		return true
	end

	local payload = PlayerSettingsSchema.sanitize(settings)
	local ok, err = pcall(function()
		settingsStore:SetAsync(getStoreKey(userId), payload)
	end)
	if not ok then
		warn(string.format("[PlayerSettingsService] Save failed for userId=%d: %s", userId, tostring(err)))
		return false
	end

	dirtyByUserId[userId] = false
	lastSaveAtByUserId[userId] = os.clock()
	return true
end

local function scheduleSave(userId: number, delaySeconds: number?)
	clearPendingSave(userId)

	local targetDelay = delaySeconds or SAVE_DEBOUNCE_SECONDS
	pendingSaveTaskByUserId[userId] = task.delay(targetDelay, function()
		pendingSaveTaskByUserId[userId] = nil

		if not dirtyByUserId[userId] then
			return
		end

		local now = os.clock()
		local lastSaveAt = lastSaveAtByUserId[userId] or 0
		local elapsed = now - lastSaveAt
		if elapsed < MIN_SAVE_INTERVAL_SECONDS then
			scheduleSave(userId, MIN_SAVE_INTERVAL_SECONDS - elapsed)
			return
		end

		if not saveForUserId(userId) then
			scheduleSave(userId, MIN_SAVE_INTERVAL_SECONDS)
		end
	end)
end

local function flushSave(userId: number)
	clearPendingSave(userId)
	saveForUserId(userId)
end

local function loadSettingsForPlayer(player: Player)
	local loaded: any = nil
	local ok, err = pcall(function()
		loaded = settingsStore:GetAsync(getStoreKey(player.UserId))
	end)
	if not ok then
		warn(string.format("[PlayerSettingsService] Load failed for %s (%d): %s", player.Name, player.UserId, tostring(err)))
	end

	local sanitized = PlayerSettingsSchema.sanitize(loaded)
	settingsByUserId[player.UserId] = sanitized
	dirtyByUserId[player.UserId] = false
	fireSettingsChanged(player, sanitized)
end

local function onUpdateSettings(player: Player, patch: any)
	if typeof(patch) ~= "table" then
		return
	end

	local userId = player.UserId
	local now = os.clock()
	local readyAt = updateReadyAtByUserId[userId] or 0
	if now < readyAt then
		return
	end
	updateReadyAtByUserId[userId] = now + UPDATE_COOLDOWN_SECONDS

	local current = getCachedOrDefault(userId)
	local merged = PlayerSettingsSchema.mergeAndSanitize(current, patch)
	if not settingsChanged(current, merged) then
		return
	end

	settingsByUserId[userId] = merged
	dirtyByUserId[userId] = true
	fireSettingsChanged(player, merged)
	scheduleSave(userId)
end

local function ensureRemoteFolder(): Folder
	local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	local settingsFolder = remotesFolder:FindFirstChild("PlayerSettings")
	if settingsFolder and settingsFolder:IsA("Folder") then
		return settingsFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "PlayerSettings"
	folder.Parent = remotesFolder
	return folder
end

local function ensureGetSettingsRemote(settingsFolder: Folder): RemoteFunction
	local existing = settingsFolder:FindFirstChild("GetSettings")
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	local remote = Instance.new("RemoteFunction")
	remote.Name = "GetSettings"
	remote.Parent = settingsFolder
	return remote
end

local function ensureUpdateSettingsRemote(settingsFolder: Folder): RemoteEvent
	local existing = settingsFolder:FindFirstChild("UpdateSettings")
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = "UpdateSettings"
	remote.Parent = settingsFolder
	return remote
end

local function ensureSettingsChangedRemote(settingsFolder: Folder): RemoteEvent
	local existing = settingsFolder:FindFirstChild("SettingsChanged")
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = "SettingsChanged"
	remote.Parent = settingsFolder
	return remote
end

function PlayerSettingsService.getSettings(player: Player): SettingsV1
	return getCachedOrDefault(player.UserId)
end

function PlayerSettingsService.init()
	if initialized then
		return
	end
	initialized = true

	local settingsFolder = ensureRemoteFolder()
	GetSettingsRemote = ensureGetSettingsRemote(settingsFolder)
	UpdateSettingsRemote = ensureUpdateSettingsRemote(settingsFolder)
	SettingsChangedRemote = ensureSettingsChangedRemote(settingsFolder)

	GetSettingsRemote.OnServerInvoke = function(player: Player)
		return getCachedOrDefault(player.UserId)
	end

	UpdateSettingsRemote.OnServerEvent:Connect(onUpdateSettings)

	Players.PlayerAdded:Connect(function(player: Player)
		loadSettingsForPlayer(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		local userId = player.UserId
		flushSave(userId)
		settingsByUserId[userId] = nil
		dirtyByUserId[userId] = nil
		updateReadyAtByUserId[userId] = nil
		lastSaveAtByUserId[userId] = nil
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		task.defer(function()
			loadSettingsForPlayer(player)
		end)
	end

	game:BindToClose(function()
		for userId, _ in pairs(settingsByUserId) do
			flushSave(userId)
		end
	end)
end

return PlayerSettingsService
