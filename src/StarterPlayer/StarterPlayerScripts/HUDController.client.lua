--!strict
-- HUDController - Syncs health and experience UI bars with player state

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local StarterGui = game:GetService("StarterGui")

-- Disable default Roblox health bar
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local mainHud = playerGui:WaitForChild("MainHUD")
local topBarFrame = mainHud:WaitForChild("TopBarFrame")
local hpFrame = topBarFrame:WaitForChild("HPFrame")
local hpFill = hpFrame:WaitForChild("HPFill") :: Frame

-- Remove any existing overheal fill (in case of reload)
local existingOverhealFill = hpFrame:FindFirstChild("OverhealFill")
if existingOverhealFill then
	existingOverhealFill:Destroy()
end

-- Create overheal bar dynamically (yellowish-white, overlays health bar and shrinks left-to-right)
local overhealFill = Instance.new("Frame")
overhealFill.Name = "OverhealFill"
overhealFill.BackgroundColor3 = Color3.fromRGB(255, 255, 200)  -- Yellowish-white
overhealFill.BackgroundTransparency = 0.2
overhealFill.BorderSizePixel = 0
overhealFill.AnchorPoint = Vector2.new(0, 0)  -- Start with left anchor (will change dynamically)
overhealFill.Position = UDim2.new(0, 0, 0, 0)  -- Initial position
overhealFill.Size = UDim2.new(0, 0, 1, 0)  -- Start at 0 width
overhealFill.ZIndex = hpFill.ZIndex + 1  -- Render ABOVE health bar
overhealFill.Visible = false
-- CRITICAL: Parent to HPFrame (becomes PlayerGui.MainHUD.TopBarFrame.HPFrame at runtime)
overhealFill.Parent = hpFrame

local bottomBarFrame = mainHud:WaitForChild("BottomBarFrame")
local expBarFrame = bottomBarFrame:WaitForChild("ExpBarFrame")
local expFill = expBarFrame:WaitForChild("ExpFill") :: Frame
local levelLabel = expBarFrame:FindFirstChild("LevelLabel") :: TextLabel?

local expTween: Tween? = nil
local hpTween: Tween? = nil
local overhealTween: Tween? = nil  -- NEW: For synchronized overheal updates
local colorTween: Tween? = nil

local baseHealthColor = hpFill.BackgroundColor3
local lowHealthColor = Color3.fromRGB(255, 0, 0)
local flashColor = Color3.fromRGB(255, 120, 120)
local baseHealthTransparency = 0.2  -- Visible but slightly transparent

local flashActive = false
local flashToken = 0

-- HP bar auto-hide state
local isHPBarHidden = false
local lastHealthChangeTime = 0
local hideTimer = nil
local hideTween: Tween? = nil
local showTween: Tween? = nil
local currentHealth = 100
local maxHealth = 100
local currentOverheal = 0
local maxOverheal = 0

local currentXP = 0
local requiredXP = 100
local currentLevel = 1

local playerEntityId: number? = nil
local playerComponentState: {[string]: any} = {}

local sharedComponents: {[string]: {[number]: any}} = {
	EntityType = {},
	AI = {},
	Visual = {},
	ItemData = {},
}

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
	local resolved = shallowCopy(entityData)
	for componentName, value in pairs(entityData) do
		if typeof(value) == "number" then
			local bucket = sharedComponents[componentName]
			if bucket and bucket[value] then
				resolved[componentName] = bucket[value]
			end
		end
	end
	return resolved
end

local function tweenFill(frame: Frame, goalScale: number)
	if frame == nil then
		return
	end

	local targetSize = UDim2.new(math.clamp(goalScale, 0, 1), 0, 1, 0)
	if expTween and frame == expFill then
		expTween:Cancel()
	elseif hpTween and frame == hpFill then
		hpTween:Cancel()
	end

	local tweenInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(frame, tweenInfo, { Size = targetSize })
	if frame == expFill then
		expTween = tween
	else
		hpTween = tween
	end
	tween:Play()
end

local function tweenOverheal(position: UDim2, size: UDim2)
	if overhealFill == nil then
		return
	end
	
	-- Cancel existing tween
	if overhealTween then
		overhealTween:Cancel()
	end
	
	-- Use same timing as health bar for synchronized animation
	local tweenInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	overhealTween = TweenService:Create(overhealFill, tweenInfo, { 
		Position = position,
		Size = size 
	})
	overhealTween:Play()
end

-- HP Bar Auto-Hide Functions
local function hideHPBar()
	if isHPBarHidden then
		return
	end
	
	-- Don't hide if flashing
	if flashActive then
		return
	end
	
	isHPBarHidden = true
	
	-- Cancel any ongoing show tween
	if showTween then
		showTween:Cancel()
		showTween = nil
	end
	
	-- Smooth fade out over 0.5 seconds to complete invisibility
	hideTween = TweenService:Create(
		hpFill,
		TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	hideTween:Play()
	
	-- Also fade out the frame background and any text/borders
	for _, child in hpFrame:GetDescendants() do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			TweenService:Create(child, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), 
				{ TextTransparency = 1, BackgroundTransparency = 1 }):Play()
		elseif child:IsA("UIStroke") then
			TweenService:Create(child, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), 
				{ Transparency = 1 }):Play()
		elseif child:IsA("ImageLabel") or child:IsA("ImageButton") then
			TweenService:Create(child, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), 
				{ ImageTransparency = 1, BackgroundTransparency = 1 }):Play()
		end
	end
	
	-- Fade the frame itself
	if hpFrame.BackgroundTransparency < 1 then
		TweenService:Create(hpFrame, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), 
			{ BackgroundTransparency = 1 }):Play()
	end
end

local function showHPBar()
	if not isHPBarHidden then
		return
	end
	
	isHPBarHidden = false
	
	-- Cancel any ongoing hide tween
	if hideTween then
		hideTween:Cancel()
		hideTween = nil
	end
	
	-- Quick fade in over 0.15 seconds
	showTween = TweenService:Create(
		hpFill,
		TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = baseHealthTransparency }
	)
	showTween:Play()
	
	-- Also fade in any text/borders
	for _, child in hpFrame:GetDescendants() do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			local originalTextTrans = child:GetAttribute("OriginalTextTransparency") or 0
			local originalBgTrans = child:GetAttribute("OriginalBackgroundTransparency") or 1
			TweenService:Create(child, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), 
				{ TextTransparency = originalTextTrans, BackgroundTransparency = originalBgTrans }):Play()
		elseif child:IsA("UIStroke") then
			local originalStrokeTrans = child:GetAttribute("OriginalTransparency") or 0
			TweenService:Create(child, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), 
				{ Transparency = originalStrokeTrans }):Play()
		elseif child:IsA("ImageLabel") or child:IsA("ImageButton") then
			local originalImgTrans = child:GetAttribute("OriginalImageTransparency") or 0
			local originalBgTrans = child:GetAttribute("OriginalBackgroundTransparency") or 1
			TweenService:Create(child, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), 
				{ ImageTransparency = originalImgTrans, BackgroundTransparency = originalBgTrans }):Play()
		end
	end
	
	-- Restore frame background if it has one
	local originalFrameTrans = hpFrame:GetAttribute("OriginalBackgroundTransparency") or 1
	if originalFrameTrans < 1 then
		TweenService:Create(hpFrame, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), 
			{ BackgroundTransparency = originalFrameTrans }):Play()
	end
end

local function onHealthChange(newHealth: number, newMaxHealth: number)
	-- Update health tracking
	local healthChanged = (newHealth ~= currentHealth) or (newMaxHealth ~= maxHealth)
	currentHealth = newHealth
	maxHealth = newMaxHealth
	
	-- If health changed and not at max, show HP bar
	if healthChanged and currentHealth < maxHealth then
		lastHealthChangeTime = tick()
		
		-- Show HP bar if hidden
		if isHPBarHidden then
			showHPBar()
		end
	end
	
	-- Cancel any pending hide timer
	if hideTimer then
		task.cancel(hideTimer)
		hideTimer = nil
	end
	
	-- Always set timer to hide if at max HP (including on spawn)
	if currentHealth >= maxHealth and not flashActive then
		hideTimer = task.delay(3, function()
			if currentHealth >= maxHealth and not flashActive then
				hideHPBar()
			end
		end)
	end
end

local function stopLowHealthFlash()
	if not flashActive then
		return
	end

	flashActive = false
	flashToken += 1

	if colorTween then
		colorTween:Cancel()
		colorTween = nil
	end

	colorTween = TweenService:Create(
		hpFill,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundColor3 = baseHealthColor }
	)
	colorTween:Play()
	
	-- Only set transparency if not hidden
	if not isHPBarHidden then
		hpFill.BackgroundTransparency = baseHealthTransparency
	end
end

local function startLowHealthFlash()
	if flashActive then
		return
	end

	flashActive = true
	flashToken += 1
	local token = flashToken
	local startTime = tick()
	
	-- Show HP bar when flashing starts
	if isHPBarHidden then
		showHPBar()
	end
	
	-- Cancel hide timer while flashing
	if hideTimer then
		task.cancel(hideTimer)
		hideTimer = nil
	end

	if colorTween then
		colorTween:Cancel()
		colorTween = nil
	end
	hpFill.BackgroundColor3 = lowHealthColor
	hpFill.BackgroundTransparency = 0  -- Fully opaque when flashing

	task.spawn(function()
		while flashActive and (tick() - startTime) < 3 and flashToken == token do
			colorTween = TweenService:Create(
				hpFill,
				TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundColor3 = flashColor }
			)
			colorTween:Play()
			colorTween.Completed:Wait()
			if not flashActive or flashToken ~= token then
				break
			end

			colorTween = TweenService:Create(
				hpFill,
				TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundColor3 = lowHealthColor }
			)
			colorTween:Play()
			colorTween.Completed:Wait()
			if not flashActive or flashToken ~= token then
				break
			end
		end

		if flashToken ~= token then
			return
		end

		if flashActive then
			hpFill.BackgroundColor3 = lowHealthColor
			hpFill.BackgroundTransparency = 0
		end
	end)
end

local function updateHealthUI(current: number, maxHealthValue: number)
	maxHealthValue = math.max(maxHealthValue, 1)
	local healthRatio = math.clamp(current / maxHealthValue, 0, 1)
	
	-- Determine which mode to use
	local isFullHealth = current >= maxHealthValue
	local totalEffectiveHP = current + currentOverheal
	local shouldCompress = not isFullHealth and totalEffectiveHP > maxHealthValue
	
	-- Update white health bar
	if isFullHealth or currentOverheal < 0.1 then
		-- Mode 1 or Mode 3: White shows actual health percentage
		tweenFill(hpFill, healthRatio)
	elseif shouldCompress then
		-- Mode 2: Compress - white shows health / total effective
		local compressedHealthRatio = current / totalEffectiveHP
		tweenFill(hpFill, compressedHealthRatio)
	else
		-- Mode 3: Actual percentage - white shows actual health percentage
		tweenFill(hpFill, healthRatio)
	end
	
	-- CRITICAL: Always make health bar visible when overheal is active
	if currentOverheal > 0 then
		hpFill.BackgroundTransparency = baseHealthTransparency
	end
	
	-- Update overheal bar (yellowish overlay) with synchronized tweening
	if currentOverheal >= 0.1 then
		overhealFill.Visible = true
		
		if isFullHealth then
			-- Mode 1: Full health - Yellow overlaps from right
			local overhealRatio = math.min(currentOverheal / maxHealthValue, 1.0)
			
			overhealFill.AnchorPoint = Vector2.new(1, 0)
			tweenOverheal(
				UDim2.new(1, 0, 0, 0),  -- Position at right edge
				UDim2.new(overhealRatio, 0, 1, 0)  -- Size = overheal ratio
			)
		elseif shouldCompress then
			-- Mode 2: Compress - Share bar proportionally
			local compressedHealthRatio = current / totalEffectiveHP
			local compressedOverhealRatio = currentOverheal / totalEffectiveHP
			
			overhealFill.AnchorPoint = Vector2.new(0, 0)
			tweenOverheal(
				UDim2.new(compressedHealthRatio, 0, 0, 0),  -- Start where white ends
				UDim2.new(compressedOverhealRatio, 0, 1, 0)  -- Width = overheal ratio
			)
		else
			-- Mode 3: Actual percentages - Yellow starts after white
			local overhealRatio = currentOverheal / maxHealthValue
			
			overhealFill.AnchorPoint = Vector2.new(0, 0)
			tweenOverheal(
				UDim2.new(healthRatio, 0, 0, 0),  -- Start where white ends
				UDim2.new(overhealRatio, 0, 1, 0)  -- Width = actual overheal %
			)
		end
	else
		-- Immediately hide when overheal is depleted
		if overhealTween then
			overhealTween:Cancel()
			overhealTween = nil
		end
		overhealFill.Visible = false
		overhealFill.Size = UDim2.new(0, 0, 1, 0)
		overhealFill.Position = UDim2.new(0, 0, 0, 0)
		overhealFill.AnchorPoint = Vector2.new(0, 0)
	end
	
	-- Trigger auto-hide logic
	onHealthChange(current, maxHealthValue)

	if healthRatio <= 0.3 then
		startLowHealthFlash()
	else
		stopLowHealthFlash()
		-- Only set transparency if not hidden
		if not isHPBarHidden then
			hpFill.BackgroundTransparency = baseHealthTransparency
		end
	end
end

local humanoidConnections = {}
local lastHealthUpdateTime = 0
local HEALTH_UPDATE_THROTTLE = 0.05  -- Max 20 updates per second to prevent freeze at low HP

local function disconnectHumanoidConnections()
	for _, connection in ipairs(humanoidConnections) do
		if connection.Connected then
			connection:Disconnect()
		end
	end
	table.clear(humanoidConnections)
end

local function onHumanoidAdded(humanoid: Humanoid)
	disconnectHumanoidConnections()

	updateHealthUI(humanoid.Health, humanoid.MaxHealth)

	-- Listen to overheal attribute changes first (immediate, no replication lag)
	table.insert(humanoidConnections, localPlayer:GetAttributeChangedSignal("Overheal"):Connect(function()
		local playerOverheal = localPlayer:GetAttribute("Overheal") or 0
		local playerMaxOverheal = localPlayer:GetAttribute("MaxOverheal") or 0
		currentOverheal = math.max(0, playerOverheal)
		maxOverheal = math.max(0, playerMaxOverheal)
		
		-- Clear overheal if below threshold
		if currentOverheal < 0.1 then
			currentOverheal = 0
			maxOverheal = 0
		end
		
		-- Update UI immediately when overheal changes
		updateHealthUI(humanoid.Health, humanoid.MaxHealth)
	end))
	
	table.insert(humanoidConnections, humanoid.HealthChanged:Connect(function(health)
		-- CRITICAL: Throttle health updates to prevent freeze when taking rapid damage
		local now = tick()
		if now - lastHealthUpdateTime >= HEALTH_UPDATE_THROTTLE then
			lastHealthUpdateTime = now
			
			-- CRITICAL: Also sync overheal from player attributes when health changes
			-- This ensures overheal is always in sync with health updates
			local playerOverheal = localPlayer:GetAttribute("Overheal") or 0
			local playerMaxOverheal = localPlayer:GetAttribute("MaxOverheal") or 0
			currentOverheal = math.max(0, playerOverheal)
			maxOverheal = math.max(0, playerMaxOverheal)
			
			-- Clear overheal if below threshold
			if currentOverheal < 0.1 then
				currentOverheal = 0
				maxOverheal = 0
			end
			
			updateHealthUI(health, humanoid.MaxHealth)
		end
	end))

	table.insert(humanoidConnections, humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		updateHealthUI(humanoid.Health, humanoid.MaxHealth)
	end))
end

local function onCharacterAdded(character: Model)
	disconnectHumanoidConnections()
	stopLowHealthFlash()
	
	-- Store original transparency values for all children (first time only)
	if not hpFrame:GetAttribute("TransparenciesStored") then
		-- Store frame transparency
		hpFrame:SetAttribute("OriginalBackgroundTransparency", hpFrame.BackgroundTransparency)
		
		-- Store child transparencies
		for _, child in hpFrame:GetDescendants() do
			if child:IsA("TextLabel") or child:IsA("TextButton") then
				child:SetAttribute("OriginalTextTransparency", child.TextTransparency)
				child:SetAttribute("OriginalBackgroundTransparency", child.BackgroundTransparency)
			elseif child:IsA("UIStroke") then
				child:SetAttribute("OriginalTransparency", child.Transparency)
			elseif child:IsA("ImageLabel") or child:IsA("ImageButton") then
				child:SetAttribute("OriginalImageTransparency", child.ImageTransparency)
				child:SetAttribute("OriginalBackgroundTransparency", child.BackgroundTransparency)
			end
		end
		hpFrame:SetAttribute("TransparenciesStored", true)
	end
	
	-- Reset HP bar auto-hide state on character spawn
	hpFill.BackgroundTransparency = baseHealthTransparency
	isHPBarHidden = false
	if hideTimer then
		task.cancel(hideTimer)
		hideTimer = nil
	end
	if hideTween then
		hideTween:Cancel()
		hideTween = nil
	end
	if showTween then
		showTween:Cancel()
		showTween = nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		onHumanoidAdded(humanoid)
	else
		table.insert(humanoidConnections, character.ChildAdded:Connect(function(child)
			if child:IsA("Humanoid") then
				onHumanoidAdded(child)
			end
		end))
	end
end

local function updateExperienceUI()
	-- DISABLED: ExpLevelController now handles exp/level updates via PlayerStatsUpdate remote
	-- This function is kept for compatibility but does nothing
	-- The old system (EntityUpdate) doesn't properly sync player Experience/Level components
end

local function applyExperienceData(experienceComponent: any?, statsComponent: any?, levelComponent: any?)
	local xpAmount = currentXP
	local xpRequired = requiredXP
	local level = currentLevel

	if levelComponent and typeof(levelComponent) == "table" then
		level = levelComponent.level or levelComponent.current or level
	end
	if statsComponent and typeof(statsComponent) == "table" then
		level = statsComponent.level or level
		xpAmount = statsComponent.experience or statsComponent.exp or xpAmount
		xpRequired = statsComponent.requiredExperience or statsComponent.experienceToLevel or statsComponent.nextLevelExperience or xpRequired
	end
	if experienceComponent and typeof(experienceComponent) == "table" then
		xpAmount = experienceComponent.amount or experienceComponent.current or xpAmount
		xpRequired = experienceComponent.required or experienceComponent.toNext or experienceComponent.max or xpRequired
	end

	level = math.max(level or 1, 1)
	xpAmount = math.max(xpAmount or 0, 0)
	if not xpRequired or xpRequired <= 0 then
		xpRequired = level * 100
	end

	currentXP = xpAmount
	requiredXP = xpRequired
	currentLevel = level
	updateExperienceUI()
end

local function handlePlayerEntityData(entityId: number, entityData: {[string]: any})
	local entityType = entityData.EntityType
	if entityType and typeof(entityType) == "table" then
		if entityType.type ~= "Player" then
			return
		end
		if entityType.player ~= localPlayer then
			return
		end
		playerEntityId = entityId
	end

	if playerEntityId and entityId ~= playerEntityId then
		return
	end

	playerEntityId = playerEntityId or entityId

	for componentName, value in pairs(entityData) do
		playerComponentState[componentName] = value
	end

	applyExperienceData(
		playerComponentState.Experience,
		playerComponentState.PlayerStats,
		playerComponentState.Level
	)
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

	for entityId, data in pairs(entities) do
		if typeof(data) == "table" then
			local resolved = resolveEntityData(data)
			handlePlayerEntityData(tonumber(entityId) or entityId, resolved)
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
		for entityId, data in pairs(entities) do
			if typeof(data) == "table" then
				local resolved = resolveEntityData(data)
				handlePlayerEntityData(tonumber(entityId) or entityId, resolved)
			end
		end
	end

	local updates = message.updates
	if typeof(updates) == "table" then
		for _, updateData in ipairs(updates) do
			if typeof(updateData) == "table" and updateData.id then
				local resolved = resolveEntityData(updateData)
				handlePlayerEntityData(updateData.id, resolved)
			end
		end
	end

	local resyncs = message.resyncs
	if typeof(resyncs) == "table" then
		for _, updateData in ipairs(resyncs) do
			if typeof(updateData) == "table" and updateData.id then
				local resolved = resolveEntityData(updateData)
				handlePlayerEntityData(updateData.id, resolved)
			end
		end
	end

	local despawns = message.despawns
	if typeof(despawns) == "table" and playerEntityId then
		for _, despawnId in ipairs(despawns) do
			if despawnId == playerEntityId then
				playerEntityId = nil
				playerComponentState = {}
				currentXP = 0
				requiredXP = 100
				updateExperienceUI()
				break
			end
		end
	end
end

local remotes = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("ECS")
local entitySync = remotes:WaitForChild("EntitySync")
local entityUpdate = remotes:WaitForChild("EntityUpdate")

entitySync.OnClientEvent:Connect(processSnapshot)
entityUpdate.OnClientEvent:Connect(processUpdates)

-- Listen for overheal updates
local overhealRemote = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("OverhealUpdate")
overhealRemote.OnClientEvent:Connect(function(overhealData: any)
	if typeof(overhealData) == "table" then
		-- Clamp overheal to avoid negative or NaN values
		currentOverheal = math.max(0, overhealData.current or 0)
		maxOverheal = math.max(0, overhealData.max or 0)
		
		-- Clear overheal completely if below threshold
		if currentOverheal < 0.1 then
			currentOverheal = 0
			maxOverheal = 0
		end
		
		-- Update health UI to reflect overheal change
		updateHealthUI(currentHealth, maxHealth)
	end
end)

-- Initial HUD state
updateExperienceUI()

if localPlayer.Character then
	onCharacterAdded(localPlayer.Character)
end

localPlayer.CharacterAdded:Connect(onCharacterAdded)

-- Death state handling - Turn health bar full red
local isInDeathState = false
local deathBarTween: Tween? = nil

local function enterDeathState()
	isInDeathState = true
	
	-- Cancel any ongoing tweens
	if hpTween then
		hpTween:Cancel()
		hpTween = nil
	end
	if colorTween then
		colorTween:Cancel()
		colorTween = nil
	end
	if overhealTween then
		overhealTween:Cancel()
		overhealTween = nil
	end
	
	-- Stop low health flash
	stopLowHealthFlash()
	
	-- Hide overheal bar
	overhealFill.Visible = false
	currentOverheal = 0
	maxOverheal = 0
	
	-- Make health bar 100% full and red with smooth transition
	deathBarTween = TweenService:Create(
		hpFill,
		TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			Size = UDim2.new(1, 0, 1, 0),  -- Full bar
			BackgroundColor3 = Color3.fromRGB(150, 0, 0),  -- Dark red
			BackgroundTransparency = 0  -- Fully opaque
		}
	)
	deathBarTween:Play()
	
	-- Ensure HP bar is visible
	showHPBar()
	
	-- Cancel auto-hide
	if hideTimer then
		task.cancel(hideTimer)
		hideTimer = nil
	end
end

local function exitDeathState()
	isInDeathState = false
	
	-- Cancel death tween
	if deathBarTween then
		deathBarTween:Cancel()
		deathBarTween = nil
	end
	
	-- Restore normal health bar color
	hpFill.BackgroundColor3 = baseHealthColor
	hpFill.BackgroundTransparency = baseHealthTransparency
	
	-- Update UI to current health
	if localPlayer.Character then
		local humanoid = localPlayer.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			updateHealthUI(humanoid.Health, humanoid.MaxHealth)
		end
	end
end

-- Listen for death/respawn events
local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
local PlayerDied = remotesFolder:WaitForChild("PlayerDied")
local PlayerRespawned = remotesFolder:WaitForChild("PlayerRespawned")

PlayerDied.OnClientEvent:Connect(function()
	enterDeathState()
end)

PlayerRespawned.OnClientEvent:Connect(function()
	exitDeathState()
end)
