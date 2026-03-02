--!strict
-- WeaponInputController - handles Oathkeeper M1 hold-fire and M2 charged cast requests.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local weaponRemotesFolder = remotesFolder:WaitForChild("Weapons")
local timeStopStateRemote = remotesFolder:WaitForChild("TimeStopState")
local primaryFireRequestRemote = weaponRemotesFolder:WaitForChild("PrimaryFireRequest")
local primaryFireReleaseRemote = weaponRemotesFolder:WaitForChild("PrimaryFireRelease")
local primaryShotRemote = weaponRemotesFolder:WaitForChild("PrimaryShot")
local secondaryFireRequestRemote = weaponRemotesFolder:WaitForChild("SecondaryFireRequest")
local secondaryShotRemote = weaponRemotesFolder:WaitForChild("SecondaryShot")
local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
if not playerScripts then
	playerScripts = localPlayer:WaitForChild("PlayerScripts", 10)
end
local scriptsContainer = playerScripts or script:FindFirstAncestor("StarterPlayerScripts")
if not scriptsContainer then
	warn("[WeaponInputController] Could not locate StarterPlayerScripts ancestor")
	return
end
local localSharedFolder = scriptsContainer:WaitForChild("_Shared", 10)
if not localSharedFolder then
	warn("[WeaponInputController] Could not locate _Shared folder")
	return
end
local LocalEventRegistry = require(localSharedFolder:WaitForChild("LocalEventRegistry"))
local InstancePath = require(localSharedFolder:WaitForChild("InstancePath"))

local WEAPON_ID = "Oathkeeper"
local DEFAULT_COOLDOWN = 1.2
local AIM_RAY_DISTANCE = 5000
local DEFAULT_PRIMARY_RANGE = 1000
local WEAPON_MUZZLE_PATH = "OathkeeperModel.Barrel"
local DEFAULT_TRACER_LIFETIME = 2.0
local DEFAULT_TRACER_FADE_DURATION = 0.5
local DEFAULT_M2_CAST_DURATION = 0.60
local DEFAULT_M2_FIRE_DELAY = 8 / 60
local DEFAULT_M2_SHARED_LOCKOUT = 3.0
local ATTR_WEAPON_RANGE = "StarterWeaponRange"
local ATTR_WEAPON_TRACER_LIFETIME = "StarterWeaponTracerLifetime"
local ATTR_WEAPON_TRACER_FADE_DURATION = "StarterWeaponTracerFadeDuration"
local ATTR_WEAPON_M2_CAST_DURATION = "StarterWeaponM2CastDuration"
local ATTR_WEAPON_M2_FIRE_DELAY = "StarterWeaponM2FireDelay"
local ATTR_WEAPON_M2_CHARGES = "StarterWeaponM2Charges"
local ATTR_WEAPON_M2_RECHARGE_END = "StarterWeaponM2RechargeEnd"
local ATTR_LOCAL_M2_CAST_ACTIVE = "WeaponM2CastActiveLocal"
local ATTR_LOCAL_M2_CAST_SERIAL = "WeaponM2CastSerialLocal"
local ATTR_LOCAL_SHARED_LOCKOUT_END = "WeaponSharedLockoutEndLocal"
local ATTR_LOCAL_ATTACK_LOCK = "WeaponAttackLockLocal"
local ATTR_LOCAL_M2_AIM_DIRECTION = "WeaponM2AimDirectionLocal"
local ATTR_SETTING_ACTIVATABLE_M2_FROM_CURSOR = "Setting_controls_activatableM2FromCursor"
local ATTR_SHIFT_LOCK_ENABLED = "ShiftLockEnabledLocal"
local ATTR_ULTIMATE_BUFFER_ACTIVE = "UltimateBufferActiveLocal"
local ATTR_EQUIPMENT_BUFFER_ACTIVE = "EquipmentBufferActiveLocal" -- Reserved for future Q equipment input.
local ATTR_MOBILITY_BUFFER_ACTIVE = "MobilityBufferActiveLocal"
local ATTR_ICESHARD_BUFFER_ACTIVE = "IceShardBufferActiveLocal"
local ATTR_WEAPON_SECONDARY_BUFFER_ACTIVE = "WeaponSecondaryBufferActiveLocal"
local ATTR_WEAPON_PRIMARY_HELD = "WeaponPrimaryHeldLocal"

local m1Held = false
local predictedCooldown = DEFAULT_COOLDOWN
local nextLocalFireAt = 0
local humanoid: Humanoid? = nil
local shotSequence = 0
local secondaryShotSequence = 0
local localSharedLockoutUntil = 0
local localM2CastToken = 0
local localM2AttackBlockedUntil = 0
local localM1ToM2BlockedUntil = 0
local m2Held = false
local pendingSecondaryBuffered = false
local secondaryCastStartedAtByShotId: {[number]: number} = {}
local isTimeStopActive = false
local canSecondaryBufferPreempt: () -> boolean
local isM2AimInputAllowed: () -> boolean

local aimRayParams = RaycastParams.new()
aimRayParams.FilterType = Enum.RaycastFilterType.Exclude
aimRayParams.IgnoreWater = true

local shotRayParams = RaycastParams.new()
shotRayParams.FilterType = Enum.RaycastFilterType.Exclude
shotRayParams.IgnoreWater = true

local primaryShotLocalEvent = LocalEventRegistry.getOrCreate(weaponRemotesFolder, "PrimaryShotLocal")
local secondaryShotLocalEvent = LocalEventRegistry.getOrCreate(weaponRemotesFolder, "SecondaryShotLocal")
local weaponSharedLockoutLocalEvent = LocalEventRegistry.getOrCreate(weaponRemotesFolder, "WeaponSharedLockoutLocal")

local function resolveMuzzleOrigin(character: Model): Vector3?
	local muzzle = InstancePath.findByPath(character, WEAPON_MUZZLE_PATH)
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

local function setLocalCharacterAttribute(attributeName: string, value: any)
	local character = localPlayer.Character
	if character then
		character:SetAttribute(attributeName, value)
	end
end

local function setLocalPlayerAttribute(attributeName: string, value: any)
	localPlayer:SetAttribute(attributeName, value)
end

local function refreshWeaponBufferAttributes()
	setLocalPlayerAttribute(ATTR_WEAPON_PRIMARY_HELD, m1Held)
	local isBuffered = pendingSecondaryBuffered or m2Held
	setLocalPlayerAttribute(ATTR_WEAPON_SECONDARY_BUFFER_ACTIVE, isBuffered and canSecondaryBufferPreempt())
end

local function hasHigherPriorityBufferedForSecondary(): boolean
	return localPlayer:GetAttribute(ATTR_ULTIMATE_BUFFER_ACTIVE) == true
		or localPlayer:GetAttribute(ATTR_EQUIPMENT_BUFFER_ACTIVE) == true
		or localPlayer:GetAttribute(ATTR_MOBILITY_BUFFER_ACTIVE) == true
		or localPlayer:GetAttribute(ATTR_ICESHARD_BUFFER_ACTIVE) == true
end

local function hasHigherPriorityBufferedForPrimary(): boolean
	return hasHigherPriorityBufferedForSecondary()
		or localPlayer:GetAttribute(ATTR_WEAPON_SECONDARY_BUFFER_ACTIVE) == true
end

local function setLocalSharedLockoutEnd(endTime: number, authoritative: boolean)
	local now = tick()
	if authoritative then
		localSharedLockoutUntil = math.max(now, endTime)
	else
		localSharedLockoutUntil = math.max(localSharedLockoutUntil, endTime)
	end
	setLocalCharacterAttribute(ATTR_LOCAL_SHARED_LOCKOUT_END, localSharedLockoutUntil)
	local remaining = math.max(0, localSharedLockoutUntil - now)
	weaponSharedLockoutLocalEvent:Fire({
		weaponId = WEAPON_ID,
		duration = remaining,
		endTime = localSharedLockoutUntil,
		authoritative = authoritative,
	})
end

local function getM2CastDuration(character: Model?): number
	return readWeaponNumberAttribute(character, ATTR_WEAPON_M2_CAST_DURATION, DEFAULT_M2_CAST_DURATION, 0.01)
end

local function getM2FireDelay(character: Model?): number
	return readWeaponNumberAttribute(character, ATTR_WEAPON_M2_FIRE_DELAY, DEFAULT_M2_FIRE_DELAY, 0)
end

local function beginLocalM2Cast(castDuration: number): number
	localM2CastToken += 1
	local token = localM2CastToken
	setLocalCharacterAttribute(ATTR_LOCAL_M2_CAST_ACTIVE, true)
	setLocalCharacterAttribute(ATTR_LOCAL_M2_CAST_SERIAL, token)
	task.delay(castDuration, function()
		if token ~= localM2CastToken then
			return
		end
		setLocalCharacterAttribute(ATTR_LOCAL_M2_CAST_ACTIVE, false)
	end)
	return token
end

local function computeAimDirectionFromPoint(character: Model?, aimPoint: Vector3): Vector3?
	if not character then
		return nil
	end
	local origin = resolveMuzzleOrigin(character)
	if not origin then
		return nil
	end
	local raw = aimPoint - origin
	local flat = Vector3.new(raw.X, 0, raw.Z)
	if flat.Magnitude <= 1e-4 then
		return nil
	end
	return flat.Unit
end

local function bindCharacter(character: Model?)
	humanoid = nil
	if not character then
		return
	end
	character:SetAttribute(ATTR_LOCAL_M2_CAST_ACTIVE, false)
	character:SetAttribute(ATTR_LOCAL_SHARED_LOCKOUT_END, localSharedLockoutUntil)
	character:SetAttribute(ATTR_LOCAL_M2_AIM_DIRECTION, nil)
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
	local currentCharges = character:GetAttribute(ATTR_WEAPON_M2_CHARGES)
	local rechargeEnd = character:GetAttribute(ATTR_WEAPON_M2_RECHARGE_END)
	if typeof(currentCharges) == "number"
		and currentCharges <= 0
		and typeof(rechargeEnd) == "number"
		and rechargeEnd > tick()
	then
		return false
	end
	local humanoidRef = humanoid
	if not humanoidRef or humanoidRef.Health <= 0.01 then
		return false
	end
	if tick() < localM2AttackBlockedUntil then
		return false
	end
	if localM2CastToken > 0 then
		local characterModel = localPlayer.Character
		if characterModel and characterModel:GetAttribute(ATTR_LOCAL_M2_CAST_ACTIVE) == true then
			return false
		end
	end
	return true
end

local function shouldRetainSecondaryBuffer(): boolean
	local character = localPlayer.Character
	if localPlayer:GetAttribute("CooldownsFrozen") == true then
		return false
	end
	if GuiService.MenuIsOpen then
		return false
	end
	if UserInputService:GetFocusedTextBox() then
		return false
	end
	if not character or character:GetAttribute("StarterWeaponId") ~= WEAPON_ID then
		return false
	end
	if not isM2AimInputAllowed() then
		return false
	end
	local humanoidRef = humanoid
	if not humanoidRef or humanoidRef.Health <= 0.01 then
		return false
	end
	local availableCharges = character:GetAttribute(ATTR_WEAPON_M2_CHARGES)
	if (not m2Held) and (typeof(availableCharges) ~= "number" or availableCharges <= 0) then
		return false
	end
	return true
end

function canSecondaryBufferPreempt(): boolean
	if hasHigherPriorityBufferedForSecondary() then
		return false
	end
	if not canAttemptFire() then
		return false
	end
	if not isM2AimInputAllowed() then
		return false
	end
	if tick() < localM1ToM2BlockedUntil then
		return false
	end
	local character = localPlayer.Character
	local availableCharges = if character then character:GetAttribute(ATTR_WEAPON_M2_CHARGES) else nil
	return typeof(availableCharges) == "number" and availableCharges > 0
end

local function isMouseLocked(): boolean
	local behavior = UserInputService.MouseBehavior
	return behavior == Enum.MouseBehavior.LockCenter
		or behavior == Enum.MouseBehavior.LockCurrentPosition
end

function isM2AimInputAllowed(): boolean
	if localPlayer:GetAttribute(ATTR_SETTING_ACTIVATABLE_M2_FROM_CURSOR) == true then
		return true
	end
	return localPlayer:GetAttribute(ATTR_SHIFT_LOCK_ENABLED) == true
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

local function attemptPrimaryFire()
	local now = tick()
	if now < nextLocalFireAt then
		return
	end
	if hasHigherPriorityBufferedForPrimary() then
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
	if (not isTimeStopActive) and predictedOrigin and predictedImpact and predictedNormal then
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
	localM1ToM2BlockedUntil = math.max(localM1ToM2BlockedUntil, now + 0.1)
end

local function attemptSecondaryFire(): boolean
	if hasHigherPriorityBufferedForSecondary() then
		return false
	end
	if not canAttemptFire() then
		return false
	end
	if not isM2AimInputAllowed() then
		return false
	end

	local character = localPlayer.Character
	local castDuration = getM2CastDuration(character)
	local fireDelay = getM2FireDelay(character)
	if tick() < localM1ToM2BlockedUntil then
		return false
	end
	local availableCharges = if character then character:GetAttribute(ATTR_WEAPON_M2_CHARGES) else nil
	if typeof(availableCharges) ~= "number" or availableCharges <= 0 then
		return false
	end
	local aimPoint = buildAimPoint()
	if not aimPoint then
		return false
	end

	secondaryShotSequence += 1
	local clientShotId = secondaryShotSequence
	local castStart = tick()
	localM2AttackBlockedUntil = math.max(localM2AttackBlockedUntil, castStart + castDuration)
	pendingSecondaryBuffered = false
	refreshWeaponBufferAttributes()
	secondaryCastStartedAtByShotId[clientShotId] = castStart
	local aimDirection = computeAimDirectionFromPoint(character, aimPoint)
	setLocalCharacterAttribute(ATTR_LOCAL_M2_AIM_DIRECTION, aimDirection)

	beginLocalM2Cast(castDuration)

	secondaryFireRequestRemote:FireServer({
		targetPoint = aimPoint,
		clientShotId = clientShotId,
	})

	task.delay(fireDelay, function()
		local startedAt = secondaryCastStartedAtByShotId[clientShotId]
		if not startedAt then
			return
		end
		if isTimeStopActive then
			return
		end
		local predictedOrigin, predictedImpact, predictedNormal = buildPredictedShot(aimPoint)
		if not predictedOrigin or not predictedImpact or not predictedNormal then
			return
		end
		local activeCharacter = localPlayer.Character
		local tracerLifetime = readWeaponNumberAttribute(activeCharacter, ATTR_WEAPON_TRACER_LIFETIME, DEFAULT_TRACER_LIFETIME, 0)
		local tracerFadeDuration = readWeaponNumberAttribute(activeCharacter, ATTR_WEAPON_TRACER_FADE_DURATION, DEFAULT_TRACER_FADE_DURATION, 0)
		secondaryShotLocalEvent:Fire({
			shooterUserId = localPlayer.UserId,
			weaponId = WEAPON_ID,
			shotKind = "M2",
			clientShotId = clientShotId,
			origin = predictedOrigin,
			impactPosition = predictedImpact,
			impactNormal = predictedNormal,
			tracerLifetime = tracerLifetime,
			tracerFadeDuration = tracerFadeDuration,
			castDuration = castDuration,
			fireDelay = fireDelay,
			predicted = true,
		})
	end)

	task.delay(castDuration + DEFAULT_M2_SHARED_LOCKOUT + 2.0, function()
		local startedAt = secondaryCastStartedAtByShotId[clientShotId]
		if startedAt == castStart then
			secondaryCastStartedAtByShotId[clientShotId] = nil
		end
	end)
	return true
end

local function processBufferedSecondaryFire()
	if not pendingSecondaryBuffered then
		return
	end
	if attemptSecondaryFire() then
		return
	end
	if not shouldRetainSecondaryBuffer() then
		pendingSecondaryBuffered = false
		refreshWeaponBufferAttributes()
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		m1Held = true
		refreshWeaponBufferAttributes()
		attemptPrimaryFire()
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		m2Held = true
		pendingSecondaryBuffered = true
		refreshWeaponBufferAttributes()
		processBufferedSecondaryFire()
	end
end)

timeStopStateRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	isTimeStopActive = payload.active == true
end)

UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		m2Held = false
		refreshWeaponBufferAttributes()
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end
	local wasHeld = m1Held
	m1Held = false
	refreshWeaponBufferAttributes()
	if wasHeld then
		primaryFireReleaseRemote:FireServer()
	end
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

secondaryShotRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.weaponId ~= WEAPON_ID or payload.shooterUserId ~= localPlayer.UserId then
		return
	end

	local shotId = if typeof(payload.clientShotId) == "number"
		then math.floor(payload.clientShotId + 0.5)
		else nil
	local castStart = if shotId then secondaryCastStartedAtByShotId[shotId] else nil
	local castDuration = if typeof(payload.castDuration) == "number" and payload.castDuration > 0
		then payload.castDuration
		else getM2CastDuration(localPlayer.Character)
	local sharedLockout = if typeof(payload.effectiveSharedLockout) == "number" and payload.effectiveSharedLockout > 0
		then payload.effectiveSharedLockout
		else DEFAULT_M2_SHARED_LOCKOUT

	if not castStart then
		castStart = tick() - castDuration
	end

	local lockoutStart = castStart + castDuration
	local lockoutEnd = lockoutStart + sharedLockout
	local applyDelay = math.max(0, lockoutStart - tick())
	task.delay(applyDelay, function()
		setLocalSharedLockoutEnd(lockoutEnd, true)
	end)
	if shotId then
		secondaryCastStartedAtByShotId[shotId] = nil
	end
end)

RunService.RenderStepped:Connect(function()
	refreshWeaponBufferAttributes()
	if m2Held and (not pendingSecondaryBuffered) then
		pendingSecondaryBuffered = true
		refreshWeaponBufferAttributes()
	end
	if pendingSecondaryBuffered then
		processBufferedSecondaryFire()
	end
	if m1Held then
		attemptPrimaryFire()
	end
end)

localPlayer.CharacterAdded:Connect(bindCharacter)
localPlayer.CharacterRemoving:Connect(function()
	m1Held = false
	localM2CastToken += 1
	localSharedLockoutUntil = 0
	localM2AttackBlockedUntil = 0
	localM1ToM2BlockedUntil = 0
	m2Held = false
	pendingSecondaryBuffered = false
	refreshWeaponBufferAttributes()
	table.clear(secondaryCastStartedAtByShotId)
	setLocalCharacterAttribute(ATTR_LOCAL_M2_CAST_ACTIVE, false)
	setLocalCharacterAttribute(ATTR_LOCAL_SHARED_LOCKOUT_END, nil)
	setLocalCharacterAttribute(ATTR_LOCAL_M2_AIM_DIRECTION, nil)
	bindCharacter(nil)
end)

if localPlayer.Character then
	bindCharacter(localPlayer.Character)
end

refreshWeaponBufferAttributes()
