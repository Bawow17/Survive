--!strict

local DebugModMenuCatalog = {}

DebugModMenuCatalog.CategoryOrder = {
	time = 1,
	items = 2,
	ultimate = 3,
}

DebugModMenuCatalog.CategoryLabels = {
	time = "Time Controls",
	items = "Items",
	ultimate = "Ultimate",
}

DebugModMenuCatalog.TimeOptions = {
	{ entryId = "time:60", name = "+1m", seconds = 60, category = "time" },
	{ entryId = "time:300", name = "+5m", seconds = 300, category = "time" },
	{ entryId = "time:600", name = "+10m", seconds = 600, category = "time" },
}

return DebugModMenuCatalog
