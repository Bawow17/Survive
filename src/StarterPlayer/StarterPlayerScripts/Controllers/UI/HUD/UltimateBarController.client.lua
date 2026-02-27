--!strict
-- UltimateBarController - Updates ultimate fill + ready stroke from server state.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
if not playerScripts then
	playerScripts = localPlayer:WaitForChild("PlayerScripts", 10)
end
local scriptsContainer = playerScripts or script:FindFirstAncestor("StarterPlayerScripts")
if not scriptsContainer then
	warn("[UltimateBarController] Could not locate StarterPlayerScripts ancestor")
	return
end
local localSharedFolder = scriptsContainer:WaitForChild("_Shared", 10)
if not localSharedFolder then
	warn("[UltimateBarController] Could not locate _Shared folder")
	return
end
local MainHUDLocator = require(localSharedFolder:WaitForChild("MainHUDLocator"))

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local ultimateStateUpdateRemote = remotesFolder:WaitForChild("UltimateStateUpdate") :: RemoteEvent

local warnedMissingPath = false
local fillFrame: Frame? = nil
local readyStroke: UIStroke? = nil

local function findPath(parent: Instance?, names: {string}): Instance?
	local current = parent
	for _, name in ipairs(names) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function resolveUI()
	local mainHUD = MainHUDLocator.waitForMainHUD(playerGui)
	local fill = findPath(mainHUD, {
		"BottomBarFrame",
		"AbilityUiFrame",
		"AbilityFrame",
		"SlotBoundsFrame",
		"UltimateBarFrame",
		"UltimateBarEmptyFrame",
		"UltimateBarFill",
	})

	if fill and fill:IsA("Frame") then
		fillFrame = fill
		local stroke = fill:FindFirstChild("UltimateReadyStroke")
		if stroke and stroke:IsA("UIStroke") then
			readyStroke = stroke
		else
			readyStroke = nil
		end
		return
	end

	fillFrame = nil
	readyStroke = nil
	if not warnedMissingPath then
		warnedMissingPath = true
		warn("[UltimateBarController] Ultimate bar path not found in MainHUD")
	end
end

local function applyState(charge: number, maxCharge: number, ready: boolean)
	if fillFrame and not fillFrame.Parent then
		fillFrame = nil
		readyStroke = nil
	end
	if not fillFrame then
		resolveUI()
	end
	if not fillFrame then
		return
	end

	local safeMax = math.max(maxCharge, 1)
	local ratio = math.clamp(charge / safeMax, 0, 1)
	fillFrame.Size = UDim2.new(ratio, 0, 1, 0)

	if readyStroke then
		readyStroke.Enabled = ready
	end
end

resolveUI()
applyState(0, 10000, false)

ultimateStateUpdateRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local charge = if typeof(payload.charge) == "number" then payload.charge else 0
	local maxCharge = if typeof(payload.maxCharge) == "number" then payload.maxCharge else 10000
	local ready = payload.ready == true
	applyState(charge, maxCharge, ready)
end)
