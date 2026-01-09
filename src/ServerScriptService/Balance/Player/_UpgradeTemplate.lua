--!strict
--[[
	UPGRADE TEMPLATE & GUIDE
	========================
	
	This file demonstrates all upgrade value types and how to structure upgrades.
	
	VALUE TYPES:
	------------
	1. ABSOLUTE (number): Sets stat to exact value
	   Example: penetration = 5  →  Sets penetration to 5
	
	2. ADD PERCENTAGE ("+X%"): Multiplies base by (1 + X/100)
	   Example: damage = "+50%"  →  base × 1.5
	
	3. SUBTRACT PERCENTAGE ("-X%"): Multiplies base by (1 - X/100)
	   Example: cooldown = "-10%"  →  base × 0.9
	
	4. SET PERCENTAGE ("X%"): Multiplies base by (X/100)
	   Example: speed = "75%"  →  base × 0.75
	
	NOTES:
	------
	- Upgrades are CUMULATIVE: Each level stacks on previous levels
	- Only specify stats that CHANGE in each level
	- maxLevel is automatically determined by array length
	- desc should describe what the upgrade does
	- Name format: "[Ability/Passive] Lv[X]"
	
	EXAMPLE ABILITY UPGRADE:
	-----------------------
]]

local ExampleAbilityUpgrades = {
	{
		name = "Example Lv1",
		desc = "Reduce cooldown by 10%",
		cooldown = "-10%",  -- Relative: base × 0.9
	},
	{
		name = "Example Lv2",
		desc = "Increase projectile count by 1",
		projectileCount = "+1",  -- Can use "+1" or just 2 (absolute)
	},
	{
		name = "Example Lv3",
		desc = "Increase damage by 50%",
		damage = "+50%",  -- Relative: base × 1.5
	},
	{
		name = "Example Lv4",
		desc = "Set penetration to 5",
		penetration = 5,  -- Absolute: exactly 5
	},
	{
		name = "Example Lv5",
		desc = "Increase size by 20% and duration by 10%",
		scale = "+20%",  -- Multiple stats can change
		duration = "+10%",
	},
}

--[[
	EXAMPLE PASSIVE UPGRADE:
	-----------------------
]]

local ExamplePassiveUpgrades = {
	{
		name = "Example Passive Lv1",
		desc = "Increase attack by 10%",
		damageMultiplier = "+10%",  -- Will be stored in PassiveEffects component
	},
	{
		name = "Example Passive Lv2",
		desc = "Increase attack by 10%",
		damageMultiplier = "+10%",  -- Stacks: 1.1 × 1.1 = 1.21x
	},
}

return {
	ExampleAbility = ExampleAbilityUpgrades,
	ExamplePassive = ExamplePassiveUpgrades,
}

