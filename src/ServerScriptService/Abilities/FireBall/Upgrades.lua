--!strict
-- FireBall Ability Upgrades
-- 6 upgrade levels for the FireBall ability

return {
	{
		name = "Fireball Lv1",
		desc = "Unlock Fireball",
		-- Special: This level unlocks the ability
		unlock = true,
	},
	{
		name = "Fireball Lv2",
		desc = "Increase Fireball number by 1",
		projectileCount = "+1",
	},
	{
		name = "Fireball Lv3",
		desc = "Increase Fireball damage by 50%",
		damage = "+50%",
	},
	{
		name = "Fireball Lv4",
		desc = "Increase Fireball size by 10%",
		scale = "+10%",
	},
	{
		name = "Fireball Lv5",
		desc = "Increase Fireball number by 1",
		projectileCount = "+1",
	},
	{
		name = "Fireball Lv6",
		desc = "Increase Fireball damage by 50% and penetration by 1",
		damage = "+50%",
		penetration = "+1",
	},
}

