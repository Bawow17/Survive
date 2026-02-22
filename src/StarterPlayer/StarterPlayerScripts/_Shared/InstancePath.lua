--!strict

local InstancePath = {}

function InstancePath.findByPath(root: Instance, path: string): Instance?
	local current: Instance = root
	for _, part in ipairs(string.split(path, ".")) do
		local child = current:FindFirstChild(part)
		if not child then
			return nil
		end
		current = child
	end
	return current
end

return InstancePath
