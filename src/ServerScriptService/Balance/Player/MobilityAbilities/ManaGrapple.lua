--!strict
-- Mana Grapple Mobility Ability Configuration
-- Launches player forward and upward with a rope/chain VFX

return {
	id = "ManaGrapple",
	displayName = "Mana Grapple",
	description = "Launch forward and upward with a mana tether. Hold Q to swing; release to drop.",
	
	-- UI color (shown in upgrade selection)
	color = Color3.fromRGB(90, 200, 255),
	
	-- Travel tuning
	grappleHorizontalDistance = 100,  -- studs
	grappleVerticalHeight = 50,  -- studs (peak height)
	grappleCooldown = 10.0,  -- seconds
	
	-- Mana point VFX placement (relative to player at activation)
	grappleManaForward = 30,  -- studs in front
	grappleManaUp = 20,  -- studs upward
	
	-- Damping (slow near end of swing)
	grappleDampStartFrac = 0.6,
	grappleDampStrength = 2.0,

	-- VFX models (ServerStorage paths; replicated to ReplicatedStorage)
	grappleStartModelPath = "ContentDrawer.PlayerAbilities.MobilityAbilities.Grapple.Grapple.Start",
	grappleManaPointModelPath = "ContentDrawer.PlayerAbilities.MobilityAbilities.Grapple.Grapple.ManaPoint",
	grappleEndModelPath = "ContentDrawer.PlayerAbilities.MobilityAbilities.Grapple.Grapple.End",
	grappleBeamModelPath = "ContentDrawer.PlayerAbilities.MobilityAbilities.Grapple.Grapple.Beam",
	
	-- Unlock
	minLevel = 15,
	category = "mobility",
}
