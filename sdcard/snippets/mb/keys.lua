-- Multibow internal "module" implementing convenience functions for sending
-- key presses to the USB host to which the Keybow device is connected to.

--[[
Copyright 2019 Harald Albrecht

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]--

-- luacheck: globals mb

-- Our key ticker queue: its elements are keys and modifiers to press and
-- release, one after another, so that USB HID operations won't ever take too
-- long as to minimize tick jitter.
mb.tq = mb.tickqueue:new()

-- Our "modern" API for sending USB keystrokes to the host is highly inspired
-- by assertion chains, such as luassert: this allows programming sequences of
-- keystrokes in a highly self-descriptive manner using "mb.keys" using chains
-- of key taps, modifier keys, repeating stroke sequences, and some other
-- crazy stuff. See README.md for a detailed description, as well as the
-- example layouts.
local Keys = {
    op = nil, -- current operation to be done when we hit the table call.
    afterms = 0, -- accumulated delay before any operation except after().
}

-- When an element (field) of the "keys" table is getting read that doesn't
-- exist (is nil), then the __index method gets triggered, so we can check for
-- any of our chaining functions. Please note that we must NOT hide the other
-- fields that aren't chaining functions.
function Keys.__index(self, key)
    -- Let's first see if it's a "real" field in this object, or alternatively
    -- a "real" field in the class object. Only if that fails, then try to
    -- handle a chain operation.
    local val = rawget(self, key) or rawget(Keys, key)
    if val then return val end
    -- Try to look up the missing field as a chain operator; only if that
    -- succeeds, then remember the chain operator for a following table call
    -- operation. Otherwise, handle the field as any ordinary field.
    local op = rawget(Keys, "op_" .. key:lower())
    if op then
        -- If there's already an operation pending, then offer the convenience
        -- of calling it first, before the store the new operation for later
        -- processing. This allows dropping the function call brackets when
        -- chaining arg-less operations (except for the last operation in a
        -- chain, which would otherwise never get called).
        if self.op then
            self.op(self) -- no further args given.
        end
        self.op = op
        return self -- ...always return ourselves for further chaining.
    end
end

-- When the "keys" table is being called as a function then activate the
-- most recent operation; this basically emulates methods using ordinary
-- table field and function call syntax.
function Keys.__call(self, ...)
    if self.op then
        self.op(self, ...)
        self.op = nil
    end
    return self -- ...always return ourselves for further chaining.
end


mb._keys = Keys

-- Initializes/resets the "virtual" mb.keys object each time it gets accessed
-- anew, so chained key operations always start in a well-known initial state.
function Keys:new() -- luacheck: ignore 212/self
    local k = {
        afterms = 0,
        jobs = {},
    }
    k = setmetatable(k, Keys)
    return k
end

-- Adds another tick job to the tick queue, unless there is already at least
-- one tick job block open: in this case, the tick job gets added to that open
-- block instead of to the tick queue itself.
-- * tickjob: the tick job to be added; either to the tick queue or the
--   currently "innermost" open block.
-- * push: if truthy, then the tick job is opening a new tick job block, and
--   subsequent tick jobs get added to it until it gets closed by a "fin"
--   chain operation.
function Keys:addtickjob(tickjob, push)
    tickjob.afterms = self.afterms -- make sure to freeze the accumulated delay.
    self.afterms = 0 -- reset accumulated delay for chain.
    if #self.jobs == 0 then
        -- No open block(s), so we queue the tick job directly, with the
        -- currently accumulated "initial" delay.
        mb.tq:add(tickjob, tickjob.afterms)
    else
        -- There's at least one tick job block open, so we need to add the
        -- tick job to the "innermost" block.
        local jobseq = self.jobs[#self.jobs].tickjob
        if jobseq == nil then
            -- first job, so we avoid a tick job sequence for the moment.
            self.jobs[#self.jobs].tickjob = tickjob
        else
            local seq = jobseq
            if seq.tickjobs == nil then
                -- second job, so swap in a sequence before adding the
                -- existing as well as the new job.
                seq = mb.TickJobSequencer:new()
                self.jobs[#self.jobs].tickjob = seq
                seq:add(jobseq)
            end
            -- add new tick job to ("newly") existing sequence.
            seq:add(tickjob)
        end
    end
    if push then
        -- Make this tick job the new innermost block.
        table.insert(self.jobs, tickjob)
    end
end

-- Convenience function to add a new tick job block.
function Keys:addtickjobblock(tickjob)
    return self:addtickjob(tickjob, true)
end

-- The "after()" chain operation adds a delay before the next key operation.
-- This operation is additive, that is, if you chain multiple after()s, then
-- they will all add up. The delay gets reset at the beginning of each chain,
-- as well as with the next operation which is not an after().
function Keys:op_after(ms)
    self.afterms = (self.afterms or 0) + (ms or 0)
    return self
end

-- The "wait()" chain operation is an alias of "after()".
Keys.op_wait = Keys.op_after

-- The "tap()" chain operation taps a string or a single key. Since it is easy
-- to chain tap()s, we do not need to support an array of keys here ... famous
-- last words.
function Keys:op_tap(keys)
    -- For convenience, explode a keys string parameter into its individual
    -- characters as an array, since we want to tap each character in the
    -- string in its own tick slot, but not all at once.
    if type(keys) == "string" then
        local keysarr = {}
        for idx = 1, #keys do
            keysarr[idx] = keys:sub(idx, idx)
        end
        keys = keysarr
    elseif type(keys) == "number" then
        keys = {keys}
    end
    -- Queue the keys to tap in a sequence of ticks. Please note that we
    -- expect things to be already broken up at this point, as the tick job
    -- mapper will dutyfully tap each element on each tick.
    self:addtickjob(mb.TickJobMapper:new(
        {
            function(key) keybow.set_key(key, keybow.KEY_DOWN) end,
            function(key) keybow.set_key(key, keybow.KEY_UP) end
        },
        table.unpack(keys)
    ))
    return self
end

-- The "mod()" chain operation encloses the following chain operations with
-- pressing the specified modifier keys, and releasing them afterwards. The
-- block of enclosed operations can be explicitly closed using the "fin()"
-- operation, otherwise the end of the whole chain is taken.
function Keys:op_mod(...)
    self:addtickjobblock(mb.TickJobEncloser:new(
        nil, -- preliminary, will be set later when we see the next operation.
        function(mod) keybow.set_modifier(mod, keybow.KEY_DOWN) end,
        function(mod) keybow.set_modifier(mod, keybow.KEY_UP) end,
        ... -- modifier(s)
    ))
    return self
end

-- The "shift()" chain operation encloses the following chain operations with
-- pressing the (left) SHIFT modifier, then releasing SHIFT afterwards.
function Keys:op_shift()
    return self:op_mod(keybow.LEFT_SHIFT)
end

-- The "ctrl()" chain operation encloses the following chain operations with
-- pressing the (left) CTRL modifier, then releasing CTRL afterwards.
function Keys:op_ctrl()
    return self:op_mod(keybow.LEFT_CTRL)
end

-- The "alt()" chain operation encloses the following chain operations with
-- pressing the (left) ALT modifier, then releasing ALT afterwards.
function Keys:op_alt()
    return self:op_mod(keybow.LEFT_ALT)
end

-- The "meta()" chain operation encloses the following chain operations with
-- pressing the (left) META modifier, then releasing META afterwards.
function Keys:op_meta()
    return self:op_mod(keybow.LEFT_META)
end

-- Cursor arrow key chain operations...
function Keys:op_left()
    return self:op_tap(keybow.LEFT_ARROW)
end

function Keys:op_right()
    return self:op_tap(keybow.RIGHT_ARROW)
end

function Keys:op_up()
    return self:op_tap(keybow.UP_ARROW)
end

function Keys:op_down()
    return self:op_tap(keybow.DOWN_ARROW)
end

function Keys:op_home()
    return self:op_tap(keybow.HOME)
end

function Keys:op_end()
    return self:op_tap(keybow.END)
end

-- The "times()" chain operation repeats the following chain operations as
-- many times as specified. The block of repeated operations can be explicitly
-- finished using the "fin()" operation, otherwise it will be the end of the
-- whole chain. The pause between repeated operation blocks can be controlled
-- using the "space()" and "apart()" operations.
function Keys:op_times(times)
    self:addtickjobblock(mb.TickJobRepeater:new(
        nil, -- preliminary, will be set later when we see the next operation.
        times,
        0 -- and no pause; this can later be changed using "space()"/"apart()".
    ))
    return self
end

-- The "space()" chain operation sets the pause parameter for a repeated tick
-- job, that is, the wait time between each round of the tick job.
function Keys:op_space(ms)
    if #self.jobs then
        self.jobs[#self.jobs].pause = ms
    end
    return self
end

-- The "apart()" chain operation is an alias for the "space()" operation.
Keys.op_apart = Keys.op_space

-- The "fin()" operation ends the innermost "block" in a chain, such as a
-- "times()" and "mod()" operations block: this pops the current tick job off
-- the stack of "open" key job blocks. It keeps silent in face of surplus
-- "fin" operations.
function Keys:op_fin()
    if #self.jobs > 0 then
        table.remove(self.jobs, #self.jobs)
    end
    return self
end

-- "done()" is an alias for "fin()".
Keys.op_done = Keys.op_fin


-- Sets up a "virtual" mb.keys object that is returned in a defined init state
-- each time the "mb.keys" element gets accessed. For this, we need to give
-- the mb object (table) a special "__index" meta function that handles
-- "mb.keys" in a special way, but otherwise works as before for all other
-- fields of the mb object/table.
setmetatable(mb, {
    -- When a non-existing table element/field is to be accessed...
    __index = function(self, key)
        if key == "keys" then
            return Keys:new()
        else
            return rawget(self, key)
        end
    end
})
