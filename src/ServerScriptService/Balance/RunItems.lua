--!strict

local RunItems = {}

RunItems.Ids = {
	FuseBomb = "fuse_bomb",
	SilverNinjaStarOfTheBrilliantLight = "silver_ninja_star_of_the_brilliant_light",
}

RunItems.Order = {
	RunItems.Ids.FuseBomb,
	RunItems.Ids.SilverNinjaStarOfTheBrilliantLight,
}

RunItems.DefaultDropSettings = {
	requiresInteract = true,
	interactionRadius = 20,
	autoPickupRadius = 5.0,
	spinPeriod = 8.0,
	bobAmplitude = 0.2,
	noDespawn = true,
	forwardDistance = 5.0,
	groundLift = 1.25,
}

RunItems.Definitions = {
	[RunItems.Ids.FuseBomb] = {
		id = RunItems.Ids.FuseBomb,
		entryId = "item:" .. RunItems.Ids.FuseBomb,
		displayName = "Fuse Bomb",
		description = "Gain a 30% (+20% per stack) chance to drop a bomb upon taking damage. This bomb detonates after 2 seconds, dealing 1000% (+800% per stack) base damage, on a 15 (-35% per stack) second cooldown.",
		promptDescription = [[Gain a 30% <font color="#7A7A7A">(+20% per stack)</font> chance to drop a <font color="#F4A11A">bomb</font> upon <font color="#17E317">taking damage</font>. This bomb detonates after 2 seconds, dealing <font color="#F4A11A">1000%</font> <font color="#7A7A7A">(+800% per stack)</font> <font color="#F4A11A">base damage</font>, on a 15 <font color="#7A7A7A">(-35% per stack)</font> second cooldown.]],
		dropModelName = "Fuse Bomb",
		viewportFrameName = "FuseBombImageLabel",
		fuseBomb = {
			baseProcChance = 0.30,
			stackProcChance = 0.20,
			baseCooldown = 15.0,
			stackCooldownMultiplier = 0.65,
			detonationDelay = 2.0,
			baseDamageCoefficient = 10.0,
			stackDamageCoefficient = 8.0,
			explosionSize = Vector3.new(50, 50, 50),
			explosionRadius = 25.0,
		},
	},
	[RunItems.Ids.SilverNinjaStarOfTheBrilliantLight] = {
		id = RunItems.Ids.SilverNinjaStarOfTheBrilliantLight,
		entryId = "item:" .. RunItems.Ids.SilverNinjaStarOfTheBrilliantLight,
		displayName = "Silver Ninja Star of the Brilliant Light",
		description = "Attacks follow up with a tracking ninja star, dealing 450% (+350% per stack) base damage, with 3 (+2 per stack) charges, and a 15 second cooldown.",
		promptDescription = [[<font color="#F4A11A">Attacks</font> follow up with a tracking <font color="#F4A11A">ninja star</font>, dealing <font color="#F4A11A">450%</font> <font color="#7A7A7A">(+350% per stack)</font> <font color="#F4A11A">base damage</font>, with <font color="#4A86FF">3</font> <font color="#7A7A7A">(+2 per stack)</font> <font color="#4A86FF">charges</font>, and a 15 second cooldown.]],
		dropModelName = "Silver Ninja Star of the Brilliant Light",
		viewportFrameName = "SilverNinjaStaroftheBrilliantLightImageLabel",
		silverStar = {
			baseDamageCoefficient = 4.5,
			stackDamageCoefficient = 3.5,
			baseCharges = 3,
			chargesPerStack = 2,
			rechargeDuration = 15.0,
			projectileSpeed = 100.0,
			projectileLifetime = 4.0,
			hitboxSize = Vector3.new(5, 5, 5),
			hitboxRadius = 2.5,
			homing = {
				acquireRadius = 100.0,
				strengthDeg = 40.0,
				maxAngleDeg = 150.0,
				maxTurnDeg = 40.0,
				stayHorizontal = false,
				alwaysStayHorizontal = false,
			},
		},
	},
}

function RunItems.get(itemId: string)
	return RunItems.Definitions[itemId]
end

function RunItems.getOrderedDefinitions(): {any}
	local ordered = table.create(#RunItems.Order)
	for _, itemId in ipairs(RunItems.Order) do
		local def = RunItems.Definitions[itemId]
		if def then
			table.insert(ordered, def)
		end
	end
	return ordered
end

return RunItems
