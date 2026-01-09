--!strict
-- EasingUtils - Pure easing functions for time-based scaling
-- Supports Linear and InQuad easing styles

local EasingUtils = {}

-- Linear easing: constant rate
local function linear(t: number): number
	return t
end

-- InQuad easing: quadratic ease-in (slow start, accelerating)
local function inQuad(t: number): number
	return t * t
end

-- Evaluate a scaling configuration at a given elapsed time
-- Returns the interpolated value clamped to [StartValue, EndValue]
function EasingUtils.evaluate(config: any, elapsedTime: number): number
	if not config or not config.StartValue or not config.EndValue or not config.Duration then
		warn("[EasingUtils] Invalid config provided to evaluate:", config)
		return config and config.StartValue or 1
	end
	
	-- Normalize time to [0, 1] range
	local t = math.clamp(elapsedTime / config.Duration, 0, 1)
	
	-- Apply easing function
	local easedT = t
	if config.EasingStyle == "InQuad" then
		easedT = inQuad(t)
	else
		-- Default to Linear
		easedT = linear(t)
	end
	
	-- Interpolate between start and end values
	return config.StartValue + (config.EndValue - config.StartValue) * easedT
end

return EasingUtils

