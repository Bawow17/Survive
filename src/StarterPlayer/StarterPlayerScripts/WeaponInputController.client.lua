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
local DEFAULT_PRIMARY_RANGE = 1000
local WEAPON_MUZZLE_PATH = "OathkeeperModel.Barrel.BarrelEnd"
local DEFAULT_TRACER_LIFETIME = 2.0
local DEFAULT_TRACER_FADE_DURATION = 0.5
local ATTR_WEAPON_RANGE = "StarterWeaponRange"
local ATTR_WEAPON_TRACER_LIFETIME = "StarterWeaponTracerLifetime"
local ATTR_WEAPON_TRACER_FADE_DURATION = "StarterWeaponTracerFadeDuration"

local m1Held = false
local predictedCooldown = DEFAULT_COOLDOWN
local nextLocalFireAt = 0
local humanoid: Humanoid? = nil
local shotSequence = 0

local aimRayParams = RaycastParams.new()
aimRayParams.FilterType = Enum.RaycastFilterType.Exclude
aimRayParams.IgnoreWater = true

local shotRayParams = RaycastParams.new()
shotRayParams.FilterType = Enum.RaycastFilterType.Exclude
shotRayParams.IgnoreWater = true

local function getOrCreatePrimaryShotLocalEvent(): BindableEvent
	local existing = weaponRemotesFolder:FindFirstChild("PrimaryShotLocal")
	if existing and existing:IsA("BindableEvent") then
		return existing
	end
	local created = Instance.new("BindableEvent")
	created.Name = "PrimaryShotLocal"
	created.Parent = weaponRemotesFolder

	local resolved = weaponRemotesFolder:FindFirstChild("PrimaryShotLocal")
	if resolved and resolved:IsA("BindableEvent") then
		if resolved ~= created then
			created:Destroy()
		end
		return resolved
	end
	return created
end

local primaryShotLocalEvent = getOrCreatePrimaryShotLocalEvent()

local function findByPath(root: Instance, path: string): Instance?
	local current: Instance = root
	for _, part in ipairs(string.split(path, ".")) do
		local child = current:FindFirstChild(part)
		if not child then
			return nil
		end
		current = child
	end
	return current
end

local function resolveMuzzleOrigin(character: Model): Vector3?
	local muzzle = findByPath(character, WEAPON_MUZZLE_PATH)
	if not muzzle then
		return nil
	end
	if muzzle:IsA("Attachment") then
		return muzzle.WorldPosition
	end
	if muzzle:IsA("BasePart") then
		return muzzle.Position
	end
	return nil
end

local function readWeaponNumberAttribute(character: Model?, attributeName: string, fallback: number, minValue: number): number
	if not character then
		return fallback
	end
	local raw = character:GetAttribute(attributeName)
	if typeof(raw) == "number" and raw >= minValue then
		return raw
	end
	return fallback
end

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

local function buildPredictedShot(aimPoint: Vector3): (Vector3?, Vector3?, Vector3?)
	local character = localPlayer.Character
	if not character then
		return nil, nil, nil
	end

	local origin = resolveMuzzleOrigin(character)
	if not origin then
		return nil, nil, nil
	end

	shotRayParams.FilterDescendantsInstances = { character }

	local direction = aimPoint - origin
	if direction.Magnitude <= 1e-4 then
		local camera = Workspace.CurrentCamera
		if camera then
			direction = camera.CFrame.LookVector
		else
			direction = Vector3.new(0, 0, -1)
		end
	end
	direction = direction.Unit

	local rayDistance = readWeaponNumberAttribute(character, ATTR_WEAPON_RANGE, DEFAULT_PRIMARY_RANGE, 1)
	local result = Workspace:Raycast(origin, direction * rayDistance, shotRayParams)
	if result then
		return origin, result.Position, result.Normal
	end
	return origin, origin + (direction * rayDistance), -direction
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

	shotSequence += 1
	local clientShotId = shotSequence

	primaryFireRequestRemote:FireServer({
		targetPoint = aimPoint,
		clientShotId = clientShotId,
	})

	local predictedOrigin, predictedImpact, predictedNormal = buildPredictedShot(aimPoint)
	if predictedOrigin and predictedImpact and predictedNormal then
		local character = localPlayer.Character
		local tracerLifetime = readWeaponNumberAttribute(character, ATTR_WEAPON_TRACER_LIFETIME, DEFAULT_TRACER_LIFETIME, 0)
		local tracerFadeDuration = readWeaponNumberAttribute(character, ATTR_WEAPON_TRACER_FADE_DURATION, DEFAULT_TRACER_FADE_DURATION, 0)
		primaryShotLocalEvent:Fire({
			shooterUserId = localPlayer.UserId,
			weaponId = WEAPON_ID,
			clientShotId = clientShotId,
			origin = predictedOrigin,
			impactPosition = predictedImpact,
			impactNormal = predictedNormal,
			tracerLifetime = tracerLifetime,
			tracerFadeDuration = tracerFadeDuration,
			predicted = true,
		})
	end

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
