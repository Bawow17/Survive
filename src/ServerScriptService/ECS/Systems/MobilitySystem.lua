--!strict
-- MobilitySystem - Server-side validation for mobility abilities (Dash, Double Jump)
-- Validates cooldowns and applies server-side effects (invincibility)
-- Movement is client-predicted for responsiveness

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local GameTimeSystem = require(script.Parent.GameTimeSystem)
local StatusEffectSystem = require(script.Parent.StatusEffectSystem)
local SpatialGridSystem = require(script.Parent.SpatialGridSystem)
local DamageSystem = require(script.Parent.DamageSystem)
local OverhealSystem = require(script.Parent.OverhealSystem)
local ModelHitboxHelper = require(game.ServerScriptService.Utilities.ModelHitboxHelper)

-- Mobility configs
local DashConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.Dash)
local ShieldBashConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.ShieldBash)
local DoubleJumpConfig = require(game.ServerScriptService.Balance.Player.MobilityAbilities.DoubleJump)

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

-- Active Shield Bash dashes (server-side collision tracking)
local activeShieldBashes: {{
	playerEntity: number,
	player: Player,
	startTime: number,
	duration: number,
	damage: number,
	knockbackDistance: number,
	invincibilityPerHit: number,
	overshieldPerHit: number,  -- NEW
	hitboxRadius: number,
	hitEnemies: {[number]: boolean},
}} = {}

-- Active afterimage tasks (for cleanup)
local activeAfterimageTasks: {thread} = {}

-- Mobility config lookup
local MOBILITY_CONFIGS = {
	Dash = DashConfig,
	ShieldBash = ShieldBashConfig,
	DoubleJump = DoubleJumpConfig,
}

-- Mobility display names for UI
local MOBILITY_DISPLAY_NAMES = {
	Dash = "Dash",
	ShieldBash = "Shield Bash",
	DoubleJump = "Double Jump",
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

-- Validate and handle mobility activation
local function handleMobilityActivation(player: Player, mobilityId: string)
	-- Get player entity
	local playerEntity = getPlayerEntity(player)
	if not playerEntity then
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
	local passiveEffects = world:get(playerEntity, PassiveEffects)
	if passiveEffects and passiveEffects.cooldownMultiplier then
		effectiveCooldown = effectiveCooldown * passiveEffects.cooldownMultiplier
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
	DirtyService.setIfChanged(world, playerEntity, MobilityCooldown, mobilityCooldown, "MobilityCooldown")
	
	-- Notify client for cooldown UI display
	local displayName = MOBILITY_DISPLAY_NAMES[mobilityId] or mobilityId
	if AbilityCastRemote then
		AbilityCastRemote:FireClient(player, "Mobility_" .. mobilityId, effectiveCooldown, displayName)
	end
	
	-- Apply server-side effects
	if mobilityId == "ShieldBash" then
		-- Grant pre-dash invincibility for lag protection
		local preDashInvuln = mobilityData.preDashInvincibility or config.preDashInvincibility or 0
		if preDashInvuln > 0 then
			StatusEffectSystem.grantInvincibility(playerEntity, preDashInvuln, false, false, false)
			print(string.format("[ShieldBash] PRE-DASH INVINCIBILITY: %.2fs granted", preDashInvuln))
		else
			warn("[ShieldBash] WARNING: No pre-dash invincibility configured!")
		end
		
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
		
		-- Start server-side collision tracking for Shield Bash
		local bashData = {
			playerEntity = playerEntity,
			player = player,
			startTime = currentTime,
			duration = config.duration or 0.2,
			damage = mobilityData.damage or 50,
			knockbackDistance = mobilityData.knockbackDistance or 20,
			invincibilityPerHit = mobilityData.invincibilityPerHit or 0.05,
			overshieldPerHit = mobilityData.overshieldPerHit or 0.05,  -- NEW
			hitboxSize = hitboxSize,  -- Store the size vector
			hitEnemies = {},  -- Track which enemies we've already hit
			lastUpdateTime = 0,  -- For 150fps throttling
			damageAbsorbed = 0,  -- Track damage taken during dash for healing
		}
		table.insert(activeShieldBashes, bashData)
		
		-- INSTANT HIT DETECTION: Check for enemies immediately on activation (no throttle delay)
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if rootPart then
			local charPos = rootPart.Position
			local lookDir = rootPart.CFrame.LookVector
			local hitboxOffset = bashData.hitboxSize.Z / 2
			local hitboxPos = charPos + (lookDir * hitboxOffset)
			
			-- Check for enemies in front of player
			local GRID_SIZE = SpatialGridSystem.getGridSize()
			local maxDimension = math.max(bashData.hitboxSize.X, bashData.hitboxSize.Y, bashData.hitboxSize.Z)
			local searchRadius = math.ceil(maxDimension / GRID_SIZE)
			local nearbyEntities = SpatialGridSystem.getNeighboringEntities(hitboxPos, searchRadius)
			
			-- Count enemies in hitbox
			local enemiesInRange = 0
			local hitboxCFrame = CFrame.new(hitboxPos, hitboxPos + lookDir)
			local halfSize = bashData.hitboxSize / 2
			
			for _, targetEntity in ipairs(nearbyEntities) do
				local targetType = world:get(targetEntity, Components.EntityType)
				if targetType and targetType.type == "Enemy" then
					local enemyPos = world:get(targetEntity, Components.Position)
					if enemyPos then
						local enemyWorldPos = Vector3.new(enemyPos.x, enemyPos.y, enemyPos.z)
						local localPos = hitboxCFrame:PointToObjectSpace(enemyWorldPos)
						
						if math.abs(localPos.X) <= halfSize.X 
							and math.abs(localPos.Y) <= halfSize.Y 
							and math.abs(localPos.Z) <= halfSize.Z then
							enemiesInRange = enemiesInRange + 1
						end
					end
				end
			end
			
			-- Grant proactive invincibility if enemies detected
			if enemiesInRange > 0 then
				local proactiveInvincibility = enemiesInRange * bashData.invincibilityPerHit
				local statusEffects = world:get(bashData.playerEntity, Components.StatusEffects)
				local currentRemaining = 0
				
				if statusEffects and statusEffects.invincible then
					local currentEndTime = statusEffects.invincible.endTime
					local currentTime = GameTimeSystem.getGameTime()
					currentRemaining = math.max(0, currentEndTime - currentTime)
				end
				
				local totalDuration = currentRemaining + proactiveInvincibility
				StatusEffectSystem.grantInvincibility(bashData.playerEntity, totalDuration, false, false, false)
				print(string.format("[ShieldBash] INSTANT: Detected %d enemies → Adding %.2fs invincibility (previous: %.2fs, total: %.2fs)", 
					enemiesInRange, proactiveInvincibility, currentRemaining, totalDuration))
			else
				print("[ShieldBash] INSTANT: No enemies detected in hitbox")
			end
		end
		
		print(string.format("[ShieldBash] Activated: duration=%.2fs, hitbox=(%.1f,%.1f,%.1f), updating at 150fps", 
			bashData.duration, hitboxSize.X, hitboxSize.Y, hitboxSize.Z))
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

-- Process active Shield Bash collisions (server-side, like projectiles)
local function processShieldBashCollisions(dt: number)
	local currentTime = GameTimeSystem.getGameTime()
	local toRemove = {}
	
	for i, bashData in ipairs(activeShieldBashes) do
		local elapsed = currentTime - bashData.startTime
		
		-- Check if Shield Bash duration expired
		if elapsed >= bashData.duration then
			-- Grant final overshield based on total hits
			local hitCount = 0
			for _ in pairs(bashData.hitEnemies) do
				hitCount = hitCount + 1
			end
			
			local health = world:get(bashData.playerEntity, Components.Health)
			if health then
				-- Grant overshield based on total hits
				if hitCount > 0 then
					local overshieldAmount = health.max * bashData.overshieldPerHit * hitCount
					OverhealSystem.grantOverheal(bashData.playerEntity, overshieldAmount)
					print(string.format("[ShieldBash] Complete: hit %d enemies, granted %.0f%% overshield", 
						hitCount, hitCount * bashData.overshieldPerHit * 100))
				end
				
				-- CRITICAL: Heal ALL damage absorbed during dash (full invincibility)
				if bashData.damageAbsorbed > 0 then
					local newHealth = math.min(health.current + bashData.damageAbsorbed, health.max)
					DirtyService.setIfChanged(world, bashData.playerEntity, Components.Health, {
						current = newHealth,
						max = health.max,
					}, "Health")
					
					-- Also update Roblox humanoid health
					if bashData.player.Character then
						local humanoid = bashData.player.Character:FindFirstChild("Humanoid")
						if humanoid then
							humanoid.Health = newHealth
						end
					end
					
					print(string.format("[ShieldBash] REVERTED %.1f absorbed damage | HP: %.1f→%.1f", 
						bashData.damageAbsorbed, health.current, newHealth))
				end
			end
			
			table.insert(toRemove, i)
		else
			-- Update hitbox at 150fps (every ~0.0067s) for high-speed tracking
			if not bashData.lastUpdateTime or (elapsed - bashData.lastUpdateTime) >= 0.0067 then
				bashData.lastUpdateTime = elapsed
				
				-- Get player position for hitbox center
				local playerPos = world:get(bashData.playerEntity, Components.Position)
				if playerPos and bashData.player.Character then
					local rootPart = bashData.player.Character:FindFirstChild("HumanoidRootPart")
					if rootPart then
						-- Update position from character (client-predicted)
						local charPos = rootPart.Position
						
						-- Hitbox offset: position in front of player based on hitbox depth
						local lookDir = rootPart.CFrame.LookVector
						local hitboxOffset = bashData.hitboxSize.Z / 2  -- Half the depth of the hitbox
						local hitboxPos = charPos + (lookDir * hitboxOffset)
						
						-- Create hitbox CFrame (oriented with player's look direction)
						local hitboxCFrame = CFrame.new(hitboxPos, hitboxPos + lookDir)
						
						-- Check for enemies in range using spatial grid
						-- Use the maximum dimension for spatial search radius
						local GRID_SIZE = SpatialGridSystem.getGridSize()
						local maxDimension = math.max(bashData.hitboxSize.X, bashData.hitboxSize.Y, bashData.hitboxSize.Z)
						local searchRadius = math.ceil(maxDimension / GRID_SIZE)
						
						local nearbyEntities = SpatialGridSystem.getNeighboringEntities(hitboxPos, searchRadius)
						
						-- Expand search if no entities found
						if #nearbyEntities == 0 then
							nearbyEntities = SpatialGridSystem.getNeighboringEntities(hitboxPos, searchRadius + 1)
						end
						
						-- Track hits this update cycle
						local hitsThisCycle = 0
						
						-- Filter for enemies and check box collision
						for _, targetEntity in ipairs(nearbyEntities) do
							-- Check if it's an enemy
							local targetType = world:get(targetEntity, Components.EntityType)
							if targetType and targetType.type == "Enemy" and not bashData.hitEnemies[targetEntity] then
								-- Check if enemy is inside the hitbox (oriented bounding box test)
								local enemyPos = world:get(targetEntity, Components.Position)
								if enemyPos then
									local enemyWorldPos = Vector3.new(enemyPos.x, enemyPos.y, enemyPos.z)
									
									-- Transform enemy position to hitbox local space
									local localPos = hitboxCFrame:PointToObjectSpace(enemyWorldPos)
									local halfSize = bashData.hitboxSize / 2
									
									-- Check if point is inside the box
									local insideBox = math.abs(localPos.X) <= halfSize.X 
										and math.abs(localPos.Y) <= halfSize.Y 
										and math.abs(localPos.Z) <= halfSize.Z
									
									-- Only hit if inside the box
									if insideBox then
										local enemyHealth = world:get(targetEntity, Components.Health)
										if enemyHealth and enemyHealth.current > 0 then
											-- Apply damage (targetEntity, damage, damageType, sourceEntity, abilityId)
											DamageSystem.applyDamage(targetEntity, bashData.damage, "physical", bashData.playerEntity, "ShieldBash")
											
											-- Track hit for invincibility grant
											hitsThisCycle = hitsThisCycle + 1
											
											-- Apply knockback
											local enemyData = world:get(targetEntity, Components.EnemyData)
											if enemyData and enemyData.model then
												local enemyRootPart = enemyData.model.PrimaryPart or enemyData.model:FindFirstChild("HumanoidRootPart")
												if enemyRootPart then
													-- Calculate knockback direction (away from player)
													local knockbackDirection = (enemyRootPart.Position - charPos)
													-- Flatten to horizontal plane
													knockbackDirection = Vector3.new(knockbackDirection.X, 0, knockbackDirection.Z)
													if knockbackDirection.Magnitude > 0.1 then
														knockbackDirection = knockbackDirection.Unit
														-- Add slight upward component
														knockbackDirection = Vector3.new(knockbackDirection.X, 0.3, knockbackDirection.Z).Unit
														local knockbackVelocity = knockbackDirection * bashData.knockbackDistance * 10
														enemyRootPart.AssemblyLinearVelocity = knockbackVelocity
													end
												end
											end
											
											-- Mark enemy as hit (prevent re-hitting same enemy)
											bashData.hitEnemies[targetEntity] = true
										end
									end
								end
							end
						end
						
						-- Grant invincibility INSTANTLY for all hits this cycle (stacks by adding durations)
						if hitsThisCycle > 0 then
							local invincibilityToAdd = hitsThisCycle * bashData.invincibilityPerHit
							
							-- Get current invincibility remaining time
							local statusEffects = world:get(bashData.playerEntity, Components.StatusEffects)
							local currentRemaining = 0
							if statusEffects and statusEffects.invincible then
								local currentEndTime = statusEffects.invincible.endTime
								local currentTime = GameTimeSystem.getGameTime()
								currentRemaining = math.max(0, currentEndTime - currentTime)
							end
							
							-- Add new invincibility to existing (true stacking)
							local totalDuration = currentRemaining + invincibilityToAdd
							StatusEffectSystem.grantInvincibility(bashData.playerEntity, totalDuration, false, false, false)
							
							print(string.format("[ShieldBash] Hit %d enemies → Added %.2fs invincibility (total: %.2fs)", 
								hitsThisCycle, invincibilityToAdd, totalDuration))
						end
					end
				end
			end
		end
	end
	
	-- Remove expired Shield Bashes
	for i = #toRemove, 1, -1 do
		table.remove(activeShieldBashes, toRemove[i])
	end
end

-- Public function to check if a player is currently Shield Bashing and absorb damage
function MobilitySystem.absorbShieldBashDamage(playerEntity: number, damageAmount: number): boolean
	local currentTime = GameTimeSystem.getGameTime()
	
	for _, bashData in ipairs(activeShieldBashes) do
		if bashData.playerEntity == playerEntity then
			local elapsed = currentTime - bashData.startTime
			-- Only absorb damage during active dash (not after completion)
			if elapsed < bashData.duration then
				bashData.damageAbsorbed = bashData.damageAbsorbed + damageAmount
				print(string.format("[ShieldBash] ABSORBED %.1f damage (total: %.1f) | Elapsed: %.3fs/%.2fs", 
					damageAmount, bashData.damageAbsorbed, elapsed, bashData.duration))
				return true  -- Damage absorbed
			end
		end
	end
	
	return false  -- Not shield bashing or dash ended
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
	
	-- Handle client activation requests
	MobilityActivateRemote.OnServerEvent:Connect(function(player: Player, mobilityId: string)
		handleMobilityActivation(player, mobilityId)
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
end

return MobilitySystem

