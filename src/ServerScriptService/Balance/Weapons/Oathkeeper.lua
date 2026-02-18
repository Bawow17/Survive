--!strict

return {
	id = "Oathkeeper",
	damage = 38,
	range = 1500,
	baseCooldown = 0.33,
	activeWalkWindow = 2.5,
	tracerLifetime = 0.6,
	tracerFadeDuration = 0.5,
	showPrimaryCooldown = false,
	primaryIconKey = "weapon:Oathkeeper",
	usesCooldownMultiplier = true,
	usesDamageMultiplier = true,
	assetPaths = {
		weaponFolder = "ContentDrawer.WeaponModels.HandCannons.Oathkeeper",
		model = "OathkeeperModel",
		gripC0 = "GripC0",
		gripC1 = "GripC1",
		animations = {
			idle = "Animations.HandCannonIdle",
			walk = "Animations.HandCannonWalk",
			m1 = "Animations.HandCannonM1",
		},
		muzzlePart = "Barrel.BarrelEnd",
		muzzleFlash = "OathkeeperModel.Barrel.BarrelEnd.MuzzleFlash",
		tracer = "VFX.Tracer",
		endpoint = "VFX.Endpoint",
		hitEffect = "VFX.Endpoint.HitEnd.HitEffect",
	},
}
