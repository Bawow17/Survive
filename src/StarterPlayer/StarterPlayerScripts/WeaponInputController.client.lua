--!strict
-- WeaponInputController - sends held-M1 primary fire requests for the starter weapon.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local weaponRemotesFolder = remotesFolder:WaitForChild("Weapons")
local primaryFireRequestRemote = weaponRemotesFolder:WaitForChild("PrimaryFireRequest")
local primaryShotRemote = weaponRemotesFolder:WaitForChild("PrimaryShot")

local WEAPON_ID = "Oathkeeper"
local DEFAULT_COOLDOWN = 1.2
local AIM_RAY_DISTANCE = 5000

local m1Held = false
local predictedCooldown = DEFAULT_COOLDOWN
local nextLocalFireAt = 0
local humanoid: Humanoid? = nil

local aimRayParams = RaycastParams.new()
aimRayParams.FilterType = Enum.RaycastFilterType.Exclude
aimRayParams.IgnoreWater = true

local function bindCharacter(character: Model?)
	humanoid = nil
	if not character then
		return
	end
	local foundHumanoid = character:FindFirstChildOfClass("Humanoid")
	if foundHumanoid then
		humanoid = foundHumanoid
	end
end

local function canAttemptFire(): boolean
	if localPlayer:GetAttribute("CooldownsFrozen") == true then
		return false
	end
	if GuiService.MenuIsOpen then
		return false
	end
	if UserInputService:GetFocusedTextBox() then
		return false
	end
	local character = localPlayer.Character
	if not character or character:GetAttribute("StarterWeaponId") ~= WEAPON_ID then
		return false
	end
	local humanoidRef = humanoid
	if not humanoidRef or humanoidRef.Health <= 0.01 then
		return false
	end
	return true
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

local function attemptFire()
	local now = tick()
	if now < nextLocalFireAt then
		return
	end
	if not canAttemptFire() then
		return
	end
	local aimPoint = buildAimPoint()
	if not aimPoint then
		return
	end

	primaryFireRequestRemote:FireServer(aimPoint)
	nextLocalFireAt = now + predictedCooldown
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end
	if gameProcessed then
		return
	end
	m1Held = true
	attemptFire()
end)

UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end
	m1Held = false
end)

primaryShotRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.weaponId ~= WEAPON_ID or payload.shooterUserId ~= localPlayer.UserId then
		return
	end
	if typeof(payload.effectiveCooldown) == "number" and payload.effectiveCooldown > 0 then
		predictedCooldown = payload.effectiveCooldown
		nextLocalFireAt = tick() + predictedCooldown
	end
end)

RunService.RenderStepped:Connect(function()
	if m1Held then
		attemptFire()
	end
end)

localPlayer.CharacterAdded:Connect(bindCharacter)
localPlayer.CharacterRemoving:Connect(function()
	m1Held = false
	bindCharacter(nil)
end)

if localPlayer.Character then
	bindCharacter(localPlayer.Character)
end
