--!strict
-- UpgradeCounter - Dynamically counts all upgrades in the game

local UpgradeCounter = {}

-- Cache to avoid rescanning every frame
local cachedTotalUpgrades: number? = nil

function UpgradeCounter.getTotalUpgrades(): number
	if cachedTotalUpgrades then
		return cachedTotalUpgrades
	end
	
	local total = 0
	
	-- Count passive upgrades
	local PassiveUpgrades = require(game.ServerScriptService.Balance.Player.PassiveUpgrades)
	for passiveName, levels in pairs(PassiveUpgrades) do
		total = total + #levels
	end
	
	-- Count ability upgrades
	local AbilitiesFolder = game.ServerScriptService.Abilities
	for _, abilityFolder in pairs(AbilitiesFolder:GetChildren()) do
		if abilityFolder:IsA("Folder") and abilityFolder.Name ~= "_Templates" then
			local upgradesModule = abilityFolder:FindFirstChild("Upgrades")
			if upgradesModule then
				local success, upgrades = pcall(require, upgradesModule)
				if success and type(upgrades) == "table" then
					total = total + #upgrades
				end
			end
		end
	end
	
	-- Count mobility abilities (each mobility ability = 1 unlock)
	local MobilityFolder = game.ServerScriptService.Balance.Player.MobilityAbilities
	for _, mobilityModule in pairs(MobilityFolder:GetChildren()) do
		if mobilityModule:IsA("ModuleScript") then
			total = total + 1
		end
	end
	
	cachedTotalUpgrades = total
	return total
end

-- Get phase breakpoints
function UpgradeCounter.getPhaseBreakpoints(): (number, number, number)
	local total = UpgradeCounter.getTotalUpgrades()
	
	-- Option B ratios: 35% / 45% / 20%
	local phase1End = math.floor(total * 0.35)
	local phase2End = math.floor(total * 0.80) -- 35% + 45%
	local phase3End = total -- All upgrades maxed
	
	return phase1End, phase2End, phase3End
end

-- Force recalculation (for testing/debugging)
function UpgradeCounter.refresh()
	cachedTotalUpgrades = nil
	return UpgradeCounter.getTotalUpgrades()
end

return UpgradeCounter

