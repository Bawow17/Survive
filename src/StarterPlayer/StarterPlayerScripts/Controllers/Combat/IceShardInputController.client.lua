--!strict
-- IceShardInputController - Manual cast input for IceShard.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local castRequestRemote = remotesFolder:WaitForChild("IceShardCastRequest") :: RemoteEvent
local abilityCastRemote = remotesFolder:WaitForChild("AbilityCast") :: RemoteEvent
local sprintStateRemote = remotesFolder:WaitForChild("SprintState") :: RemoteEvent

local CAST_KEY = Enum.KeyCode.R
local AIM_RAY_DISTANCE = 5000
local ICE_SHARD_ID = "IceShard"
local ATTR_ULTIMATE_BUFFER_ACTIVE = "UltimateBufferActiveLocal"
local ATTR_EQUIPMENT_BUFFER_ACTIVE = "EquipmentBufferActiveLocal" -- Reserved for future Q equipment input.
local ATTR_MOBILITY_BUFFER_ACTIVE = "MobilityBufferActiveLocal"
local ATTR_ICESHARD_BUFFER_ACTIVE = "IceShardBufferActiveLocal"

local castHeld = false
local pendingBufferedCast = false
local localCooldownEnd = 0
local isLocallyReadyToCast: () -> boolean

local aimRayParams = RaycastParams.new()
aimRayParams.FilterType = Enum.RaycastFilterType.Exclude
aimRayParams.IgnoreWater = true

local function refreshBufferAttribute()
	local isBuffered = pendingBufferedCast or castHeld
	local isActive = isBuffered and isLocallyReadyToCast()
	localPlayer:SetAttribute(ATTR_ICESHARD_BUFFER_ACTIVE, isActive)
end

local function hasHigherPriorityBufferedAction(): boolean
	return localPlayer:GetAttribute(ATTR_ULTIMATE_BUFFER_ACTIVE) == true
		or localPlayer:GetAttribute(ATTR_EQUIPMENT_BUFFER_ACTIVE) == true
		or localPlayer:GetAttribute(ATTR_MOBILITY_BUFFER_ACTIVE) == true
end

local function buildAimPoint(): Vector3?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	local character = localPlayer.Character
	if character then
		aimRayParams.FilterDescendantsInstances = { character }
	else
		aimRayParams.FilterDescendantsInstances = {}
	end

	local mousePosition = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
	local rayDirection = ray.Direction.Unit * AIM_RAY_DISTANCE
	local result = Workspace:Raycast(ray.Origin, rayDirection, aimRayParams)
	if result then
		return result.Position
	end
	return ray.Origin + rayDirection
end

local function canAttemptCast(): boolean
	if GuiService.MenuIsOpen then
		return false
	end
	if UserInputService:GetFocusedTextBox() then
		return false
	end
	if localPlayer:GetAttribute("CooldownsFrozen") == true then
		return false
	end

	local character = localPlayer.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0.01 then
		return false
	end

	return true
end

function isLocallyReadyToCast(): boolean
	return tick() >= localCooldownEnd and canAttemptCast()
end

local function canRetainBufferedCast(): boolean
	if not castHeld then
		return false
	end
	return canAttemptCast()
end

local function attemptCast(): boolean
	if hasHigherPriorityBufferedAction() then
		return false
	end
	if not isLocallyReadyToCast() then
		return false
	end

	local targetPoint = buildAimPoint()
	if not targetPoint then
		return false
	end

	-- Mirror weapon behavior: casting should immediately drop sprint intent.
	sprintStateRemote:FireServer(false)

	pendingBufferedCast = false
	refreshBufferAttribute()

	castRequestRemote:FireServer({
		targetPoint = targetPoint,
		clientPressedAt = tick(),
	})
	return true
end

local function processBufferedCast()
	if not pendingBufferedCast then
		return
	end
	if attemptCast() then
		return
	end
	if not canRetainBufferedCast() then
		pendingBufferedCast = false
		refreshBufferAttribute()
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode ~= CAST_KEY then
		return
	end
	castHeld = true
	pendingBufferedCast = true
	refreshBufferAttribute()
	processBufferedCast()
end)

UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
	if input.KeyCode ~= CAST_KEY then
		return
	end
	castHeld = false
	pendingBufferedCast = false
	refreshBufferAttribute()
end)

abilityCastRemote.OnClientEvent:Connect(function(abilityId: string, cooldownDuration: number)
	if abilityId ~= ICE_SHARD_ID then
		return
	end
	if typeof(cooldownDuration) ~= "number" or cooldownDuration <= 0 then
		return
	end
	localCooldownEnd = tick() + cooldownDuration
end)

RunService.RenderStepped:Connect(function()
	refreshBufferAttribute()
	if castHeld and (not pendingBufferedCast) then
		pendingBufferedCast = true
		refreshBufferAttribute()
	end
	if pendingBufferedCast then
		processBufferedCast()
	end
end)

localPlayer.CharacterRemoving:Connect(function()
	castHeld = false
	pendingBufferedCast = false
	refreshBufferAttribute()
end)

refreshBufferAttribute()
