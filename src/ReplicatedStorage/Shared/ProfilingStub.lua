--!strict

local Profiling = {}

function Profiling.beginTimer(_name: string)
end

function Profiling.endTimer(_name: string)
end

function Profiling.incCounter(_name: string, _amount: number?)
end

function Profiling.gauge(_name: string, _value: number)
end

function Profiling.printWindow()
end

return Profiling
