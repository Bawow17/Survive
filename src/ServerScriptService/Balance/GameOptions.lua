--!strict
-- GameOptions - Global game mode configuration

return {
	-- Pause System
	GlobalPause = false,  -- false = per-player pause (multiplayer), true = global pause (singleplayer)
	
	-- Per-Player Pause Settings (only applies when GlobalPause = false)
	IndividualPauseTimeout = 30,  -- Seconds before auto-selecting random upgrade
	
	-- Enemy behavior during individual pause
	EnemyPauseTransition = {
		FreezeDuration = 3.0,  -- Freeze enemies for 3 seconds (then restore + retarget)
	},
	
	-- Debug toggles (extra logs/asserts should be gated here)
	Debug = {
		Enabled = false,
	},

}
