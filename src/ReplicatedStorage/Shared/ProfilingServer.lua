--!strict

local Profiling = {}

local timerStarts: {[string]: number} = {}
local timerTotals: {[string]: number} = {}
local timerCounts: {[string]: number} = {}
local counters: {[string]: number} = {}
local gauges: {[string]: {last: number, max: number}} = {}

local function resetWindow()
	table.clear(timerTotals)
	table.clear(timerCounts)
	table.clear(counters)
	table.clear(gauges)
end

function Profiling.beginTimer(name: string)
	timerStarts[name] = os.clock()
end

function Profiling.endTimer(name: string)
	local start = timerStarts[name]
	if not start then
		return
	end
	local elapsed = os.clock() - start
	timerTotals[name] = (timerTotals[name] or 0) + elapsed
	timerCounts[name] = (timerCounts[name] or 0) + 1
end

function Profiling.incCounter(name: string, amount: number?)
	local delta = amount or 1
	counters[name] = (counters[name] or 0) + delta
end

function Profiling.gauge(name: string, value: number)
	local entry = gauges[name]
	if entry then
		entry.last = value
		if value > entry.max then
			entry.max = value
		end
	else
		gauges[name] = {last = value, max = value}
	end
end

function Profiling.printWindow()
	if next(timerTotals) == nil and next(counters) == nil and next(gauges) == nil then
		return
	end

	local lines = {}
	table.insert(lines, "[Profiling][Server] 2s window")

	for name, total in pairs(timerTotals) do
		local count = timerCounts[name] or 0
		local ms = total * 1000
		if count > 0 then
			table.insert(lines, string.format("%s: %.2f ms (%d)", name, ms, count))
		else
			table.insert(lines, string.format("%s: %.2f ms", name, ms))
		end
	end

	for name, value in pairs(counters) do
		table.insert(lines, string.format("%s: %d", name, value))
	end

	for name, entry in pairs(gauges) do
		table.insert(lines, string.format("%s: %d/%d", name, entry.last, entry.max))
	end

	print(table.concat(lines, " | "))
	resetWindow()
end

task.spawn(function()
	while true do
		task.wait(2)
		Profiling.printWindow()
	end
end)

return Profiling
