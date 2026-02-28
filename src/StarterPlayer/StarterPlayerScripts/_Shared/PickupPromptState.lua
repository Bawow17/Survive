--!strict

local PickupPromptState = {}

export type PromptData = {
	pickupId: number,
	itemId: string,
	displayName: string?,
	description: string?,
	nameColorHex: string?,
	distance: number,
	canPickup: boolean,
}

local changedEvent = Instance.new("BindableEvent")
local currentPrompt: PromptData? = nil

local function promptEquals(a: PromptData?, b: PromptData?): boolean
	if a == b then
		return true
	end
	if a == nil or b == nil then
		return false
	end
	return a.pickupId == b.pickupId
		and a.itemId == b.itemId
		and a.displayName == b.displayName
		and a.description == b.description
		and a.nameColorHex == b.nameColorHex
		and math.abs(a.distance - b.distance) <= 0.05
		and a.canPickup == b.canPickup
end

function PickupPromptState.setPrompt(nextPrompt: PromptData?)
	if promptEquals(currentPrompt, nextPrompt) then
		return
	end
	currentPrompt = nextPrompt
	changedEvent:Fire(currentPrompt)
end

function PickupPromptState.getPrompt(): PromptData?
	return currentPrompt
end

function PickupPromptState.getChangedEvent(): RBXScriptSignal
	return changedEvent.Event
end

return PickupPromptState
