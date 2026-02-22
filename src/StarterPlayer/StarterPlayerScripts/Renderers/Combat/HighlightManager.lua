--!strict
-- HighlightManager - Centralized priority-based character highlight system
-- Ensures highest-priority effects are always visible and lower ones reappear when they expire

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local HighlightManager = {}

-- Active effects tracker with priority
local activeEffects: {[string]: {
	priority: number,
	endTime: number,
	color: Color3,
	characterTransparency: number,
	fadeChunks: number,
	fadeDuration: number,
	currentTransparency: number,
}} = {}

-- Current visible effect
local currentVisibleEffect: string? = nil
local currentHighlight: Highlight? = nil
local cloakOriginalTransparencies: {[BasePart]: number} = {}

-- Pause tracking
local isPaused = false
local pauseStartTime = 0
local totalPausedTime = 0

-- Apply character transparency (for Cloak effect)
local function setCharacterTransparency(character: Model, transparency: number)
	for _, descendant in pairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			if transparency > 0 and not cloakOriginalTransparencies[descendant] then
				-- Store original transparency
				cloakOriginalTransparencies[descendant] = descendant.Transparency
			end
			
			if transparency > 0 then
				-- Apply transparency
				descendant.Transparency = transparency
			elseif cloakOriginalTransparencies[descendant] then
				-- Restore original transparency
				descendant.Transparency = cloakOriginalTransparencies[descendant]
				cloakOriginalTransparencies[descendant] = nil
			end
		end
	end
end

-- Get highest-priority active effect
local function getHighestPriorityEffect(): string?
	local highestPriority = math.huge
	local highestEffectId = nil
	
	for effectId, effect in pairs(activeEffects) do
		if effect.priority < highestPriority then
			highestPriority = effect.priority
			highestEffectId = effectId
		end
	end
	
	return highestEffectId
end

-- Create or update highlight for an effect
local function showEffect(effectId: string)
	local character = player.Character
	if not character then
		return
	end
	
	local effect = activeEffects[effectId]
	if not effect then
		return
	end
	
	-- Remove old highlight if switching effects
	if currentHighlight then
		currentHighlight:Destroy()
		currentHighlight = nil
	end
	
	-- Create new highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = "CharacterHighlight"
	highlight.Adornee = character
	highlight.OutlineColor = effect.color
	highlight.FillColor = effect.color
	highlight.FillTransparency = 1.0  -- Outline only
	highlight.OutlineTransparency = 1.0  -- Start invisible
	highlight.Parent = character
	
	currentHighlight = highlight
	currentVisibleEffect = effectId
	effect.currentTransparency = 1.0
	
	-- Apply character transparency if needed (Cloak effect)
	if effect.characterTransparency > 0 then
		setCharacterTransparency(character, effect.characterTransparency)
	end
end

-- Hide current highlight (when clearing all effects)
local function hideCurrentHighlight()
	if currentHighlight then
		currentHighlight:Destroy()
		currentHighlight = nil
	end
	currentVisibleEffect = nil
	
	-- Restore character transparency
	local character = player.Character
	if character then
		setCharacterTransparency(character, 0)
	end
end

-- PUBLIC API: Add an effect to the tracker
function HighlightManager.addEffect(effectId: string, priority: number, duration: number, color: Color3, characterTransparency: number?)
	local now = tick() - totalPausedTime
	
	-- Add to active effects
	activeEffects[effectId] = {
		priority = priority,
		endTime = now + duration,
		color = color,
		characterTransparency = characterTransparency or 0,
		fadeChunks = 10,
		fadeDuration = 0.5,
		currentTransparency = 1.0,
	}
	
	-- Check if this should be the visible effect
	if not currentVisibleEffect then
		-- No current effect, show this one
		showEffect(effectId)
	else
		local currentEffect = activeEffects[currentVisibleEffect]
		if currentEffect and priority < currentEffect.priority then
			-- New effect has HIGHER priority (lower number), switch to it
			showEffect(effectId)
		end
		-- Otherwise, keep current effect visible (new effect is tracked but hidden)
	end
end

-- PUBLIC API: Remove an effect
function HighlightManager.removeEffect(effectId: string)
	-- Remove from tracking
	activeEffects[effectId] = nil
	
	-- If this was the visible effect, show next highest priority
	if currentVisibleEffect == effectId then
		hideCurrentHighlight()
		
		local nextEffect = getHighestPriorityEffect()
		if nextEffect then
			showEffect(nextEffect)
		end
	end
end

-- Update effects each frame (fade animations, expiration)
function HighlightManager.updateEffects()
	if isPaused then
		return
	end
	
	local now = tick() - totalPausedTime
	local character = player.Character
	if not character or not currentHighlight then
		return
	end
	
	-- Check for expired effects (but don't remove yet - let fade complete)
	local effectsToRemove = {}
	for effectId, effect in pairs(activeEffects) do
		-- Calculate fade-out progress
		local fadeInterval = effect.fadeDuration / effect.fadeChunks
		local fadeCompleteTime = effect.endTime + (fadeInterval * effect.fadeChunks)
		
		-- Only remove after fade-out is complete
		if now >= fadeCompleteTime then
			table.insert(effectsToRemove, effectId)
		end
	end
	
	-- Remove fully faded effects
	for _, effectId in ipairs(effectsToRemove) do
		HighlightManager.removeEffect(effectId)
	end
	
	-- Update fade animation for visible effect
	if currentVisibleEffect and activeEffects[currentVisibleEffect] then
		local effect = activeEffects[currentVisibleEffect]
		local effectEnded = now >= effect.endTime
		
		if effectEnded then
			-- Fade out in chunks over 0.5s
			local fadeInterval = effect.fadeDuration / effect.fadeChunks
			local timeSinceEnd = now - effect.endTime
			local chunksPassed = math.floor(timeSinceEnd / fadeInterval)
			
			if chunksPassed >= effect.fadeChunks then
				-- Fully faded out
				effect.currentTransparency = 1.0
			else
				-- Fade out (transparency increases 0 → 1)
				local targetTransparency = chunksPassed / effect.fadeChunks
				effect.currentTransparency = targetTransparency
			end
		else
			-- Fade in (transparency decreases 1 → 0)
			if effect.currentTransparency > 0 then
				effect.currentTransparency = math.max(0, effect.currentTransparency - 0.1)
			end
		end
		
		-- Apply transparency to highlight
		if currentHighlight then
			currentHighlight.OutlineTransparency = effect.currentTransparency
			currentHighlight.FillTransparency = 1.0  -- Always transparent fill
		end
	end
end

-- Handle pause/unpause
function HighlightManager.onPause()
	if not isPaused then
		isPaused = true
		pauseStartTime = tick()
	end
end

function HighlightManager.onUnpause()
	if isPaused then
		isPaused = false
		local pauseDuration = tick() - pauseStartTime
		totalPausedTime = totalPausedTime + pauseDuration
	end
end

-- Handle character respawn
function HighlightManager.onCharacterAdded(character: Model)
	-- Clear all effects
	hideCurrentHighlight()
	table.clear(activeEffects)
	table.clear(cloakOriginalTransparencies)
	
	-- Reset pause tracking
	isPaused = false
	totalPausedTime = 0
end

-- Initialize
RunService.Heartbeat:Connect(HighlightManager.updateEffects)

return HighlightManager

