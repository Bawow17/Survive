--!strict
-- UltimateInputController - Handles G cast requests + local movement lock.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local ultimateCastRequestRemote = remotesFolder:WaitForChild("UltimateCastRequest") :: RemoteEvent
local ultimateStateUpdateRemote = remotesFolder:WaitForChild("UltimateStateUpdate") :: RemoteEvent

local CAST_KEY = Enum.KeyCode.G
local AIM_RAY_DISTANCE = 5000
local ABILITY_CAST_ACTIVE_ATTRIBUTE = "AbilityCastActiveLocal"
local WEAPON_M2_CAST_ACTIVE_LOCAL_ATTRIBUTE = "WeaponM2CastActiveLocal"
local UTILITY_CAST_ACTIVE_LOCAL_ATTRIBUTE = "UtilityCastActiveLocal"
local ATTR_ULTIMATE_BUFFER_ACTIVE = "UltimateBufferActiveLocal"

local isReady = false
local movementLocked = false
local cachedControls: any = nil
local abilityCastActiveConnection: RBXScriptConnection? = nil
local sawLocalCastActiveForCurrentServerLock = false
local castHeld = false
local pendingBufferedCast = false
local isLocallyReadyToCast: () -> boolean

local aimRayParams = RaycastParams.new()
aimRayParams.FilterType = Enum.RaycastFilterType.Exclude
aimRayParams.IgnoreWater = true

local function resolveControls(): any
	if cachedControls then
		return cachedControls
	end

	local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
	if not playerScripts then
		playerScripts = localPlayer:WaitForChild("PlayerScripts", 10)
	end
	if not playerScripts then
		return nil
	end

	local playerModuleScript = playerScripts:FindFirstChild("PlayerModule")
	if not playerModuleScript or not playerModuleScript:IsA("ModuleScript") then
		return nil
	end

	local ok, playerModule = pcall(function()
		return require(playerModuleScript)
	end)
	if not ok or not playerModule or typeof(playerModule.GetControls) ~= "function" then
		return nil
	end

	local controls = playerModule:GetControls()
	if controls then
		cachedControls = controls
	end
	return controls
end

local function setMovementLocked(locked: boolean)
	if movementLocked == locked then
		return
	end
	movementLocked = locked

	local controls = resolveControls()
	if not controls then
		if locked then
			task.delay(0.2, function()
				local retryControls = resolveControls()
				if not retryControls then
					return
				end
				if movementLocked then
					retryControls:Disable()
				else
					retryControls:Enable()
				end
			end)
		end
		return
	end

	if locked then
		controls:Disable()
	else
		controls:Enable()
	end
end

local function refreshMovementLock()
	local serverLocked = localPlayer:GetAttribute("UltimateInputLocked") == true
	if not serverLocked then
		sawLocalCastActiveForCurrentServerLock = false
		setMovementLocked(false)
		return
	end

	local character = localPlayer.Character
	local localCastActive = character and character:GetAttribute(ABILITY_CAST_ACTIVE_ATTRIBUTE) == true
	if localCastActive then
		sawLocalCastActiveForCurrentServerLock = true
		setMovementLocked(true)
		return
	end

	-- Lock immediately when server lock first appears; once we've observed the
	-- local cast animation active and then inactive, unlock movement right away.
	local locked = not sawLocalCastActiveForCurrentServerLock
	setMovementLocked(locked)
end

local function bindCharacter(character: Model?)
	if abilityCastActiveConnection then
		abilityCastActiveConnection:Disconnect()
		abilityCastActiveConnection = nil
	end
	if not character then
		return
	end
	abilityCastActiveConnection = character:GetAttributeChangedSignal(ABILITY_CAST_ACTIVE_ATTRIBUTE):Connect(refreshMovementLock)
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

local function refreshBufferAttribute()
	local isBuffered = pendingBufferedCast or castHeld
	local isActive = isBuffered and isLocallyReadyToCast()
	localPlayer:SetAttribute(ATTR_ULTIMATE_BUFFER_ACTIVE, isActive)
end

local function canAttemptCast(requireReady: boolean, suppressWarnings: boolean?): boolean
	if requireReady and (not isReady) then
		return false
	end
	if (not requireReady) and (not isReady) and not suppressWarnings then
		-- Server is authoritative for charge; allow initial request even if local ready state is stale.
		warn("[UltimateInputController] G pressed while local ready=false; sending request to server for authoritative check")
	end
	if GuiService.MenuIsOpen then
		if not suppressWarnings then
			warn("[UltimateInputController] G blocked: menu open")
		end
		return false
	end
	if UserInputService:GetFocusedTextBox() then
		if not suppressWarnings then
			warn("[UltimateInputController] G blocked: textbox focused")
		end
		return false
	end
	if localPlayer:GetAttribute("CooldownsFrozen") == true then
		if not suppressWarnings then
			warn("[UltimateInputController] G blocked: CooldownsFrozen=true")
		end
		return false
	end
	if localPlayer:GetAttribute("UltimateInputLocked") == true then
		if not suppressWarnings then
			warn("[UltimateInputController] G blocked: UltimateInputLocked=true")
		end
		return false
	end

	local character = localPlayer.Character
	if not character then
		return false
	end
	if character:GetAttribute(WEAPON_M2_CAST_ACTIVE_LOCAL_ATTRIBUTE) == true then
		if not suppressWarnings then
			warn("[UltimateInputController] G blocked: WeaponM2CastActiveLocal=true")
		end
		return false
	end
	if character:GetAttribute(UTILITY_CAST_ACTIVE_LOCAL_ATTRIBUTE) == true then
		if not suppressWarnings then
			warn("[UltimateInputController] G blocked: UtilityCastActiveLocal=true")
		end
		return false
	end
	if character:GetAttribute(ABILITY_CAST_ACTIVE_ATTRIBUTE) == true then
		if not suppressWarnings then
			warn("[UltimateInputController] G blocked: AbilityCastActiveLocal=true")
		end
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0.01 then
		if not suppressWarnings then
			warn("[UltimateInputController] G blocked: character not alive")
		end
		return false
	end

	return true
end

function isLocallyReadyToCast(): boolean
	return canAttemptCast(true, true)
end

local function canRetainBufferedCast(): boolean
	if not castHeld then
		return false
	end
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

local function attemptCast(requireReady: boolean, suppressWarnings: boolean?): boolean
	if not canAttemptCast(requireReady, suppressWarnings) then
		return false
	end

	local targetPoint = buildAimPoint()
	if not targetPoint then
		return false
	end

	pendingBufferedCast = false
	refreshBufferAttribute()
	isReady = false

	ultimateCastRequestRemote:FireServer({
		targetPoint = targetPoint,
		clientPressedAt = tick(),
	})
	if not suppressWarnings then
		warn("[UltimateInputController] Sent UltimateCastRequest")
	end
	return true
end

local function processBufferedCast()
	if not pendingBufferedCast then
		return
	end
	if attemptCast(true, true) then
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
	if attemptCast(false, false) then
		return
	end
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

ultimateStateUpdateRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	isReady = payload.ready == true
	if pendingBufferedCast then
		processBufferedCast()
	end
end)

localPlayer:GetAttributeChangedSignal("UltimateInputLocked"):Connect(refreshMovementLock)
localPlayer.CharacterAdded:Connect(function()
	bindCharacter(localPlayer.Character)
	refreshMovementLock()
end)
localPlayer.CharacterRemoving:Connect(function()
	castHeld = false
	pendingBufferedCast = false
	refreshBufferAttribute()
	bindCharacter(nil)
	sawLocalCastActiveForCurrentServerLock = false
	setMovementLocked(false)
end)

bindCharacter(localPlayer.Character)
refreshMovementLock()

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

refreshBufferAttribute()
