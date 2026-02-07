--!strict
-- UpgradeIcons - per-upgrade icon mapping (paste rbxassetid:// IDs here)
-- Keys are stable ids used by the upgrade system.
-- Supported keys:
--  Passive stats: statId (e.g. "damage", "cooldownReduction")
--  Ability upgrades: abilityId (e.g. "MagicBolt")
--  Ability unlocks: "unlock:<abilityId>" (e.g. "unlock:FireBall")
--  Attributes: "attr:<abilityId>:<attributeId>" (e.g. "attr:IceShard:frozen_petals")
--  Mobility: "mobility:<mobilityId>" (e.g. "mobility:ShieldBash")

local UpgradeIcons = {
	-- Example:
	-- damage = "rbxassetid://123456",
	-- cooldownReduction = "rbxassetid://123456",
	-- MagicBolt = "rbxassetid://123456",
	-- ["unlock:FireBall"] = "rbxassetid://123456",
	-- ["attr:IceShard:frozen_petals"] = "rbxassetid://123456",
	-- ["mobility:ShieldBash"] = "rbxassetid://123456",

	-- Ability upgrades (fill in as you add icons)
	MagicBolt = "137338447639770",
	FireBall = "129036102914829",
	IceShard = "101138111348070",
	Refractions = "87778366744205",

	-- Ability unlocks (optional, separate from ability upgrade icons)
	["unlock:MagicBolt"] = "137338447639770",
	["unlock:FireBall"] = "129036102914829",
	["unlock:IceShard"] = "101138111348070",
	["unlock:Refractions"] = "87778366744205",

	-- Passive upgrades
	damage = "",
	critChance = "117447607456881",
	critDamage = "74895737431797",
	projectileCount = "124099181412764",
	healthArmor = "108071713789743",
	vampiric = "72194263039152",
	abilitySize = "126546245240667",
	cooldownReduction = "72605923567526",
	abilityDuration = "113652545092588",
	penetration = "",
	moveSpeed = "",
	mobilityCooldown = "",
	dashDistance = "",
	luck = "82318061048285",
	expGain = "113673838028786",

	-- Mobility upgrades
	["mobility:Dash"] = "",
	["mobility:ShieldBash"] = "",
	["mobility:DoubleJump"] = "",

	-- Attributes
	["attr:MagicBolt:ChainCasting"] = "",
	["attr:MagicBolt:FireAtWill"] = "",
	["attr:MagicBolt:Afterimages"] = "",
	["attr:FireBall:FireStorm"] = "",
	["attr:FireBall:TheBigOne"] = "",
	["attr:FireBall:CannonFire"] = "",
	["attr:IceShard:FrozenPetals"] = "",
	["attr:IceShard:ImpalingFrost"] = "",
	["attr:IceShard:CrystalShards"] = "",
}

return UpgradeIcons
