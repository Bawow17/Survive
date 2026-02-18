--!strict
-- WeaponIdleController - weapon idle/walk/M1 animation state machine for no-tool primaries.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer

local ATTR_WEAPON_ID = "StarterWeaponId"
local ATTR_IDLE_ANIM = "StarterWeaponIdleAnimationId"
local ATTR_WALK_ANIM = "StarterWeaponWalkAnimationId"
local ATTR_M1_ANIM = "StarterWeaponM1AnimationId"
local ATTR_ACTIVE_WALK_WINDOW = "StarterWeaponActiveWalkWindow"
local ATTR_LOCAL_M1_ACTIVE = "WeaponM1ActiveLocal"
local ATTR_LOCAL_WEAPON_ACTIVE = "WeaponPrimaryActiveLocal"

local WEAPON_ID = "Oathkeeper"
local WEAPON_MODEL_NAME = "OathkeeperModel"
local SPRINT_OVERRIDE_ANIMATION_NAME = "SprintOverride"
local DEFAULT_ACTIVE_WALK_WINDOW = 5.0
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
local idleTrack: AnimationTrack? = nil
local walkTrack: AnimationTrack? = nil
local m1Track: AnimationTrack? = nil

local lastShotTime: number? = nil
local characterBoundAt = 0
local m1PlaybackToken = 0
local shotFacingLockDirection: Vector3? = nil
local shotFacingLockToken = 0
local shotFacingCurrentDirection: Vector3? = nil
local shotFacingAutoRotateOverridden = false
local shotFacingAutoRotatePrevious: boolean? = nil

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

local function clearTracks()
	stopTrack(idleTrack)
	stopTrack(walkTrack)
	stopTrack(m1Track)
	idleTrack = nil
	walkTrack = nil
	m1Track = nil
	local characterModel = character
	if characterModel then
		characterModel:SetAttribute(ATTR_LOCAL_M1_ACTIVE, false)
		characterModel:SetAttribute(ATTR_LOCAL_WEAPON_ACTIVE, false)
	end
	setShotFacingHardLockEnabled(false)
	shotFacingLockDirection = nil
	shotFacingLockToken = 0
	shotFacingCurrentDirection = nil
end

local function disconnectUpdate()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
end

local function ensureTrack(
	trackType: "Idle" | "Walk" | "M1",
	animationId: string?,
	priority: Enum.AnimationPriority,
	looped: boolean
): AnimationTrack?
	if not animator or not animationId then
		return nil
	end

	local animRef = if trackType == "Idle" then idleAnimation elseif trackType == "Walk" then walkAnimation else m1Animation
	local trackRef = if trackType == "Idle" then idleTrack elseif trackType == "Walk" then walkTrack else m1Track

	if not animRef then
		animRef = Instance.new("Animation")
		animRef.Name = "Weapon" .. trackType
		if trackType == "Idle" then
			idleAnimation = animRef
		elseif trackType == "Walk" then
			walkAnimation = animRef
		else
			m1Animation = animRef
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
		else
			m1Track = trackRef
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

	local characterModel = character
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

	local idle = ensureTrack("Idle", idleId, Enum.AnimationPriority.Action, true)
	local walk = ensureTrack("Walk", walkId, Enum.AnimationPriority.Action, true)
	ensureTrack("M1", m1Id, Enum.AnimationPriority.Action2, false)

	local sprinting = isSprintTrackPlaying()
	local moving = humanoidRef.MoveDirection.Magnitude > 0.05
	local shotTime = lastShotTime
	local activeWalkWindow = resolveActiveWalkWindow(characterModel)
	local withinWalkWindow = shotTime ~= nil and (tick() - shotTime) <= activeWalkWindow
	characterModel:SetAttribute(ATTR_LOCAL_WEAPON_ACTIVE, withinWalkWindow)

	if isAirborneState(humanoidRef) then
		stopTrack(idle)
		stopTrack(walk)
		applyUnshiftShotFacingLock(dt)
		return
	end

	if sprinting then
		stopTrack(idle)
		stopTrack(walk)
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
	if characterModel and not isMouseLocked() then
		local origin = payload.origin
		local impact = payload.impactPosition
		if typeof(origin) == "Vector3" and typeof(impact) == "Vector3" then
			local shotDirection = impact - origin
			local flatDirection = Vector3.new(shotDirection.X, 0, shotDirection.Z)
			if flatDirection.Magnitude > 1e-4 then
				pendingLockDirection = flatDirection.Unit
			end
		end
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
	nextCharacter:SetAttribute(ATTR_LOCAL_WEAPON_ACTIVE, false)

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
