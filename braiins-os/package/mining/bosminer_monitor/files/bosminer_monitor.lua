#!/usr/bin/lua

-- Copyright (C) 2020  Braiins Systems s.r.o.
--
-- This file is part of Braiins Open-Source Initiative (BOSI).
--
-- BOSI is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.
--
-- Please, keep in mind that we may also license BOSI or any part thereof
-- under a proprietary license. For more information on the terms and conditions
-- of such proprietary license or if you have any other questions, please
-- contact us at opensource@braiins.com.

function printr(fn, x)
	local max = 8
	local function rec(x, n)
		local t = type(x)
		if t == 'table' then
			local indent = ('\t'):rep(n)
			if n >= max then
				fn('{ ... }')
				return
			end
			fn('{\n')
			for k, v in pairs(x) do
				fn(indent)
				if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
					fn('\t'..k.. ' = ')
				else
					fn('\t[')
					rec(k, n+1)
					fn('] = ')
				end
				rec(v, n + 1)
				fn(',\n')
			end
			fn(indent)
			fn('}')
		elseif t == 'string' then
			fn(string.format('%q', x))
		else
			fn(tostring(x))
		end
	end
	rec(x, 0)
	fn('\n')
end

function pp(x)
	printr(io.write, x)
end



local CJSON = require "cjson"
local SOCKET = require "socket"
local NX = require "nixio"

local BOSMINER_HOST = "127.0.0.1"
local BOSMINER_PORT = 4028

local SERVER_HOST = "*"
local SERVER_PORT = 4029

-- chains must be running at leat at 80% of nominal rate
local MINIMAL_RATE = 80

local SAMPLE_TIME = 1


local RED_LED_PATH = '/sys/class/leds/Red LED'
local GREEN_LED_PATH = '/sys/class/leds/Green LED'

local MINER_MODEL_PATH = '/tmp/sysinfo/board_name'

-- utility functions
function log(fmt, ...)
	io.write((fmt..'\n'):format(...))
end

function push(t, x)
	t[#t + 1] = x
end

function get_miner_model()
	local f = io.open(MINER_MODEL_PATH, 'r')
	if not f then
		log('cannot determine miner model')
		return
	end
	local model = f:read('*l')
	f:close()
	return model
end

-- class declarations
local BOSMinerStatus = {}
BOSMinerStatus.__index = BOSMinerStatus

local Monitor = {}
Monitor.__index = Monitor

local Led = {}
Led.__index = Led

function get_uptime()
	return NX.sysinfo()['uptime']
end

-- Led class
function Led.new(path)
	local self = setmetatable({}, Led)
	self.path = path
	return self
end

function Led:sysfs_write(attr, val)
	local path = self.path..'/'..attr
	local f = io.open(path, 'w')
	if not f then
		log('failed to open %s', path)
		return
	end
	f:write(val)
	f:close()
end

function Led:set_mode(mode)
	log('%s mode %s', self.path, mode)
	if mode == 'on' or mode == 'off' then
		self:sysfs_write('trigger', 'none')
		if mode == 'off' then
			self:sysfs_write('brightness', '0')
		else
			self:sysfs_write('brightness', '255')
		end
	elseif mode == 'blink-fast' or mode == 'blink-slow' or mode == 'blink-slooow' then
		local time_on, time_off = 50, 950
		if mode == 'blink-fast' then
			time_off = 50
		elseif mode == 'blink-slooow' then
			time_on = 1000
			time_off = 1000
		end
		self:sysfs_write('trigger', 'timer')
		self:sysfs_write('delay_on', tostring(time_on))
		self:sysfs_write('delay_off', tostring(time_off))
	else
		log('bad led mode %s', mode)
		return
	end
end

-- BOSMinerStatus class
function BOSMinerStatus.new(response)
	local self = setmetatable({}, BOSMinerStatus)
	local json = response and CJSON.decode(response)
	self.chains = {}
	for _, dev in ipairs(json.devs[1].DEVS) do
		local chain = {
			mhs_cur = tonumber(dev["MHS 5m"]) or 0,
			mhs_nom = tonumber(dev["Nominal MHS"]) or 0,
		}
		push(self.chains, chain)
	end
	self.pools = json.pools[1].POOLS
	return self
end

-- Monitor class
function Monitor.new(red_led, green_led, model)
	local self = setmetatable({}, Monitor)
	self.last_time = 0
	self.state = ''
	self.led_override = false
	self.red_led = red_led
	self.green_led = green_led
	self.model = model
	self:set_state('dead', 'initialization')
	return self
end


function Monitor:sample_time()
	local time_diff = get_uptime() - self.last_time
	return math.abs(time_diff) >= SAMPLE_TIME
end

-- check if miner is running
function Monitor:check_healthy(status)
	local active_chains = 0
	local active_pools = 0
	local sick_chains = 0
	for i, chain in ipairs(status.chains) do
		if chain.mhs_nom > 0 then
			--log("chain %d health %f", i, chain.mhs_cur/chain.mhs_nom * 100)
			active_chains = active_chains + 1
			if chain.mhs_cur < chain.mhs_nom * MINIMAL_RATE / 100 then
				sick_chains = sick_chains + 1
			end
		end
	end
	for i, pool in ipairs(status.pools) do
		if pool.Status == 'Alive' then
			active_pools = active_pools + 1
		end
	end
	--log("alive_pools=%d alive_chains=%d sick_chains=%d",
		--active_pools, active_chains, sick_chains)
	if active_pools == 0 then
		return 'dead', 'no active pools'
	end
	if active_chains == 0 then
		return 'dead', 'no active chains'
	end
	if sick_chains > 0 then
		return 'sick', 'low hashrate'
	end
	return 'ok'
end

local state_to_red_led = {
	dead = 'on',
	sick = 'blink-slow',
	ok = 'off',
}
local state_to_green_led = {
	dead = 'off',
	sick = 'off',
	ok = 'blink-slooow',
}

function Monitor:update_leds()
	local red_mode = assert(state_to_red_led[self.state])
	if self.led_override then
		self.red_led:set_mode('blink-fast')
	else
		self.red_led:set_mode(red_mode)
	end
	local green_mode = assert(state_to_green_led[self.state])
	self.green_led:set_mode(green_mode);
end

local function write_to_file(path, fmt, ...)
	local f = io.open(path, 'w')
	if not f then
		print('cannot open '..path)
		return
	end
	f:write(fmt:format(...))
	f:close()
end

local function fan_set_duty(n, duty)
	local prefix = ('/sys/class/pwm/pwmchip%d'):format(n)
	local period = 100000
	write_to_file(prefix..'/export', '0')
	write_to_file(prefix..'/pwm0/period', '%d', period)
	write_to_file(prefix..'/pwm0/duty_cycle', '%d', math.floor((100 - duty)*period))
	write_to_file(prefix..'/pwm0/enable', '1')
end

-- TODO: implement this function for all models and just fill it in during
-- initialization as a method
function Monitor:safety_turn_all_fans_on()
	if self.model ~= 'am1-s9' then
		if self.state ~= 'dead' then
			log('turning all fans on')
		end
		for i = 0, 2 do
			fan_set_duty(i, 100)
		end
	end
end

function Monitor:set_state(state, reason)
	if state == 'dead' then
		self:safety_turn_all_fans_on()
	end
	if state ~= self.state then
		if reason then
			log('state %s because %s', state, reason)
		else
			log('state %s', state)
		end
		self.state = state
		self:update_leds()
	end
end

local model = get_miner_model()
local monitor = Monitor.new(Led.new(RED_LED_PATH), Led.new(GREEN_LED_PATH), model)
local server = assert(SOCKET.bind(SERVER_HOST, SERVER_PORT))

-- server accept is interrupted every second to get new sample from bosminer
server:settimeout(SAMPLE_TIME)

-- wait forever for incomming connections
while true do
	local client, err = server:accept()
	if client == nil and err ~= 'timeout' then
		NX.nanosleep(SAMPLE_TIME)
	end

	if monitor:sample_time() then
		local bosminer = assert(SOCKET.tcp())
		local result = nil
		local new_state = 'dead'
		local reason = "BOSminer API doesn't respond"
		bosminer:settimeout(3)
		local ret, err = bosminer:connect(BOSMINER_HOST, BOSMINER_PORT)
		if ret then
			bosminer:send('{ "command":"devs+pools" }')
			-- read all data and close the connection
			local str = bosminer:receive('*a')
			if str then
				-- remove null from string
				result = str:sub(1, -2)
			end
		end
		if result then
			local status = BOSMinerStatus.new(result)
			new_state, reason = monitor:check_healthy(status)
		end
		monitor:set_state(new_state, reason)
	end
	if client then
		--local response = monitor:get_response(history)
		--if response then
		--	client:send(response)
		-- end
		client:settimeout(1)
		local ok, err = client:receive('*a')
		if ok then
			local w = ok:match('^(%w+)')
			if w == 'on' then
				monitor.led_override = true
			elseif w == 'off' then
				monitor.led_override = false
			end
			monitor:update_leds()
		end
		client:close()
	end
end
