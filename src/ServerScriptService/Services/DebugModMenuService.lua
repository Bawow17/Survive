--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local RunItems = require(game.ServerScriptService.Balance.RunItems)
local DebugModMenuCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DebugModMenuCatalog"))
local UltimateSystem = require(game.ServerScriptService.ECS.Systems.UltimateSystem)

local DebugModMenuService = {}

local world: any
local Components: any
local GameTimeSystem: any
local DifficultyCoeff: any
local GameSessionTimer: any
local ItemSystem: any

local openStateRemote: RemoteEvent
local applyEntryRemote: RemoteEvent
local addSessionTimeRemote: RemoteEvent
local ackRemote: RemoteEvent
local sessionTimerUpdateRemote: RemoteEvent?

local applyCooldowns: {[number]: number} = {}
local timeCooldowns: {[number]: number} = {}

local APPLY_COOLDOWN = 0.1
local TIME_COOLDOWN = 0.25
local ULTIMATE_MAX_CHARGE_ENTRY_ID = "ultimate:max_charge"
local CLEAR_ITEMS_ENTRY_ID = "items:clear_all"

local function ensureRemoteEvent(parent: Instance, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing then
		if existing:IsA("RemoteEvent") then
			return existing
		end
		existing:Destroy()
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
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

local function sendOpenState(player: Player)
	local allowed = isAllowed(player)
	local catalog = {
		{
			entryId = ULTIMATE_MAX_CHARGE_ENTRY_ID,
			category = "ultimate",
			categoryLabel = "Ultimate",
			categoryOrder = DebugModMenuCatalog.CategoryOrder.ultimate or 2,
			name = "Fill Ultimate",
			subtitle = "Set ultimate charge to max",
			iconId = nil,
		},
	}
	for _, itemDef in ipairs(RunItems.getOrderedDefinitions()) do
		table.insert(catalog, {
			entryId = itemDef.entryId,
			category = "items",
			categoryLabel = DebugModMenuCatalog.CategoryLabels.items or "Items",
			categoryOrder = DebugModMenuCatalog.CategoryOrder.items or 2,
			name = itemDef.displayName,
			subtitle = itemDef.description,
			iconId = nil,
		})
	end
	table.insert(catalog, {
		entryId = CLEAR_ITEMS_ENTRY_ID,
		category = "items",
		categoryLabel = DebugModMenuCatalog.CategoryLabels.items or "Items",
		categoryOrder = DebugModMenuCatalog.CategoryOrder.items or 2,
		sortRank = 999999,
		name = "Clear Items",
		subtitle = "Remove all current run items",
		iconId = nil,
	})
	openStateRemote:FireClient(player, {
		allowed = allowed,
		catalog = if allowed then catalog else {},
		timeOptions = DebugModMenuCatalog.TimeOptions,
	})
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

local function onApplyEntry(player: Player, _data: any)
	if not isAllowed(player) then
		fireAck(player, false, "Not allowed")
		return
	end
	if not canRunWithCooldown(applyCooldowns, player, APPLY_COOLDOWN) then
		return
	end

	if type(_data) ~= "table" or type(_data.entryId) ~= "string" then
		fireAck(player, false, "Invalid payload")
		return
	end

	if _data.entryId ~= ULTIMATE_MAX_CHARGE_ENTRY_ID then
		if _data.entryId == CLEAR_ITEMS_ENTRY_ID then
			if not ItemSystem or not ItemSystem.clearDebugItemsForPlayer then
				fireAck(player, false, "ItemSystem unavailable")
				sendOpenState(player)
				return
			end
			local ok, message = ItemSystem.clearDebugItemsForPlayer(player)
			fireAck(player, ok, message)
			sendOpenState(player)
			return
		end

		local isItemEntry = string.sub(_data.entryId, 1, 5) == "item:"
		if isItemEntry then
			if not ItemSystem or not ItemSystem.spawnDebugDropForPlayer then
				fireAck(player, false, "ItemSystem unavailable")
				sendOpenState(player)
				return
			end
			local itemId = string.sub(_data.entryId, 6)
			local ok, message = ItemSystem.spawnDebugDropForPlayer(player, itemId)
			fireAck(player, ok, message)
			sendOpenState(player)
			return
		end

		fireAck(player, false, "Entry disabled")
		sendOpenState(player)
		return
	end

	local playerEntity = getPlayerEntity(player)
	if not playerEntity then
		fireAck(player, false, "Player entity missing")
		return
	end

	local ok = UltimateSystem.debugSetMaxCharge(playerEntity)
	if ok then
		fireAck(player, true, "Ultimate charge set to max")
	else
		fireAck(player, false, "Failed to set ultimate charge")
	end
	sendOpenState(player)
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

function DebugModMenuService.init(worldRef: any, components: any, gameTimeSystemRef: any, difficultyCoeffRef: any, gameSessionTimerRef: any, itemSystemRef: any?)
	world = worldRef
	Components = components
	GameTimeSystem = gameTimeSystemRef
	DifficultyCoeff = difficultyCoeffRef
	GameSessionTimer = gameSessionTimerRef
	ItemSystem = itemSystemRef

	local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	local folder = remotesFolder:FindFirstChild("DebugModMenu") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "DebugModMenu"
		folder.Parent = remotesFolder
	end

	openStateRemote = ensureRemoteEvent(folder, "OpenState")
	applyEntryRemote = ensureRemoteEvent(folder, "ApplyEntry")
	addSessionTimeRemote = ensureRemoteEvent(folder, "AddSessionTime")
	ackRemote = ensureRemoteEvent(folder, "Ack")

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

function DebugModMenuService.setItemSystem(itemSystemRef: any)
	ItemSystem = itemSystemRef
end

return DebugModMenuService
