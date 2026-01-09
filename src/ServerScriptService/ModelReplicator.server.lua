--!strict
-- Mirrors required models from ServerStorage into ReplicatedStorage for client rendering

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local function ensureFolder(parent: Instance, name: string): Instance
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end

local function replicateZombie()
	local ssContent = ServerStorage:FindFirstChild("Content Drawer")
	if not ssContent then return end
	local ssEnemies = ssContent:FindFirstChild("Enemies")
	local ssMobs = ssEnemies and ssEnemies:FindFirstChild("Mobs")
	local ssZombie = ssMobs and ssMobs:FindFirstChild("Zombie")
	if not ssZombie then return end

	local rsContent = ensureFolder(ReplicatedStorage, "Content Drawer")
	local rsModels = ensureFolder(rsContent, "Models")
	local rsEnemies = ensureFolder(rsModels, "Enemies")
	local rsMobs = ensureFolder(rsEnemies, "Mobs")

	local existing = rsMobs:FindFirstChild("Zombie")
	if existing then existing:Destroy() end
	local clone = (ssZombie :: Instance):Clone()
	clone.Parent = rsMobs
end

replicateZombie()

