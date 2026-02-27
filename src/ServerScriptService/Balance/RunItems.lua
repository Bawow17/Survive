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
	interactionRadius = 10,
	autoPickupRadius = 0.2,
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
		description = "Gain a 30% chance to drop a bomb upon taking damage. This bomb detonates after 2 seconds, dealing 1400% base damage, on a 15 (-35% per stack) second cooldown.",
		dropModelName = "Fuse Bomb",
		viewportFrameName = "FuseBombViewportFrame",
		fuseBomb = {
			baseProcChance = 0.30,
			baseCooldown = 15.0,
			stackCooldownMultiplier = 0.75,
			detonationDelay = 2.0,
			damageCoefficient = 14.0,
			explosionSize = Vector3.new(20, 20, 20),
			explosionRadius = 10.0,
		},
	},
	[RunItems.Ids.SilverNinjaStarOfTheBrilliantLight] = {
		id = RunItems.Ids.SilverNinjaStarOfTheBrilliantLight,
		entryId = "item:" .. RunItems.Ids.SilverNinjaStarOfTheBrilliantLight,
		displayName = "Silver Ninja Star of the Brilliant Light",
		description = "Attacks follow up with a tracking ninja star, dealing 450% (+350% per stack) base damage, with 3 (+2 per stack) charges, and a 15 second cooldown.",
		dropModelName = "Silver Ninja Star of the Brilliant Light",
		viewportFrameName = "SilverNinjaStaroftheBrilliantLightViewportFrame",
		silverStar = {
			baseDamageCoefficient = 4.5,
			stackDamageCoefficient = 3.5,
			baseCharges = 3,
			chargesPerStack = 2,
			rechargeDuration = 15.0,
			projectileSpeed = 100.0,
			projectileLifetime = 6.0,
			hitboxSize = Vector3.new(5, 5, 5),
			hitboxRadius = 2.5,
			homing = {
				acquireRadius = 240.0,
				strengthDeg = 200.0,
				maxAngleDeg = 150.0,
				maxTurnDeg = 200.0,
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
