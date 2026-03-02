--!strict
-- WeaponIdleController - Oathkeeper idle/walk/M1/M2/reload animation state machine.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer

local ATTR_WEAPON_ID = "StarterWeaponId"
local ATTR_IDLE_ANIM = "StarterWeaponIdleAnimationId"
local ATTR_WALK_ANIM = "StarterWeaponWalkAnimationId"
local ATTR_M1_ANIM = "StarterWeaponM1AnimationId"
local ATTR_M2_ANIM = "StarterWeaponM2AnimationId"
local ATTR_RELOAD_ANIM = "StarterWeaponReloadAnimationId"
local ATTR_ACTIVE_WALK_WINDOW = "StarterWeaponActiveWalkWindow"
local ATTR_LOCAL_M1_ACTIVE = "WeaponM1ActiveLocal"
local ATTR_LOCAL_M2_CAST_ACTIVE = "WeaponM2CastActiveLocal"
local ATTR_LOCAL_M2_CAST_SERIAL = "WeaponM2CastSerialLocal"
local ATTR_WEAPON_M2_CHARGES = "StarterWeaponM2Charges"
local ATTR_WEAPON_M2_RECHARGE_END = "StarterWeaponM2RechargeEnd"
local ATTR_LOCAL_M2_AIM_DIRECTION = "WeaponM2AimDirectionLocal"
local ATTR_LOCAL_ATTACK_LOCK = "WeaponAttackLockLocal"
local ATTR_LOCAL_WEAPON_ACTIVE = "WeaponPrimaryActiveLocal"
local ATTR_LOCAL_UTILITY_FACING_LOCK = "UtilityFacingLockActiveLocal"
local ATTR_LOCAL_MOUSE_AIM_DIRECTION = "WeaponMouseAimDirectionLocal"
local ATTR_LOCAL_MOUSE_AIM_EXPIRES_AT = "WeaponMouseAimExpiresAtLocal"

local WEAPON_ID = "Oathkeeper"
local WEAPON_MODEL_NAME = "OathkeeperModel"
local SPRINT_OVERRIDE_ANIMATION_NAME = "SprintOverride"
local DEFAULT_ACTIVE_WALK_WINDOW = 5.0
local DEFAULT_MOUSE_AIM_DURATION = 1.0
local AIM_TURN_SHARPNESS = 36.0
local AIM_TURN_HARD_LOCK_DOT = 0.9995

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local weaponRemotesFolder = remotesFolder:WaitForChild("Weapons")
local primaryShotRemote = weaponRemotesFolder:WaitForChild("PrimaryShot")

local character: Model? = nil
local humanoid: Humanoid? = nil
local animator: Animator? = nil
local updateConnection: RBXScriptConnection? = nil

local idleAnimation: Animation? = nil
local walkAnimation: Animation? = nil
local m1Animation: Animation? = nil
local m2Animation: Animation? = nil
local reloadAnimation: Animation? = nil
local idleTrack: AnimationTrack? = nil
local walkTrack: AnimationTrack? = nil
local m1Track: AnimationTrack? = nil
local m2Track: AnimationTrack? = nil
local reloadTrack: AnimationTrack? = nil

local lastShotTime: number? = nil
local characterBoundAt = 0
local m1PlaybackToken = 0
local lastM2CastSerialPlayed: number? = nil
local shotFacingLockDirection: Vector3? = nil
local shotFacingLockToken = 0
local shotFacingCurrentDirection: Vector3? = nil
local shotFacingAutoRotateOverridden = false
local shotFacingAutoRotatePrevious: boolean? = nil
local m2FacingLockActive = false

local function clearMouseAimDirectionOverride(characterModel: Model?)
	if not characterModel then
		return
	end
	characterModel:SetAttribute(ATTR_LOCAL_MOUSE_AIM_DIRECTION, nil)
	characterModel:SetAttribute(ATTR_LOCAL_MOUSE_AIM_EXPIRES_AT, nil)
end

local function setMouseAimDirectionOverride(characterModel: Model?, direction: Vector3?)
	if not characterModel then
		return
	end
	if typeof(direction) ~= "Vector3" or direction.Magnitude <= 1e-4 then
		clearMouseAimDirectionOverride(characterModel)
		return
	end
	characterModel:SetAttribute(ATTR_LOCAL_MOUSE_AIM_DIRECTION, direction.Unit)
	characterModel:SetAttribute(ATTR_LOCAL_MOUSE_AIM_EXPIRES_AT, tick() + DEFAULT_MOUSE_AIM_DURATION)
end

local function normalizeAnimationId(rawId: any): string?
	if typeof(rawId) == "number" then
		return "rbxassetid://" .. tostring(math.floor(rawId))
	end
	if typeof(rawId) ~= "string" or rawId == "" then
		return nil
	end
	if string.sub(rawId, 1, 13) == "rbxassetid://" then
		return rawId
	end
	if string.match(rawId, "^%d+$") then
		return "rbxassetid://" .. rawId
	end
	return nil
end

local function animationIdFromInstance(source: Instance?): string?
	if not source then
		return nil
	end
	if source:IsA("Animation") then
		return normalizeAnimationId(source.AnimationId)
	end
	if source:IsA("StringValue") then
		return normalizeAnimationId(source.Value)
	end
	if source:IsA("NumberValue") then
		return normalizeAnimationId(source.Value)
	end
	return nil
end

local function resolveAnimationId(characterModel: Model, attributeName: string, fallbackName: string): string?
	local fromAttribute = normalizeAnimationId(characterModel:GetAttribute(attributeName))
	if fromAttribute then
		return fromAttribute
	end

	local weaponModel = characterModel:FindFirstChild(WEAPON_MODEL_NAME)
	if weaponModel then
		local fromWeapon = animationIdFromInstance(weaponModel:FindFirstChild(fallbackName, true))
		if fromWeapon then
			return fromWeapon
		end
	end

	return animationIdFromInstance(characterModel:FindFirstChild(fallbackName, true))
end

local function resolveActiveWalkWindow(characterModel: Model): number
	local configuredWindow = characterModel:GetAttribute(ATTR_ACTIVE_WALK_WINDOW)
	if typeof(configuredWindow) == "number" and configuredWindow >= 0 then
		return configuredWindow
	end
	return DEFAULT_ACTIVE_WALK_WINDOW
end

local function stopTrack(track: AnimationTrack?)
	if track and track.IsPlaying then
		track:Stop(0.08)
	end
end

local function setShotFacingHardLockEnabled(enabled: boolean)
	local humanoidRef = humanoid
	if enabled then
		if shotFacingAutoRotateOverridden then
			return
		end
		if humanoidRef then
			shotFacingAutoRotatePrevious = humanoidRef.AutoRotate
			humanoidRef.AutoRotate = false
			shotFacingAutoRotateOverridden = true
		end
		return
	end

	if not shotFacingAutoRotateOverridden then
		return
	end
	if humanoidRef then
		if typeof(shotFacingAutoRotatePrevious) == "boolean" then
			humanoidRef.AutoRotate = shotFacingAutoRotatePrevious
		else
			humanoidRef.AutoRotate = true
		end
	end
	shotFacingAutoRotateOverridden = false
	shotFacingAutoRotatePrevious = nil
end

local function setLocalAttackLock(enabled: boolean)
	local characterModel = character
	if not characterModel then
		return
	end
	characterModel:SetAttribute(ATTR_LOCAL_ATTACK_LOCK, enabled)
end

local function clearTracks()
	stopTrack(idleTrack)
	stopTrack(walkTrack)
	stopTrack(m1Track)
	stopTrack(m2Track)
	stopTrack(reloadTrack)
	idleTrack = nil
	walkTrack = nil
	m1Track = nil
	m2Track = nil
	reloadTrack = nil
	local characterModel = character
	if characterModel then
		characterModel:SetAttribute(ATTR_LOCAL_M1_ACTIVE, false)
		characterModel:SetAttribute(ATTR_LOCAL_WEAPON_ACTIVE, false)
		characterModel:SetAttribute(ATTR_LOCAL_ATTACK_LOCK, false)
		clearMouseAimDirectionOverride(characterModel)
	end
	setShotFacingHardLockEnabled(false)
	shotFacingLockDirection = nil
	shotFacingLockToken = 0
	shotFacingCurrentDirection = nil
	m2FacingLockActive = false
	lastM2CastSerialPlayed = nil
end

local function disconnectUpdate()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
end

local function ensureTrack(
	trackType: "Idle" | "Walk" | "M1" | "M2" | "Reload",
	animationId: string?,
	priority: Enum.AnimationPriority,
	looped: boolean
): AnimationTrack?
	if not animator or not animationId then
		return nil
	end

	local animRef = if trackType == "Idle"
		then idleAnimation
		elseif trackType == "Walk"
		then walkAnimation
		elseif trackType == "M1"
		then m1Animation
		elseif trackType == "M2"
		then m2Animation
		else reloadAnimation
	local trackRef = if trackType == "Idle"
		then idleTrack
		elseif trackType == "Walk"
		then walkTrack
		elseif trackType == "M1"
		then m1Track
		elseif trackType == "M2"
		then m2Track
		else reloadTrack

	if not animRef then
		animRef = Instance.new("Animation")
		animRef.Name = "Weapon" .. trackType
		if trackType == "Idle" then
			idleAnimation = animRef
		elseif trackType == "Walk" then
			walkAnimation = animRef
		elseif trackType == "M1" then
			m1Animation = animRef
		elseif trackType == "M2" then
			m2Animation = animRef
		else
			reloadAnimation = animRef
		end
	end

	if animRef.AnimationId ~= animationId then
		stopTrack(trackRef)
		trackRef = nil
		animRef.AnimationId = animationId
	end

	if not trackRef then
		trackRef = animator:LoadAnimation(animRef)
		trackRef.Priority = priority
		trackRef.Looped = looped
		if trackType == "Idle" then
			idleTrack = trackRef
		elseif trackType == "Walk" then
			walkTrack = trackRef
		elseif trackType == "M1" then
			m1Track = trackRef
		elseif trackType == "M2" then
			m2Track = trackRef
		else
			reloadTrack = trackRef
		end
	end

	return trackRef
end

local function playLooped(track: AnimationTrack?)
	if track and not track.IsPlaying then
		track:Play(0.1, 1, 1)
	end
end

local function isSprintTrackPlaying(): boolean
	if not animator then
		return false
	end
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		local animation = track.Animation
		if track.IsPlaying and animation and animation.Name == SPRINT_OVERRIDE_ANIMATION_NAME then
			return true
		end
	end
	return false
end

local function isAirborneState(humanoidRef: Humanoid): boolean
	local state = humanoidRef:GetState()
	return state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.FallingDown
end

local function isWeaponEnabled(characterModel: Model): boolean
	return characterModel:GetAttribute(ATTR_WEAPON_ID) == WEAPON_ID
end

local function isMouseLocked(): boolean
	local behavior = UserInputService.MouseBehavior
	return behavior == Enum.MouseBehavior.LockCenter
		or behavior == Enum.MouseBehavior.LockCurrentPosition
end

local function applyUnshiftShotFacingLock(dt: number?)
	local characterModel = character
	if characterModel and characterModel:GetAttribute(ATTR_LOCAL_UTILITY_FACING_LOCK) == true then
		-- Utility facing lock has higher priority than primary shot facing lock.
		setShotFacingHardLockEnabled(false)
		shotFacingCurrentDirection = nil
		return
	end

	local lockDirection = shotFacingLockDirection
	if not lockDirection then
		setShotFacingHardLockEnabled(false)
		shotFacingCurrentDirection = nil
		return
	end
	if isMouseLocked() then
		setShotFacingHardLockEnabled(false)
		shotFacingCurrentDirection = nil
		return
	end

	local humanoidRef = humanoid
	if not characterModel or not humanoidRef or humanoidRef.Health <= 0 then
		setShotFacingHardLockEnabled(false)
		shotFacingCurrentDirection = nil
		return
	end
	local rootPart = characterModel:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		setShotFacingHardLockEnabled(false)
		shotFacingCurrentDirection = nil
		return
	end
	setShotFacingHardLockEnabled(true)

	local currentLook = shotFacingCurrentDirection
	if not currentLook then
		currentLook = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)
	end
	if currentLook.Magnitude <= 1e-4 then
		currentLook = lockDirection
	else
		currentLook = currentLook.Unit
	end
	local stepDt = if typeof(dt) == "number" and dt > 0 then dt else (1 / 60)
	local alpha = 1 - math.exp(-AIM_TURN_SHARPNESS * stepDt)
	alpha = math.clamp(alpha, 0, 1)
	local blended = currentLook:Lerp(lockDirection, alpha)
	if blended.Magnitude <= 1e-4 then
		blended = lockDirection
	else
		blended = blended.Unit
	end
	if blended:Dot(lockDirection) >= AIM_TURN_HARD_LOCK_DOT then
		blended = lockDirection
	end
	shotFacingCurrentDirection = blended

	local position = rootPart.Position
	rootPart.CFrame = CFrame.lookAt(position, position + blended)
end

local function updateWeaponAnimationState(dt: number?)
	local characterModel = character
	local humanoidRef = humanoid
	if not characterModel or not humanoidRef or humanoidRef.Health <= 0 then
		clearTracks()
		return
	end
	if not isWeaponEnabled(characterModel) then
		clearTracks()
		return
	end

	local idleId = resolveAnimationId(characterModel, ATTR_IDLE_ANIM, "HandCannonIdle")
	local walkId = resolveAnimationId(characterModel, ATTR_WALK_ANIM, "HandCannonWalk")
	local m1Id = resolveAnimationId(characterModel, ATTR_M1_ANIM, "HandCannonM1")
	local m2Id = resolveAnimationId(characterModel, ATTR_M2_ANIM, "HandCannonChargedM2")
	local reloadId = resolveAnimationId(characterModel, ATTR_RELOAD_ANIM, "HandCannonChargedReloadingLoop")

	local idle = ensureTrack("Idle", idleId, Enum.AnimationPriority.Action, true)
	local walk = ensureTrack("Walk", walkId, Enum.AnimationPriority.Action, true)
	local m1 = ensureTrack("M1", m1Id, Enum.AnimationPriority.Action2, false)
	local m2 = ensureTrack("M2", m2Id, Enum.AnimationPriority.Action4, false)
	local reload = ensureTrack("Reload", reloadId, Enum.AnimationPriority.Action3, true)

	local m2Casting = characterModel:GetAttribute(ATTR_LOCAL_M2_CAST_ACTIVE) == true
	local m2CastSerialValue = characterModel:GetAttribute(ATTR_LOCAL_M2_CAST_SERIAL)
	local m2CastSerial = if typeof(m2CastSerialValue) == "number" then m2CastSerialValue else nil
	local currentChargesValue = characterModel:GetAttribute(ATTR_WEAPON_M2_CHARGES)
	local currentCharges = if typeof(currentChargesValue) == "number" then currentChargesValue else 1
	local rechargeEndValue = characterModel:GetAttribute(ATTR_WEAPON_M2_RECHARGE_END)
	local rechargeEnd = if typeof(rechargeEndValue) == "number" then rechargeEndValue else 0
	local reloading = currentCharges <= 0 and rechargeEnd > tick()
	local sprinting = isSprintTrackPlaying()
	if sprinting and lastShotTime ~= nil then
		-- Entering sprint cancels the weapon-active animation window.
		lastShotTime = nil
	end
	if m2Casting and m2CastSerial and m2CastSerial ~= lastM2CastSerialPlayed then
		-- M2 use should enter the same active-state window as M1.
		lastShotTime = tick()
	end
	local activeWalkWindow = resolveActiveWalkWindow(characterModel)
	local shotTime = lastShotTime
	local withinWalkWindow = shotTime ~= nil and (tick() - shotTime) <= activeWalkWindow
	characterModel:SetAttribute(ATTR_LOCAL_WEAPON_ACTIVE, withinWalkWindow)

	if m2Casting then
		stopTrack(idle)
		stopTrack(walk)
		stopTrack(reload)
		stopTrack(m1)
		if m2 and m2CastSerial and m2CastSerial ~= lastM2CastSerialPlayed then
			if m2.IsPlaying then
				m2:Stop(0.03)
			end
			m2:Play(0.03, 1, 1)
			lastM2CastSerialPlayed = m2CastSerial

			local rawAimDirection = characterModel:GetAttribute(ATTR_LOCAL_M2_AIM_DIRECTION)
			if typeof(rawAimDirection) == "Vector3" then
				local flatDirection = Vector3.new(rawAimDirection.X, 0, rawAimDirection.Z)
				if flatDirection.Magnitude > 1e-4 then
					shotFacingLockDirection = flatDirection.Unit
					shotFacingCurrentDirection = nil
					m2FacingLockActive = true
				else
					setShotFacingHardLockEnabled(false)
					shotFacingLockDirection = nil
					shotFacingLockToken = 0
					shotFacingCurrentDirection = nil
					m2FacingLockActive = false
				end
			else
				setShotFacingHardLockEnabled(false)
				shotFacingLockDirection = nil
				shotFacingLockToken = 0
				shotFacingCurrentDirection = nil
				m2FacingLockActive = false
			end
		end
		setLocalAttackLock(true)
		applyUnshiftShotFacingLock(dt)
		return
	end

	if m2 and m2.IsPlaying then
		stopTrack(idle)
		stopTrack(walk)
		stopTrack(reload)
		stopTrack(m1)
		setLocalAttackLock(true)
		applyUnshiftShotFacingLock(dt)
		return
	end
	if m2FacingLockActive then
		setShotFacingHardLockEnabled(false)
		shotFacingLockDirection = nil
		shotFacingLockToken = 0
		shotFacingCurrentDirection = nil
		m2FacingLockActive = false
	end

	if reloading then
		stopTrack(idle)
		stopTrack(walk)
		stopTrack(m1)
		playLooped(reload)
		setLocalAttackLock(false)
		applyUnshiftShotFacingLock(dt)
		return
	end

	stopTrack(reload)

	local moving = humanoidRef.MoveDirection.Magnitude > 0.05

	if isAirborneState(humanoidRef) then
		stopTrack(idle)
		stopTrack(walk)
		local m1Active = characterModel:GetAttribute(ATTR_LOCAL_M1_ACTIVE) == true
		setLocalAttackLock(m1Active)
		applyUnshiftShotFacingLock(dt)
		return
	end

	if sprinting then
		stopTrack(idle)
		stopTrack(walk)
		local m1Active = characterModel:GetAttribute(ATTR_LOCAL_M1_ACTIVE) == true
		setLocalAttackLock(m1Active)
		applyUnshiftShotFacingLock(dt)
		return
	end

	if moving then
		stopTrack(idle)
		if withinWalkWindow then
			playLooped(walk)
		else
			stopTrack(walk)
		end
	else
		stopTrack(walk)
		if withinWalkWindow then
			playLooped(idle)
		else
			stopTrack(idle)
		end
	end

	local m1Active = characterModel:GetAttribute(ATTR_LOCAL_M1_ACTIVE) == true
	setLocalAttackLock(m1Active)
	applyUnshiftShotFacingLock(dt)
end

local function onShot(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.weaponId ~= WEAPON_ID then
		return
	end
	if payload.shooterUserId ~= localPlayer.UserId then
		return
	end

	local firedAt = payload.firedAt
	if typeof(firedAt) == "number" and firedAt < (characterBoundAt - 0.05) then
		return
	end
	lastShotTime = tick()

	local characterModel = character
	local pendingLockDirection: Vector3? = nil
	local pendingMouseAimDirection: Vector3? = nil
	if characterModel and not isMouseLocked() then
		local origin = payload.origin
		local impact = payload.impactPosition
		if typeof(origin) == "Vector3" and typeof(impact) == "Vector3" then
			local shotDirection = impact - origin
			if shotDirection.Magnitude > 1e-4 then
				pendingMouseAimDirection = shotDirection.Unit
			end
			local flatDirection = Vector3.new(shotDirection.X, 0, shotDirection.Z)
			if flatDirection.Magnitude > 1e-4 then
				pendingLockDirection = flatDirection.Unit
			end
		end
	elseif characterModel then
		clearMouseAimDirectionOverride(characterModel)
	end

	local track = m1Track
	if not track then
		if characterModel then
			local m1Id = resolveAnimationId(characterModel, ATTR_M1_ANIM, "HandCannonM1")
			track = ensureTrack("M1", m1Id, Enum.AnimationPriority.Action2, false)
		end
	end
	if track then
		-- Stop current playback first so the previous shot's Stopped callback resolves
		-- before we create state for the new shot.
		if track.IsPlaying then
			track:Stop(0.03)
		end

		m1PlaybackToken += 1
		local token = m1PlaybackToken
		if characterModel then
			characterModel:SetAttribute(ATTR_LOCAL_M1_ACTIVE, true)
			setLocalAttackLock(true)
			setMouseAimDirectionOverride(characterModel, pendingMouseAimDirection)
		end
		if pendingLockDirection then
			shotFacingLockDirection = pendingLockDirection
			shotFacingLockToken = token
			shotFacingCurrentDirection = nil
		else
			setShotFacingHardLockEnabled(false)
			shotFacingLockDirection = nil
			shotFacingLockToken = 0
			shotFacingCurrentDirection = nil
		end
		local stoppedConnection: RBXScriptConnection?
		stoppedConnection = track.Stopped:Connect(function()
			if stoppedConnection then
				stoppedConnection:Disconnect()
				stoppedConnection = nil
			end
			local currentCharacter = character
			if token == m1PlaybackToken and currentCharacter then
				currentCharacter:SetAttribute(ATTR_LOCAL_M1_ACTIVE, false)
				local m2Casting = currentCharacter:GetAttribute(ATTR_LOCAL_M2_CAST_ACTIVE) == true
				setLocalAttackLock(m2Casting)
			end
			if token == shotFacingLockToken then
				setShotFacingHardLockEnabled(false)
				shotFacingLockDirection = nil
				shotFacingLockToken = 0
				shotFacingCurrentDirection = nil
			end
		end)
		track:Play(0.03, 1, 1)
	else
		if characterModel then
			characterModel:SetAttribute(ATTR_LOCAL_M1_ACTIVE, false)
			local m2Casting = characterModel:GetAttribute(ATTR_LOCAL_M2_CAST_ACTIVE) == true
			setLocalAttackLock(m2Casting)
		end
		setShotFacingHardLockEnabled(false)
		shotFacingLockDirection = nil
		shotFacingLockToken = 0
		shotFacingCurrentDirection = nil
	end
end

local function bindCharacter(nextCharacter: Model?)
	disconnectUpdate()
	clearTracks()
	local previousCharacter = character
	if previousCharacter then
		previousCharacter:SetAttribute(ATTR_LOCAL_WEAPON_ACTIVE, false)
		previousCharacter:SetAttribute(ATTR_LOCAL_ATTACK_LOCK, false)
		clearMouseAimDirectionOverride(previousCharacter)
	end
	character = nextCharacter
	humanoid = nil
	animator = nil
	lastShotTime = nil
	characterBoundAt = tick()
	m1PlaybackToken = 0
	setShotFacingHardLockEnabled(false)
	shotFacingLockDirection = nil
	shotFacingLockToken = 0
	shotFacingCurrentDirection = nil

	if not nextCharacter then
		return
	end

	nextCharacter:SetAttribute(ATTR_LOCAL_M1_ACTIVE, false)
	nextCharacter:SetAttribute(ATTR_LOCAL_ATTACK_LOCK, false)
	nextCharacter:SetAttribute(ATTR_LOCAL_WEAPON_ACTIVE, false)
	clearMouseAimDirectionOverride(nextCharacter)

	local foundHumanoid = nextCharacter:FindFirstChildOfClass("Humanoid")
	if not foundHumanoid then
		local waited = nextCharacter:WaitForChild("Humanoid", 5)
		if waited and waited:IsA("Humanoid") then
			foundHumanoid = waited
		end
	end
	if not foundHumanoid then
		return
	end
	humanoid = foundHumanoid

	local foundAnimator = foundHumanoid:FindFirstChildOfClass("Animator")
	if not foundAnimator then
		local waited = foundHumanoid:WaitForChild("Animator", 5)
		if waited and waited:IsA("Animator") then
			foundAnimator = waited
		end
	end
	if not foundAnimator then
		return
	end
	animator = foundAnimator

	updateWeaponAnimationState()
	updateConnection = RunService.RenderStepped:Connect(updateWeaponAnimationState)
end

primaryShotRemote.OnClientEvent:Connect(onShot)

if localPlayer.Character then
	bindCharacter(localPlayer.Character)
end

localPlayer.CharacterAdded:Connect(bindCharacter)
localPlayer.CharacterRemoving:Connect(function(removingCharacter: Model)
	if removingCharacter == character then
		bindCharacter(nil)
	end
end)
