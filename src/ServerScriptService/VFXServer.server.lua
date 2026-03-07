--[[
	VFXServer — Animation Marker Data Builder & Dispatcher
	=======================================================

	HOW THIS SYSTEM WORKS
	---------------------
	This script reads a manually defined ANIMATION_REGISTRY at startup. For
	each entry, it resolves the Animation instance from a path string, extracts
	every KeyframeMarker from that animation, and packages the result into a
	flat data table. When a player's character spawns, that table is sent to
	the client once via VFXRemote. The client uses it to execute VFX locally
	whenever an ability fires.

	No executable code is ever sent. Only plain data (strings, numbers, tables).

	ADDING A NEW ANIMATION
	----------------------
	Add a new entry to ANIMATION_REGISTRY below. Each entry has one field:

	  path  — The full instance path from "game" to the Animation object,
	           with each level separated by a "." dot.
	           Example: "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Walk"

	The target instances for VFX are specified directly inside each marker name
	(see MARKER NAMING CONVENTION below) — no separate refs table is needed.

	WHAT THE SERVER SENDS
	---------------------
	VFXRemote fires to each client with a table of entries. Each entry is:

	  {
	    animationId = "rbxassetid://...",   -- the Animation.AnimationId string
	    markers     = {                      -- all KeyframeMarkers in the anim
	      -- Format: (path.to.Instance) _ Property _ Easing _ StartVal _ EndVal _ StartFrame-EndFrame
	      { name = "(RightFoot.BasicAttachments.DustEmitter)_Emit_Linear_20_20_0",           time = 0.25 },
	      { name = "(RightHand.IceAttachments.FireEmitter)_Enabled_Linear_1_1_0",            time = 0.10 }, -- enable instantly
      { name = "(RightHand.IceAttachments.FireEmitter)_Enabled_Linear_1_1_0-24",         time = 0.10 }, -- enable for ~0.4s then auto-disable
	      { name = "(TorsoVFX.IceRingMesh)_Transparency_QuadOut_1_0_0-24",                   time = 0.05 },
	      ...
	    },
	  }

	CONNECTING AN ABILITY
	---------------------
	To trigger VFX for an ability, fire AbilityFired from the relevant ability
	System.lua (server-side) with the animationId string:

	  AbilityFired:FireClient(player, animationId)

	The client will look up the stored data for that ID and play the animation
	with all its VFX markers automatically.

	MARKER NAMING CONVENTION
	------------------------
	All KeyframeMarkers must follow this format (path wrapped in parens, then 5 underscore-separated fields):

	  (path.to.Instance) _ Property _ Easing _ StartVal _ EndVal _ StartFrame-EndFrame

	  path          — character-relative dot path to the target instance.
	                  Wrapped in () so underscores inside instance names don't break parsing.
	                  Example: (RightHand.Ice_Emitter.ParticleEmitter)
	  Property      — "Emit", "Enabled", or any valid numeric Roblox property name
	  Easing        — easing style + direction combined:
	                    "Linear"    -> Linear (direction always Out)
	                    "QuadOut"   -> Quad, Out
	                    "ExpoIn"    -> Exponential, In
	                    "SineInOut" -> Sine, InOut
	  StartVal      — start value (unused by the executor; present for readability)
	  EndVal        — particle count for Emit | "1"/"0" for Enabled | number for tween
	  StartFrame-EndFrame — frame range from the animation timeline; duration = (end - start) / 60 s
	                        use "0" for instant Emit or Enabled with no auto-flip
	                        for Enabled with a duration: sets Enabled to EndVal, then flips it after the duration

	MARKER EXAMPLES
	---------------
	  -- Emit: burst N particles from a ParticleEmitter
	  (RightFoot.BasicAttachments.DustEmitter)_Emit_Linear_20_20_0

	  -- Enabled: turn a ParticleEmitter on or off (instance names with underscores work fine)
	  (RightHand.Ice_Emitter)_Enabled_Linear_1_1_0          -- enable instantly
	  (RightHand.Ice_Emitter)_Enabled_Linear_0_0_0          -- disable instantly
	  (RightHand.Ice_Emitter)_Enabled_Linear_1_1_0-24       -- enable for 24 frames (~0.4s), then auto-disable

	  -- Property tween: animate any numeric property on a mesh or part
	  (TorsoVFX.IceRingMesh)_Transparency_QuadOut_1_0_0-24    -- fade in  over frames 0→24 (~0.4s)
	  (UpperTorso.HandMesh)_Transparency_QuadOut_0_1_0-24     -- fade out over frames 0→24 (~0.4s)
	  (TorsoVFX.BubbleMesh)_Size_ExpoOut_0.01_150_0-39        -- grow Size over frames 0→39 (~0.65s)

	SUPPORTED EASING STYLES
	-----------------------
	Linear, Quad, Expo, Sine, Cubic, Quart, Quint, Bounce, Elastic, Back
	Unknown styles fall back to Linear with a warning.
]]

-- OPTIMISATION NOTE (two changes applied):
--   1. Registry is processed once at script load, not per player spawn.
--      builtData is populated before CharacterAdded can fire; dataReady
--      guards against the rare fast-spawn edge case.
--   2. All GetKeyframeSequenceAsync calls are launched in parallel via
--      task.spawn so 100 animations load in ~1x the slowest, not 100x.

local Players               = game:GetService("Players")
local ReplicatedStorage     = game:GetService("ReplicatedStorage")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

-- =============================================================================
-- ANIMATION REGISTRY — Edit this table to add/remove animations
-- =============================================================================
-- Each entry: { path = "game.path.to.Animation" }
-- Target instance paths are written directly inside each marker name — no refs needed.
local ANIMATION_REGISTRY = {
	{
		path = "ReplicatedStorage.ContentDrawer.PlayerAbilities.BasicAnimations.Walk",
	},
	{
		path = "ReplicatedStorage.ContentDrawer.PlayerAbilities.Ice.Ultimate.TempusGelidum.TempusGelidum",
	},
}

-- =============================================================================
-- REMOTE SETUP
-- =============================================================================

-- ensureRemote — creates a RemoteEvent under parent if one doesn't exist yet
local function ensureRemote(parent, name)
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	-- Remove stale instance of wrong type if present
	if existing then
		existing:Destroy()
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name   = name
	remote.Parent = parent
	return remote
end

local VFXRemote     = ensureRemote(ReplicatedStorage, "VFXRemote")
local _AbilityFired = ensureRemote(ReplicatedStorage, "AbilityFired")

-- Module-level cache populated once at startup by buildAllData()
local builtData = nil   -- the assembled entries table; nil until ready
local dataReady = false -- set to true when all parallel loads have finished

-- =============================================================================
-- HELPERS
-- =============================================================================

-- resolvePath — walks from game down to a named instance using "." delimited path
local function resolvePath(pathString)
	local current = game
	for _, segment in ipairs(string.split(pathString, ".")) do
		local child = current:FindFirstChild(segment)
		if not child then
			warn("[VFXServer] resolvePath: could not find '" .. segment .. "' in path: " .. pathString)
			return nil
		end
		current = child
	end
	return current
end

-- readMarkers — fetches the KeyframeSequence for an animationId and collects
-- every KeyframeMarker across all keyframes, returning { name, time } pairs
local function readMarkers(animationId)
	local markers = {}

	-- GetKeyframeSequenceAsync is a network call; wrap in pcall to handle failures
	local ok, seq = pcall(function()
		return KeyframeSequenceProvider:GetKeyframeSequenceAsync(animationId)
	end)
	if not ok or not seq then
		warn("[VFXServer] readMarkers: failed to fetch sequence for " .. tostring(animationId) .. " — " .. tostring(seq))
		return markers
	end

	-- Walk every Keyframe and collect its KeyframeMarker children
	for _, keyframe in ipairs(seq:GetKeyframes()) do
		for _, marker in ipairs(keyframe:GetMarkers()) do
			table.insert(markers, {
				name = marker.Name,
				time = keyframe.Time,
			})
		end
	end

	return markers
end

-- buildEntry — resolves one registry entry into sendable data
-- Returns { animationId, markers } or nil on failure
local function buildEntry(registryEntry)
	local animation = resolvePath(registryEntry.path)
	if not animation then
		warn("[VFXServer] buildEntry: skipping entry — could not resolve path: " .. tostring(registryEntry.path))
		return nil
	end
	if not animation:IsA("Animation") then
		warn("[VFXServer] buildEntry: resolved instance is not an Animation: " .. registryEntry.path)
		return nil
	end

	local animationId = animation.AnimationId
	if animationId == "" then
		warn("[VFXServer] buildEntry: Animation has empty AnimationId: " .. registryEntry.path)
		return nil
	end

	local markers = readMarkers(animationId)

	return {
		animationId = animationId,
		markers     = markers,
	}
end

-- =============================================================================
-- STARTUP: BUILD ALL ANIMATION DATA IN PARALLEL
-- =============================================================================

-- buildAllData — runs once at script load; fires all GetKeyframeSequenceAsync
-- calls concurrently via task.spawn and stores the assembled result in builtData
local function buildAllData()
	local total   = #ANIMATION_REGISTRY
	local pending = total
	local results = {}  -- [index] = built entry, or nil on failure

	if total == 0 then
		builtData = {}
		dataReady = true
		return
	end

	for i, registryEntry in ipairs(ANIMATION_REGISTRY) do
		task.spawn(function()
			local entry = buildEntry(registryEntry)  -- uses existing helper unchanged
			results[i]  = entry                      -- nil if buildEntry failed
			pending     -= 1
			if pending == 0 then
				-- All spawns finished; assemble in original registry order
				local allEntries = {}
				for j = 1, total do
					if results[j] then
						table.insert(allEntries, results[j])
					end
				end
				builtData = allEntries
				dataReady = true
				print(string.format("[VFXServer] Parallel load complete: %d/%d entries ready", #allEntries, total))
			end
		end)
	end
end

-- =============================================================================
-- PER-PLAYER SPAWN HANDLER
-- =============================================================================

-- onCharacterAdded — fires the already-built data to the new client instantly;
-- yields only in the rare case where a player spawns before startup load finishes
local function onCharacterAdded(player)
	task.spawn(function()
		while not dataReady do
			task.wait(0.05)
		end
		VFXRemote:FireClient(player, builtData)
		print(string.format("[VFXServer] Sent %d animation entries to %s", #builtData, player.Name))
	end)
end

-- =============================================================================
-- PLAYER LIFECYCLE HOOKS
-- =============================================================================

-- Kick off the one-time parallel animation load immediately at script start
buildAllData()

-- Wire up CharacterAdded for players who join after this script runs
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		onCharacterAdded(player)
	end)
	-- Handle character already loaded at time of connection
	if player.Character then
		onCharacterAdded(player)
	end
end)

-- Handle players already in-game when this script first runs
for _, player in ipairs(Players:GetPlayers()) do
	player.CharacterAdded:Connect(function()
		onCharacterAdded(player)
	end)
	if player.Character then
		onCharacterAdded(player)
	end
end
