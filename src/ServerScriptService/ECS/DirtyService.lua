--!strict
-- DirtyService - tracks component changes for syncing
-- OPTIMIZATION: Table pooling + in-place mutation to eliminate GC spikes

local DirtyService = {}

local dirtyComponents: {[number]: {[string]: boolean}} = {}

-- Quantization steps for network optimization
-- Larger steps = less precision but lower bandwidth (0.01 = 1cm precision)
local QUANTIZE_STEPS = {
	Position = 0.01,  -- Increased from 0.005 to 0.01 (1cm precision, 50% bandwidth reduction)
	Velocity = 0.01,  -- Increased from 0.005 to 0.01
}

-- OPTIMIZATION PHASE 1: Component Table Pooling
-- Pre-allocated reusable vector tables to eliminate hot-loop allocations
local VECTOR_POOL_SIZE = 2048  -- Increased from 512: allows 1000+ entities * 2 components + overhead
local vectorTablePool: {{x: number, y: number, z: number}} = {}
local vectorTablePoolCount = 0

-- Initialize vector pool (pre-warm on startup)
for i = 1, VECTOR_POOL_SIZE do
	table.insert(vectorTablePool, {x = 0, y = 0, z = 0})
end
vectorTablePoolCount = VECTOR_POOL_SIZE

-- Get reusable vector table from pool
local function acquireVectorTable(): {x: number, y: number, z: number}
	if vectorTablePoolCount > 0 then
		local table = vectorTablePool[vectorTablePoolCount]
		vectorTablePoolCount -= 1
		return table
	end
	-- Fallback: allocate new table (silent fallback - pool overflow is expected)
	-- Tables stored in world:set() won't return to pool, so overflow is normal
	return {x = 0, y = 0, z = 0}
end

-- Return vector table to pool for reuse
local function releaseVectorTable(tbl: {x: number, y: number, z: number})
	if vectorTablePoolCount < VECTOR_POOL_SIZE then
		vectorTablePoolCount += 1
		vectorTablePool[vectorTablePoolCount] = tbl
	end
end

-- Track position changes separately for spatial grid optimization
local positionChanges: {[number]: boolean} = {}

local function shallowEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return false
	end
	local count = 0
	for key, value in pairs(a) do
		if b[key] ~= value then
			return false
		end
		count += 1
	end
	for _ in pairs(b) do
		count -= 1
		if count < 0 then
			return false
		end
	end
	return count == 0
end

-- OPTIMIZATION: Mutate vector table in-place for quantization (no allocation)
local function quantizeVectorTableInPlace(value: any, step: number, outTable: {x: number, y: number, z: number}): {x: number, y: number, z: number}
	if typeof(value) ~= "table" then
		return value
	end

	local x = value.x or value.X
	local y = value.y or value.Y
	local z = value.z or value.Z

	if x == nil and y == nil and z == nil then
		return value
	end

	local function quantize(numberValue: number)
		return math.round(numberValue / step) * step
	end

	-- Mutate outTable in-place (reused table from pool)
	outTable.x = x and quantize(x) or 0
	outTable.y = y and quantize(y) or 0
	outTable.z = z and quantize(z) or 0
	
	-- Copy any extra fields (preserve ownership data, etc.)
	for key, existing in pairs(value) do
		if key ~= "x" and key ~= "y" and key ~= "z" and key ~= "X" and key ~= "Y" and key ~= "Z" then
			outTable[key] = existing
		end
	end

	return outTable
end

function DirtyService.mark(entity: number, componentName: string)
	local entry = dirtyComponents[entity]
	if not entry then
		entry = {}
		dirtyComponents[entity] = entry
	end
	entry[componentName] = true
end

-- OPTIMIZATION: Fast-path for Position/Velocity updates with in-place mutation
function DirtyService.setVector(world: any, entity: number, component: any, x: number, y: number, z: number, componentName: string)
	local quantizeStep = QUANTIZE_STEPS[componentName]
	local pooledVector = acquireVectorTable()
	
	if quantizeStep then
		pooledVector.x = math.round(x / quantizeStep) * quantizeStep
		pooledVector.y = math.round(y / quantizeStep) * quantizeStep
		pooledVector.z = math.round(z / quantizeStep) * quantizeStep
	else
		pooledVector.x = x
		pooledVector.y = y
		pooledVector.z = z
	end
	
	local current = world:get(entity, component)
	if not current or not shallowEqual(current, pooledVector) then
		world:set(entity, component, pooledVector)
		DirtyService.mark(entity, componentName)
		
		-- OPTIMIZATION PHASE 2: Track position changes for spatial grid
		if componentName == "Position" then
			positionChanges[entity] = true
		end
	else
		-- Release pooled table if not used
		releaseVectorTable(pooledVector)
	end
end

function DirtyService.setIfChanged(world: any, entity: number, component: any, newValue: any, componentName: string)
	local quantizeStep = QUANTIZE_STEPS[componentName]
	
	-- If it's a vector type and we have a pooled table, use in-place mutation
	if quantizeStep and typeof(newValue) == "table" then
		local pooledVector = acquireVectorTable()
		newValue = quantizeVectorTableInPlace(newValue, quantizeStep, pooledVector)
	elseif quantizeStep then
		-- Old path for non-table vector values (fallback)
		local tempTable = {x = newValue.x or newValue.X or 0, y = newValue.y or newValue.Y or 0, z = newValue.z or newValue.Z or 0}
		newValue = quantizeVectorTableInPlace(tempTable, quantizeStep, acquireVectorTable())
	end

	local current = world:get(entity, component)
	if not current or not shallowEqual(current, newValue) then
		world:set(entity, component, newValue)
		DirtyService.mark(entity, componentName)
		
		-- OPTIMIZATION PHASE 2: Track position changes for spatial grid
		if componentName == "Position" then
			positionChanges[entity] = true
		end
	end
end

function DirtyService.consumeDirty()
	local current = dirtyComponents
	dirtyComponents = {}
	return current
end

-- OPTIMIZATION PHASE 2: Consume position changes for spatial grid updates
function DirtyService.consumePositionChanges()
	local current = positionChanges
	positionChanges = {}
	return current
end

-- Return pool statistics for monitoring
function DirtyService.getPoolStats()
	return {
		vectorTablePoolUsage = vectorTablePoolCount .. "/" .. VECTOR_POOL_SIZE,
		vectorTablePoolPercent = (vectorTablePoolCount / VECTOR_POOL_SIZE) * 100,
		availableSlots = vectorTablePoolCount,
		note = "Tables stored in world:set() are kept by world and don't return to pool - this is expected"
	}
end

return DirtyService
