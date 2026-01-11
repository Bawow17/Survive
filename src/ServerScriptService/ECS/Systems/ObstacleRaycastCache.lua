--!strict
-- Shared obstacle raycast cache for AI systems (avoids duplicate rebuilds).

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local ObstacleRaycastCache = {}

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local exclusionCache = {}
local lastRebuildTime = 0.0
local REBUILD_INTERVAL = 5.0
local rebuildId = 0
local lastRebuildDuration = 0.0
local lastExclusionSize = 0

local function rebuildCache()
	local startTime = os.clock()
	table.clear(exclusionCache)

	for _, player in pairs(Players:GetPlayers()) do
		if player.Character then
			for _, part in pairs(player.Character:GetDescendants()) do
				if part:IsA("BasePart") then
					table.insert(exclusionCache, part)
				end
			end
		end
	end

	local expOrbsFolder = Workspace:FindFirstChild("ExpOrbs")
	if expOrbsFolder then
		for _, orbModel in pairs(expOrbsFolder:GetChildren()) do
			if orbModel:IsA("Model") then
				for _, part in pairs(orbModel:GetDescendants()) do
					if part:IsA("BasePart") then
						table.insert(exclusionCache, part)
					end
				end
			end
		end
	end

	local powerupsFolder = Workspace:FindFirstChild("Powerups")
	if powerupsFolder then
		for _, powerupModel in pairs(powerupsFolder:GetChildren()) do
			if powerupModel:IsA("Model") then
				for _, part in pairs(powerupModel:GetDescendants()) do
					if part:IsA("BasePart") then
						table.insert(exclusionCache, part)
					end
				end
			end
		end
	end

	local projectilesFolder = Workspace:FindFirstChild("Projectiles")
	if projectilesFolder then
		for _, projectileModel in pairs(projectilesFolder:GetChildren()) do
			if projectileModel:IsA("Model") then
				for _, part in pairs(projectileModel:GetDescendants()) do
					if part:IsA("BasePart") then
						table.insert(exclusionCache, part)
					end
				end
			end
		end
	end

	local afterimageClonesFolder = Workspace:FindFirstChild("AfterimageClones")
	if afterimageClonesFolder then
		for _, cloneModel in pairs(afterimageClonesFolder:GetChildren()) do
			if cloneModel:IsA("Model") then
				for _, part in pairs(cloneModel:GetDescendants()) do
					if part:IsA("BasePart") then
						table.insert(exclusionCache, part)
					end
				end
			end
		end
	end

	for _, descendant in pairs(Workspace:GetDescendants()) do
		if descendant:IsA("BasePart") or descendant:IsA("MeshPart") then
			if descendant.Transparency >= 1 or not descendant.CanCollide then
				table.insert(exclusionCache, descendant)
			end
		end
	end

	raycastParams.FilterDescendantsInstances = exclusionCache
	lastRebuildTime = tick()
	rebuildId += 1
	lastExclusionSize = #exclusionCache
	lastRebuildDuration = os.clock() - startTime
end

function ObstacleRaycastCache.getParams(): RaycastParams
	local now = tick()
	if (now - lastRebuildTime) >= REBUILD_INTERVAL or #exclusionCache == 0 then
		rebuildCache()
	end
	return raycastParams
end

function ObstacleRaycastCache.getStats(): {rebuildId: number, lastRebuildDuration: number, exclusionSize: number}
	return {
		rebuildId = rebuildId,
		lastRebuildDuration = lastRebuildDuration,
		exclusionSize = lastExclusionSize,
	}
end

return ObstacleRaycastCache
