--[[
	William Horn 2019 EventMaker Module (Lua 5.1)
	ScriptGuider @ ROBLOX.com
	Created: 4/5/2019
	Updated: 5/12/2021

	Changelog:

		[5/12/2019]
			• Added enable/disable mechanic as an alternative to unbinding events if
			re-binding them is necessary later on.

		[12/6/2019]
			• Major code clean-up

			• Fixed some logic issue with "isbinded" field

			• Added mechanic where creating signals with the same name will overwrite
			eachother to avoid clutter and confusion if same names are given by accident
			or on purpose.

		[12/8/2019]
			• Updated to V2

			• Switched to coroutines for concurrency instead of using the ROBLOX bindableEvent API. However, bindableEvents are still used
			when yielding to avoid busy waiting or weird coroutines.

			• `bind` no longer returns an object to unbind the connection. Instead it is recommended to create an ID name for the connection
			and use `unbind` from the event API.

		[5/12/2021]
			• Added newEventRecord class to hold event statistic and base controls like enable/disable

			• Replaced "getEventByIndex" with "findConnectionByName" and included it in the API

			• Removed "isBinded" class field as it served to be useless

			• EventMaker() is no longer a valid constructor, instead use EventMaker.event()

			• Two new constructors: EventMaker.eventInterval() and EventMaker.eventIntervalSequence() have been added. These
			constructors allow you to create event objects that only respond to being fired in succession within some interval
			of time. i.e, making a double-click event

	TO-DO:
		? Add `timeout` argument to yield -- Implemented [12/8/2019]
		• Create an "Onbind" function that is executed before binding the event
		? Create API for event intervals


	API:

		* = optional

		local event = EventMaker.event()

		event:bind(name[string]*, func)
		event:unbind(name[string]*)
		event:fire(...)
		event:wait(timeout[number]*)
		event:findConnectionByName



--]]

local coro_create = coroutine.create
local coro_resume = coroutine.resume
local coro_yield = coroutine.yield

--[[
local function getEventByIndex(connections, index, value)
	for i = 1, #connections do
		if connections[i][index] == value then
			return connections[i], i
		end
	end
end
]]

local baseClass = {}
baseClass.__index = baseClass

function baseClass:enable()
	self.enabled = true
end
function baseClass:disable()
	self.enabled = false
end
function baseClass:setEnabled(bool)
	self.enabled = bool
end
function baseClass:isEnabled()
	return self.enabled
end

local function newEventRecord(fields)
	local eventRecord = {}

	for key, value in next, fields do
		eventRecord[key] = value
	end

	eventRecord.timesFired = 0
	eventRecord.timesFiredWhileDisabled = 0
	eventRecord.enabled = true

	return setmetatable(eventRecord, baseClass)
end

local function findConnectionByName(self, name)
	local connections = self._connections
	for i = 1, #connections do
		if connections[i].name == name then
			return connections[i], i
		end
	end
end

local function disconnectEvent(connections, index)
	local event = connections[index]
	event.func = nil
	table.remove(connections, index)
end

local function unbind(self, name)
	local connections = self._connections
	local event, index = findConnectionByName(self, name)

	if event then
		disconnectEvent(connections, index)
	else
		for i = 1, #connections do
			disconnectEvent(connections, i)
		end
	end
end

local function bind(self, name, func)
	local connections = self._connections

	if not func then
		func, name = name, nil
	end

	-- avoid events with same name
	if name then
		local event, index = findConnectionByName(self, name)
		if event then
			warn("EventMaker: Event of same name \"" .. name .. "\" was disconnected because it was overwritten")
			disconnectEvent(connections, index)
		end
	end

	local connection = newEventRecord{
		func = func,
		name = name or false,
	}

	connections[#connections+1] = connection
	--return connection
end

local function fire(self, ...)
	if self:isEnabled() then
		local connections = self._connections
		self.timesFired = self.timesFired + 1 -- *optional: for debugging/optimizing
		self._yieldSignal:Fire(...)

		for i = 1, #connections do
			local connection = connections[i]
			if connection:isEnabled() then
				connection.timesFired = connection.timesFired + 1 -- *optional: for debugging/optimizing
				coro_resume(coro_create(connection.func), ...)
			else
				connection.timesFiredWhileDisabled = connection.timesFiredWhileDisabled + 1 -- *optional: for debugging/optimizing
			end
		end
	else
		self.timesFiredWhileDisabled = self.timesFiredWhileDisabled + 1 -- *optional: for debugging/optimizing
	end
end

local function fireInterval(self, ...)
	local now = tick()
	self.currentRepetitions = self.currentRepetitions + 1

	if not self.intervalStarted then
		self.intervalStarted = now
	elseif now - self.intervalStarted <= self.interval then
		if self.currentRepetitions == self.repetitions then
			self.currentRepetitions = 0
			self.intervalStarted = false
			fire(self, ...)
		end
	else
		self.currentRepetitions = 1
		self.intervalStarted = now
	end
end

local function fireIntervalSequence(self, ...)
	local now = tick()

	if now - self.lastFired <= self.interval then
		self.currentRepetitions = self.currentRepetitions + 1
	else
		self.currentRepetitions = 1
	end

	if self.currentRepetitions == self.repetitions then
		self.currentRepetitions = 0
		self.lastFired = 0
		fire(self, ...)
	else
		self.lastFired = now
	end
end

local function yield(self, timeout)
	local dt = tick()
	local isWaiting = true

	if timeout then
		delay(timeout, function()
			if isWaiting then
				isWaiting = false
				self._yieldSignal:Fire()
				warn("EventMaker wait() timed out after " .. tostring(tick() - dt) .. " seconds")
			end
		end)
	end

	local args = {self._yieldSignal.Event:Wait()}
	isWaiting = false
	return tick() - dt, unpack(args)
end

--------------
--------------

local EventMaker = {}

function EventMaker.event(fields)
	local event = newEventRecord{
		-- hidden (should not be accessed by developer)
		_yieldSignal = Instance.new("BindableEvent"),
		_connections = {},

		-- fields
		--IsWaiting = false,

		-- API
		bind = bind,
		fire = fire,
		wait = yield,
		unbind = unbind,
		findConnectionByName = findConnectionByName,
	}

	if fields then
		for k, v in next, fields do
			if event[k] then
				warn("EventMaker: \"" ..k.."\" was overwritten by constructor. Consider using a different fieldname.")
			end
			event[k] = v
		end
	end

	return event
end

function EventMaker.eventInterval(repetitions, interval, fields)
	if repetitions <= 1 then
		warn("You cannot set repetitions for EventMaker.eventInterval() less than or equal to 1. Try using EventMaker.event() instead.")
		return
	end

	local event = EventMaker.event(fields)
	event.currentRepetitions = 0
	event.repetitions = repetitions
	event.interval = interval
	event.intervalStarted = false
	event.fire = fireInterval

	return event
end

function EventMaker.eventIntervalSequence(repetitions, interval, fields)
	if repetitions <= 1 then
		warn("You cannot set repetitions for EventMaker.intervalEventSequence() less than or equal to 1. Try using EventMaker.event() instead.")
		return
	end

	local event = EventMaker.event(fields)
	event.currentRepetitions = 0
	event.repetitions = repetitions
	event.interval = interval
	event.lastFired = 0
	event.fire = fireIntervalSequence

	return event
end


--------------
--------------

return EventMaker
