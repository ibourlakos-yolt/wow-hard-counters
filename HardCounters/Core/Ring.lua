-- Ring: a bounded buffer over a plain table, so it can live inside SavedVariables. Pure Lua.
-- store = { cap = n, head = index of the newest item (0 when empty), n = count, items = {} }
local ADDON, ns = ...

local Ring = {}
ns.Ring = Ring

function Ring.new(cap)
  return { cap = cap, head = 0, n = 0, items = {} }
end

--- Repair or resize a store read from saved data; returns a usable store.
function Ring.adopt(store, cap)
  if type(store) ~= "table" or type(store.items) ~= "table" or type(store.head) ~= "number" or type(store.n) ~= "number" then
    return Ring.new(cap)
  end
  if store.cap ~= cap then
    local list = Ring.list(store)
    local fresh = Ring.new(cap)
    for i = math.max(1, #list - cap + 1), #list do Ring.push(fresh, list[i]) end
    return fresh
  end
  return store
end

function Ring.push(store, item)
  local head = store.head % store.cap + 1
  store.items[head] = item
  store.head = head
  if store.n < store.cap then store.n = store.n + 1 end
end

--- Items oldest first (a new table). `max` limits to the newest `max` items.
function Ring.list(store, max)
  local out, n, cap = {}, store.n, store.cap
  local take = (max and max < n) and max or n
  local first = store.head - take + 1
  for i = 0, take - 1 do
    local idx = (first + i - 1) % cap + 1
    out[#out + 1] = store.items[idx]
  end
  return out
end

function Ring.clear(store)
  store.head, store.n = 0, 0
  for k in pairs(store.items) do store.items[k] = nil end
end
