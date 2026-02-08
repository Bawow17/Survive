--!strict

local ChunkDecorationConfig = {}

export type DecorationEntry = {
	templatePath: string,
	seedOffset: number,
	countMin: number,
	countMax: number,
	minSpacing: number,
	edgeMargin: number,
	collidable: boolean?,
}

ChunkDecorationConfig.BiomeDecorations = {
	Forest = {
		{
			templatePath = "Forest/Trees",
			seedOffset = 12345,
			countMin = 3,
			countMax = 10,
			minSpacing = 117,
			edgeMargin = 6,
		},
		{
			templatePath = "Forest/Grass",
			seedOffset = 23456,
			countMin = 8,
			countMax = 16,
			minSpacing = 41,
			edgeMargin = 4,
			collidable = false,
		},
	},
	Flatlands = {
		{
			templatePath = "Flatlands/Grass",
			seedOffset = 34567,
			countMin = 10,
			countMax = 24,
			minSpacing = 43,
			edgeMargin = 6,
			collidable = false,
		},
	},
	Desert = {
		{
			templatePath = "Desert/Cactus",
			seedOffset = 45678,
			countMin = 4,
			countMax = 8,
			minSpacing = 50,
			edgeMargin = 8,
		},
		{
			templatePath = "Desert/Tumbleweed",
			seedOffset = 56789,
			countMin = 2,
			countMax = 4,
			minSpacing = 57,
			edgeMargin = 8,
			collidable = false,
		},
	},
	Swamp = {
		{
			templatePath = "Swamp/Trees",
			seedOffset = 67890,
			countMin = 3,
			countMax = 7,
			minSpacing = 153,
			edgeMargin = 10,
		},
		{
			templatePath = "Swamp/Ponds",
			seedOffset = 78901,
			countMin = 1,
			countMax = 2,
			minSpacing = 36,
			edgeMargin = 12,
		},
	},
	Tundra = {
		{
			templatePath = "Tundra/Trees",
			seedOffset = 89012,
			countMin = 3,
			countMax = 6,
			minSpacing = 119.25,
			edgeMargin = 10,
		},
		{
			templatePath = "Tundra/Grass",
			seedOffset = 90123,
			countMin = 8,
			countMax = 16,
			minSpacing = 41,
			edgeMargin = 4,
			collidable = false,
		},
	},
}

function ChunkDecorationConfig.getForBiome(biomeName: string): {DecorationEntry}
	return (ChunkDecorationConfig.BiomeDecorations[biomeName] or {}) :: {DecorationEntry}
end

return ChunkDecorationConfig
