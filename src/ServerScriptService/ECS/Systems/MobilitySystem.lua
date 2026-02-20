--!strict
-- MobilitySystem - Server-side validation for mobility abilities (Dash, Double Jump)
-- Validates cooldowns and applies server-side effects (invincibility)
-- Movement is client-predicted for responsiveness

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local GameTimeSystem = require(script.Parent.GameTimeSystem)
local PauseSystem = require(script.Parent.PauseSystem)
local GameOptions = require(game.ServerScriptService.Balance.GameOptions)
local DEBUG = GameOptions.Debug and GameOptions.Debug.Enabled
local StatusEffectSystem = require(script.Parent.StatusEffectSystem)
local SpatialGridSystem = require(script.Parent.SpatialGridSystem)
local DamageSystem = require(script.Parent.DamageSystem)
local OverhealSystem = require(script.Parent.OverhealSystem)
local ModelHitboxHelper = require(game.ServerScriptService.Utilities.ModelHitboxHelper)

-- Mobility configs
local DashConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.Dash)
local IceTracerConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.IceTracer)
local ShieldBashConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.ShieldBash)
local DoubleJumpConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.DoubleJump)
local BlinkConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.Blink)
local ManaGrappleConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.ManaGrapple)

local MobilitySystem = {}

local world: any
local Components: any
local DirtyService: any

-- Component references
local PlayerStats: any
local MobilityData: any
local MobilityCooldown: any
local PassiveEffects: any

-- Remote events
local MobilityActivateRemote: RemoteEvent
local AbilityCastRemote: RemoteEvent
local DashAfterimageRemote: RemoteEvent
local IceTracerPathReplicateRemote: RemoteEvent

-- Active Shield Bash dashes (server-side collision tracking)
local activeShieldBashes: {{
	playerEntity: number,
	player: Player,
	startTime: number,
	endTime: number,
	duration: number,
	damage: number,
	knockbackDistance: number,
	invincibilityPerHit: number,
	overshieldPerHit: number,
	hitboxSize: Vector3,
	startPosition: Vector3,
	direction: Vector3,
	distance: number,
	lastPosition: Vector3,
	hitEnemies: {[number]: boolean},
}} = {}

-- Active afterimage tasks (for cleanup)
local activeAfterimageTasks: {thread} = {}
local activeIceTracerReplication: {[number]: {
	playerEntity: number,
	expiresAt: number,
	castId: number?,
	totalSegments: number,
}} = {}

local ICE_TRACER_ALLOWED_BUFFER = 0.5
local ICE_TRACER_MAX_SEGMENTS_PER_PACKET = 48
local ICE_TRACER_MAX_SEGMENTS_PER_CAST = 720

-- Mobility config lookup
local MOBILITY_CONFIGS = {
	Dash = DashConfig,
	IceTracer = IceTracerConfig,
	ShieldBash = ShieldBashConfig,
	DoubleJump = DoubleJumpConfig,
	Blink = BlinkConfig,
	ManaGrapple = ManaGrappleConfig,
}

-- Mobility display names for UI
local MOBILITY_DISPLAY_NAMES = {
	Dash = "Dash",
	IceTracer = "Ice Tracer",
	ShieldBash = "Shield Bash",
	DoubleJump = "Double Jump",
	Blink = "Blink",
	ManaGrapple = "Mana Grapple",
}

-- Get player entity from Player instance
local function getPlayerEntity(player: Player): number?
	if not world or not PlayerStats then
		return nil
	end
	
	for entity, stats in world:query(PlayerStats) do
		if stats.player == player then
			return entity
		end
	end
	return nil
end

local function pruneExpiredIceTracerWindows(now: number)
	for userId, state in pairs(activeIceTracerReplication) do
		if now > state.expiresAt then
			activeIceTracerReplication[userId] = nil
		end
	end
end

local function beginIceTracerReplicationWindow(player: Player, playerEntity: number, now: number, duration: number)
	local safeDuration = math.max(0.05, duration)
	activeIceTracerReplication[player.UserId] = {
		playerEntity = playerEntity,
		expiresAt = now + safeDuration + ICE_TRACER_ALLOWED_BUFFER,
		castId = nil,
		totalSegments = 0,
	}
end

local function validateIceTracerSegment(rawSegment: any): (boolean, any?)
	if typeof(rawSegment) ~= "table" then
		return false, nil
	end
	if typeof(rawSegment.position) ~= "Vector3" then
		return false, nil
	end
	if typeof(rawSegment.forward) ~= "Vector3" then
		return false, nil
	end
	if rawSegment.forward.Magnitude < 1e-4 then
		return false, nil
	end
	if typeof(rawSegment.yawDeg) ~= "number" then
		return false, nil
	end

	return true, {
		position = rawSegment.position,
		forward = rawSegment.forward.Unit,
		yawDeg = rawSegment.yawDeg,
	}
end

local function handleIceTracerPathReplication(player: Player, payload: any)
	if not IceTracerPathReplicateRemote then
		return
	end
	if typeof(payload) ~= "table" then
		return
	end

	local now = GameTimeSystem.getGameTime()
	pruneExpiredIceTracerWindows(now)

	local state = activeIceTracerReplication[player.UserId]
	if not state then
		return
	end
	if now > state.expiresAt then
		activeIceTracerReplication[player.UserId] = nil
		return
	end

	local castId = payload.castId
	if typeof(castId) ~= "number" then
		return
	end
	castId = math.floor(castId + 0.5)
	if castId < 0 then
		return
	end

	local isFinal = payload.isFinal == true
	local rawSegments = payload.segments
	if typeof(rawSegments) ~= "table" then
		if isFinal then
			rawSegments = {}
		else
			return
		end
	end

	if state.castId == nil then
		state.castId = castId
	elseif state.castId ~= castId then
		return
	end

	local segmentCount = #rawSegments
	if segmentCount > ICE_TRACER_MAX_SEGMENTS_PER_PACKET then
		return
	end

	state.totalSegments += segmentCount
	if state.totalSegments > ICE_TRACER_MAX_SEGMENTS_PER_CAST then
		activeIceTracerReplication[player.UserId] = nil
		return
	end

	local playerEntity = getPlayerEntity(player)
	if not playerEntity or playerEntity ~= state.playerEntity then
		return
	end
	local mobilityData = world and MobilityData and world:get(playerEntity, MobilityData)
	if not mobilityData or mobilityData.equippedMobility ~= "IceTracer" then
		return
	end

	local sanitizedSegments = table.create(segmentCount)
	for _, rawSegment in ipairs(rawSegments) do
		local ok, sanitized = validateIceTracerSegment(rawSegment)
		if ok and sanitized then
			table.insert(sanitizedSegments, sanitized)
		end
	end

	if #sanitizedSegments == 0 and not isFinal then
		return
	end

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= player then
			IceTracerPathReplicateRemote:FireClient(otherPlayer, player, castId, sanitizedSegments, isFinal)
		end
	end

	if isFinal then
		activeIceTracerReplication[player.UserId] = nil
	end
end

-- Validate and handle mobility activation
local function handleMobilityActivation(player: Player, mobilityId: string, variant: string?)
	-- Get player entity
	local playerEntity = getPlayerEntity(player)
	if not playerEntity then
		return
	end
	
	-- Reject mobility activation while player is paused
	if PauseSystem and PauseSystem.isPlayerPaused(playerEntity) then
		if DEBUG then
			print(string.format("[MobilitySystem] Reject mobility during pause | player=%s mobility=%s", player.Name, tostring(mobilityId)))
		end
		return
	end
	
	-- Validate mobility ID
	local config = MOBILITY_CONFIGS[mobilityId]
	if not config then
		return
	end
	
	-- Check if player has this mobility equipped
	local mobilityData = world:get(playerEntity, MobilityData)
	if not mobilityData or mobilityData.equippedMobility ~= mobilityId then
		return
	end
	
	-- Get cooldown component
	local mobilityCooldown = world:get(playerEntity, MobilityCooldown)
	if not mobilityCooldown then
		-- Initialize if missing
		mobilityCooldown = { lastUsedTime = 0 }
		DirtyService.setIfChanged(world, playerEntity, MobilityCooldown, mobilityCooldown, "MobilityCooldown")
	end
	
	-- Check cooldown
	local currentTime = GameTimeSystem.getGameTime()
	local timeSinceLastUse = currentTime - mobilityCooldown.lastUsedTime
	
	-- Apply cooldown multiplier from passive effects
	local effectiveCooldown = config.cooldown
	if mobilityId == "Blink" then
		local groundCooldown = mobilityData.groundCooldown or config.groundCooldown or config.cooldown
		local airCooldown = mobilityData.airCooldown or config.airCooldown or config.cooldown
		if variant == "air" then
			effectiveCooldown = airCooldown
		else
			effectiveCooldown = groundCooldown
		end
	elseif mobilityId == "ManaGrapple" then
		effectiveCooldown = mobilityData.grappleCooldown or config.grappleCooldown or config.cooldown
	end
	local passiveEffects = world:get(playerEntity, PassiveEffects)
	if passiveEffects then
		local mobilityCooldownMult = passiveEffects.mobilityCooldownMultiplier or passiveEffects.cooldownMultiplier
		if mobilityCooldownMult then
			effectiveCooldown = effectiveCooldown * mobilityCooldownMult
		end
	end
	
	-- Grace period: Allow activation if within 1 second of cooldown finishing
	-- This prevents client-predicted movement from happening without server effects
	local COOLDOWN_GRACE_PERIOD = 1.0
	local cooldownDifference = effectiveCooldown - timeSinceLastUse
	
	if cooldownDifference > COOLDOWN_GRACE_PERIOD then
		-- Still on cooldown (more than 1 second early)
		return
	end
	
	-- Validate activation conditions (server-side validation)
	local character = player.Character
	if not character then
		return
	end
	
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	
	-- Double Jump airborne check: Done client-side only (server check would fail due to network delay)
	-- Client validates airborne before sending activation - trust the client for this check
	
	-- Validation passed - apply cooldown
	mobilityCooldown.lastUsedTime = currentTime
	mobilityCooldown.lastUsedCooldown = effectiveCooldown
	DirtyService.setIfChanged(world, playerEntity, MobilityCooldown, mobilityCooldown, "MobilityCooldown")
	
	-- Notify client for cooldown UI display
	local displayName = MOBILITY_DISPLAY_NAMES[mobilityId] or mobilityId
	if AbilityCastRemote then
		AbilityCastRemote:FireClient(player, "Mobility_" .. mobilityId, effectiveCooldown, displayName)
	end

	if mobilityId == "IceTracer" then
		local castDuration = mobilityData.duration or config.duration or (35 / 60)
		beginIceTracerReplicationWindow(player, playerEntity, currentTime, castDuration)
	end
	
	-- Apply server-side effects
	if mobilityId == "ShieldBash" then
		-- Get hitbox size from the shield model using shared helper
		local hitboxSize = Vector3.new(6, 6, 6)  -- Default fallback
		
		if mobilityData.shieldModelPath then
			local size, _offset = ModelHitboxHelper.getModelHitboxData(mobilityData.shieldModelPath)
			if size then
				hitboxSize = size
				print(string.format("[ShieldBash] Using Hitbox part size from model: (%.1f, %.1f, %.1f)", 
					hitboxSize.X, hitboxSize.Y, hitboxSize.Z))
			else
				warn(string.format("[ShieldBash] Could not find Hitbox part in model: %s, using default size", mobilityData.shieldModelPath))
			end
		else
			warn("[ShieldBash] No shieldModelPath in config, using default hitbox size")
		end
		
		-- Determine dash direction + predicted path (instant response, no wall checks)
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then
			return
		end

		local dashDirection = rootPart.CFrame.LookVector
		dashDirection = Vector3.new(dashDirection.X, 0, dashDirection.Z)
		if dashDirection.Magnitude < 0.1 then
			dashDirection = Vector3.new(0, 0, 1)
		else
			dashDirection = dashDirection.Unit
		end

		local passiveEffects = world:get(playerEntity, PassiveEffects)
		local distanceMultiplier = 1.0
		if passiveEffects and typeof(passiveEffects.mobilityDistanceMultiplier) == "number" then
			distanceMultiplier = passiveEffects.mobilityDistanceMultiplier
		end
		local dashDistance = (mobilityData.distance or config.distance or 25) * distanceMultiplier
		local dashDuration = mobilityData.duration or config.duration or 0.2
		local startPosition = rootPart.Position

		-- Start server-side collision tracking for Shield Bash
		local bashData = {
			playerEntity = playerEntity,
			player = player,
			startTime = currentTime,
			endTime = currentTime + dashDuration,
			duration = dashDuration,
			damage = mobilityData.damage or 50,
			knockbackDistance = mobilityData.knockbackDistance or 20,
			invincibilityPerHit = mobilityData.invincibilityPerHit or 0.05,
			overshieldPerHit = mobilityData.overshieldPerHit or 0.05,
			hitboxSize = hitboxSize,
			startPosition = startPosition,
			direction = dashDirection,
			distance = dashDistance,
			lastPosition = startPosition,
			hitEnemies = {},
		}
		table.insert(activeShieldBashes, bashData)

		print(string.format("[ShieldBash] Activated: duration=%.2fs, distance=%.1f, hitbox=(%.1f,%.1f,%.1f)", 
			bashData.duration, bashData.distance, hitboxSize.X, hitboxSize.Y, hitboxSize.Z))
	elseif mobilityId == "DoubleJump" then
		-- Grant HP heal on Double Jump use
		-- ONLY applies overheal when player is already at full HP
		local health = world:get(playerEntity, Components.Health)
		if health then
			local healPercent = config.healAmount or 0.15  -- Default to 15%
			local healAmount = health.max * healPercent
			
			-- Check if player is already at full HP
			if health.current >= health.max then
				-- Player is full HP - ALL healing becomes overheal
				OverhealSystem.grantOverheal(playerEntity, healAmount)
			else
				-- Player is not full HP - heal normally (no overheal for excess)
				local newHealth = math.min(health.current + healAmount, health.max)
				
				-- Update health
				DirtyService.setIfChanged(world, playerEntity, Components.Health, {
					current = newHealth,
					max = health.max,
				}, "Health")
				
				-- Also update Roblox humanoid health
				local playerStats = world:get(playerEntity, Components.PlayerStats)
				if playerStats and playerStats.player then
					local player = playerStats.player
					if player.Character then
						local humanoid = player.Character:FindFirstChild("Humanoid")
						if humanoid then
							humanoid.Health = newHealth
						end
					end
				end
			end
		end
	end
	-- Basic Dash has no server-side effects
	
	-- Spawn afterimages for Dash and ShieldBash
	if mobilityId == "Dash" or mobilityId == "ShieldBash" then
		local afterimageInterval = config.afterimageInterval or 0.03
		local afterimageDuration = config.afterimageDuration or 0.2
		local dashDuration = config.duration or 0.5
		local afterimageSpawnDuration = dashDuration - 0.38  -- Stop spawning 0.38s before dash ends
		
		-- Spawn afterimages on interval for the dash duration (minus 0.38s)
		local afterimageTask = task.spawn(function()
			local startTime = tick()
			local character = player.Character
			
			if not character or not character.PrimaryPart then
				return
			end
			
			-- Wait one interval before starting (give time for dash animation to begin)
			task.wait(afterimageInterval)
			
			-- Spawn afterimages on interval
			while true do
				local elapsed = tick() - startTime
				
				-- Check if afterimage spawn duration has elapsed (0.31s before dash ends)
				if elapsed >= afterimageSpawnDuration then
					break
				end
				
				-- Check if character still exists
				if not character or not character.Parent or not character.PrimaryPart then
					break
				end
				
				-- Fire to all clients to render afterimage
				-- Position and pose are copied from the character model directly on the client
				if DashAfterimageRemote then
					DashAfterimageRemote:FireAllClients(
						character,
						mobilityId,
						afterimageDuration,
						nil  -- transparency not used, model's original transparency is preserved
					)
				end
				
				-- Wait for next interval
				task.wait(afterimageInterval)
			end
		end)
		
		-- Track task for cleanup
		table.insert(activeAfterimageTasks, afterimageTask)
	end
	
	-- Movement is handled by client (client-predicted)
	-- Server validates but does not force position correction
end

local function isShieldBashing(playerEntity: number, now: number): boolean
	for _, bashData in ipairs(activeShieldBashes) do
		if bashData.playerEntity == playerEntity and now < bashData.endTime then
			return true
		end
	end
	return false
end

-- Process active Shield Bash collisions (server-side, like projectiles)
local function processShieldBashCollisions(dt: number)
	local currentTime = GameTimeSystem.getGameTime()
	local toRemove = {}

	local function applyShieldBashHits(bashData: any, centerPos: Vector3)
		local lookDir = bashData.direction
		if lookDir.Magnitude < 0.1 then
			lookDir = Vector3.new(0, 0, 1)
		end
		local hitboxOffset = bashData.hitboxSize.Z / 2
		local hitboxPos = centerPos + (lookDir * hitboxOffset)
		local hitboxCFrame = CFrame.new(hitboxPos, hitboxPos + lookDir)

		local GRID_SIZE = SpatialGridSystem.getGridSize()
		local maxDimension = math.max(bashData.hitboxSize.X, bashData.hitboxSize.Y, bashData.hitboxSize.Z)
		local searchRadius = math.ceil(maxDimension / GRID_SIZE)
		local nearbyEntities = SpatialGridSystem.getNeighboringEntities(hitboxPos, searchRadius)
		if #nearbyEntities == 0 then
			nearbyEntities = SpatialGridSystem.getNeighboringEntities(hitboxPos, searchRadius + 1)
		end

		local halfSize = bashData.hitboxSize / 2
		local hitsThisCycle = 0

		for _, targetEntity in ipairs(nearbyEntities) do
			local targetType = world:get(targetEntity, Components.EntityType)
			if targetType and targetType.type == "Enemy" and not bashData.hitEnemies[targetEntity] then
				local enemyPos = world:get(targetEntity, Components.Position)
				if enemyPos then
					local enemyWorldPos = Vector3.new(enemyPos.x, enemyPos.y, enemyPos.z)
					local localPos = hitboxCFrame:PointToObjectSpace(enemyWorldPos)

					if math.abs(localPos.X) <= halfSize.X
						and math.abs(localPos.Y) <= halfSize.Y
						and math.abs(localPos.Z) <= halfSize.Z then
						local enemyHealth = world:get(targetEntity, Components.Health)
						if enemyHealth and enemyHealth.current > 0 then
							DamageSystem.applyDamage(targetEntity, bashData.damage, "physical", bashData.playerEntity, "ShieldBash")
							hitsThisCycle += 1

							local enemyData = world:get(targetEntity, Components.EnemyData)
							if enemyData and enemyData.model then
								local enemyRootPart = enemyData.model.PrimaryPart or enemyData.model:FindFirstChild("HumanoidRootPart")
								if enemyRootPart then
									local knockbackDirection = (enemyRootPart.Position - centerPos)
									knockbackDirection = Vector3.new(knockbackDirection.X, 0, knockbackDirection.Z)
									if knockbackDirection.Magnitude > 0.1 then
										knockbackDirection = knockbackDirection.Unit
										knockbackDirection = Vector3.new(knockbackDirection.X, 0.3, knockbackDirection.Z).Unit
										local knockbackVelocity = knockbackDirection * bashData.knockbackDistance * 10
										enemyRootPart.AssemblyLinearVelocity = knockbackVelocity
									end
								end
							end

							bashData.hitEnemies[targetEntity] = true
						end
					end
				end
			end
		end

		if hitsThisCycle > 0 then
			local invincibilityToAdd = hitsThisCycle * bashData.invincibilityPerHit
			local statusEffects = world:get(bashData.playerEntity, Components.StatusEffects)
			local currentRemaining = 0
			if statusEffects and statusEffects.invincible then
				local currentEndTime = statusEffects.invincible.endTime
				local now = GameTimeSystem.getGameTime()
				currentRemaining = math.max(0, currentEndTime - now)
			end
			local totalDuration = currentRemaining + invincibilityToAdd
			StatusEffectSystem.grantInvincibility(bashData.playerEntity, totalDuration, false, false, false)

			local health = world:get(bashData.playerEntity, Components.Health)
			if health and bashData.overshieldPerHit > 0 then
				local overshieldAmount = health.max * bashData.overshieldPerHit * hitsThisCycle
				OverhealSystem.grantOverheal(bashData.playerEntity, overshieldAmount)
			end
		end
	end
	
	for i, bashData in ipairs(activeShieldBashes) do
		local elapsed = currentTime - bashData.startTime
		
		-- Check if Shield Bash duration expired
		if elapsed >= bashData.duration then
			table.insert(toRemove, i)
		else
			local t = math.clamp(elapsed / bashData.duration, 0, 1)
			local currentPos = bashData.startPosition + (bashData.direction * (bashData.distance * t))
			local lastPos = bashData.lastPosition
			local segment = currentPos - lastPos
			local samples = {lastPos}
			if segment.Magnitude > (bashData.hitboxSize.Z * 0.5) then
				table.insert(samples, lastPos + segment * 0.5)
			end
			table.insert(samples, currentPos)
			
			for _, samplePos in ipairs(samples) do
				applyShieldBashHits(bashData, samplePos)
			end
			
			bashData.lastPosition = currentPos
		end
	end
	
	-- Remove expired Shield Bashes
	for i = #toRemove, 1, -1 do
		table.remove(activeShieldBashes, toRemove[i])
	end
end

-- Public function to check if a player is currently Shield Bashing and absorb damage
function MobilitySystem.absorbShieldBashDamage(playerEntity: number, damageAmount: number): boolean
	local now = GameTimeSystem.getGameTime()
	if isShieldBashing(playerEntity, now) then
		return true
	end
	return false
end

function MobilitySystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	PlayerStats = Components.PlayerStats
	MobilityData = Components.MobilityData
	MobilityCooldown = Components.MobilityCooldown
	PassiveEffects = Components.PassiveEffects
	
	-- Create or get RemoteEvents
	local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
	
	MobilityActivateRemote = remotes:FindFirstChild("MobilityActivate")
	if not MobilityActivateRemote then
		MobilityActivateRemote = Instance.new("RemoteEvent")
		MobilityActivateRemote.Name = "MobilityActivate"
		MobilityActivateRemote.Parent = remotes
	end
	
	-- Get AbilityCast remote for cooldown UI
	AbilityCastRemote = remotes:FindFirstChild("AbilityCast")
	if not AbilityCastRemote then
		warn("[MobilitySystem] AbilityCast remote not found - cooldown UI may not work")
	end
	
	-- Get DashAfterimage remote for visual effects
	DashAfterimageRemote = remotes:FindFirstChild("DashAfterimage")
	if not DashAfterimageRemote then
		warn("[MobilitySystem] DashAfterimage remote not found - afterimage effects may not work")
	end

	IceTracerPathReplicateRemote = remotes:FindFirstChild("IceTracerPathReplicate")
	if not IceTracerPathReplicateRemote then
		IceTracerPathReplicateRemote = Instance.new("RemoteEvent")
		IceTracerPathReplicateRemote.Name = "IceTracerPathReplicate"
		IceTracerPathReplicateRemote.Parent = remotes
	end
	
	-- Handle client activation requests
	MobilityActivateRemote.OnServerEvent:Connect(function(player: Player, mobilityId: string, variant: string?)
		handleMobilityActivation(player, mobilityId, variant)
	end)
	IceTracerPathReplicateRemote.OnServerEvent:Connect(function(player: Player, payload: any)
		handleIceTracerPathReplication(player, payload)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		activeIceTracerReplication[player.UserId] = nil
	end)
end

function MobilitySystem.step(dt: number)
	if not world then
		return
	end
	
	-- Process active Shield Bash collisions (server-side hitbox tracking)
	if #activeShieldBashes > 0 then
		processShieldBashCollisions(dt)
	end
	pruneExpiredIceTracerWindows(GameTimeSystem.getGameTime())
end

return MobilitySystem

