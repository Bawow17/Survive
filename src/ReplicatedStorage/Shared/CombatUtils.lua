--!strict
-- Combat Utilities - Shared functions for combat and collision detection

local CombatUtils = {}

-- Check if a part is a valid enemy hitbox (can be hit by projectiles)
function CombatUtils.isValidEnemyHitbox(part: BasePart): boolean
	if not part or not part:IsA("BasePart") then
		return false
	end
	
	-- Only "Hitbox" parts can be hit by projectiles
	if part.Name ~= "Hitbox" then
		return false
	end
	
	-- Must be part of an enemy model
	local model = part.Parent
	if not model or not model:IsA("Model") then
		return false
	end
	
	-- Verify it's an enemy by checking for both Hitbox and Attackbox
	local hasHitbox = model:FindFirstChild("Hitbox")
	local hasAttackbox = model:FindFirstChild("Attackbox")
	
	return hasHitbox ~= nil and hasAttackbox ~= nil
end

-- Get the enemy model from a hitbox part
function CombatUtils.getEnemyFromHitbox(hitbox: BasePart): Model?
	if not CombatUtils.isValidEnemyHitbox(hitbox) then
		return nil
	end
	
	return hitbox.Parent :: Model
end

-- Check if a part is an attackbox (should not be hit by projectiles)
function CombatUtils.isAttackbox(part: BasePart): boolean
	if not part or not part:IsA("BasePart") then
		return false
	end
	
	return part.Name == "Attackbox"
end

return CombatUtils
