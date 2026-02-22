--!strict

local LocalEventRegistry = {}

function LocalEventRegistry.getExisting(container: Instance, name: string): BindableEvent?
	local existing = container:FindFirstChild(name)
	if existing and existing:IsA("BindableEvent") then
		return existing
	end
	return nil
end

function LocalEventRegistry.getOrCreate(container: Instance, name: string): BindableEvent
	local existing = LocalEventRegistry.getExisting(container, name)
	if existing then
		return existing
	end

	local created = Instance.new("BindableEvent")
	created.Name = name
	created.Parent = container

	local resolved = LocalEventRegistry.getExisting(container, name)
	if resolved then
		if resolved ~= created then
			created:Destroy()
		end
		return resolved
	end

	return created
end

return LocalEventRegistry
