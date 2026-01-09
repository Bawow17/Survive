--!strict
-- DeathBodyFadeSystem - Server-side body fade for dead players (visible to all clients)

local PlayerBalance = require(game.ServerScriptService.Balance.PlayerBalance)
local RunService = game:GetService("RunService")

local DeathBodyFadeSystem = {}

-- Track active fades: {[player] = {character: Model, fadeStartTime: number, fadeDelay: number}}
local activeFades: {[Player]: {character: Model, fadeStartTime: number, fadeDelay: number}} = {}

function DeathBodyFadeSystem.startFade(player: Player)
	if not player or not player.Character then return end
	
	local fadeDelay = PlayerBalance.DeathFadeDelay or 5.0
	
	-- Store fade data
	activeFades[player] = {
		character = player.Character,
		fadeStartTime = tick(),
		fadeDelay = fadeDelay,
	}
	
	print(string.format("[DeathBodyFade] Started fade for %s (delay: %.1fs)", player.Name, fadeDelay))
end

function DeathBodyFadeSystem.stopFade(player: Player)
	print(string.format("[DeathBodyFade] Stopping fade for %s (restoring visibility)", player.Name))
	
	-- Clear any active fade tracking
	activeFades[player] = nil
	
	-- ALWAYS restore body visibility server-side (replicates to all clients)
	-- Use task.defer to ensure character is fully loaded
	task.defer(function()
		if not player or not player.Parent then return end
		
		-- Wait a tiny bit for character to fully load
		task.wait(0.1)
		
		if player.Character then
			for _, part in ipairs(player.Character:GetDescendants()) do
				if part:IsA("BasePart") then
					-- Skip HumanoidRootPart - keep it transparent
					if part.Name == "HumanoidRootPart" then
						part.Transparency = 1
					else
						part.Transparency = 0
					end
				elseif part:IsA("Decal") or part:IsA("Texture") then
					part.Transparency = 0
				end
			end
			print(string.format("[DeathBodyFade] Restored visibility for %s", player.Name))
		else
			warn(string.format("[DeathBodyFade] No character to restore for %s", player.Name))
		end
	end)
end

function DeathBodyFadeSystem.step(dt: number)
	local currentTime = tick()
	local fadeSpeed = PlayerBalance.DeathFadeSpeed or 2.0
	
	for player, fadeData in pairs(activeFades) do
		-- Check if character still exists
		if not fadeData.character or not fadeData.character.Parent then
			activeFades[player] = nil
			continue
		end
		
		-- Check if fade delay has passed
		local elapsed = currentTime - fadeData.fadeStartTime
		if elapsed < fadeData.fadeDelay then
			continue  -- Still waiting for delay
		end
		
		-- Calculate fade progress (starts after delay)
		local fadeElapsed = elapsed - fadeData.fadeDelay
		local targetTransparency = math.min(fadeElapsed * fadeSpeed, 0.95)
		
		-- Apply transparency to all body parts (server-side, replicates to all clients)
		for _, part in ipairs(fadeData.character:GetDescendants()) do
			if part:IsA("BasePart") then
				-- Skip HumanoidRootPart to preserve its transparency
				if part.Name ~= "HumanoidRootPart" then
					part.Transparency = math.max(part.Transparency, targetTransparency)
				end
			elseif part:IsA("Decal") or part:IsA("Texture") then
				part.Transparency = targetTransparency
			end
		end
		
		-- Clean up if fully faded
		if targetTransparency >= 0.95 then
			print(string.format("[DeathBodyFade] Fade complete for %s", player.Name))
			activeFades[player] = nil
		end
	end
end

return DeathBodyFadeSystem

