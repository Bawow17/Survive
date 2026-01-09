--!strict
-- Octree - Fast spatial partitioning for 3D entities
-- Based on DevForum performance benchmarks showing 10-40x speedup vs linear searches
-- Reference: https://devforum.roblox.com/t/how-to-optimize-5000-parts-spinning/3032250/15

local Octree = {}
Octree.__index = Octree

export type OctreeNode = {
	position: Vector3,
	size: number,
	objects: {{id: any, position: Vector3}},
	children: {OctreeNode}?,
	maxObjects: number,
	maxDepth: number,
	depth: number,
}

-- Create a new Octree
function Octree.new(position: Vector3?, size: number?, maxObjects: number?, maxDepth: number?): OctreeNode
	local self = setmetatable({}, Octree)
	
	self.position = position or Vector3.new(0, 0, 0)
	self.size = size or 1000 -- Default 1000 studs
	self.objects = {}
	self.children = nil
	self.maxObjects = maxObjects or 8 -- Subdivide when > 8 objects
	self.maxDepth = maxDepth or 8 -- Max tree depth
	self.depth = 0
	
	return self :: any
end

-- Check if a position is within this node's bounds
local function containsPosition(node: OctreeNode, position: Vector3): boolean
	local halfSize = node.size / 2
	local min = node.position - Vector3.new(halfSize, halfSize, halfSize)
	local max = node.position + Vector3.new(halfSize, halfSize, halfSize)
	
	return position.X >= min.X and position.X <= max.X
		and position.Y >= min.Y and position.Y <= max.Y
		and position.Z >= min.Z and position.Z <= max.Z
end

-- Subdivide node into 8 children (octants)
local function subdivide(node: OctreeNode)
	if node.children then
		return -- Already subdivided
	end
	
	local quarterSize = node.size / 4
	local childSize = node.size / 2
	local children = {}
	
	-- Create 8 octants
	local offsets = {
		Vector3.new(-1, -1, -1), -- Bottom-Left-Back
		Vector3.new(1, -1, -1),  -- Bottom-Right-Back
		Vector3.new(-1, 1, -1),  -- Top-Left-Back
		Vector3.new(1, 1, -1),   -- Top-Right-Back
		Vector3.new(-1, -1, 1),  -- Bottom-Left-Front
		Vector3.new(1, -1, 1),   -- Bottom-Right-Front
		Vector3.new(-1, 1, 1),   -- Top-Left-Front
		Vector3.new(1, 1, 1),    -- Top-Right-Front
	}
	
	for i, offset in ipairs(offsets) do
		local childPos = node.position + (offset * quarterSize)
		local child = Octree.new(childPos, childSize, node.maxObjects, node.maxDepth)
		child.depth = node.depth + 1
		children[i] = child
	end
	
	node.children = children
	
	-- Redistribute objects to children
	local objectsToRedistribute = node.objects
	node.objects = {} -- Clear parent objects
	
	for _, obj in ipairs(objectsToRedistribute) do
		Octree.AddObject(node, obj.id, obj.position)
	end
end

-- Add an object to the octree
function Octree:AddObject(id: any, position: Vector3)
	local node = self :: OctreeNode
	
	-- Check if position is within bounds
	if not containsPosition(node, position) then
		return -- Out of bounds
	end
	
	-- If we have children, delegate to them
	if node.children then
		for _, child in ipairs(node.children) do
			Octree.AddObject(child, id, position)
		end
		return
	end
	
	-- Add to this node
	table.insert(node.objects, {id = id, position = position})
	
	-- Subdivide if we exceed capacity and haven't reached max depth
	if #node.objects > node.maxObjects and node.depth < node.maxDepth then
		subdivide(node)
	end
end

-- Radius search: Find all objects within a sphere
function Octree:RadiusSearch(center: Vector3, radius: number): {any}
	local node = self :: OctreeNode
	local results = {}
	local radiusSq = radius * radius
	
	-- Check if this node's bounds intersect with the search sphere
	local halfSize = node.size / 2
	local closestPoint = Vector3.new(
		math.clamp(center.X, node.position.X - halfSize, node.position.X + halfSize),
		math.clamp(center.Y, node.position.Y - halfSize, node.position.Y + halfSize),
		math.clamp(center.Z, node.position.Z - halfSize, node.position.Z + halfSize)
	)
	
	local distSq = (center - closestPoint).Magnitude ^ 2
	if distSq > radiusSq then
		return results -- Node doesn't intersect search sphere
	end
	
	-- Check objects in this node
	for _, obj in ipairs(node.objects) do
		local objDistSq = (center - obj.position).Magnitude ^ 2
		if objDistSq <= radiusSq then
			table.insert(results, obj.id)
		end
	end
	
	-- Recursively check children
	if node.children then
		for _, child in ipairs(node.children) do
			local childResults = Octree.RadiusSearch(child, center, radius)
			for _, id in ipairs(childResults) do
				table.insert(results, id)
			end
		end
	end
	
	return results
end

-- Clear all objects from the octree (for rebuilding each frame)
function Octree:Clear()
	local node = self :: OctreeNode
	node.objects = {}
	node.children = nil
end

return Octree

