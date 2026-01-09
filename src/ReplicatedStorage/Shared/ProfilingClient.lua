--!strict

local Profiling = {}

local timerStarts: {[string]: number} = {}
local timerTotals: {[string]: number} = {}
local timerCounts: {[string]: number} = {}
local counters: {[string]: number} = {}

local function resetWindow()
	table.clear(timerTotals)
	table.clear(timerCounts)
	table.clear(counters)
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

function Profiling.printWindow()
	if next(timerTotals) == nil and next(counters) == nil then
		return
	end

	local lines = {}
	table.insert(lines, "[Profiling][Client] 2s window")

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
