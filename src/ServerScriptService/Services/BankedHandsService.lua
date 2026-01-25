--!strict
-- BankedHandsService - queued level-up choices without pausing gameplay

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BankedHandsService = {}

local world: any
local Components: any
local DirtyService: any
local UpgradeSystem: any
local ExpSystem: any
local PassiveEffectSystem: any

local PlayerStats: any

local remotesFolder: Instance
local bankedFolder: Instance
local BankedHandsUpdate: RemoteEvent
local BankedHandsShow: RemoteEvent
local BankedHandsOpen: RemoteEvent
local BankedHandsSelect: RemoteEvent

local openPlayers: {[Player]: boolean} = setmetatable({}, { __mode = "k" })

local function getPlayerEntityFromPlayer(player: Player): number?
	if not world or not Components then
		return nil
	end
	for entity, stats in world:query(Components.PlayerStats) do
		if stats and stats.player == player then
			return entity
		end
	end
	return nil
end

local function getPlayerFromEntity(playerEntity: number): Player?
	if not world or not Components or not PlayerStats then
		return nil
	end
	local stats = world:get(playerEntity, PlayerStats)
	return stats and stats.player or nil
end

local function getBankedHands(playerEntity: number): {queue: {any}, nextId: number}
	local hands = world:get(playerEntity, Components.BankedHands)
	if not hands then
		hands = {
			queue = {},
			nextId = 1,
		}
		world:set(playerEntity, Components.BankedHands, hands)
		DirtyService.mark(playerEntity, "BankedHands")
	end
	return hands
end

local function sendCount(player: Player?, count: number, added: boolean)
	if player and player.Parent then
		BankedHandsUpdate:FireClient(player, {
			count = count,
			added = added,
		})
	end
end

local function resolveNextHand(playerEntity: number, player: Player?): (any?, {queue: {any}, nextId: number})
	local hands = getBankedHands(playerEntity)
	local changed = false

	while #hands.queue > 0 do
		local hand = hands.queue[1]
		if not hand.choices then
			hand.choices = UpgradeSystem.selectUpgradeChoices(playerEntity, hand.toLevel, 5)
			changed = true
		end
		if hand.choices and #hand.choices > 0 then
			if changed then
				DirtyService.mark(playerEntity, "BankedHands")
			end
			return hand, hands
		end
		table.remove(hands.queue, 1)
		changed = true
	end

	if changed then
		DirtyService.mark(playerEntity, "BankedHands")
		sendCount(player, #hands.queue, false)
	end

	return nil, hands
end

local function sendHand(player: Player?, hand: any, count: number)
	if not player or not player.Parent then
		return
	end
	BankedHandsShow:FireClient(player, {
		handId = hand.id,
		fromLevel = hand.fromLevel,
		toLevel = hand.toLevel,
		choices = hand.choices or {},
		pendingCount = count,
	})
end

function BankedHandsService.init(worldRef: any, components: any, dirtyService: any, upgradeSystemRef: any, expSystemRef: any, passiveEffectSystemRef: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	UpgradeSystem = upgradeSystemRef
	ExpSystem = expSystemRef
	PassiveEffectSystem = passiveEffectSystemRef
	PlayerStats = Components.PlayerStats

	remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	bankedFolder = remotesFolder:FindFirstChild("BankedHands") or Instance.new("Folder")
	bankedFolder.Name = "BankedHands"
	bankedFolder.Parent = remotesFolder

	BankedHandsUpdate = bankedFolder:FindFirstChild("BankedHandsUpdate") :: RemoteEvent
	if not BankedHandsUpdate then
		BankedHandsUpdate = Instance.new("RemoteEvent")
		BankedHandsUpdate.Name = "BankedHandsUpdate"
		BankedHandsUpdate.Parent = bankedFolder
	end

	BankedHandsShow = bankedFolder:FindFirstChild("BankedHandsShow") :: RemoteEvent
	if not BankedHandsShow then
		BankedHandsShow = Instance.new("RemoteEvent")
		BankedHandsShow.Name = "BankedHandsShow"
		BankedHandsShow.Parent = bankedFolder
	end

	BankedHandsOpen = bankedFolder:FindFirstChild("BankedHandsOpen") :: RemoteEvent
	if not BankedHandsOpen then
		BankedHandsOpen = Instance.new("RemoteEvent")
		BankedHandsOpen.Name = "BankedHandsOpen"
		BankedHandsOpen.Parent = bankedFolder
	end

	BankedHandsSelect = bankedFolder:FindFirstChild("BankedHandsSelect") :: RemoteEvent
	if not BankedHandsSelect then
		BankedHandsSelect = Instance.new("RemoteEvent")
		BankedHandsSelect.Name = "BankedHandsSelect"
		BankedHandsSelect.Parent = bankedFolder
	end

	BankedHandsOpen.OnServerEvent:Connect(function(player: Player, data: any)
		local open = data and data.open
		if open == false then
			openPlayers[player] = nil
			return
		end
		openPlayers[player] = true
		local playerEntity = getPlayerEntityFromPlayer(player)
		if not playerEntity then
			return
		end
		local hand, hands = resolveNextHand(playerEntity, player)
		if hand then
			sendHand(player, hand, #hands.queue)
		end
	end)

	BankedHandsSelect.OnServerEvent:Connect(function(player: Player, data: any)
		local playerEntity = getPlayerEntityFromPlayer(player)
		if not playerEntity then
			return
		end
		local hands = getBankedHands(playerEntity)
		if #hands.queue == 0 then
			sendCount(player, 0, false)
			return
		end
		local hand = hands.queue[1]
		if not hand then
			return
		end

		local action = data and data.action
		if action == "skip" then
			table.remove(hands.queue, 1)
			DirtyService.mark(playerEntity, "BankedHands")
			sendCount(player, #hands.queue, false)
			if ExpSystem and ExpSystem.skipLevel then
				ExpSystem.skipLevel(playerEntity, hand.requiredExp)
			end
		elseif action == "upgrade" then
			local upgradeId = data and data.upgradeId
			if not upgradeId then
				return
			end
			local valid = false
			if hand.choices then
				for _, choice in ipairs(hand.choices) do
					if choice and choice.id == upgradeId then
						valid = true
						break
					end
				end
			end
			if not valid then
				return
			end
			local success = UpgradeSystem.applyUpgrade(playerEntity, upgradeId)
			if not success then
				return
			end
			if PassiveEffectSystem and PassiveEffectSystem.applyToPlayer then
				PassiveEffectSystem.applyToPlayer(playerEntity)
			end
			table.remove(hands.queue, 1)
			DirtyService.mark(playerEntity, "BankedHands")
			sendCount(player, #hands.queue, false)
		else
			return
		end

		if openPlayers[player] then
			local nextHand, updated = resolveNextHand(playerEntity, player)
			if nextHand then
				sendHand(player, nextHand, #updated.queue)
			end
		end
	end)
end

function BankedHandsService.enqueueHand(playerEntity: number, fromLevel: number, toLevel: number)
	if not world or not Components then
		return
	end
	local player = getPlayerFromEntity(playerEntity)
	local hands = getBankedHands(playerEntity)
	local nextId = hands.nextId or 1
	hands.nextId = nextId + 1

	local requiredExp = 0
	if ExpSystem and ExpSystem.getExpRequired then
		requiredExp = ExpSystem.getExpRequired(toLevel)
	end

	local hand = {
		id = nextId,
		fromLevel = fromLevel,
		toLevel = toLevel,
		requiredExp = requiredExp,
		choices = nil,
	}
	table.insert(hands.queue, hand)
	DirtyService.mark(playerEntity, "BankedHands")
	sendCount(player, #hands.queue, true)
end

function BankedHandsService.getPendingCount(playerEntity: number): number
	local hands = world:get(playerEntity, Components.BankedHands)
	return hands and hands.queue and #hands.queue or 0
end

return BankedHandsService
