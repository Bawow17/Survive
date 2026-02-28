--!strict
-- IceShardInputController - Manual cast input for IceShard.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local castRequestRemote = remotesFolder:WaitForChild("IceShardCastRequest") :: RemoteEvent
local sprintStateRemote = remotesFolder:WaitForChild("SprintState") :: RemoteEvent

local CAST_KEY = Enum.KeyCode.R
local AIM_RAY_DISTANCE = 5000

local aimRayParams = RaycastParams.new()
aimRayParams.FilterType = Enum.RaycastFilterType.Exclude
aimRayParams.IgnoreWater = true

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

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode ~= CAST_KEY then
		return
	end
	if not canAttemptCast() then
		return
	end

	local targetPoint = buildAimPoint()
	if not targetPoint then
		return
	end

	-- Mirror weapon behavior: casting should immediately drop sprint intent.
	sprintStateRemote:FireServer(false)

	castRequestRemote:FireServer({
		targetPoint = targetPoint,
		clientPressedAt = tick(),
	})
end)
