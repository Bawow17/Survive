--!strict

local ChunkHeightField = {}
ChunkHeightField.__index = ChunkHeightField

export type Config = {
	seed: number,
	centerHeight: number,
	maxNeighborDelta: number,
	maxAxisOffset: number,
}

export type ChunkHeightField = {
	seed: number,
	centerHeight: number,
	maxNeighborDelta: number,
	maxAxisOffset: number,
	xAxisSeed: number,
	zAxisSeed: number,
	xOffsets: {[number]: number},
	zOffsets: {[number]: number},
	configure: (self: ChunkHeightField, config: Config) -> (),
	getHeight: (self: ChunkHeightField, cx: number, cz: number) -> number,
}

local PRIME_A = 92821
local PRIME_B = 146959

local function stepDelta(axisSeed: number, index: number, maxNeighborDelta: number): number
	local stepSeed = axisSeed + index * PRIME_A + PRIME_B
	return Random.new(stepSeed):NextInteger(-maxNeighborDelta, maxNeighborDelta)
end

local function computeAxisOffset(cache: {[number]: number}, axisSeed: number, index: number, maxNeighborDelta: number, maxAxisOffset: number): number
	local cached = cache[index]
	if cached ~= nil then
		return cached
	end

	if index > 0 then
		local start = 0
		for i = index - 1, 0, -1 do
			if cache[i] ~= nil then
				start = i
				break
			end
		end

		for i = start + 1, index do
			local prev = cache[i - 1] or 0
			local nextValue = math.clamp(prev + stepDelta(axisSeed, i, maxNeighborDelta), -maxAxisOffset, maxAxisOffset)
			cache[i] = nextValue
		end
	else
		local start = 0
		for i = index + 1, 0 do
			if cache[i] ~= nil then
				start = i
				break
			end
		end

		for i = start - 1, index, -1 do
			local prev = cache[i + 1] or 0
			local nextValue = math.clamp(prev + stepDelta(axisSeed, i, maxNeighborDelta), -maxAxisOffset, maxAxisOffset)
			cache[i] = nextValue
		end
	end

	return cache[index] or 0
end

function ChunkHeightField.new(config: Config): ChunkHeightField
	local self = setmetatable({}, ChunkHeightField) :: any
	self:configure(config)
	return self
end

function ChunkHeightField:configure(config: Config)
	self.seed = config.seed
	self.centerHeight = config.centerHeight
	self.maxNeighborDelta = config.maxNeighborDelta
	self.maxAxisOffset = config.maxAxisOffset
	self.xAxisSeed = self.seed + 101
	self.zAxisSeed = self.seed + 202
	self.xOffsets = { [0] = 0 }
	self.zOffsets = { [0] = 0 }
end

function ChunkHeightField:getHeight(cx: number, cz: number): number
	local xOffset = computeAxisOffset(self.xOffsets, self.xAxisSeed, cx, self.maxNeighborDelta, self.maxAxisOffset)
	local zOffset = computeAxisOffset(self.zOffsets, self.zAxisSeed, cz, self.maxNeighborDelta, self.maxAxisOffset)
	return self.centerHeight + xOffset + zOffset
end

return ChunkHeightField
