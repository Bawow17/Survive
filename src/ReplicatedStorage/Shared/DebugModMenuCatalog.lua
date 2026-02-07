--!strict

local DebugModMenuCatalog = {}

DebugModMenuCatalog.CategoryOrder = {
	time = 1,
	unlock = 2,
	ability = 3,
	passive = 4,
	attribute = 5,
	mobility = 6,
}

DebugModMenuCatalog.CategoryLabels = {
	time = "Time Controls",
	unlock = "Ability Unlock",
	ability = "Ability Upgrade",
	passive = "Passive",
	attribute = "Attribute",
	mobility = "Mobility",
}

DebugModMenuCatalog.TimeOptions = {
	{ entryId = "time:60", name = "+1m", seconds = 60, category = "time" },
	{ entryId = "time:300", name = "+5m", seconds = 300, category = "time" },
	{ entryId = "time:600", name = "+10m", seconds = 600, category = "time" },
}

return DebugModMenuCatalog
