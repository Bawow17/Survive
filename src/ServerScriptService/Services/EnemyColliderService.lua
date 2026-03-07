--!strict
-- EnemyColliderService - Centralized enemy collider and scale resolution.
-- Single source of truth for hitbox/attackbox world transforms.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModelReplicationService = require(game.ServerScriptService.ECS.ModelReplicationService)
local FacingResolver = require(ReplicatedStorage.Shared.FacingResolver)

local EnemyColliderService = {}

local world: any
local Components: any

local DEFAULT_SUPER_SCALE = 4.0
local DEFAULT_ELITE_SCALE = 7.5
local DEFAULT_SCALE = 1.0
local DEFAULT_GROUND_CLEARANCE = 0
local DEFAULT_MAX_GROUND_OFFSET = 12.0

type ColliderProfile = {
	size: Vector3,
	offset: Vector3,
	halfExtents: Vector3,
	radius: number,
	rotation: CFrame?,
}

local hitboxBySubtype: {[string]: ColliderProfile} = {}
local attackboxBySubtype: {[string]: ColliderProfile} = {}
local groundOffsetByKey: {[string]: number} = {}

function EnemyColliderService.init(worldRef: any, componentsRef: any)
	world = worldRef
	Components = componentsRef
	table.clear(hitboxBySubtype)
	table.clear(attackboxBySubtype)
	table.clear(groundOffsetByKey)
end

local function getFacingOrientation(enemyEntity: number): CFrame
	if not world or not Components then
		return CFrame.new()
	end
	local facing = Components.FacingDirection and world:get(enemyEntity, Components.FacingDirection) or nil
	local desiredVelocity = Components.DesiredVelocity and world:get(enemyEntity, Components.DesiredVelocity) or nil
	local velocity = Components.Velocity and world:get(enemyEntity, Components.Velocity) or nil
	local resolvedFacing = FacingResolver.resolveEnemyFacing(
		facing,
		desiredVelocity,
		velocity,
		Vector3.new(0, 0, 1)
	)
	return CFrame.lookAt(Vector3.zero, resolvedFacing)
end

local function getCollisionRadius(enemyEntity: number): number?
	if not world or not Components or not Components.Collision then
		return nil
	end
	local collision = world:get(enemyEntity, Components.Collision)
	local collisionRadius = collision and collision.radius
	if typeof(collisionRadius) == "number" and collisionRadius > 0 then
		return collisionRadius
	end
	return nil
end

local function getTierFallbackScale(tierName: any): number
	if tierName == "Super" then
		return DEFAULT_SUPER_SCALE
	end
	if tierName == "Elite" then
		return DEFAULT_ELITE_SCALE
	end
	return DEFAULT_SCALE
end

function EnemyColliderService.getEnemySubtype(enemyEntity: number): string?
	if not world or not Components or not Components.EntityType then
		return nil
	end
	local entityType = world:get(enemyEntity, Components.EntityType)
	if typeof(entityType) ~= "table" then
		return nil
	end
	local subtype = entityType.subtype
	if typeof(subtype) == "string" and subtype ~= "" then
		return subtype
	end
	return nil
end

function EnemyColliderService.getEnemyTier(enemyEntity: number): string?
	if not world or not Components or not Components.EnemyTier then
		return nil
	end
	local tierData = world:get(enemyEntity, Components.EnemyTier)
	if typeof(tierData) == "table" and typeof(tierData.tier) == "string" then
		return tierData.tier
	end
	return nil
end

function EnemyColliderService.getEffectiveScale(enemyEntity: number): number
	if not world or not Components then
		return DEFAULT_SCALE
	end

	-- Scale must match rendered model scale exactly.
	if Components.Visual then
		local visual = world:get(enemyEntity, Components.Visual)
		local visualScale = visual and visual.scale
		if typeof(visualScale) == "number" and visualScale == visualScale and visualScale > 0 then
			return math.clamp(visualScale, 0.1, 20.0)
		end
	end

	if Components.EnemyTier then
		local tierData = world:get(enemyEntity, Components.EnemyTier)
		if typeof(tierData) == "table" then
			local tierScale = tierData.scale
			if typeof(tierScale) == "number" and tierScale == tierScale and tierScale > 0 then
				return math.clamp(tierScale, 0.1, 20.0)
			end
			return getTierFallbackScale(tierData.tier)
		end
	end

	return DEFAULT_SCALE
end

function EnemyColliderService.getBasePosition(enemyEntity: number): Vector3?
	if not world or not Components or not Components.Position then
		return nil
	end
	local pos = world:get(enemyEntity, Components.Position)
	if not pos then
		return nil
	end
	return Vector3.new(pos.x, pos.y, pos.z)
end

local function toColliderProfile(data: any): ColliderProfile?
	if not data or not data.size then
		return nil
	end
	local size = data.size
	local offset = data.offset or Vector3.new(0, 0, 0)
	local rotation = data.rotation
	if typeof(rotation) == "CFrame" then
		rotation = rotation - rotation.Position
	else
		rotation = nil
	end
	return {
		size = size,
		offset = offset,
		halfExtents = size * 0.5,
		-- Use horizontal radius so tall hitboxes do not inflate collision breadth.
		radius = math.max(size.X, size.Z) * 0.5,
		rotation = rotation,
	}
end

local function ensureHitboxProfile(subtype: string?): ColliderProfile?
	if typeof(subtype) ~= "string" or subtype == "" then
		return nil
	end
	local cached = hitboxBySubtype[subtype]
	if cached then
		return cached
	end
	local hitbox = ModelReplicationService.getEnemyHitbox(subtype)
	if not hitbox then
		ModelReplicationService.ensureEnemyHitbox(subtype)
		hitbox = ModelReplicationService.getEnemyHitbox(subtype)
	end
	local profile = toColliderProfile(hitbox)
	if profile then
		hitboxBySubtype[subtype] = profile
	end
	return profile
end

local function ensureAttackboxProfile(subtype: string?): ColliderProfile?
	if typeof(subtype) ~= "string" or subtype == "" then
		return nil
	end
	local cached = attackboxBySubtype[subtype]
	if cached then
		return cached
	end
	local attackbox = ModelReplicationService.getEnemyAttackbox(subtype)
	if not attackbox then
		ModelReplicationService.ensureEnemyHitbox(subtype)
		attackbox = ModelReplicationService.getEnemyAttackbox(subtype)
	end
	local profile = toColliderProfile(attackbox)
	if profile then
		attackboxBySubtype[subtype] = profile
	end
	return profile
end

local function buildWorldCollider(enemyEntity: number, basePos: Vector3, scale: number, profile: ColliderProfile): {[string]: any}
	local facingOrientation = getFacingOrientation(enemyEntity)
	local localRotation = profile.rotation or CFrame.new()
	local scaledOffset = profile.offset * scale
	local worldOffset = facingOrientation:VectorToWorldSpace(scaledOffset)
	local center = basePos + worldOffset
	local halfExtents = profile.halfExtents * scale
	local radius = profile.radius * scale
	local rotation = facingOrientation * localRotation
	return {
		basePos = basePos,
		center = center,
		halfExtents = halfExtents,
		radius = radius,
		boxCFrame = CFrame.new(center) * rotation,
	}
end

function EnemyColliderService.getWorldHitbox(enemyEntity: number): {[string]: any}?
	local basePos = EnemyColliderService.getBasePosition(enemyEntity)
	if not basePos then
		return nil
	end
	local scale = EnemyColliderService.getEffectiveScale(enemyEntity)
	local subtype = EnemyColliderService.getEnemySubtype(enemyEntity)
	local profile = ensureHitboxProfile(subtype)
	if not profile then
		local fallbackRadius = getCollisionRadius(enemyEntity) or (2.5 * scale)
		local half = Vector3.new(fallbackRadius, fallbackRadius, fallbackRadius)
		local fallbackFacing = getFacingOrientation(enemyEntity)
		local attackProfile = ensureAttackboxProfile(subtype)
		local attackLocalRotation = attackProfile and attackProfile.rotation or CFrame.new()
		local fallbackRotation = fallbackFacing * attackLocalRotation
		return {
			basePos = basePos,
			center = basePos,
			halfExtents = half,
			radius = fallbackRadius,
			boxCFrame = CFrame.new(basePos) * fallbackRotation,
			scale = scale,
			subtype = subtype,
			tier = EnemyColliderService.getEnemyTier(enemyEntity),
		}
	end
	local collider = buildWorldCollider(enemyEntity, basePos, scale, profile)
	collider.scale = scale
	collider.subtype = subtype
	collider.tier = EnemyColliderService.getEnemyTier(enemyEntity)
	return collider
end

function EnemyColliderService.getWorldAttackbox(enemyEntity: number): {[string]: any}?
	local basePos = EnemyColliderService.getBasePosition(enemyEntity)
	if not basePos then
		return nil
	end
	local subtype = EnemyColliderService.getEnemySubtype(enemyEntity)
	local profile = ensureAttackboxProfile(subtype)
	if not profile then
		return EnemyColliderService.getWorldHitbox(enemyEntity)
	end
	local scale = EnemyColliderService.getEffectiveScale(enemyEntity)
	local collider = buildWorldCollider(enemyEntity, basePos, scale, profile)
	collider.scale = scale
	collider.subtype = subtype
	collider.tier = EnemyColliderService.getEnemyTier(enemyEntity)
	return collider
end

function EnemyColliderService.getScaledAttackRange(enemyEntity: number, contactBuffer: number?): number
	local fallback = 3.5
	local worldAttackbox = EnemyColliderService.getWorldAttackbox(enemyEntity)
	if not worldAttackbox then
		return fallback
	end
	local half = worldAttackbox.halfExtents
	local center = worldAttackbox.center
	local basePos = worldAttackbox.basePos
	if typeof(half) ~= "Vector3" or typeof(center) ~= "Vector3" or typeof(basePos) ~= "Vector3" then
		return fallback
	end
	local horizontalOffset = Vector3.new(center.X - basePos.X, 0, center.Z - basePos.Z).Magnitude
	local horizontalHalfExtent = math.max(half.X, half.Z)
	local buffer = if typeof(contactBuffer) == "number" then contactBuffer else 0.5
	return horizontalOffset + horizontalHalfExtent + buffer
end

function EnemyColliderService.getGroundSnapOffsetForSubtype(
	subtype: string?,
	scale: number?,
	groundClearance: number?,
	maxOffset: number?
): number
	local safeSubtype = if typeof(subtype) == "string" and subtype ~= "" then subtype else "Zombie"
	local safeScale = DEFAULT_SCALE
	if typeof(scale) == "number" and scale == scale and scale > 0 then
		safeScale = math.clamp(scale, 0.1, 20.0)
	end

	local clearance = if typeof(groundClearance) == "number" then groundClearance else DEFAULT_GROUND_CLEARANCE
	local maxAllowed = if typeof(maxOffset) == "number" then maxOffset else DEFAULT_MAX_GROUND_OFFSET

	local scaleBucket = math.floor(safeScale * 100 + 0.5)
	local key = string.format("%s@%d|%.3f|%.3f", safeSubtype, scaleBucket, clearance, maxAllowed)
	local cached = groundOffsetByKey[key]
	if cached then
		return cached
	end

	local profile = ensureHitboxProfile(safeSubtype)
	if not profile then
		groundOffsetByKey[key] = clearance
		return clearance
	end

	local scaledOffsetY = profile.offset.Y * safeScale
	local scaledSizeY = profile.size.Y * safeScale
	local offset = clearance - scaledOffsetY + (scaledSizeY * 0.5)
	offset = math.clamp(offset, 0, maxAllowed)
	groundOffsetByKey[key] = offset
	return offset
end

function EnemyColliderService.getGroundSnapOffsetForEntity(
	enemyEntity: number,
	groundClearance: number?,
	maxOffset: number?
): number
	local subtype = EnemyColliderService.getEnemySubtype(enemyEntity)
	local scale = EnemyColliderService.getEffectiveScale(enemyEntity)
	return EnemyColliderService.getGroundSnapOffsetForSubtype(subtype, scale, groundClearance, maxOffset)
end

return EnemyColliderService
