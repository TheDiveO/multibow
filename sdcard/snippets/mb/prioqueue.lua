-- Multibow internal "module" implementing a simple min priority queue, to be
-- used for alarm/timer functionality.

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

local pq = {}
pq.__index = pq

-- Creates a new priority queue.
function pq:new() -- luacheck: ignore 212/self
    return setmetatable({
        heap={},
        size=0
    }, pq)
end

-- Returns the foremost (minimum) element (priority, value) from the priority
-- queue, without removing it from the priority queue. If the queue is empty,
-- then the element returned will be (nil, nil).
function pq:peek()
    if self.size > 0 then
        return self.heap[1].priority, self.heap[1].value
    end
    return nil, nil
end

-- Adds another element (priority, value) to the priority queue. It's perfectly
-- fine to add multiple elements of the same priority.
function pq:add(priority, value)
    self.size = self.size + 1
    self.heap[self.size] = {priority=priority, value=value}
    -- let the new element move up the heap as far as necessary.
    local i = self.size
    while math.floor(i/2) > 0 do
        local half = math.floor(i/2)
        if self.heap[i].priority < self.heap[half].priority then
            self.heap[i], self.heap[half] = self.heap[half], self.heap[i]
        end
        i = half
    end
end

-- Removes the foremost (minimum) element from the priority queue and returns
-- it as (priority, value).
function pq:remove()
    if self.size == 0 then
        return nil, nil
    end
    local min = self.heap[1]
    self.heap[1] = self.heap[self.size]
    self.heap[self.size] = nil
    self.size = self.size - 1
    --
    local i = 1
    while i*2 <= self.size do
        local minchild = self:minchild(i)
        if self.heap[i].priority > self.heap[minchild].priority then
            self.heap[i], self.heap[minchild] = self.heap[minchild], self.heap[i]
        end
        i = minchild
    end
    --
    return min.priority, min.value
end

-- Returns the index for the smaller child of heap element i.
function pq:minchild(i)
    local i2 = i*2
    if i2+1 > self.size then
        return i2
    end
    return self.heap[i2].priority < self.heap[i2+1].priority and i2 or i2+1
end

-- Searches for a specific element of (priority, value) and returns its index
-- within the heap. If multiple elements of (priority, value) exist, then the
-- index of an arbitrary one of these elements will be returned.
function pq:search(priority, value)
    for i = 1,self.size do
        if self.heap[i].priority == priority and self.heap[i].value == value then
            return i
        end
    end
    return nil
end

-- Deletes the element (priority, value) from the priority queue. If there are
-- multiple elements of (priority, value) in the head, then only an arbitrary
-- one of them will be removed. As an indication, the element removed will be
-- returned, otherwise nil.
function pq:delete(priority, value)
    local i = self:search(priority, value)
    if i == nil then
        return nil
    end
    -- reset element to lowest priority, then let it swim up, so it will be
    -- removed the next time the min element is to be removed from the queue.
    self.heap[i].priority = math.mininteger
    while math.floor(i/2) > 0 do
        local half = math.floor(i/2)
        if self.heap[i].priority < self.heap[half].priority then
            self.heap[i], self.heap[half] = self.heap[half], self.heap[i]
        end
        i = half
    end
    local _, v = self:remove()
    return priority, v
end

return pq -- module