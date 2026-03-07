local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer

local EASING_STYLES = {
	Linear  = Enum.EasingStyle.Linear,
	Quad    = Enum.EasingStyle.Quad,
	Expo    = Enum.EasingStyle.Exponential,
	Sine    = Enum.EasingStyle.Sine,
	Cubic   = Enum.EasingStyle.Cubic,
	Quart   = Enum.EasingStyle.Quart,
	Quint   = Enum.EasingStyle.Quint,
	Bounce  = Enum.EasingStyle.Bounce,
	Elastic = Enum.EasingStyle.Elastic,
	Back    = Enum.EasingStyle.Back,
}

local animationDataByID = {}

local function resolveRef(character, refPath)
	local current = character
	for _, segment in ipairs(string.split(refPath, ".")) do
		local child = current:FindFirstChild(segment)
		if not child then
			warn("[VFXClient] resolveRef: could not find '" .. segment .. "' in path: " .. refPath)
			return nil
		end
		current = child
	end
	return current
end

local function parseEasing(easingString)
	if easingString == "Linear" then
		return Enum.EasingStyle.Linear, Enum.EasingDirection.Out
	end

	local styleName, direction
	if easingString:sub(-5) == "InOut" then
		direction = Enum.EasingDirection.InOut
		styleName = easingString:sub(1, -6)
	elseif easingString:sub(-3) == "Out" then
		direction = Enum.EasingDirection.Out
		styleName = easingString:sub(1, -4)
	elseif easingString:sub(-2) == "In" then
		direction = Enum.EasingDirection.In
		styleName = easingString:sub(1, -3)
	else
		warn("[VFXClient] parseEasing: unrecognised easing string '" .. easingString .. "', using Linear/Out")
		return Enum.EasingStyle.Linear, Enum.EasingDirection.Out
	end

	local easingStyle = EASING_STYLES[styleName]
	if not easingStyle then
		warn("[VFXClient] parseEasing: unknown easing style '" .. styleName .. "' in '" .. easingString .. "', using Linear")
		easingStyle = Enum.EasingStyle.Linear
	end

	return easingStyle, direction
end

local function executeMarker(target, property, easingStyle, easingDir, endVal, frames)
	if property == "Emit" then
		target:Emit(tonumber(endVal) or 1)

	elseif property == "Enabled" then
		local a, b = frames:match("^(%d+%.?%d*)-(%d+%.?%d*)$")
		local duration = a and ((tonumber(b) :: number) - (tonumber(a) :: number)) / 60
		             or (tonumber(frames) or 0) / 60
		local state = (endVal == "1")
		target.Enabled = state
		if duration > 0 then
			task.delay(duration, function()
				target.Enabled = not state
			end)
		end

	else
		local a, b = frames:match("^(%d+%.?%d*)-(%d+%.?%d*)$")
		local duration
		if a and b then
			duration = ((tonumber(b) :: number) - (tonumber(a) :: number)) / 60
		else
			duration = (tonumber(frames) or 0) / 60
		end
		local goal = tonumber(endVal)
		if goal == nil then
			warn("[VFXClient] executeMarker: endVal is not a number for property '" .. property .. "'")
			return
		end
		local tweenInfo = TweenInfo.new(duration, easingStyle, easingDir)
		TweenService:Create(target, tweenInfo, { [property] = goal }):Play()
	end
end

local function parseAndRunMarker(markerName, character)
	local path, rest = markerName:match("^%(([^%)]+)%)_(.+)$")
	if not path then
		warn("[VFXClient] parseAndRunMarker: marker must start with (path.to.Instance): '" .. markerName .. "'")
		return
	end

	local parts = string.split(rest, "_")
	if #parts ~= 5 then
		warn("[VFXClient] parseAndRunMarker: expected 5 fields after path, got " .. #parts .. ": '" .. markerName .. "'")
		return
	end

	local property = parts[1]
	local easing   = parts[2]
	local endVal   = parts[4]
	local frames   = parts[5]

	local target = resolveRef(character, path)
	if not target then
		warn("[VFXClient] parseAndRunMarker: could not resolve path '" .. path .. "' in marker: " .. markerName)
		return
	end

	local easingStyle, easingDir = parseEasing(easing)
	executeMarker(target, property, easingStyle, easingDir, endVal, frames)
end

local function connectMarkers(track, character, markers)
	for _, markerData in ipairs(markers) do
		track:GetMarkerReachedSignal(markerData.name):Connect(function()
			parseAndRunMarker(markerData.name, character)
		end)
	end
end

local function playWithVFX(animationId)
	local entry = animationDataByID[animationId]
	if not entry then
		warn("[VFXClient] playWithVFX: no entry stored for animationId: " .. tostring(animationId))
		return
	end

	local character = localPlayer.Character
	if not character then
		warn("[VFXClient] playWithVFX: no character found for local player")
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warn("[VFXClient] playWithVFX: no Humanoid in character")
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		warn("[VFXClient] playWithVFX: no Animator under Humanoid")
		return
	end

	local animInstance       = Instance.new("Animation")
	animInstance.AnimationId = entry.animationId
	local track = animator:LoadAnimation(animInstance)
	animInstance:Destroy()

	connectMarkers(track, character, entry.markers)

	track:Play()
end

local VFXRemote    = ReplicatedStorage:WaitForChild("VFXRemote", 15)
local AbilityFired = ReplicatedStorage:WaitForChild("AbilityFired", 15)

if not VFXRemote then
	warn("[VFXClient] VFXRemote not found in ReplicatedStorage after timeout — VFX system disabled")
	return
end
if not AbilityFired then
	warn("[VFXClient] AbilityFired not found in ReplicatedStorage after timeout — VFX system disabled")
	return
end

VFXRemote.OnClientEvent:Connect(function(allEntries)
	animationDataByID = {}
	for _, entry in ipairs(allEntries) do
		animationDataByID[entry.animationId] = entry
	end
	print(string.format("[VFXClient] Received and stored %d animation entries", #allEntries))
end)

AbilityFired.OnClientEvent:Connect(function(animationId)
	playWithVFX(animationId)
end)
