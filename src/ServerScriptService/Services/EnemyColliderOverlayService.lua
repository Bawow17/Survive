--!strict
-- EnemyColliderOverlayService
-- Draws server-authoritative enemy hitbox/attackbox overlays for debugging.

local Workspace = game:GetService("Workspace")

local EnemyColliderService = require(game.ServerScriptService.Services.EnemyColliderService)

local EnemyColliderOverlayService = {}

local world: any
local Components: any
local enemyQuery: any

local rootFolder: Folder? = nil
local hitboxFolder: Folder? = nil
local attackboxFolder: Folder? = nil

local hitboxPartsByEnemy: {[number]: BasePart} = {}
local attackboxPartsByEnemy: {[number]: BasePart} = {}

local enabled = false
local updateAccumulator = 0
local UPDATE_INTERVAL = 0.1

local function ensureFolders()
	if rootFolder and rootFolder.Parent then
		return
	end

	local existingRoot = Workspace:FindFirstChild("EnemyColliderOverlays")
	if existingRoot and existingRoot:IsA("Folder") then
		rootFolder = existingRoot
	else
		if existingRoot then
			existingRoot:Destroy()
		end
		rootFolder = Instance.new("Folder")
		rootFolder.Name = "EnemyColliderOverlays"
		rootFolder.Parent = Workspace
	end

	local existingHitboxFolder = rootFolder:FindFirstChild("Hitboxes")
	if existingHitboxFolder and existingHitboxFolder:IsA("Folder") then
		hitboxFolder = existingHitboxFolder
	else
		if existingHitboxFolder then
			existingHitboxFolder:Destroy()
		end
		hitboxFolder = Instance.new("Folder")
		hitboxFolder.Name = "Hitboxes"
		hitboxFolder.Parent = rootFolder
	end

	local existingAttackboxFolder = rootFolder:FindFirstChild("Attackboxes")
	if existingAttackboxFolder and existingAttackboxFolder:IsA("Folder") then
		attackboxFolder = existingAttackboxFolder
	else
		if existingAttackboxFolder then
			existingAttackboxFolder:Destroy()
		end
		attackboxFolder = Instance.new("Folder")
		attackboxFolder.Name = "Attackboxes"
		attackboxFolder.Parent = rootFolder
	end
end

local function newOverlayPart(name: string, color: Color3, transparency: number): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.ForceField
	part.Color = color
	part.Transparency = transparency
	part.Locked = true
	part.Size = Vector3.new(1, 1, 1)
	return part
end

local function applyCollider(part: BasePart, collider: {[string]: any})
	local half = collider.halfExtents
	local size = Vector3.new(
		math.max((half and half.X or 0.5) * 2, 0.1),
		math.max((half and half.Y or 0.5) * 2, 0.1),
		math.max((half and half.Z or 0.5) * 2, 0.1)
	)
	part.Size = size
	part.CFrame = collider.boxCFrame or CFrame.new(collider.center or Vector3.zero)
	part:SetAttribute("EnemyId", tonumber(collider.enemyId))
	part:SetAttribute("EnemyTier", tostring(collider.tier))
	part:SetAttribute("EnemySubtype", tostring(collider.subtype))
	part:SetAttribute("EnemyScale", tonumber(collider.scale) or 1)
end

local function destroyPartMap(map: {[number]: BasePart})
	for enemyId, part in pairs(map) do
		map[enemyId] = nil
		if part then
			part:Destroy()
		end
	end
end

local function clearAll()
	destroyPartMap(hitboxPartsByEnemy)
	destroyPartMap(attackboxPartsByEnemy)
	if rootFolder and rootFolder.Parent then
		rootFolder:Destroy()
	end
	rootFolder = nil
	hitboxFolder = nil
	attackboxFolder = nil
end

function EnemyColliderOverlayService.init(worldRef: any, componentsRef: any)
	world = worldRef
	Components = componentsRef
	enemyQuery = world:query(Components.EntityType):cached()
	clearAll()
	updateAccumulator = 0
	enabled = false
end

function EnemyColliderOverlayService.setEnabled(isEnabled: boolean)
	if enabled == isEnabled then
		return
	end
	enabled = isEnabled
	updateAccumulator = UPDATE_INTERVAL
	if not enabled then
		clearAll()
	end
end

function EnemyColliderOverlayService.step(dt: number, isEnabled: boolean)
	if not world or not Components then
		return
	end

	EnemyColliderOverlayService.setEnabled(isEnabled)
	if not enabled then
		return
	end

	updateAccumulator += dt
	if updateAccumulator < UPDATE_INTERVAL then
		return
	end
	updateAccumulator = 0

	ensureFolders()
	local alive: {[number]: boolean} = {}

	for enemyId, entityType in enemyQuery do
		if entityType and entityType.type == "Enemy" and not world:has(enemyId, Components.DeathAnimation) then
			local hitboxCollider = EnemyColliderService.getWorldHitbox(enemyId)
			local attackboxCollider = EnemyColliderService.getWorldAttackbox(enemyId)
			if hitboxCollider and attackboxCollider then
				alive[enemyId] = true

				local hitPart = hitboxPartsByEnemy[enemyId]
				if not hitPart or not hitPart.Parent then
					hitPart = newOverlayPart(("Enemy_%d_Hitbox"):format(enemyId), Color3.fromRGB(0, 255, 120), 0.75)
					hitPart.Parent = hitboxFolder
					hitboxPartsByEnemy[enemyId] = hitPart
				end
				hitboxCollider.enemyId = enemyId
				applyCollider(hitPart, hitboxCollider)

				local attackPart = attackboxPartsByEnemy[enemyId]
				if not attackPart or not attackPart.Parent then
					attackPart = newOverlayPart(("Enemy_%d_Attackbox"):format(enemyId), Color3.fromRGB(255, 85, 85), 0.82)
					attackPart.Parent = attackboxFolder
					attackboxPartsByEnemy[enemyId] = attackPart
				end
				attackboxCollider.enemyId = enemyId
				applyCollider(attackPart, attackboxCollider)
			end
		end
	end

	for enemyId, part in pairs(hitboxPartsByEnemy) do
		if not alive[enemyId] then
			hitboxPartsByEnemy[enemyId] = nil
			if part then
				part:Destroy()
			end
		end
	end

	for enemyId, part in pairs(attackboxPartsByEnemy) do
		if not alive[enemyId] then
			attackboxPartsByEnemy[enemyId] = nil
			if part then
				part:Destroy()
			end
		end
	end
end

return EnemyColliderOverlayService
