--!strict
-- Dash Mobility Ability Configuration
-- Basic starter dash - movement only, no combat abilities

return {
	id = "Dash",
	displayName = "Dash",
	description = "Quick horizontal dash",
	
	-- Movement
	distance = 125,  -- studs (affected by Haste passive)
	duration = 0.57,  -- seconds for dash movement
	
	-- Timing
	cooldown = 3.5,  -- seconds (affected by Fast Casting)
	
	-- Visual
	afterimageCount = 6,  -- number of copies left behind
	afterimageDuration = 0.2,  -- how long each afterimage lasts (fade duration)
	afterimageInterval = 0.021,  -- spawn interval in seconds
	afterimageModelPath = "ReplicatedStorage.ContentDrawer.PlayerAbilities.MobilityAbilities.Dash.Afterimage",
	
	-- Model path (optional - Dash uses character afterimages, no model needed)
	modelPath = nil,
	
	-- Unlock
	category = "mobility",
}

    