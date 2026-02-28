--!strict
-- AbilitySlotHUDController - Drives slot-based ability HUD with single-clock cooldown visuals

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local UpgradeIcons = require(sharedFolder:WaitForChild("UpgradeIcons"))

local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local ecsRemotes = remotesFolder:WaitForChild("ECS")
local entitySync = ecsRemotes:WaitForChild("EntitySync")
local entityUpdate = ecsRemotes:WaitForChild("EntityUpdate")
local requestInitialSync = ecsRemotes:WaitForChild("RequestInitialSync")
local abilityCastRemote = remotesFolder:WaitForChild("AbilityCast")
local weaponRemotesFolder = remotesFolder:WaitForChild("Weapons")

local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
if not playerScripts then
	playerScripts = localPlayer:WaitForChild("PlayerScripts", 10)
end
local scriptsContainer = playerScripts or script:FindFirstAncestor("StarterPlayerScripts")
if not scriptsContainer then
	warn("[AbilitySlotHUDController] Could not locate StarterPlayerScripts ancestor")
	return
end
local localSharedFolder = scriptsContainer:WaitForChild("_Shared", 10)
if not localSharedFolder then
	warn("[AbilitySlotHUDController] Could not locate _Shared folder")
	return
end
local LocalEventRegistry = require(localSharedFolder:WaitForChild("LocalEventRegistry"))
local MainHUDLocator = require(localSharedFolder:WaitForChild("MainHUDLocator"))

local gamePaused = remotesFolder:WaitForChild("GamePaused")
local gameUnpaused = remotesFolder:WaitForChild("GameUnpaused")

local PRIMARY_ABILITY_ID = "MagicBolt"
local WEAPON_ID = "Oathkeeper"
local PRIMARY_WEAPON_ICON_KEY = "weapon:Oathkeeper"
local SECONDARY_WEAPON_ICON_KEY = "MagicBolt"
local COOLDOWN_EPSILON = 1e-4
local DEBUG_COOLDOWN_HUD = false

type SlotName = "Primary" | "Utility" | "Secondary" | "Special" | "Equipment"
type ImageGui = ImageLabel | ImageButton
type CooldownStateName = "idle" | "active"

type SlotRef = {
	root: Instance?,
	image: ImageGui?,
	cooldown: Frame?,
	timerLabel: TextLabel?,
	stroke: UIStroke?,
}

type ServerCooldownSample = {
	remaining: number,
	maximum: number,
	at: number,
}

type SlotCooldownState = {
	state: CooldownStateName,
	duration: number,
	remaining: number,
	lastCastSerial: number,
	lastStartAt: number,
	lastStartDuration: number,
	lastRenderedY: number?,
	lastVisible: boolean?,
	lastServerSample: ServerCooldownSample?,
}

type CooldownBaseY = {
	scale: number,
	offset: number,
}

local warned: {[string]: boolean} = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn(message)
end

local weaponSharedLockoutLocalEvent = LocalEventRegistry.getOrCreate(weaponRemotesFolder, "WeaponSharedLockoutLocal")

local function debugLog(message: string)
	if not DEBUG_COOLDOWN_HUD then
		return
	end
	print("[AbilitySlotHUDController] " .. message)
end

local mainHUD: Instance = MainHUDLocator.waitForMainHUD(playerGui)

local sharedComponents: {[string]: {[number]: any}} = {
	EntityType = {},
	AbilityData = {},
	MobilityData = {},
}

local playerEntityId: number? = nil
local playerComponentState: {[string]: any} = {}

local isPaused = false

local slotRefs: {[string]: SlotRef} = {
	Primary = { root = nil, image = nil, cooldown = nil, timerLabel = nil, stroke = nil },
	Utility = { root = nil, image = nil, cooldown = nil, timerLabel = nil, stroke = nil },
	Secondary = { root = nil, image = nil, cooldown = nil, timerLabel = nil, stroke = nil },
	Special = { root = nil, image = nil, cooldown = nil, timerLabel = nil, stroke = nil },
	Equipment = { root = nil, image = nil, cooldown = nil, timerLabel = nil, stroke = nil },
}

local CASTABLE_SLOTS: {SlotName} = { "Primary", "Utility", "Secondary", "Special", "Equipment" }
local ABILITY_SLOTS: {SlotName} = { "Secondary", "Special", "Equipment" }
local NON_SECONDARY_ABILITY_SLOTS: {SlotName} = { "Special", "Equipment" }
local ABILITY_PRIORITY = { "IceShard", "FireBall", "Refractions" }

local chargeLabels: {[string]: TextLabel?} = {
	Primary = nil,
	Utility = nil,
	Secondary = nil,
	Special = nil,
	Equipment = nil,
}
local lastAppliedIconBySlot: {[string]: string?} = {}
local lastAppliedHiddenBySlot: {[string]: boolean?} = {}
local lastAppliedTimerTextBySlot: {[string]: string?} = {}
local lastAppliedTimerVisibleBySlot: {[string]: boolean?} = {}
local lastAppliedStrokeEnabledBySlot: {[string]: boolean?} = {}
local cooldownBaseYByFrame: {[Frame]: CooldownBaseY} = {}
local sanitizedCooldownFrames: {[Frame]: boolean} = {}

local function getCooldownBaseY(frame: Frame): CooldownBaseY
	local cached = cooldownBaseYByFrame[frame]
	if cached then
		return cached
	end
	local yScale = frame.Size.Y.Scale
	local yOffset = frame.Size.Y.Offset
	if yScale == 0 and yOffset == 0 then
		yScale = 1
	end
	local base = {
		scale = yScale,
		offset = yOffset,
	}
	cooldownBaseYByFrame[frame] = base
	return base
end

local function sanitizeCooldownFrame(frame: Frame)
	if sanitizedCooldownFrames[frame] then
		return
	end
	sanitizedCooldownFrames[frame] = true

	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("UISizeConstraint") then
			child.Enabled = false
		end
	end
end

local function forceTransparent(instance: Instance)
	if instance:IsA("UIStroke") then
		instance.Transparency = 1
		return
	end
	if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		instance.ImageTransparency = 1
		instance.BackgroundTransparency = 1
		return
	end
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		instance.TextTransparency = 1
		instance.BackgroundTransparency = 1
		return
	end
	if instance:IsA("Frame") then
		instance.BackgroundTransparency = 1
	end
end

local function hidePrimaryCooldownLine(cooldownFrame: Frame?)
	if not cooldownFrame then
		return
	end
	local cooldownLine = cooldownFrame:FindFirstChild("CooldownLine", true)
	if not cooldownLine then
		return
	end
	forceTransparent(cooldownLine)
	if cooldownLine:IsA("GuiObject") then
		cooldownLine.Visible = false
	end
	for _, descendant in ipairs(cooldownLine:GetDescendants()) do
		forceTransparent(descendant)
		if descendant:IsA("GuiObject") then
			descendant.Visible = false
		end
	end
end

local slotCooldownStates: {[string]: SlotCooldownState} = {}
for _, slotName in ipairs(CASTABLE_SLOTS) do
	slotCooldownStates[slotName] = {
		state = "idle",
		duration = 1,
		remaining = 0,
		lastCastSerial = 0,
		lastStartAt = 0,
		lastStartDuration = 0,
		lastRenderedY = nil,
		lastVisible = nil,
		lastServerSample = nil,
	}
end

local abilitySlotByAbilityId: {[string]: SlotName} = {}
local assignedAbilityBySlot: {[string]: string?} = {
	Primary = nil,
	Utility = nil,
	Secondary = nil,
	Special = nil,
	Equipment = nil,
}
local lastWeaponModeActive = false

local uiResolved = false
local lastUIResolveTime = 0

local function shallowCopy<T>(original: {[any]: T}): {[any]: T}
	local copy: {[any]: T} = {}
	for key, value in pairs(original) do
		copy[key] = value
	end
	return copy
end

local function applySharedDefinitions(sharedData: any)
	if typeof(sharedData) ~= "table" then
		return
	end

	for componentName, entries in pairs(sharedData) do
		local bucket = sharedComponents[componentName]
		if bucket and typeof(entries) == "table" then
			for id, value in pairs(entries) do
				local numericId = tonumber(id)
				if numericId then
					bucket[numericId] = value
				end
			end
		end
	end
end

local function resolveEntityData(entityData: {[string]: any}): {[string]: any}
	local needsResolve = false
	for componentName, value in pairs(entityData) do
		if typeof(value) == "number" then
			local bucket = sharedComponents[componentName]
			if bucket and bucket[value] ~= nil then
				needsResolve = true
				break
			end
		end
	end

	if not needsResolve then
		return entityData
	end

	local resolved = shallowCopy(entityData)
	for componentName, value in pairs(entityData) do
		if typeof(value) == "number" then
			local bucket = sharedComponents[componentName]
			if bucket and bucket[value] ~= nil then
				resolved[componentName] = bucket[value]
			end
		end
	end
	return resolved
end

local function isPlayerEntityPayload(entityData: any): boolean
	if typeof(entityData) ~= "table" then
		return false
	end

	local entityType = entityData.EntityType
	if entityType and typeof(entityType) == "table" then
		return entityType.type == "Player" and entityType.player == localPlayer
	end
	return false
end

local function getSlotImage(slotRoot: Instance?): ImageGui?
	if not slotRoot then
		return nil
	end
	if slotRoot:IsA("ImageLabel") or slotRoot:IsA("ImageButton") then
		return slotRoot
	end

	local imageLabel = slotRoot:FindFirstChildWhichIsA("ImageLabel", true)
	if imageLabel and imageLabel:IsA("ImageLabel") then
		return imageLabel
	end
	local imageButton = slotRoot:FindFirstChildWhichIsA("ImageButton", true)
	if imageButton and imageButton:IsA("ImageButton") then
		return imageButton
	end
	return nil
end

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

local function parseEntityId(rawId: any): number?
	if typeof(rawId) == "number" then
		return rawId
	end
	if typeof(rawId) == "string" then
		return tonumber(rawId)
	end
	return nil
end

local function isWeaponModeActive(): boolean
	local character = localPlayer.Character
	if not character then
		return false
	end
	return character:GetAttribute("StarterWeaponId") == WEAPON_ID
end

local function resolveUIReferences()
	if not mainHUD.Parent then
		mainHUD = MainHUDLocator.waitForMainHUD(playerGui)
	end

	local bottomBarFrame = mainHUD:FindFirstChild("BottomBarFrame")
	if not bottomBarFrame then
		uiResolved = false
		warnOnce("MissingBottomBarFrame", "[AbilitySlotHUDController] MainHUD.BottomBarFrame not found")
		return
	end

	local abilityUiFrame = bottomBarFrame:FindFirstChild("AbilityUiFrame")
	if not abilityUiFrame then
		uiResolved = false
		warnOnce("MissingAbilityUiFrame", "[AbilitySlotHUDController] MainHUD.BottomBarFrame.AbilityUiFrame not found")
		return
	end

	local abilityFrame = abilityUiFrame:FindFirstChild("AbilityFrame")
	if not abilityFrame then
		uiResolved = false
		warnOnce("MissingAbilityFrame", "[AbilitySlotHUDController] AbilityUiFrame.AbilityFrame not found")
		return
	end

	local basicAbilityFrame = abilityFrame:FindFirstChild("BasicAbilityFrame")
	if not basicAbilityFrame then
		local slotBoundsFrame = abilityFrame:FindFirstChild("SlotBoundsFrame")
		if slotBoundsFrame then
			basicAbilityFrame = slotBoundsFrame:FindFirstChild("BasicAbilityFrame")
		end
	end
	if not basicAbilityFrame then
		uiResolved = false
		warnOnce(
			"MissingBasicAbilityFrame",
			"[AbilitySlotHUDController] BasicAbilityFrame not found (checked direct and SlotBoundsFrame)"
		)
		return
	end

	local abilityChargesFrame = abilityUiFrame:FindFirstChild("AbilityChargesFrame")
	if not abilityChargesFrame then
		abilityChargesFrame = abilityFrame:FindFirstChild("AbilityChargesFrame")
	end
	if not abilityChargesFrame then
		local slotBoundsFrame = abilityFrame:FindFirstChild("SlotBoundsFrame")
		if slotBoundsFrame then
			abilityChargesFrame = slotBoundsFrame:FindFirstChild("AbilityChargesFrame")
		end
	end

	slotRefs.Primary.root = findPath(basicAbilityFrame, { "PrimaryAbility" })
	slotRefs.Utility.root = findPath(basicAbilityFrame, { "UtilityAbility" })
	slotRefs.Secondary.root = findPath(basicAbilityFrame, { "SecondaryAbility" })
	slotRefs.Special.root = findPath(basicAbilityFrame, { "SpecialAbility" })
	slotRefs.Equipment.root = findPath(basicAbilityFrame, { "EquipmentAbilityFrame", "EquipmentAbility" })

	for slotName, ref in pairs(slotRefs) do
		ref.image = getSlotImage(ref.root)
		local cooldown = findPath(ref.root, { "BaseCooldownFrame", "CooldownFrame" })
		ref.cooldown = if cooldown and cooldown:IsA("Frame") then cooldown else nil
		local timerLabel = ref.root and ref.root:FindFirstChild("CooldownTimerLabel")
		ref.timerLabel = if timerLabel and timerLabel:IsA("TextLabel") then timerLabel else nil
		local stroke = ref.root and ref.root:FindFirstChild("UIStroke")
		if not stroke and ref.root then
			stroke = ref.root:FindFirstChildWhichIsA("UIStroke", true)
		end
		ref.stroke = if stroke and stroke:IsA("UIStroke") then stroke else nil
		if ref.cooldown then
			sanitizeCooldownFrame(ref.cooldown)
			getCooldownBaseY(ref.cooldown)
			if slotName == "Primary" then
				hidePrimaryCooldownLine(ref.cooldown)
			end
		end
		if ref.root == nil then
			warnOnce("MissingSlotRoot_" .. slotName, string.format("[AbilitySlotHUDController] Slot root missing: %s", slotName))
		end
		if ref.cooldown == nil then
			warnOnce("MissingCooldownFrame_" .. slotName, string.format("[AbilitySlotHUDController] CooldownFrame missing for slot: %s", slotName))
		end
		if ref.timerLabel == nil then
			warnOnce("MissingCooldownTimerLabel_" .. slotName, string.format("[AbilitySlotHUDController] CooldownTimerLabel missing for slot: %s", slotName))
		end
		if ref.stroke == nil then
			warnOnce("MissingUIStroke_" .. slotName, string.format("[AbilitySlotHUDController] UIStroke missing for slot: %s", slotName))
		end
	end

	chargeLabels.Primary = nil
	chargeLabels.Utility = nil
	chargeLabels.Secondary = nil
	chargeLabels.Special = nil
	chargeLabels.Equipment = nil

	local primaryCharges = findPath(slotRefs.Primary.root, { "BaseFrameExtras", "PrimaryChargesTextLabel" })
	chargeLabels.Primary = if primaryCharges and primaryCharges:IsA("TextLabel") then primaryCharges else nil

	local utilityCharges = findPath(slotRefs.Utility.root, { "BaseFrameExtras", "UtilityChargesTextLabel" })
	chargeLabels.Utility = if utilityCharges and utilityCharges:IsA("TextLabel") then utilityCharges else nil

	local secondaryCharges = findPath(slotRefs.Secondary.root, { "BaseFrameExtras", "SecondaryChargesTextLabel" })
	chargeLabels.Secondary = if secondaryCharges and secondaryCharges:IsA("TextLabel") then secondaryCharges else nil

	local specialCharges = findPath(slotRefs.Special.root, { "BaseFrameExtras", "SpecialChargesTextLabel" })
	chargeLabels.Special = if specialCharges and specialCharges:IsA("TextLabel") then specialCharges else nil

	local equipmentCharges = findPath(slotRefs.Equipment.root, { "BaseFrameExtras", "EquipmentChargesTextLabel" })
	chargeLabels.Equipment = if equipmentCharges and equipmentCharges:IsA("TextLabel") then equipmentCharges else nil

	if chargeLabels.Primary == nil then
		warnOnce("MissingPrimaryChargesTextLabel", "[AbilitySlotHUDController] PrimaryChargesTextLabel not found")
	end
	if chargeLabels.Utility == nil then
		warnOnce("MissingUtilityChargesTextLabel", "[AbilitySlotHUDController] UtilityChargesTextLabel not found")
	end
	if chargeLabels.Secondary == nil then
		warnOnce("MissingSecondaryChargesTextLabel", "[AbilitySlotHUDController] SecondaryChargesTextLabel not found")
	end
	if chargeLabels.Special == nil then
		warnOnce("MissingSpecialChargesTextLabel", "[AbilitySlotHUDController] SpecialChargesTextLabel not found")
	end
	if chargeLabels.Equipment == nil then
		warnOnce("MissingEquipmentChargesTextLabel", "[AbilitySlotHUDController] EquipmentChargesTextLabel not found")
	end

	-- Legacy fallback (older UI tree with AbilityChargesFrame).
	if abilityChargesFrame then
		if chargeLabels.Primary == nil then
			local primaryText = abilityChargesFrame:FindFirstChild("PrimaryTextLabel")
			chargeLabels.Primary = if primaryText and primaryText:IsA("TextLabel") then primaryText else nil
		end
		if chargeLabels.Utility == nil then
			local utilityText = abilityChargesFrame:FindFirstChild("UtilityTextLabel")
			chargeLabels.Utility = if utilityText and utilityText:IsA("TextLabel") then utilityText else nil
		end
		if chargeLabels.Secondary == nil then
			local secondaryText = abilityChargesFrame:FindFirstChild("SecondaryTextLabel")
			chargeLabels.Secondary = if secondaryText and secondaryText:IsA("TextLabel") then secondaryText else nil
		end
		if chargeLabels.Special == nil then
			local specialText = abilityChargesFrame:FindFirstChild("SpecialTextLabel")
			chargeLabels.Special = if specialText and specialText:IsA("TextLabel") then specialText else nil
		end
		if chargeLabels.Equipment == nil then
			local equipmentText = findPath(abilityChargesFrame, { "EquipmentAbilityFrame", "EquipmentTextLabel" })
			chargeLabels.Equipment = if equipmentText and equipmentText:IsA("TextLabel") then equipmentText else nil
		end
	end

	uiResolved = true
end

local function normalizeIconId(rawId: any): string?
	if rawId == nil then
		return nil
	end

	local iconString = tostring(rawId)
	if iconString == "" then
		return nil
	end
	if iconString:match("^%d+$") then
		return "rbxassetid://" .. iconString
	end
	return iconString
end

local function setSlotIcon(slotName: SlotName, iconKey: string?)
	local ref = slotRefs[slotName]
	if not ref then
		return
	end
	local imageObject = ref.image
	if not imageObject then
		warnOnce("MissingSlotImage_" .. slotName, string.format("[AbilitySlotHUDController] Image object missing for slot: %s", slotName))
		return
	end
	if not iconKey then
		return
	end

	local rawIconId = UpgradeIcons[iconKey]
	local iconId = normalizeIconId(rawIconId)
	if not iconId then
		warnOnce("MissingIconKey_" .. iconKey, string.format("[AbilitySlotHUDController] Missing icon mapping for key: %s", iconKey))
		return
	end

	local alreadyApplied = lastAppliedIconBySlot[slotName] == iconId
		and lastAppliedHiddenBySlot[slotName] == false
		and imageObject.Image == iconId
		and imageObject.ImageTransparency == 0
	if alreadyApplied then
		return
	end

	imageObject.Image = iconId
	imageObject.ImageTransparency = 0
	lastAppliedIconBySlot[slotName] = iconId
	lastAppliedHiddenBySlot[slotName] = false
end

local function forceHideSlotImage(slotName: SlotName)
	local ref = slotRefs[slotName]
	if not ref or not ref.image then
		return
	end
	if lastAppliedHiddenBySlot[slotName] == true and ref.image.ImageTransparency == 1 then
		return
	end
	ref.image.ImageTransparency = 1
	lastAppliedHiddenBySlot[slotName] = true
end

local function setLabelHidden(label: TextLabel?)
	if not label then
		return
	end
	label.TextTransparency = 1
end

local function getSlotCooldownState(slotName: SlotName): SlotCooldownState?
	return slotCooldownStates[slotName]
end

local function clearSlotCooldown(slotName: SlotName)
	local state = getSlotCooldownState(slotName)
	if not state then
		return
	end
	state.state = "idle"
	state.remaining = 0
	state.lastServerSample = nil
end

local function startSlotCooldown(slotName: SlotName, duration: number, initialRemaining: number?)
	if duration <= 0 then
		return
	end

	local state = getSlotCooldownState(slotName)
	if not state then
		return
	end

	local clampedDuration = math.max(duration, COOLDOWN_EPSILON)
	local remaining = initialRemaining
	if typeof(remaining) ~= "number" then
		remaining = clampedDuration
	end
	local now = tick()
	local duplicateStartWindow = 0.08
	local sameDuration = math.abs(state.lastStartDuration - clampedDuration) <= COOLDOWN_EPSILON
	if state.state == "active" and sameDuration and (now - state.lastStartAt) <= duplicateStartWindow then
		return
	end

	state.lastCastSerial += 1
	state.lastStartAt = now
	state.lastStartDuration = clampedDuration
	state.state = "active"
	state.duration = clampedDuration
	state.remaining = math.clamp(remaining, 0, clampedDuration)
	if state.remaining <= 0 then
		state.state = "idle"
	end

	debugLog(string.format("cast-start slot=%s serial=%d duration=%.3f remaining=%.3f", slotName, state.lastCastSerial, state.duration, state.remaining))
end

local function hydrateSlotCooldownFromServer(slotName: SlotName, remaining: number, maximum: number, source: string)
	if typeof(remaining) ~= "number" or typeof(maximum) ~= "number" or maximum <= 0 then
		return
	end

	local state = getSlotCooldownState(slotName)
	if not state then
		return
	end

	local now = tick()
	local prevSample = state.lastServerSample
	if prevSample then
		local sameRemaining = math.abs(prevSample.remaining - remaining) <= COOLDOWN_EPSILON
		local sameMaximum = math.abs(prevSample.maximum - maximum) <= COOLDOWN_EPSILON
		if sameRemaining and sameMaximum and (now - prevSample.at) <= 1.0 then
			return
		end
	end

	state.lastServerSample = {
		remaining = remaining,
		maximum = maximum,
		at = now,
	}

	-- Cast-owned timer is authoritative while active.
	if state.state == "active" then
		debugLog(string.format("server-ignored slot=%s source=%s remaining=%.3f max=%.3f", slotName, source, remaining, maximum))
		return
	end

	if remaining <= 0 then
		state.state = "idle"
		state.duration = math.max(maximum, COOLDOWN_EPSILON)
		state.remaining = 0
		return
	end

	state.state = "active"
	state.duration = math.max(maximum, COOLDOWN_EPSILON)
	state.remaining = math.clamp(remaining, 0, state.duration)
	debugLog(string.format("server-recover slot=%s source=%s remaining=%.3f max=%.3f", slotName, source, state.remaining, state.duration))
end

local function stepSlotCooldowns(dt: number)
	if isPaused then
		return
	end

	for _, slotName in ipairs(CASTABLE_SLOTS) do
		local state = getSlotCooldownState(slotName)
		if state and state.state == "active" then
			state.remaining = math.max(0, state.remaining - dt)
			if state.remaining <= 0 then
				state.remaining = 0
				state.state = "idle"
				debugLog("timer-complete slot=" .. slotName)
			end
		end
	end
end

local function getSlotCooldownRatio(slotName: SlotName): number
	local state = getSlotCooldownState(slotName)
	if not state or state.state ~= "active" then
		return 0
	end
	if state.duration <= 0 then
		return 0
	end
	return math.clamp(state.remaining / state.duration, 0, 1)
end

local function renderCooldownFrame(slotName: SlotName, ratio: number)
	local ref = slotRefs[slotName]
	local state = getSlotCooldownState(slotName)
	if not ref or not ref.cooldown or not state then
		return
	end

	local frame = ref.cooldown
	local clamped = math.clamp(ratio, 0, 1)
	local baseY = getCooldownBaseY(frame)
	local renderRatio = clamped
	local shouldShow = clamped > 0
	if state.lastVisible == nil or state.lastVisible ~= shouldShow or frame.Visible ~= shouldShow then
		frame.Visible = shouldShow
		state.lastVisible = shouldShow
	end

	if not shouldShow then
		state.lastRenderedY = 0
		return
	end

	local desiredYScale = baseY.scale * renderRatio
	local desiredYOffset = baseY.offset * renderRatio
	local size = frame.Size
	local currentY = size.Y.Scale
	local needsResize = state.lastRenderedY == nil
		or math.abs(renderRatio - (state.lastRenderedY or 0)) > COOLDOWN_EPSILON
		or math.abs(currentY - desiredYScale) > COOLDOWN_EPSILON
		or math.abs(size.Y.Offset - desiredYOffset) > COOLDOWN_EPSILON
	if needsResize then
		-- Cooldown overlay contract: only Y size changes.
		local nextSize = UDim2.new(size.X.Scale, size.X.Offset, desiredYScale, desiredYOffset)
		frame.Size = nextSize
		state.lastRenderedY = renderRatio
	end
end

local function renderAllCooldownFrames(ratiosBySlot: {[string]: number})
	for _, slotName in ipairs(CASTABLE_SLOTS) do
		renderCooldownFrame(slotName, ratiosBySlot[slotName] or 0)
	end
end

local function formatCooldownTimer(remaining: number): string?
	if remaining <= 0 then
		return nil
	end
	if remaining > 5 then
		return tostring(math.ceil(remaining))
	end
	local roundedTenths = math.floor((remaining * 10) + 0.5) / 10
	if roundedTenths <= 0 then
		return nil
	end
	return string.format("%.1f", roundedTenths)
end

local function renderCooldownTimerLabel(slotName: SlotName, remaining: number, slotEnabled: boolean)
	local ref = slotRefs[slotName]
	local label = ref and ref.timerLabel
	if not label then
		return
	end

	local displayText = if slotEnabled then formatCooldownTimer(remaining) else nil
	local shouldShow = displayText ~= nil
	if not shouldShow then
		local alreadyHidden = lastAppliedTimerVisibleBySlot[slotName] == false and label.Visible == false
		if alreadyHidden then
			return
		end
		label.Visible = false
		label.Text = ""
		lastAppliedTimerTextBySlot[slotName] = nil
		lastAppliedTimerVisibleBySlot[slotName] = false
		return
	end

	if lastAppliedTimerVisibleBySlot[slotName] ~= true or label.Visible ~= true then
		label.Visible = true
		lastAppliedTimerVisibleBySlot[slotName] = true
	end

	local textValue = displayText :: string
	if lastAppliedTimerTextBySlot[slotName] ~= textValue or label.Text ~= textValue then
		label.Text = textValue
		lastAppliedTimerTextBySlot[slotName] = textValue
	end
end

local function renderAllCooldownTimerLabels(weaponModeActive: boolean)
	local slotEnabledByName: {[string]: boolean} = {
		Primary = false,
		Utility = true,
		Secondary = weaponModeActive or (assignedAbilityBySlot.Secondary ~= nil),
		Special = assignedAbilityBySlot.Special ~= nil,
		Equipment = assignedAbilityBySlot.Equipment ~= nil,
	}

	for _, slotName in ipairs(CASTABLE_SLOTS) do
		local state = getSlotCooldownState(slotName)
		local remaining = 0
		if state and state.state == "active" then
			remaining = math.max(0, state.remaining)
		end
		renderCooldownTimerLabel(slotName, remaining, slotEnabledByName[slotName] == true)
	end
end

local function renderSlotStroke(slotName: SlotName)
	local ref = slotRefs[slotName]
	local state = getSlotCooldownState(slotName)
	if not ref or not ref.stroke or not state then
		return
	end

	local shouldEnable = not (state.state == "active" and state.remaining > COOLDOWN_EPSILON)
	if lastAppliedStrokeEnabledBySlot[slotName] == shouldEnable and ref.stroke.Enabled == shouldEnable then
		return
	end
	ref.stroke.Enabled = shouldEnable
	lastAppliedStrokeEnabledBySlot[slotName] = shouldEnable
end

local function renderAllSlotStrokes()
	for _, slotName in ipairs(CASTABLE_SLOTS) do
		renderSlotStroke(slotName)
	end
end

local function rebuildAbilitySlotAssignments(weaponModeActive: boolean)
	abilitySlotByAbilityId = {}
	assignedAbilityBySlot.Primary = nil

	for _, slotName in ipairs(ABILITY_SLOTS) do
		assignedAbilityBySlot[slotName] = nil
	end

	local abilityData = playerComponentState.AbilityData
	if typeof(abilityData) ~= "table" or typeof(abilityData.abilities) ~= "table" then
		return
	end

	local available: {string} = {}
	for abilityId, record in pairs(abilityData.abilities) do
		if abilityId ~= PRIMARY_ABILITY_ID and typeof(record) == "table" and record.enabled == true then
			table.insert(available, abilityId)
		end
	end

	table.sort(available, function(a, b)
		local aRank = 1000
		local bRank = 1000
		for idx, preferred in ipairs(ABILITY_PRIORITY) do
			if preferred == a then
				aRank = idx
			end
			if preferred == b then
				bRank = idx
			end
		end
		if aRank ~= bRank then
			return aRank < bRank
		end
		return a < b
	end)

	local assignmentSlots: {SlotName}
	if weaponModeActive then
		assignmentSlots = NON_SECONDARY_ABILITY_SLOTS
	else
		assignmentSlots = ABILITY_SLOTS
	end

	for idx, slotName in ipairs(assignmentSlots) do
		local abilityId = available[idx]
		if abilityId then
			assignedAbilityBySlot[slotName] = abilityId
			abilitySlotByAbilityId[abilityId] = slotName
		end
	end
end

local function resolveCastSlot(abilityId: string): SlotName?
	if abilityId == PRIMARY_ABILITY_ID then
		return nil
	end
	if string.sub(abilityId, 1, 9) == "Mobility_" then
		return "Utility"
	end
	rebuildAbilitySlotAssignments(isWeaponModeActive())
	return abilitySlotByAbilityId[abilityId]
end

local function renderAbilitySlotIcons(weaponModeActive: boolean)
	setSlotIcon("Primary", PRIMARY_WEAPON_ICON_KEY)

	local mobilityData = playerComponentState.MobilityData
	local equippedMobility: string? = nil
	if typeof(mobilityData) == "table" and typeof(mobilityData.equippedMobility) == "string" then
		equippedMobility = mobilityData.equippedMobility
	end
	if equippedMobility then
		setSlotIcon("Utility", "mobility:" .. equippedMobility)
	end

	if weaponModeActive then
		setSlotIcon("Secondary", SECONDARY_WEAPON_ICON_KEY)
	else
		local secondaryAbilityId = assignedAbilityBySlot.Secondary
		if secondaryAbilityId then
			setSlotIcon("Secondary", secondaryAbilityId)
		else
			forceHideSlotImage("Secondary")
			clearSlotCooldown("Secondary")
		end
	end

	for _, slotName in ipairs(NON_SECONDARY_ABILITY_SLOTS) do
		local abilityId = assignedAbilityBySlot[slotName]
		if abilityId then
			setSlotIcon(slotName, abilityId)
		else
			forceHideSlotImage(slotName)
			clearSlotCooldown(slotName)
		end
	end
end

local function hydrateIdleCooldownsFromComponents(weaponModeActive: boolean)
	local abilityCooldown = playerComponentState.AbilityCooldown
	local cooldowns = if typeof(abilityCooldown) == "table" and typeof(abilityCooldown.cooldowns) == "table"
		then abilityCooldown.cooldowns
		else nil

	if cooldowns then
		for _, slotName in ipairs(ABILITY_SLOTS) do
			if weaponModeActive and slotName == "Secondary" then
				continue
			end
			local abilityId = assignedAbilityBySlot[slotName]
			if abilityId then
				local record = cooldowns[abilityId]
				if typeof(record) == "table" then
					local slotState = getSlotCooldownState(slotName)
					if slotState and slotState.state == "idle" then
						hydrateSlotCooldownFromServer(slotName, record.remaining, record.max, "AbilityCooldown." .. abilityId)
					end
				end
			end
		end
	end

end

local function getPrimaryChargeCounts(): (number, number)
	return 0, 1
end

local function renderChargeLabels()
	local currentCharges, totalCharges = getPrimaryChargeCounts()
	local primaryLabel = chargeLabels.Primary
	if primaryLabel then
		if totalCharges > 1 then
			primaryLabel.TextTransparency = 0
			primaryLabel.Text = string.format("%d/%d", currentCharges, totalCharges)
		else
			primaryLabel.TextTransparency = 1
		end
	end
	setLabelHidden(primaryLabel)

	setLabelHidden(chargeLabels.Utility)
	setLabelHidden(chargeLabels.Secondary)
	setLabelHidden(chargeLabels.Special)
	setLabelHidden(chargeLabels.Equipment)
end

local function refreshUI()
	local now = tick()
	if not uiResolved or (now - lastUIResolveTime) >= 1 then
		lastUIResolveTime = now
		resolveUIReferences()
	end

	local weaponModeActive = isWeaponModeActive()
	if lastWeaponModeActive ~= weaponModeActive then
		clearSlotCooldown("Primary")
		clearSlotCooldown("Secondary")
	end
	lastWeaponModeActive = weaponModeActive

	rebuildAbilitySlotAssignments(weaponModeActive)
	renderAbilitySlotIcons(weaponModeActive)
	hydrateIdleCooldownsFromComponents(weaponModeActive)
	renderChargeLabels()

	local ratiosBySlot: {[string]: number} = {
		Primary = 0,
		Utility = getSlotCooldownRatio("Utility"),
		Secondary = getSlotCooldownRatio("Secondary"),
		Special = getSlotCooldownRatio("Special"),
		Equipment = getSlotCooldownRatio("Equipment"),
	}
	if weaponModeActive then
		local primaryState = getSlotCooldownState("Primary")
		ratiosBySlot.Primary = if primaryState and primaryState.state == "active" and primaryState.remaining > COOLDOWN_EPSILON
			then 1
			else 0
	end

	-- Hide inactive placeholders when no assigned ability.
	for _, slotName in ipairs(ABILITY_SLOTS) do
		if slotName == "Secondary" and weaponModeActive then
			continue
		end
		if assignedAbilityBySlot[slotName] == nil then
			ratiosBySlot[slotName] = 0
		end
	end

	renderAllCooldownFrames(ratiosBySlot)
	renderAllCooldownTimerLabels(weaponModeActive)
	renderAllSlotStrokes()
end

local function resetAllCooldownStates()
	for _, slotName in ipairs(CASTABLE_SLOTS) do
		local state = getSlotCooldownState(slotName)
		if state then
			state.state = "idle"
			state.remaining = 0
			state.duration = 1
			state.lastCastSerial = 0
			state.lastStartAt = 0
			state.lastStartDuration = 0
			state.lastRenderedY = nil
			state.lastVisible = nil
			state.lastServerSample = nil
		end
	end
end

local function clearPlayerState()
	playerEntityId = nil
	playerComponentState = {}
	abilitySlotByAbilityId = {}
	assignedAbilityBySlot = {
		Primary = nil,
		Utility = nil,
		Secondary = nil,
		Special = nil,
		Equipment = nil,
	}
	resetAllCooldownStates()
	lastAppliedIconBySlot.Utility = nil
	lastAppliedTimerTextBySlot = {}
	lastAppliedTimerVisibleBySlot = {}
	lastAppliedStrokeEnabledBySlot = {}
	lastWeaponModeActive = false
	setLabelHidden(chargeLabels.Primary)
	setLabelHidden(chargeLabels.Utility)
	setLabelHidden(chargeLabels.Secondary)
	setLabelHidden(chargeLabels.Special)
	setLabelHidden(chargeLabels.Equipment)
	for _, slotName in ipairs(CASTABLE_SLOTS) do
		renderCooldownTimerLabel(slotName, 0, false)
	end
end

local function handlePlayerEntityData(entityId: number, entityData: {[string]: any})
	local entityType = entityData.EntityType
	if entityType and typeof(entityType) == "table" then
		if entityType.type ~= "Player" or entityType.player ~= localPlayer then
			return
		end
		playerEntityId = entityId
	end

	if playerEntityId and entityId ~= playerEntityId then
		return
	end
	playerEntityId = playerEntityId or entityId

	if entityData.AbilityData ~= nil then
		playerComponentState.AbilityData = entityData.AbilityData
	end
	if entityData.AbilityCooldown ~= nil then
		playerComponentState.AbilityCooldown = entityData.AbilityCooldown
	end
	if entityData.MobilityData ~= nil then
		playerComponentState.MobilityData = entityData.MobilityData
	end
	if entityData.MobilityCooldown ~= nil then
		playerComponentState.MobilityCooldown = entityData.MobilityCooldown
	end
end

local function processSnapshot(snapshot: any)
	if typeof(snapshot) ~= "table" then
		return
	end

	applySharedDefinitions(snapshot.shared)

	local entities = snapshot.entities
	if typeof(entities) ~= "table" then
		return
	end

	if playerEntityId then
		local direct = entities[playerEntityId] or entities[tostring(playerEntityId)]
		if typeof(direct) == "table" then
			handlePlayerEntityData(playerEntityId, resolveEntityData(direct))
		end
		return
	end

	for entityId, data in pairs(entities) do
		if typeof(data) == "table" then
			local resolved = resolveEntityData(data)
			if isPlayerEntityPayload(resolved) then
				local numericId = parseEntityId(entityId)
				if numericId then
					handlePlayerEntityData(numericId, resolved)
				end
				break
			end
		end
	end

end

local function processUpdates(message: any)
	if typeof(message) ~= "table" then
		return
	end

	applySharedDefinitions(message.shared)

	local entities = message.entities
	if typeof(entities) == "table" then
		if playerEntityId then
			local direct = entities[playerEntityId] or entities[tostring(playerEntityId)]
			if typeof(direct) == "table" then
				handlePlayerEntityData(playerEntityId, resolveEntityData(direct))
			end
		else
			for entityId, data in pairs(entities) do
				if typeof(data) == "table" then
					local resolved = resolveEntityData(data)
					if isPlayerEntityPayload(resolved) then
						local numericId = parseEntityId(entityId)
						if numericId then
							handlePlayerEntityData(numericId, resolved)
						end
						break
					end
				end
			end
		end
	end

	local updates = message.updates
	if typeof(updates) == "table" then
		for _, updateData in ipairs(updates) do
			if typeof(updateData) == "table" and updateData.id then
				local updateId = parseEntityId(updateData.id)
				if not updateId then
					continue
				end
				if playerEntityId then
					if updateId == playerEntityId then
						handlePlayerEntityData(updateId, resolveEntityData(updateData))
					end
				else
					local resolved = resolveEntityData(updateData)
					if isPlayerEntityPayload(resolved) then
						handlePlayerEntityData(updateId, resolved)
					end
				end
			end
		end
	end

	local resyncs = message.resyncs
	if typeof(resyncs) == "table" then
		for _, updateData in ipairs(resyncs) do
			if typeof(updateData) == "table" and updateData.id then
				local updateId = parseEntityId(updateData.id)
				if not updateId then
					continue
				end
				if playerEntityId then
					if updateId == playerEntityId then
						handlePlayerEntityData(updateId, resolveEntityData(updateData))
					end
				else
					local resolved = resolveEntityData(updateData)
					if isPlayerEntityPayload(resolved) then
						handlePlayerEntityData(updateId, resolved)
					end
				end
			end
		end
	end

	local despawns = message.despawns
	if typeof(despawns) == "table" and playerEntityId then
		for _, despawnId in ipairs(despawns) do
			local numericId = parseEntityId(despawnId)
			if numericId == playerEntityId then
				-- Avoid UI flicker from transient despawn notifications; wait for real entity replacement.
				debugLog("ignoring transient player despawn for UI stability")
				break
			end
		end
	end

end

entitySync.OnClientEvent:Connect(processSnapshot)
entityUpdate.OnClientEvent:Connect(processUpdates)

gamePaused.OnClientEvent:Connect(function()
	isPaused = true
end)

gameUnpaused.OnClientEvent:Connect(function()
	isPaused = false
end)

abilityCastRemote.OnClientEvent:Connect(function(abilityId: string, cooldownDuration: number)
	if typeof(cooldownDuration) ~= "number" or cooldownDuration <= 0 then
		return
	end

	local slotName = resolveCastSlot(abilityId)
	if not slotName then
		return
	end
	if slotName == "Primary" then
		return
	end
	if slotName == "Secondary" and isWeaponModeActive() then
		return
	end

	startSlotCooldown(slotName, cooldownDuration, cooldownDuration)
end)

weaponSharedLockoutLocalEvent.Event:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.weaponId ~= WEAPON_ID then
		return
	end
	if not isWeaponModeActive() then
		return
	end

	local duration = if typeof(payload.duration) == "number" then payload.duration else nil
	if (not duration or duration <= 0) and typeof(payload.endTime) == "number" then
		duration = math.max(0, payload.endTime - tick())
	end
	if not duration or duration <= 0 then
		clearSlotCooldown("Primary")
		clearSlotCooldown("Secondary")
		return
	end

	startSlotCooldown("Primary", duration, duration)
	startSlotCooldown("Secondary", duration, duration)
end)

pcall(function()
	local snapshot = requestInitialSync:InvokeServer()
	processSnapshot(snapshot)
end)

RunService.RenderStepped:Connect(function(dt)
	stepSlotCooldowns(dt)
	refreshUI()
end)

refreshUI()
