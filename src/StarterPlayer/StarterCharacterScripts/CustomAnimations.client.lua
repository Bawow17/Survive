--!strict
-- CustomAnimations
-- Overrides Roblox's default character animations
-- Replace the animation IDs below with your own custom animations

local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer

-- ========================================
-- ANIMATION IDs - Replace with your own!
-- ========================================
-- These are Roblox's default R6 animation IDs (as reference)
-- Upload your own animations and replace these IDs

local ANIMATION_IDS = {
	-- IDLE ANIMATIONS (plays when standing still)
	idle = {
		"rbxassetid://180435571",  -- Default R6 idle animation
		"rbxassetid://180435792",  -- Default R6 idle animation 2 (variation)
	},
	
	-- WALK ANIMATION (plays when walking) - CUSTOM
	walk = {
		"rbxassetid://95806595891252",  -- Your custom walk animation
	},
	
	-- RUN ANIMATION (plays when running) - CUSTOM
	run = {
		"rbxassetid://95806595891252",  -- Your custom run animation
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
	
	-- Override each animation type
	for animType, animIdList in pairs(ANIMATION_IDS) do
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

