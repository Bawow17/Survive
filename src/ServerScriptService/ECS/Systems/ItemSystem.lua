--!strict
-- ItemSystem - Server-authoritative run item ownership, drop spawning, and item effects.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local GameTimeSystem = require(game.ServerScriptService.ECS.Systems.GameTimeSystem)
local GameStateManager = require(game.ServerScriptService.ECS.Systems.GameStateManager)
local DamageSystem = require(game.ServerScriptService.ECS.Systems.DamageSystem)
local OctreeSystem = require(game.ServerScriptService.ECS.Systems.OctreeSystem)
local EnemyColliderService = require(game.ServerScriptService.Services.EnemyColliderService)
local BuffSystem = require(game.ServerScriptService.ECS.Systems.BuffSystem)
local RunItems = require(game.ServerScriptService.Balance.RunItems)
local CombatScaling = require(ReplicatedStorage.Shared.CombatScaling)

local ItemSystem = {}

type ItemState = {
	counts: {[string]: number},
	order: {string},
	seen: {[string]: boolean},
	fuseReadyAt: number,
	silver: {
		charges: number,
		maxCharges: number,
		nextRechargeAt: number,
	},
}

type PendingFuseBomb = {
	ownerEntity: number,
	position: Vector3,
	detonateAt: number,
	damage: number,
	procCoefficient: number,
	visual: Instance?,
}

local world: any
local Components: any
local PickupService: any
local ProjectileService: any
local ModelReplicationService: any

local Position: any
local PlayerStats: any
local EntityType: any
local Level: any
local PassiveEffects: any
local Health: any

local itemStateByEntity: {[number]: ItemState} = {}
local pendingFuseBombs: {PendingFuseBomb} = {}
local activeItemDropIds: {[number]: boolean} = {}
local itemStateRemote: RemoteEvent

local RNG = Random.new()

local function normalizeLookupKey(value: string): string
	return string.lower((value:gsub("[%W_]+", "")))
end

local function ensureRemoteEvent(parent: Instance, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function buildReplicatedCommonItemPath(modelName: string): string
	return "ReplicatedStorage.ContentDrawer.ItemModels.CommonItems." .. modelName
end

local function getCommonItemsFolder(): Instance?
	local contentDrawer = ServerStorage:FindFirstChild("ContentDrawer")
	if not contentDrawer then
		return nil
	end
	local itemModels = contentDrawer:FindFirstChild("ItemModels")
	if not itemModels then
		return nil
	end
	return itemModels:FindFirstChild("CommonItems")
end

local function resolveCommonItemModelName(modelName: string): string
	if ModelReplicationService and ModelReplicationService.resolveCommonItemName then
		local resolved = ModelReplicationService.resolveCommonItemName(modelName)
		if typeof(resolved) == "string" and resolved ~= "" then
			return resolved
		end
	end

	local commonItems = getCommonItemsFolder()
	if not commonItems then
		return modelName
	end
	local exact = commonItems:FindFirstChild(modelName)
	if exact and exact:IsA("Model") then
		return exact.Name
	end

	local wanted = normalizeLookupKey(modelName)
	for _, child in ipairs(commonItems:GetChildren()) do
		if child:IsA("Model") and normalizeLookupKey(child.Name) == wanted then
			return child.Name
		end
	end

	return modelName
end

local function replicateCommonItemModel(modelName: string)
	if ModelReplicationService and ModelReplicationService.replicateCommonItem then
		ModelReplicationService.replicateCommonItem(modelName)
	end
end

local function getCommonItemTemplate(modelName: string): Model?
	local commonItems = getCommonItemsFolder()
	if not commonItems then
		return nil
	end

	local model = commonItems:FindFirstChild(modelName)
	if model and model:IsA("Model") then
		return model
	end

	local wanted = normalizeLookupKey(modelName)
	for _, child in ipairs(commonItems:GetChildren()) do
		if child:IsA("Model") and normalizeLookupKey(child.Name) == wanted then
			return child
		end
	end

	return nil
end

local function configureAnchoredModel(model: Model)
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if primary and not model.PrimaryPart then
		model.PrimaryPart = primary
	end
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = false
			desc.CanTouch = false
			desc.CanQuery = false
			desc.Massless = true
		elseif desc:IsA("Highlight") then
			desc.Enabled = false
		end
	end
end

local function getModelGroundPivotLift(modelName: string, fallback: number): number
	local template = getCommonItemTemplate(modelName)
	if not template then
		return fallback
	end

	local ok, bboxCf, bboxSize = pcall(function()
		return template:GetBoundingBox()
	end)
	if not ok or typeof(bboxCf) ~= "CFrame" or typeof(bboxSize) ~= "Vector3" then
		return fallback
	end

	local pivot = template:GetPivot()
	local localCf = pivot:ToObjectSpace(bboxCf)
	local bottomLocalY = localCf.Position.Y - (bboxSize.Y * 0.5)
	local lift = -bottomLocalY
	if lift ~= lift or lift < 0 then
		return fallback
	end
	return lift
end

local function spawnWorldModel(modelName: string, position: Vector3, stripHighlight: boolean?): Instance?
	local template = getCommonItemTemplate(modelName)
	if not template then
		return nil
	end
	local clone = template:Clone()
	configureAnchoredModel(clone)
	if stripHighlight == true then
		for _, desc in ipairs(clone:GetDescendants()) do
			if desc:IsA("Highlight") then
				desc.Enabled = false
			end
		end
	end
	clone.Parent = Workspace
	clone:PivotTo(CFrame.new(position))
	return clone
end

local function clampProcCoefficient(rawProc: any): number
	if typeof(rawProc) ~= "number" or rawProc ~= rawProc then
		return 1.0
	end
	if rawProc < 0 then
		return 0
	end
	return rawProc
end

local function getEntityTypeName(entity: number): string?
	if not world then
		return nil
	end
	local entityType = world:get(entity, EntityType)
	if entityType and entityType.type then
		return entityType.type
	end
	local playerStats = world:get(entity, PlayerStats)
	if playerStats and playerStats.player then
		return "Player"
	end
	return nil
end

local function getPlayerFromEntity(playerEntity: number): Player?
	if not world then
		return nil
	end
	local stats = world:get(playerEntity, PlayerStats)
	if stats and stats.player and stats.player.Parent == Players then
		return stats.player
	end
	return nil
end

local function getEntityPosition(entity: number): Vector3?
	if not world then
		return nil
	end
	local pos = world:get(entity, Position)
	if pos then
		return Vector3.new(pos.x, pos.y, pos.z)
	end
	return nil
end

local function snapToGround(position: Vector3, ignoreModel: Model?, lift: number): Vector3
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true
	local filter = {}
	if ignoreModel then
		table.insert(filter, ignoreModel)
	end
	local pickupsFolder = Workspace:FindFirstChild("Pickups")
	if pickupsFolder then
		table.insert(filter, pickupsFolder)
	end
	rayParams.FilterDescendantsInstances = filter

	local castOrigin = position + Vector3.new(0, 12, 0)
	local castDirection = Vector3.new(0, -128, 0)
	local result = Workspace:Raycast(castOrigin, castDirection, rayParams)
	if result then
		return result.Position + Vector3.new(0, lift, 0)
	end
	return position + Vector3.new(0, lift, 0)
end

local function getForwardGroundedDropPosition(player: Player, forwardDistance: number, lift: number): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return nil
	end

	local look = (hrp :: BasePart).CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude <= 1e-4 then
		flatLook = Vector3.new(0, 0, -1)
	else
		flatLook = flatLook.Unit
	end

	local basePos = (hrp :: BasePart).Position + (flatLook * forwardDistance)
	return snapToGround(basePos, character, lift)
end

local function ensureEntityState(playerEntity: number): ItemState
	local state = itemStateByEntity[playerEntity]
	if state then
		return state
	end
	state = {
		counts = {},
		order = {},
		seen = {},
		fuseReadyAt = 0,
		silver = {
			charges = 0,
			maxCharges = 0,
			nextRechargeAt = 0,
		},
	}
	itemStateByEntity[playerEntity] = state
	return state
end

local function sendItemState(playerEntity: number)
	local player = getPlayerFromEntity(playerEntity)
	if not player then
		return
	end

	local state = itemStateByEntity[playerEntity]
	if not state then
		itemStateRemote:FireClient(player, { items = {} })
		return
	end

	local payloadItems = {}
	for orderIndex, itemId in ipairs(state.order) do
		local count = state.counts[itemId]
		local def = RunItems.get(itemId)
		if def and count and count > 0 then
			table.insert(payloadItems, {
				itemId = itemId,
				displayName = def.displayName,
				viewportFrameName = def.viewportFrameName,
				count = count,
				layoutOrder = orderIndex,
			})
		end
	end

	itemStateRemote:FireClient(player, {
		items = payloadItems,
	})
end

local function clearEntityState(playerEntity: number, sendEmptyState: boolean)
	itemStateByEntity[playerEntity] = nil
	if sendEmptyState then
		sendItemState(playerEntity)
	end
end

local function getItemStackCount(playerEntity: number, itemId: string): number
	local state = itemStateByEntity[playerEntity]
	if not state then
		return 0
	end
	return state.counts[itemId] or 0
end

local function getSilverMaxCharges(stacks: number): number
	if stacks <= 0 then
		return 0
	end
	local silverCfg = RunItems.Definitions[RunItems.Ids.SilverNinjaStarOfTheBrilliantLight].silverStar
	return silverCfg.baseCharges + (math.max(0, stacks - 1) * silverCfg.chargesPerStack)
end

local function ensureSilverCapacity(state: ItemState, stacks: number, isNewStack: boolean)
	local maxCharges = getSilverMaxCharges(stacks)
	local oldMax = state.silver.maxCharges
	state.silver.maxCharges = maxCharges

	if maxCharges <= 0 then
		state.silver.charges = 0
		state.silver.nextRechargeAt = 0
		return
	end

	if oldMax <= 0 then
		state.silver.charges = maxCharges
		state.silver.nextRechargeAt = 0
		return
	end

	if isNewStack and maxCharges > oldMax then
		local gain = maxCharges - oldMax
		state.silver.charges = math.min(maxCharges, state.silver.charges + gain)
	else
		state.silver.charges = math.min(maxCharges, state.silver.charges)
	end

	if state.silver.charges >= maxCharges then
		state.silver.nextRechargeAt = 0
	end
end

local function addItemToEntity(playerEntity: number, itemId: string)
	local def = RunItems.get(itemId)
	if not def then
		return
	end
	local state = ensureEntityState(playerEntity)
	local oldCount = state.counts[itemId] or 0
	local newCount = oldCount + 1
	state.counts[itemId] = newCount

	if not state.seen[itemId] then
		state.seen[itemId] = true
		table.insert(state.order, itemId)
	end

	if itemId == RunItems.Ids.SilverNinjaStarOfTheBrilliantLight then
		ensureSilverCapacity(state, newCount, true)
	end

	sendItemState(playerEntity)
end

local function getScaledBaseDamage(playerEntity: number): number
	local level = 1
	if Level then
		local levelComp = world:get(playerEntity, Level)
		if levelComp and typeof(levelComp.current) == "number" then
			level = math.max(1, math.floor(levelComp.current))
		end
	end

	local damage = CombatScaling.getBaseDamageAtLevel(level)

	if PassiveEffects then
		local effects = world:get(playerEntity, PassiveEffects)
		if effects and typeof(effects.damageMultiplier) == "number" then
			damage *= effects.damageMultiplier
		end
	end

	local buffMult = BuffSystem.getDamageMultiplier(playerEntity)
	if typeof(buffMult) == "number" then
		damage *= buffMult
	end

	return math.max(0, damage)
end

local function spawnFuseExplosionVfx(position: Vector3, targetSize: Vector3)
	local sphere = Instance.new("Part")
	sphere.Name = "FuseBombExplosionVFX"
	sphere.Shape = Enum.PartType.Ball
	sphere.Material = Enum.Material.Neon
	sphere.Color = Color3.fromRGB(255, 140, 40)
	sphere.Transparency = 0.35
	sphere.Anchored = true
	sphere.CanCollide = false
	sphere.CanTouch = false
	sphere.CanQuery = false
	sphere.CastShadow = false
	sphere.Size = Vector3.new(0.5, 0.5, 0.5)
	sphere.CFrame = CFrame.new(position)
	sphere.Parent = Workspace

	local tween = TweenService:Create(sphere, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = targetSize,
		Transparency = 1,
	})
	tween:Play()
	Debris:AddItem(sphere, 0.3)
end

local function explodeFuseBomb(pending: PendingFuseBomb)
	if pending.visual and pending.visual.Parent then
		pending.visual:Destroy()
	end

	local fuseDef = RunItems.Definitions[RunItems.Ids.FuseBomb]
	local fuseCfg = fuseDef.fuseBomb
	local radius = fuseCfg.explosionRadius
	spawnFuseExplosionVfx(pending.position, fuseCfg.explosionSize)

	local candidates = OctreeSystem.getEnemiesInRadius(pending.position, radius + 8)
	for _, enemyId in ipairs(candidates) do
		if getEntityTypeName(enemyId) ~= "Enemy" then
			continue
		end
		local enemyHealth = world:get(enemyId, Health)
		if not enemyHealth or (enemyHealth.current or 0) <= 0 then
			continue
		end

		local hit = false
		local collider = EnemyColliderService.getWorldHitbox(enemyId)
		if collider then
			hit = (collider.center - pending.position).Magnitude <= (radius + collider.radius)
		else
			local enemyPos = getEntityPosition(enemyId)
			if enemyPos then
				hit = (enemyPos - pending.position).Magnitude <= radius
			end
		end

		if hit then
			DamageSystem.applyDamage(
				enemyId,
				pending.damage,
				"explosion",
				pending.ownerEntity,
				"FuseBomb",
				{ procCoefficient = pending.procCoefficient }
			)
		end
	end
end

local function cloneTable(input: {[string]: any}): {[string]: any}
	local out = {}
	for key, value in pairs(input) do
		out[key] = value
	end
	return out
end

local function refreshSilverRecharge(state: ItemState, stacks: number, now: number)
	if stacks <= 0 then
		return
	end
	ensureSilverCapacity(state, stacks, false)
	local maxCharges = state.silver.maxCharges
	if maxCharges <= 0 then
		return
	end

	local interval = RunItems.Definitions[RunItems.Ids.SilverNinjaStarOfTheBrilliantLight].silverStar.rechargeDuration / maxCharges
	while state.silver.charges < maxCharges and state.silver.nextRechargeAt > 0 and now >= state.silver.nextRechargeAt do
		state.silver.charges += 1
		if state.silver.charges < maxCharges then
			state.silver.nextRechargeAt += interval
		else
			state.silver.nextRechargeAt = 0
		end
	end
end

local function triggerFuseBomb(targetPlayerEntity: number, procCoefficient: number)
	local stacks = getItemStackCount(targetPlayerEntity, RunItems.Ids.FuseBomb)
	if stacks <= 0 then
		return
	end

	local state = ensureEntityState(targetPlayerEntity)
	local now = GameTimeSystem.getGameTime()
	if now < state.fuseReadyAt then
		return
	end

	local fuseCfg = RunItems.Definitions[RunItems.Ids.FuseBomb].fuseBomb
	local stackBonusCount = math.max(0, stacks - 1)
	local totalProcChance = fuseCfg.baseProcChance + (fuseCfg.stackProcChance * stackBonusCount)
	local effectiveChance = math.clamp(totalProcChance * procCoefficient, 0, 1)
	if RNG:NextNumber() > effectiveChance then
		return
	end

	local cooldown = fuseCfg.baseCooldown * (fuseCfg.stackCooldownMultiplier ^ stackBonusCount)
	local scaledCooldown = cooldown * procCoefficient
	state.fuseReadyAt = math.max(state.fuseReadyAt, now + scaledCooldown)

	local sourcePos = getEntityPosition(targetPlayerEntity)
	if not sourcePos then
		return
	end
	local resolvedFuseModelName = resolveCommonItemModelName(RunItems.Definitions[RunItems.Ids.FuseBomb].dropModelName)
	local fuseGroundLift = getModelGroundPivotLift(resolvedFuseModelName, 0.25) + 0.05
	local sourcePlayer = getPlayerFromEntity(targetPlayerEntity)
	local ignoreModel = if sourcePlayer and sourcePlayer.Character and sourcePlayer.Character:IsA("Model")
		then sourcePlayer.Character
		else nil
	local groundedPos = snapToGround(sourcePos, ignoreModel, fuseGroundLift)
	local damageCoefficient = fuseCfg.baseDamageCoefficient + (fuseCfg.stackDamageCoefficient * stackBonusCount)
	local damage = getScaledBaseDamage(targetPlayerEntity) * damageCoefficient

	local visual = spawnWorldModel(resolvedFuseModelName, groundedPos, true)
	table.insert(pendingFuseBombs, {
		ownerEntity = targetPlayerEntity,
		position = groundedPos,
		detonateAt = now + fuseCfg.detonationDelay,
		damage = damage,
		procCoefficient = procCoefficient,
		visual = visual,
	})
end

local function isEnemyAlive(enemyEntity: number?): boolean
	if typeof(enemyEntity) ~= "number" then
		return false
	end
	if not world or not world:contains(enemyEntity) then
		return false
	end
	if getEntityTypeName(enemyEntity) ~= "Enemy" then
		return false
	end
	local enemyHealth = world:get(enemyEntity, Health)
	return enemyHealth ~= nil and (enemyHealth.current or 0) > 0
end

local function resolveSilverTargetEntity(origin: Vector3, preferredTargetEntity: number?, acquireRadius: number): number?
	if isEnemyAlive(preferredTargetEntity) then
		return preferredTargetEntity
	end

	local closestEnemy: number? = nil
	local closestDistSq = math.huge
	local candidates = OctreeSystem.getEnemiesInRadius(origin, acquireRadius)
	for _, enemyId in ipairs(candidates) do
		if isEnemyAlive(enemyId) then
			local enemyPos = getEntityPosition(enemyId)
			if enemyPos then
				local delta = enemyPos - origin
				local distSq = delta:Dot(delta)
				if distSq < closestDistSq then
					closestDistSq = distSq
					closestEnemy = enemyId
				end
			end
		end
	end
	return closestEnemy
end

local function getPlayerAimDirection(playerEntity: number): Vector3
	local player = getPlayerFromEntity(playerEntity)
	if player and player.Character then
		local hrp = player.Character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			local look = (hrp :: BasePart).CFrame.LookVector
			if look.Magnitude > 1e-4 then
				return look.Unit
			end
		end
	end
	return Vector3.new(0, 0, -1)
end

local function triggerSilverStar(sourcePlayerEntity: number, targetEnemyEntity: number?, procCoefficient: number, aimPoint: Vector3?)
	local stacks = getItemStackCount(sourcePlayerEntity, RunItems.Ids.SilverNinjaStarOfTheBrilliantLight)
	if stacks <= 0 then
		return
	end

	local state = ensureEntityState(sourcePlayerEntity)
	local now = GameTimeSystem.getGameTime()
	refreshSilverRecharge(state, stacks, now)
	if state.silver.charges <= 0 then
		return
	end

	state.silver.charges -= 1
	local silverCfg = RunItems.Definitions[RunItems.Ids.SilverNinjaStarOfTheBrilliantLight].silverStar
	local maxCharges = math.max(1, state.silver.maxCharges)
	local baseInterval = silverCfg.rechargeDuration / maxCharges
	local scaledInterval = baseInterval * procCoefficient
	local desiredRechargeAt = now + scaledInterval
	if state.silver.nextRechargeAt <= 0 then
		state.silver.nextRechargeAt = desiredRechargeAt
	else
		state.silver.nextRechargeAt = math.max(state.silver.nextRechargeAt, desiredRechargeAt)
	end

	local origin = getEntityPosition(sourcePlayerEntity)
	if not origin then
		return
	end

	local projectileOrigin = origin + Vector3.new(0, 2, 0)
	local resolvedTarget = resolveSilverTargetEntity(projectileOrigin, targetEnemyEntity, silverCfg.homing.acquireRadius or 240.0)
	local direction = getPlayerAimDirection(sourcePlayerEntity)
	if typeof(aimPoint) == "Vector3" then
		local toCursor = aimPoint - projectileOrigin
		if toCursor.Magnitude > 1e-4 then
			direction = toCursor.Unit
		end
	end

	local silverDropModelName = resolveCommonItemModelName(
		RunItems.Definitions[RunItems.Ids.SilverNinjaStarOfTheBrilliantLight].dropModelName
	)
	replicateCommonItemModel(silverDropModelName)
	local damageCoefficient = silverCfg.baseDamageCoefficient + (math.max(0, stacks - 1) * silverCfg.stackDamageCoefficient)
	local projectileDamage = getScaledBaseDamage(sourcePlayerEntity) * damageCoefficient
	local homingConfig = cloneTable(silverCfg.homing)
	homingConfig.targetEntity = resolvedTarget

	ProjectileService.spawnProjectile({
		kind = "SilverNinjaStaroftheBrilliantLight",
		origin = projectileOrigin,
		direction = direction,
		speed = silverCfg.projectileSpeed,
		damage = projectileDamage,
		radius = silverCfg.hitboxRadius,
		lifetime = silverCfg.projectileLifetime,
		ownerEntity = sourcePlayerEntity,
		modelPath = buildReplicatedCommonItemPath(silverDropModelName),
		collision = {
			useRaycast = true,
			collideWithWorld = true,
		},
		homing = homingConfig,
		procCoefficient = procCoefficient,
	})
end

function ItemSystem.onAttackAttempt(data: {[string]: any})
	if typeof(data) ~= "table" then
		return
	end

	local sourceEntity = data.sourceEntity
	if typeof(sourceEntity) ~= "number" or getEntityTypeName(sourceEntity) ~= "Player" then
		return
	end

	local abilityId = data.abilityId
	if abilityId == "SilverNinjaStaroftheBrilliantLight" then
		return
	end

	local targetEntity = if typeof(data.targetEntity) == "number" then data.targetEntity else nil
	local procCoefficient = clampProcCoefficient(data.procCoefficient)
	local aimPoint = if typeof(data.aimPoint) == "Vector3" then data.aimPoint else nil
	triggerSilverStar(sourceEntity, targetEntity, procCoefficient, aimPoint)
end

function ItemSystem.init(worldRef: any, components: any, deps: {[string]: any})
	world = worldRef
	Components = components
	PickupService = deps.PickupService
	ProjectileService = deps.ProjectileService
	ModelReplicationService = deps.ModelReplicationService

	Position = Components.Position
	PlayerStats = Components.PlayerStats
	EntityType = Components.EntityType
	Level = Components.Level
	PassiveEffects = Components.PassiveEffects
	Health = Components.Health

	local remotesFolder = ReplicatedStorage:WaitForChild("RemoteEvents")
	local itemsFolder = remotesFolder:FindFirstChild("Items")
	if not itemsFolder then
		itemsFolder = Instance.new("Folder")
		itemsFolder.Name = "Items"
		itemsFolder.Parent = remotesFolder
	end
	itemStateRemote = ensureRemoteEvent(itemsFolder, "ItemState")
end

function ItemSystem.onEntityRemoved(entity: number)
	if itemStateByEntity[entity] then
		clearEntityState(entity, true)
	end
end

function ItemSystem.spawnDebugDropForPlayer(player: Player, itemId: string): (boolean, string)
	local def = RunItems.get(itemId)
	if not def then
		return false, "Unknown item id"
	end
	if not PickupService then
		return false, "PickupService unavailable"
	end

	local dropCfg = RunItems.DefaultDropSettings
	local spawnPos = getForwardGroundedDropPosition(player, dropCfg.forwardDistance, dropCfg.groundLift)
	if not spawnPos then
		return false, "Missing HumanoidRootPart"
	end

	local resolvedDropModelName = resolveCommonItemModelName(def.dropModelName)
	replicateCommonItemModel(resolvedDropModelName)
	local modelPath = buildReplicatedCommonItemPath(resolvedDropModelName)
	local pickupId = PickupService.spawnPickup(
		spawnPos,
		0,
		"item:" .. itemId,
		nil,
		nil,
		{
			allowMerge = false,
			noDespawn = dropCfg.noDespawn,
			itemId = itemId,
			itemDisplayName = def.displayName,
			itemDescription = def.promptDescription or def.description,
			modelPath = modelPath,
			requiresInteract = dropCfg.requiresInteract,
			interactionRadius = dropCfg.interactionRadius,
			autoPickupRadius = dropCfg.autoPickupRadius,
			spinPeriod = dropCfg.spinPeriod,
			bobAmplitude = dropCfg.bobAmplitude,
			onCollect = function(record: any, _collectorPlayer: Player, collectorEntity: number)
				if record and typeof(record.id) == "number" then
					activeItemDropIds[record.id] = nil
				end
				if collectorEntity and world and world:contains(collectorEntity) then
					addItemToEntity(collectorEntity, itemId)
				end
			end,
		}
	)

	if pickupId then
		activeItemDropIds[pickupId] = true
	end

	return pickupId ~= nil, if pickupId then "Spawned item drop" else "Failed to spawn item drop"
end

function ItemSystem.onDamageResolved(data: {[string]: any})
	if typeof(data) ~= "table" then
		return
	end
	if data.applied ~= true then
		return
	end
	if typeof(data.appliedDamage) ~= "number" or data.appliedDamage <= 0 then
		return
	end

	local procCoefficient = clampProcCoefficient(data.procCoefficient)

	local targetEntity = data.targetEntity
	local sourceEntity = data.sourceEntity
	local abilityId = data.abilityId
	local targetIsPlayer = data.targetIsPlayer == true
	local targetIsEnemy = data.targetIsEnemy == true

	if targetIsPlayer and typeof(targetEntity) == "number" and getEntityTypeName(targetEntity) == "Player" then
		triggerFuseBomb(targetEntity, procCoefficient)
	end

	if targetIsEnemy
		and typeof(targetEntity) == "number"
		and typeof(sourceEntity) == "number"
		and getEntityTypeName(sourceEntity) == "Player"
		and abilityId ~= "SilverNinjaStaroftheBrilliantLight"
		and abilityId ~= "OathkeeperPrimary"
		and abilityId ~= "OathkeeperSecondary"
	then
		triggerSilverStar(sourceEntity, targetEntity, procCoefficient, nil)
	end
end

function ItemSystem.step(_dt: number)
	if not world then
		return
	end

	local now = GameTimeSystem.getGameTime()
	local currentState = GameStateManager.getCurrentState()
	if currentState ~= "InGame" then
		for playerEntity in pairs(itemStateByEntity) do
			clearEntityState(playerEntity, true)
		end
		local dropIds = {}
		for pickupId in pairs(activeItemDropIds) do
			table.insert(dropIds, pickupId)
		end
		for _, pickupId in ipairs(dropIds) do
			activeItemDropIds[pickupId] = nil
			if PickupService and PickupService.despawnPickup then
				PickupService.despawnPickup(pickupId)
			end
		end
		for i = #pendingFuseBombs, 1, -1 do
			local pending = pendingFuseBombs[i]
			if pending.visual and pending.visual.Parent then
				pending.visual:Destroy()
			end
			table.remove(pendingFuseBombs, i)
		end
		return
	end

	for playerEntity, state in pairs(itemStateByEntity) do
		if not world:contains(playerEntity) then
			clearEntityState(playerEntity, false)
			continue
		end
		local player = getPlayerFromEntity(playerEntity)
		if not player then
			clearEntityState(playerEntity, false)
			continue
		end
		if not GameStateManager.isPlayerInGame(player) then
			clearEntityState(playerEntity, true)
			continue
		end

		local silverStacks = state.counts[RunItems.Ids.SilverNinjaStarOfTheBrilliantLight] or 0
		if silverStacks > 0 then
			refreshSilverRecharge(state, silverStacks, now)
		end
	end

	for i = #pendingFuseBombs, 1, -1 do
		local pending = pendingFuseBombs[i]
		if now >= pending.detonateAt then
			explodeFuseBomb(pending)
			table.remove(pendingFuseBombs, i)
		end
	end
end

return ItemSystem
