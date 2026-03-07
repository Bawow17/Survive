--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IconAssetResolver = {}

local function normalizePathRoot(path: string): string
	local normalizedPath = path
	if normalizedPath:sub(1, #"game:GetService(\"ServerStorage\").") == "game:GetService(\"ServerStorage\")." then
		return "ReplicatedStorage." .. normalizedPath:sub(#"game:GetService(\"ServerStorage\")." + 1)
	end
	if normalizedPath:sub(1, #"game:GetService('ServerStorage').") == "game:GetService('ServerStorage')." then
		return "ReplicatedStorage." .. normalizedPath:sub(#"game:GetService('ServerStorage')." + 1)
	end
	if normalizedPath:sub(1, #"game:GetService(\"ReplicatedStorage\").") == "game:GetService(\"ReplicatedStorage\")." then
		return "ReplicatedStorage." .. normalizedPath:sub(#"game:GetService(\"ReplicatedStorage\")." + 1)
	end
	if normalizedPath:sub(1, #"game:GetService('ReplicatedStorage').") == "game:GetService('ReplicatedStorage')." then
		return "ReplicatedStorage." .. normalizedPath:sub(#"game:GetService('ReplicatedStorage')." + 1)
	end
	if normalizedPath:sub(1, #"ServerStorage.") == "ServerStorage." then
		return "ReplicatedStorage." .. normalizedPath:sub(#"ServerStorage." + 1)
	end
	if normalizedPath:sub(1, #"game.") == "game." then
		return normalizedPath:sub(#"game." + 1)
	end
	return normalizedPath
end

local function findByPath(path: string): Instance?
	local normalizedPath = normalizePathRoot(path)
	if normalizedPath:sub(1, #"ReplicatedStorage.") ~= "ReplicatedStorage." then
		return nil
	end

	local current: Instance? = ReplicatedStorage
	for _, partName in ipairs(string.split(normalizedPath:sub(#"ReplicatedStorage." + 1), ".")) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(partName)
	end
	return current
end

local function extractImageFromInstance(instance: Instance?): string?
	if not instance then
		return nil
	end
	if instance:IsA("Decal") or instance:IsA("Texture") then
		return instance.Texture
	end
	if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		return instance.Image
	end
	if instance:IsA("StringValue") then
		return instance.Value
	end
	if instance:IsA("MeshPart") then
		return instance.TextureID
	end
	return nil
end

function IconAssetResolver.resolve(rawId: any): string?
	if rawId == nil then
		return nil
	end

	local iconString = tostring(rawId)
	if iconString == "" then
		return nil
	end
	if iconString:match("^%d+$") then
		return "rbxassetid://" .. iconString
	end
	if iconString:sub(1, #"rbxassetid://") == "rbxassetid://" then
		return iconString
	end
	if iconString:find("://", 1, true) then
		return iconString
	end

	local normalizedPath = normalizePathRoot(iconString)
	local resolvedInstance = findByPath(normalizedPath)
	local resolvedImage = extractImageFromInstance(resolvedInstance)
	if resolvedImage and resolvedImage ~= "" then
		return resolvedImage
	end
	if normalizedPath ~= iconString or normalizedPath:sub(1, #"ReplicatedStorage.") == "ReplicatedStorage." then
		return nil
	end

	return iconString
end

return IconAssetResolver
