--!strict

local Players = game:GetService("Players")

local TixService = {}

local initialized = false
local balancesByPlayer: {[Player]: number} = {}

local function normalizeAmount(amount: number?): number
	if typeof(amount) ~= "number" then
		return 0
	end
	if amount ~= amount or amount == math.huge or amount == -math.huge then
		return 0
	end
	return math.max(0, amount)
end

local function getDisplayAmount(amount: number): number
	return math.max(0, math.floor(amount))
end

local function applyAttribute(player: Player, amount: number)
	player:SetAttribute("Tix", getDisplayAmount(amount))
end

function TixService.ensurePlayer(player: Player)
	if not player then
		return
	end
	if balancesByPlayer[player] == nil then
		balancesByPlayer[player] = 0
	end
	applyAttribute(player, balancesByPlayer[player])
end

function TixService.getTix(player: Player): number
	if not player then
		return 0
	end
	if balancesByPlayer[player] == nil then
		TixService.ensurePlayer(player)
	end
	return getDisplayAmount(balancesByPlayer[player] or 0)
end

function TixService.setTix(player: Player, amount: number)
	if not player then
		return
	end
	local normalized = normalizeAmount(amount)
	balancesByPlayer[player] = normalized
	applyAttribute(player, normalized)
end

function TixService.addTix(player: Player, amount: number): number
	if not player then
		return 0
	end
	if balancesByPlayer[player] == nil then
		TixService.ensurePlayer(player)
	end
	local current = balancesByPlayer[player] or 0
	local nextValue = current + normalizeAmount(amount)
	TixService.setTix(player, nextValue)
	return getDisplayAmount(nextValue)
end

function TixService.resetPlayer(player: Player)
	if not player then
		return
	end
	TixService.setTix(player, 0)
end

function TixService.resetAll()
	for player in pairs(balancesByPlayer) do
		if player and player.Parent == Players then
			TixService.setTix(player, 0)
		else
			balancesByPlayer[player] = nil
		end
	end
end

function TixService.cleanupPlayer(player: Player)
	if not player then
		return
	end
	balancesByPlayer[player] = nil
end

function TixService.init()
	if initialized then
		return
	end
	initialized = true

	Players.PlayerRemoving:Connect(function(player: Player)
		TixService.cleanupPlayer(player)
	end)
end

return TixService
