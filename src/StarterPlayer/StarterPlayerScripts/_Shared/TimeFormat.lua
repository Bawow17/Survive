--!strict

local TimeFormat = {}

function TimeFormat.formatMMSS(totalSeconds: number): string
	local minutes = math.floor(totalSeconds / 60)
	local seconds = math.floor(totalSeconds % 60)
	return string.format("%02d:%02d", minutes, seconds)
end

function TimeFormat.formatSecondsCompact(totalSeconds: number): string
	if totalSeconds >= 60 then
		local mins = math.floor(totalSeconds / 60)
		local secs = totalSeconds % 60
		return string.format("%d:%02d", mins, math.floor(secs))
	end
	return string.format("%.1f", totalSeconds)
end

function TimeFormat.formatIntWithCommas(value: number): string
	local rounded = math.floor(value + 0.0001)
	local sign = ""
	if rounded < 0 then
		sign = "-"
		rounded = -rounded
	end
	local text = tostring(rounded)
	local withCommas = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if withCommas:sub(1, 1) == "," then
		withCommas = withCommas:sub(2)
	end
	return sign .. withCommas
end

return TimeFormat
