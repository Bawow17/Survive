--!strict
-- DifficultyCoeff - RoR2-style global difficulty coefficient (Normal)
-- stageFactor fixed at 1 (no stages yet)

local Players = game:GetService("Players")
local EnemyBalance = require(game.ServerScriptService.Balance.EnemyBalance)

local DifficultyCoeff = {}

local runStartTime: number? = nil

function DifficultyCoeff.reset(startTime: number?)
	runStartTime = startTime or os.clock()
end

local function getPlayerCount(): number
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if player and player.Parent then
			count += 1
		end
	end
	return math.max(1, count)
end

function DifficultyCoeff.getCoeff(): (number, {[string]: number})
	if not runStartTime then
		runStartTime = os.clock()
	end

	local cfg = EnemyBalance.DifficultyCoeff or {}
	local enemyDifficulty = cfg.EnemyDifficulty or 1.0
	local rateMult = cfg.RateMult or 1.25
	local playerCount = getPlayerCount()
	local timeMinutes = (os.clock() - runStartTime) / 60

	local playerFactor = 0.7 + 0.3 * playerCount
	local timeFactor = 0.0506 * enemyDifficulty * (playerCount ^ 0.2) * rateMult
	local coeff = playerFactor + timeMinutes * timeFactor

	return coeff, {
		playerCount = playerCount,
		timeMinutes = timeMinutes,
		playerFactor = playerFactor,
		timeFactor = timeFactor,
		enemyDifficulty = enemyDifficulty,
		rateMult = rateMult,
		stageFactor = 1.0,
	}
end

function DifficultyCoeff.validate()
	local coeff, details = DifficultyCoeff.getCoeff()
	if coeff <= 0 or coeff ~= coeff then
		warn(string.format("[DifficultyCoeff] Invalid coeff: %s", tostring(coeff)))
	end
	if details.playerCount <= 0 then
		warn("[DifficultyCoeff] PlayerCount <= 0 (should be at least 1)")
	end
	if details.timeFactor <= 0 then
		warn(string.format("[DifficultyCoeff] timeFactor <= 0 (%.4f)", details.timeFactor))
	end
end

return DifficultyCoeff
