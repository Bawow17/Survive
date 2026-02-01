--!strict
-- ModelHitboxHelper.lua - Shared utility for resolving hitbox data from models
-- Used by both projectile creation and collision detection systems

local ModelHitboxHelper = {}

-- Helper function to resolve hitbox info from a model path
-- Returns: hitboxSize (Vector3?), hitboxOffset (Vector3?)
function ModelHitboxHelper.getModelHitboxData(modelPath: string): (Vector3?, Vector3?)
	if not modelPath then
		return nil, nil
	end

	local current: Instance? = game
	for _, partName in ipairs(string.split(modelPath, ".")) do
		if not current then
			return nil, nil
		end
		current = current:FindFirstChild(partName)
	end

	if not current or not current:IsA("Model") then
		return nil, nil
	end

	local model: Model = current

	-- Priority 1: Look for "Hitbox"/"hitbox" part (this is what we want for projectiles)
	local hitbox = model:FindFirstChild("Hitbox") or model:FindFirstChild("hitbox")
	if not hitbox then
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") and (descendant.Name == "Hitbox" or descendant.Name == "hitbox") then
				hitbox = descendant
				break
			end
		end
	end
	if hitbox and hitbox:IsA("BasePart") then
		local pivot = model:GetPivot()
		return hitbox.Size, hitbox.Position - pivot.Position
	end

	-- Priority 2: Use PrimaryPart (but not "Attackbox")
	local primary = model.PrimaryPart
	if primary and primary:IsA("BasePart") and primary.Name ~= "Attackbox" then
		local pivot = model:GetPivot()
		return primary.Size, primary.Position - pivot.Position
	end

	-- Priority 3: Find any BasePart (but not "Attackbox")
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name ~= "Attackbox" then
			local pivot = model:GetPivot()
			return descendant.Size, descendant.Position - pivot.Position
		end
	end

	return nil, nil
end

-- Returns: hitboxSize (Vector3?), hitboxOffset (Vector3?), hitboxRotation (CFrame?)
function ModelHitboxHelper.getModelHitboxTransform(modelPath: string): (Vector3?, Vector3?, CFrame?)
	if not modelPath then
		return nil, nil, nil
	end

	local current: Instance? = game
	for _, partName in ipairs(string.split(modelPath, ".")) do
		if not current then
			return nil, nil, nil
		end
		current = current:FindFirstChild(partName)
	end

	if not current or not current:IsA("Model") then
		return nil, nil, nil
	end

	local model: Model = current
	local hitbox = model:FindFirstChild("Hitbox") or model:FindFirstChild("hitbox")
	if not hitbox then
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") and (descendant.Name == "Hitbox" or descendant.Name == "hitbox") then
				hitbox = descendant
				break
			end
		end
	end

	if hitbox and hitbox:IsA("BasePart") then
		local pivot = model:GetPivot()
		local localCf = pivot:ToObjectSpace(hitbox.CFrame)
		local rotation = CFrame.fromMatrix(Vector3.new(0, 0, 0), localCf.RightVector, localCf.UpVector, localCf.LookVector)
		return hitbox.Size, localCf.Position, rotation
	end

	return nil, nil, nil
end

return ModelHitboxHelper
