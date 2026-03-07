--!strict
-- CustomAnimations
-- Overrides Roblox's default character animations
-- Replace the animation IDs below with your own custom animations

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local localPlayer = Players.LocalPlayer

-- ========================================
-- ANIMATION IDs - defaults are used when custom entries are missing.
-- ========================================
-- Custom animations are pulled from:
-- ReplicatedStorage.ContentDrawer.PlayerAbilities.BasicAnimations

local DEFAULT_ANIMATION_IDS = {
	-- IDLE ANIMATIONS (plays when standing still)
	idle = {
		"rbxassetid://180435571",  -- Default R6 idle animation
		"rbxassetid://180435792",  -- Default R6 idle animation 2 (variation)
	},
	
	-- WALK ANIMATION (plays when walking)
	walk = {
		"rbxassetid://180426354",  -- Default R6 walk animation
	},
	
	-- RUN ANIMATION (plays when running)
	run = {
		"rbxassetid://180426354",  -- Default R6 run animation
	},
	
	-- JUMP ANIMATION (plays when jumping)
	jump = {
		"rbxassetid://125750702",  -- Default R6 jump animation
	},
	
	-- FALL ANIMATION (plays when falling)
	fall = {
		"rbxassetid://180436148",  -- Default R6 fall animation
	},
	
	-- CLIMB ANIMATION (plays when climbing)
	climb = {
		"rbxassetid://180436334",  -- Default R6 climb animation
	},
	
	-- SWIM ANIMATIONS (plays when swimming)
	swim = {
		"rbxassetid://865830669",  -- Default R6 swim animation
	},
	swimidle = {
		"rbxassetid://865830669",  -- Default R6 swim idle animation
	},
	
	-- TOOL ANIMATIONS (plays when holding tools)
	toolnone = {
		"rbxassetid://182393478",  -- Default R6 tool hold
	},
	toolslash = {
		"rbxassetid://129967390",  -- Default R6 tool slash animation
	},
	toollunge = {
		"rbxassetid://129967478",  -- Default R6 tool lunge animation
	},
}

local function cloneAnimationIds(): {[string]: {string}}
	local clone: {[string]: {string}} = {}
	for animType, animList in pairs(DEFAULT_ANIMATION_IDS) do
		local listCopy = table.create(#animList)
		for index, animId in ipairs(animList) do
			listCopy[index] = animId
		end
		clone[animType] = listCopy
	end
	return clone
end

local function resolveBasicAnimationsFolder(): Folder?
	local contentDrawer = ReplicatedStorage:FindFirstChild("ContentDrawer")
	if not contentDrawer then
		return nil
	end
	local playerAbilities = contentDrawer:FindFirstChild("PlayerAbilities")
	if not playerAbilities then
		return nil
	end
	local basicAnimations = playerAbilities:FindFirstChild("BasicAnimations")
	if basicAnimations and basicAnimations:IsA("Folder") then
		return basicAnimations
	end
	return nil
end

local function resolveAnimationIdFromFolder(folder: Folder, childName: string): string?
	local animation = folder:FindFirstChild(childName)
	if not animation or not animation:IsA("Animation") then
		return nil
	end
	local animationId = animation.AnimationId
	if animationId == "" then
		return nil
	end
	return animationId
end

local function buildAnimationIds(): {[string]: {string}}
	local animationIds = cloneAnimationIds()
	local basicAnimations = resolveBasicAnimationsFolder()
	if not basicAnimations then
		return animationIds
	end

	local idle1 = resolveAnimationIdFromFolder(basicAnimations, "Idle1")
	if idle1 then
		animationIds.idle[1] = idle1
	end

	local idle2 = resolveAnimationIdFromFolder(basicAnimations, "Idle2")
	if idle2 then
		animationIds.idle[2] = idle2
	end

	local walk = resolveAnimationIdFromFolder(basicAnimations, "Walk")
	if walk then
		animationIds.walk[1] = walk
	end

	local run = resolveAnimationIdFromFolder(basicAnimations, "Run")
	if run then
		animationIds.run[1] = run
	end

	local jump = resolveAnimationIdFromFolder(basicAnimations, "Jump")
	if jump then
		animationIds.jump[1] = jump
	end

	local fall = resolveAnimationIdFromFolder(basicAnimations, "Fall")
	if fall then
		animationIds.fall[1] = fall
	end

	return animationIds
end

-- ========================================
-- ANIMATION OVERRIDE SYSTEM
-- ========================================

local function overrideAnimations(character)
	local animateScript = character:WaitForChild("Animate", 5)
	if not animateScript then
		return
	end
	
	-- Wait a frame for Animate script to fully initialize
	task.wait()
	
	local overrideCount = 0
	
	local animationIds = buildAnimationIds()

	-- Override each animation type
	for animType, animIdList in pairs(animationIds) do
		local folder = animateScript:FindFirstChild(animType)
		if folder then
			-- Clear existing animations in folder
			local existingAnims = folder:GetChildren()
			
			-- If we have custom animations, replace all
			if #animIdList > 0 then
				-- Remove old animations
				for _, oldAnim in ipairs(existingAnims) do
					if oldAnim:IsA("Animation") then
						oldAnim:Destroy()
					end
				end
				
				-- Add new animations
				for index, animId in ipairs(animIdList) do
					local newAnim = Instance.new("Animation")
					newAnim.Name = animType .. tostring(index)
					newAnim.AnimationId = animId
					newAnim.Parent = folder
					overrideCount = overrideCount + 1
				end
			end
		end
	end
end

-- ========================================
-- CHARACTER LIFECYCLE
-- ========================================

-- Apply to current character
if localPlayer.Character then
	task.spawn(overrideAnimations, localPlayer.Character)
end

-- Apply to future characters (respawns)
localPlayer.CharacterAdded:Connect(overrideAnimations)

