--!strict
-- UpgradeIcons - per-upgrade icon mapping (asset ids or replicated asset paths)
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
	IceShard = "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Special.IceShard.IceShardDecal",
	Refractions = "87778366744205",

	-- Ability unlocks (optional, separate from ability upgrade icons)
	["unlock:MagicBolt"] = "137338447639770",
	["unlock:FireBall"] = "129036102914829",
	["unlock:IceShard"] = "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Special.IceShard.IceShardDecal",
	["unlock:Refractions"] = "87778366744205",

	-- Passive upgrades
	damage = "108126005649243",
	critChance = "117447607456881",
	critDamage = "74895737431797",
	projectileCount = "124099181412764",
	healthArmor = "108071713789743",
	vampiric = "72194263039152",
	abilitySize = "126546245240667",
	cooldownReduction = "71832146367825",
	abilityDuration = "113652545092588",
	penetration = "118848371871533",
	moveSpeed = "99817712946636",
	mobilityCooldown = "78598550205745",
	dashDistance = "73388896129650",
	luck = "82318061048285",
	expGain = "91526535217647",

	-- Mobility upgrades
	["mobility:Dash"] = "99817712946636",
	["mobility:GlacialPath"] = "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Utility.GlacialPath.GlacialPathDecal",
	["mobility:ShieldBash"] = "98379470571047",
	["mobility:DoubleJump"] = "118165830384003",
	["mobility:Blink"] = "103856385303705",
	["mobility:ManaGrapple"] = "135518071156835",
	["weapon:HeavyTrigger"] = "ReplicatedStorage.ContentDrawer.WeaponModels.HandCannons.Oathkeeper.HeavyTriggerDecal",
	["weapon:PowerSurge"] = "ReplicatedStorage.ContentDrawer.WeaponModels.HandCannons.Oathkeeper.PowerSurgeDecal",

	-- Attributes
	["attr:MagicBolt:ChainCasting"] = "",
	["attr:MagicBolt:FireAtWill"] = "",
	["attr:MagicBolt:Afterimages"] = "",
	["attr:FireBall:FireStorm"] = "",
	["attr:FireBall:TheBigOne"] = "",
	["attr:FireBall:CannonFire"] = "",
}

return UpgradeIcons
