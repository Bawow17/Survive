--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local DebugModMenuCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DebugModMenuCatalog"))

local DebugModMenuService = {}

local world: any
local Components: any
local UpgradeSystem: any
local GameTimeSystem: any
local DifficultyCoeff: any
local GameSessionTimer: any

local openStateRemote: RemoteEvent
local applyEntryRemote: RemoteEvent
local addSessionTimeRemote: RemoteEvent
local ackRemote: RemoteEvent
local sessionTimerUpdateRemote: RemoteEvent?

local applyCooldowns: {[number]: number} = {}
local timeCooldowns: {[number]: number} = {}

local APPLY_COOLDOWN = 0.1
local TIME_COOLDOWN = 0.25

local CATEGORY_ORDER = DebugModMenuCatalog.CategoryOrder
local CATEGORY_LABELS = DebugModMenuCatalog.CategoryLabels

local function getPlayerEntity(player: Player): number?
	if not world or not Components or not Components.PlayerStats then
		return nil
	end
	for entity, stats in world:query(Components.PlayerStats) do
		if stats and stats.player == player then
			return entity
		end
	end
	return nil
end

local function getModMenuConfig(): any
	local debugCfg = GameOptions.Debug or {}
	return debugCfg.ModMenu or {}
end

local function containsNumber(list: {any}?, value: number): boolean
	if type(list) ~= "table" then
		return false
	end
	for _, item in ipairs(list) do
		if tonumber(item) == value then
			return true
		end
	end
	return false
end

local function containsString(list: {any}?, value: string): boolean
	if type(list) ~= "table" then
		return false
	end
	for _, item in ipairs(list) do
		if tostring(item) == value then
			return true
		end
	end
	return false
end

local function isAllowed(player: Player): boolean
	local cfg = getModMenuConfig()
	if containsNumber(cfg.AllowedUserIds, player.UserId) then
		return true
	end
	if containsString(cfg.AllowedUserNames, player.Name) then
		return true
	end
	if RunService:IsStudio() and cfg.AllowStudioTesters == true then
		return true
	end
	return false
end

local function fireAck(player: Player, ok: boolean, message: string)
	if ackRemote then
		ackRemote:FireClient(player, {
			ok = ok,
			message = message,
		})
	end
end

local function normalizeIconId(iconId: any): string?
	if iconId == nil then
		return nil
	end
	local text = tostring(iconId)
	if text == "" then
		return nil
	end
	if string.match(text, "^%d+$") then
		return "rbxassetid://" .. text
	end
	return text
end

local function buildCatalogPayload(playerEntity: number): {any}
	local entries = UpgradeSystem.getDebugCatalog(playerEntity)
	local payload = {}
	local iconsModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UpgradeIcons"))
	for _, entry in ipairs(entries) do
		local iconId = nil
		if entry.iconKey then
			iconId = iconsModule[entry.iconKey]
		end
		if (not iconId or iconId == "") and entry.category == "attribute" and entry.entryId then
			local _, abilityId = tostring(entry.entryId):match("^(attribute):([^:]+)")
			if abilityId then
				iconId = iconsModule[abilityId]
			end
		end
		table.insert(payload, {
			entryId = tostring(entry.entryId),
			category = tostring(entry.category),
			categoryLabel = CATEGORY_LABELS[entry.category] or tostring(entry.category),
			categoryOrder = CATEGORY_ORDER[entry.category] or 99,
			name = tostring(entry.name or entry.entryId),
			subtitle = tostring(entry.subtitle or ""),
			iconId = normalizeIconId(iconId),
		})
	end
	table.sort(payload, function(a, b)
		if a.categoryOrder ~= b.categoryOrder then
			return a.categoryOrder < b.categoryOrder
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.entryId < b.entryId
	end)
	return payload
end

local function sendOpenState(player: Player)
	local allowed = isAllowed(player)
	local catalog = {}
	if allowed then
		local playerEntity = getPlayerEntity(player)
		if playerEntity then
			catalog = buildCatalogPayload(playerEntity)
		end
	end
	openStateRemote:FireClient(player, {
		allowed = allowed,
		catalog = catalog,
		timeOptions = DebugModMenuCatalog.TimeOptions,
	})
end

local function catalogHasEntry(playerEntity: number, entryId: string): boolean
	local catalog = UpgradeSystem.getDebugCatalog(playerEntity)
	for _, entry in ipairs(catalog) do
		if tostring(entry.entryId) == entryId then
			return true
		end
	end
	return false
end

local function canRunWithCooldown(map: {[number]: number}, player: Player, cooldown: number): boolean
	local now = os.clock()
	local readyAt = map[player.UserId] or 0
	if now < readyAt then
		return false
	end
	map[player.UserId] = now + cooldown
	return true
end

local function onApplyEntry(player: Player, data: any)
	if not isAllowed(player) then
		fireAck(player, false, "Not allowed")
		return
	end
	if not canRunWithCooldown(applyCooldowns, player, APPLY_COOLDOWN) then
		return
	end
	if type(data) ~= "table" or type(data.entryId) ~= "string" then
		fireAck(player, false, "Invalid payload")
		return
	end

	local playerEntity = getPlayerEntity(player)
	if not playerEntity then
		fireAck(player, false, "Player entity missing")
		return
	end

	if not catalogHasEntry(playerEntity, data.entryId) then
		fireAck(player, false, "Entry not available")
		sendOpenState(player)
		return
	end

	local ok = UpgradeSystem.applyDebugEntry(playerEntity, data.entryId)
	if ok then
		fireAck(player, true, "Applied: " .. data.entryId)
		sendOpenState(player)
	else
		fireAck(player, false, "Apply failed: " .. data.entryId)
	end
end

local function onAddSessionTime(player: Player, data: any)
	if not isAllowed(player) then
		fireAck(player, false, "Not allowed")
		return
	end
	if not canRunWithCooldown(timeCooldowns, player, TIME_COOLDOWN) then
		return
	end
	if type(data) ~= "table" or type(data.seconds) ~= "number" then
		fireAck(player, false, "Invalid payload")
		return
	end

	local seconds = math.floor(data.seconds + 0.5)
	if seconds ~= 60 and seconds ~= 300 and seconds ~= 600 then
		fireAck(player, false, "Invalid seconds")
		return
	end

	DifficultyCoeff.addTime(seconds)
	if GameTimeSystem and GameTimeSystem.addTime then
		GameTimeSystem.addTime(seconds)
	end
	GameSessionTimer.addTime(seconds)

	if sessionTimerUpdateRemote then
		sessionTimerUpdateRemote:FireAllClients(GameSessionTimer.getSessionTime())
	end
	local coeff, details = DifficultyCoeff.getCoeff()
	local minutes = (type(details) == "table" and details.timeMinutes) or 0
	fireAck(player, true, string.format("Added +%ds | diff %.2f @ %.1fm", seconds, coeff, minutes))
	sendOpenState(player)
end

function DebugModMenuService.init(worldRef: any, components: any, upgradeSystemRef: any, gameTimeSystemRef: any, difficultyCoeffRef: any, gameSessionTimerRef: any)
	world = worldRef
	Components = components
	UpgradeSystem = upgradeSystemRef
	GameTimeSystem = gameTimeSystemRef
	DifficultyCoeff = difficultyCoeffRef
	GameSessionTimer = gameSessionTimerRef

	local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	local folder = remotesFolder:FindFirstChild("DebugModMenu") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "DebugModMenu"
		folder.Parent = remotesFolder
	end

	openStateRemote = folder:FindFirstChild("OpenState") :: RemoteEvent
	if not openStateRemote then
		openStateRemote = Instance.new("RemoteEvent")
		openStateRemote.Name = "OpenState"
		openStateRemote.Parent = folder
	end

	applyEntryRemote = folder:FindFirstChild("ApplyEntry") :: RemoteEvent
	if not applyEntryRemote then
		applyEntryRemote = Instance.new("RemoteEvent")
		applyEntryRemote.Name = "ApplyEntry"
		applyEntryRemote.Parent = folder
	end

	addSessionTimeRemote = folder:FindFirstChild("AddSessionTime") :: RemoteEvent
	if not addSessionTimeRemote then
		addSessionTimeRemote = Instance.new("RemoteEvent")
		addSessionTimeRemote.Name = "AddSessionTime"
		addSessionTimeRemote.Parent = folder
	end

	ackRemote = folder:FindFirstChild("Ack") :: RemoteEvent
	if not ackRemote then
		ackRemote = Instance.new("RemoteEvent")
		ackRemote.Name = "Ack"
		ackRemote.Parent = folder
	end

	sessionTimerUpdateRemote = remotesFolder:FindFirstChild("SessionTimerUpdate") :: RemoteEvent?

	openStateRemote.OnServerEvent:Connect(function(player: Player, data: any)
		if type(data) == "table" and data.request == true then
			sendOpenState(player)
		end
	end)
	applyEntryRemote.OnServerEvent:Connect(onApplyEntry)
	addSessionTimeRemote.OnServerEvent:Connect(onAddSessionTime)

	Players.PlayerAdded:Connect(function(player: Player)
		task.defer(function()
			sendOpenState(player)
		end)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		task.defer(function()
			sendOpenState(player)
		end)
	end
end

return DebugModMenuService
