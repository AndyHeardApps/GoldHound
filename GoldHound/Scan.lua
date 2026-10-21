-- GoldHound: full auction house scans, price history and sale-rate inference.
local ADDON, ns = ...
local Scan = {}
ns.Scan = Scan

local BATCH = 150
local state = { running = false, byKey = {}, byName = {}, total = 0 }
ns.scan = state

local frame = CreateFrame("Frame")

ns.RegisterEvent("AUCTION_HOUSE_SHOW", function()
  ns.ahOpen = true
  ns.Fire("AH_OPEN")
end)

ns.RegisterEvent("AUCTION_HOUSE_CLOSED", function()
  ns.ahOpen = false
  if state.running then Scan.Abort("Auction house closed before the scan finished.") end
  ns.Fire("AH_CLOSED")
end)

function Scan.CanStart(force)
  if not ns.realm then return false, "Not ready yet." end
  if not ns.ahOpen then return false, "Open the auction house first." end
  if state.running then return false, "A scan is already running." end
  if ns.Refresh and ns.Refresh.IsRunning() then return false, "Wait for the craft refresh to finish (or /gh refresh stop)." end
  local last = ns.realm.lastScan or 0
  local wait = (last + (ns.settings.scanCooldown or 900)) - time()
  if wait > 0 and not force then
    return false, ("Next scan in %d min %d s (use /gh scan force to try anyway)."):format(math.floor(wait / 60), wait % 60)
  end
  return true
end

function Scan.IsRunning()
  return state.running
end

-- Seconds until the local scan cooldown allows another scan (0 when ready).
function Scan.CooldownRemaining()
  if not ns.realm then return 0 end
  local wait = ((ns.realm.lastScan or 0) + (ns.settings.scanCooldown or 900)) - time()
  return wait > 0 and wait or 0
end

function Scan.Status(text)
  state.status = text
  ns.Fire("SCAN_STATUS", text)
end

function Scan.Start(force)
  local ok, why = Scan.CanStart(force)
  if not ok then ns.Print(why); return false end
  state.running = true
  state.phase = "request"
  state.startedAt = GetTime()
  state.requestedAt = time()
  pcall(frame.RegisterEvent, frame, "REPLICATE_ITEM_LIST_UPDATE")
  Scan.Status("Requesting auction data...")
  ns.Print("Starting full scan...")
  C_AuctionHouse.ReplicateItems()
  C_Timer.After(120, function()
    if state.running and state.phase == "request" then
      Scan.Abort("No reply from the server. The full-scan throttle is probably active; try again in a few minutes.")
    end
  end)
  return true
end

function Scan.Abort(reason)
  state.running = false
  state.phase = nil
  frame:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
  Scan.Status(reason)
  ns.Print(reason)
  ns.Fire("SCAN_FAILED", reason)
end

-- True when the replicated list reports commodity buyouts per unit rather than
-- per stack. Detected by comparing one scan listing with a live search (see
-- Calibrate) unless /gh units overrides it.
function Scan.PerUnitBuyout()
  local mode = ns.settings.buyoutMode or "auto"
  if mode == "unit" then return true end
  if mode == "stack" then return false end
  return ns.realm and ns.realm.perUnitBuyout or false
end

-- Reads one replicated auction. Returns true when stored, false when unusable,
-- nil when the item data is not cached yet (caller retries). The buyout is
-- taken as the stack total here; StorePrices corrects commodities when the
-- server reports them per unit.
local function Ingest(i)
  local info = { C_AuctionHouse.GetReplicateItemInfo(i) }
  local itemID = info[17]
  if not itemID or itemID == 0 then return false end
  if not info[18] then
    C_Item.RequestLoadItemDataByID(itemID)
    return nil
  end
  local count = info[3] or 1
  if count <= 0 then count = 1 end
  local buyout = info[10] or 0
  local link = C_AuctionHouse.GetReplicateItemLink(i)
  local suffix = ns.SuffixFromLink(link)
  local key = ns.KeyFor(itemID, suffix)
  local listing = {
    key = key, itemID = itemID, suffix = suffix, link = link, name = info[1], icon = info[2],
    count = count, buyout = buyout, unit = buyout / count, minBid = info[8] or 0,
    minIncrement = info[9] or 0, bidAmount = info[11] or 0, owner = info[14],
    timeLeft = C_AuctionHouse.GetReplicateItemTimeLeft(i) or 0, quality = info[4],
  }
  local agg = state.byKey[key]
  if not agg then
    agg = { listings = {}, qty = 0, n = 0, itemID = itemID, name = info[1] }
    state.byKey[key] = agg
  end
  table.insert(agg.listings, listing)
  if buyout > 0 then agg.qty = agg.qty + count; agg.n = agg.n + 1 end
  if info[1] and not state.byName[info[1]] then state.byName[info[1]] = itemID end
  return true
end

local function Signature(l)
  -- %.0f rather than %d: the client's Lua rejects %d for values above 2^31,
  -- and troll listings at millions of gold exceed that in copper.
  return ("%.0f:%.0f:%d"):format(l.count or 0, math.floor(l.buyout or 0), l.timeLeft or 0)
end

-- Runs fn over a list in slices so the client never freezes, then calls done().
local function Batched(list, size, fn, status, done)
  local i, n = 1, #list
  local function step()
    if not state.running then return end
    local stop = math.min(i + size - 1, n)
    local ok, err = pcall(function()
      for j = i, stop do fn(list[j]) end
    end)
    if not ok then
      Scan.Abort("Scan failed while " .. status .. ": " .. tostring(err))
      return
    end
    i = stop + 1
    Scan.Status(("%s (%d / %d)"):format(status, math.min(i - 1, n), n))
    if i <= n then C_Timer.After(0, step) else done() end
  end
  step()
end

local function KeyList()
  local keys = {}
  for key in pairs(state.byKey) do table.insert(keys, key) end
  return keys
end

-- Step 0: find out whether commodity buyouts in the replicated list are per
-- unit or per stack, by searching one commodity whose listings make the two
-- interpretations differ and comparing the cheapest unit price. Runs once an
-- hour at most and only in automatic mode.
local calibrateFrame = CreateFrame("Frame")
local calibratedAt = nil
local SORT_PRICE = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }

local function Calibrate(done)
  if (ns.settings.buyoutMode or "auto") ~= "auto" or not ns.ahOpen or not state.running
     or (calibratedAt and GetTime() - calibratedAt < 3600) then
    done()
    return
  end
  local candidates = {}
  for _, agg in pairs(state.byKey) do
    if agg.n >= 3 and ns.IsCommodity(agg.itemID) then
      local minTotal, minUnit = math.huge, math.huge
      for _, l in ipairs(agg.listings) do
        if l.buyout > 0 then
          if l.buyout < minTotal then minTotal = l.buyout end
          local u = l.buyout / l.count
          if u < minUnit then minUnit = u end
        end
      end
      if minTotal < math.huge and minTotal > minUnit * 1.5 then
        table.insert(candidates, { itemID = agg.itemID, unit = minTotal, stack = minUnit, n = agg.n })
      end
    end
  end
  if #candidates == 0 then done() return end
  table.sort(candidates, function(a, b) return a.n > b.n end)
  Scan.Status("Checking how the server reports commodity prices...")
  local index, finished = 0, false
  local function Conclude(perUnit)
    if finished then return end
    finished = true
    calibrateFrame:UnregisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
    calibrateFrame:SetScript("OnEvent", nil)
    calibratedAt = GetTime()
    if perUnit ~= nil and ns.realm then
      local before = ns.realm.perUnitBuyout
      ns.realm.perUnitBuyout = perUnit
      -- A change of interpretation makes earlier commodity history and the
      -- sale-rate snapshot meaningless; the per-stack reading was the default.
      if before ~= perUnit and not (before == nil and perUnit == false) then
        for key, e in pairs(ns.realm.prices) do
          if ns.IsCommodity(ns.ItemIDFromKey(key)) then e.h = nil end
        end
        ns.realm.snapshot = nil
        ns.Print("The full scan reports commodity prices per %s. Prices are now read that way and earlier commodity history was cleared.", perUnit and "unit" or "stack")
      end
      ns.Debug("buyout calibration:", perUnit and "per unit" or "per stack")
    end
    done()
  end
  local TryNext
  TryNext = function()
    if finished then return end
    index = index + 1
    local cand = candidates[index]
    if not cand or index > 3 then Conclude(nil) return end
    local key = C_AuctionHouse.MakeItemKey(cand.itemID)
    local myIndex, waited = index, 0
    calibrateFrame:SetScript("OnEvent", function(_, _, itemID)
      if finished or itemID ~= cand.itemID then return end
      local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
      local u = r and r.unitPrice
      if not u then TryNext() return end
      local matchUnit = math.abs(u - cand.unit) <= math.max(1, cand.unit * 0.001)
      local matchStack = math.abs(u - cand.stack) <= math.max(1, cand.stack * 0.001)
      if matchUnit and not matchStack then Conclude(true)
      elseif matchStack and not matchUnit then Conclude(false)
      else TryNext() end
    end)
    local function Send()
      if finished or not state.running then Conclude(nil) return end
      if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        waited = waited + 1
        if waited > 25 then Conclude(nil) return end
        C_Timer.After(0.2, Send)
        return
      end
      local ok = pcall(C_AuctionHouse.SendSearchQuery, key, SORT_PRICE, false)
      if not ok then Conclude(nil) return end
      C_Timer.After(5, function() if not finished and index == myIndex then TryNext() end end)
    end
    Send()
  end
  pcall(calibrateFrame.RegisterEvent, calibrateFrame, "COMMODITY_SEARCH_RESULTS_UPDATED")
  TryNext()
end

-- Step 1: sort listings and store the cheapest price and history per item.
local function StorePrices(done)
  local now = state.scanTime
  local prices = ns.realm.prices
  local perUnit = Scan.PerUnitBuyout()
  state.items = 0
  Batched(KeyList(), 400, function(key)
    local agg = state.byKey[key]
    if perUnit and ns.IsCommodity(agg.itemID) then
      for _, l in ipairs(agg.listings) do
        l.unit = l.buyout
        l.buyout = l.unit * l.count
      end
    end
    table.sort(agg.listings, function(a, b)
      if a.buyout > 0 and b.buyout > 0 then return a.unit < b.unit end
      return a.buyout > 0 and b.buyout == 0
    end)
    if agg.n > 0 then
      local s = ns.Pricing.ListingStats(agg.listings)
      local e = prices[key] or {}
      e.m, e.q, e.n, e.t = s.m, agg.qty, agg.n, now
      ns.Pricing.RecordHistory(e, s, now)
      prices[key] = e
      state.items = state.items + 1
    end
  end, "Storing prices", done)
end

-- Step 2: compare the previous scan's listings with this one. A listing that
-- vanished before its time-left band could have expired counts as a sale.
local function InferSales(done)
  local now = state.scanTime
  local snap = ns.realm.snapshot
  local sales = ns.realm.sales
  if not (snap and snap.t and snap.keys) then done() return end
  local elapsed = now - snap.t
  if elapsed <= 0 or elapsed >= 3 * 86400 then done() return end
  local bandMin = {}
  for band = 0, 3 do bandMin[band] = ns.BandMinSeconds(band) end
  local keys = {}
  for key in pairs(snap.keys) do table.insert(keys, key) end
  Batched(keys, 300, function(key)
    local packed = snap.keys[key]
    local current = {}
    local agg = state.byKey[key]
    if agg then
      for _, l in ipairs(agg.listings) do
        local sig = Signature(l)
        current[sig] = (current[sig] or 0) + 1
      end
    end
    local soldUnits, observedHours = 0, 0
    for sig in packed:gmatch("[^;]+") do
      local count, _, band = sig:match("^(%d+):(%d+):(%d+)$")
      count, band = tonumber(count), tonumber(band)
      if count then
        local minSeconds = bandMin[band] or 0
        observedHours = observedHours + math.min(elapsed, minSeconds) / 3600
        if current[sig] and current[sig] > 0 then
          current[sig] = current[sig] - 1
        elseif elapsed < minSeconds then
          soldUnits = soldUnits + count
        end
      end
    end
    if observedHours > 0 then
      local s = sales[key] or { u = 0, hrs = 0 }
      s.u = (s.u or 0) + soldUnits
      s.hrs = (s.hrs or 0) + observedHours
      s.t = now
      if s.hrs > 24 * 14 then -- decay so the rate tracks the current market
        local f = (24 * 14) / s.hrs
        s.u, s.hrs = s.u * f, s.hrs * f
      end
      sales[key] = s
    end
  end, "Inferring sales", done)
end

-- Step 3: remember this scan's listings for the next comparison.
local function SaveSnapshot(done)
  local keys = {}
  Batched(KeyList(), 400, function(key)
    local parts = {}
    for _, l in ipairs(state.byKey[key].listings) do table.insert(parts, Signature(l)) end
    keys[key] = table.concat(parts, ";")
  end, "Saving snapshot", function()
    ns.realm.snapshot = { t = state.scanTime, keys = keys }
    done()
  end)
end

local function Prune()
  local cutoff = state.scanTime - (ns.settings.pruneDays or 30) * 86400
  local prices = ns.realm.prices
  for key, e in pairs(prices) do
    if (e.t or 0) < cutoff then prices[key] = nil; ns.realm.sales[key] = nil end
  end
end

local function Finish()
  state.scanTime = time()
  state.phase = "finish"
  Calibrate(function()
    StorePrices(function()
      InferSales(function()
        SaveSnapshot(function()
          local ok, err = pcall(Prune)
          if not ok then ns.Debug("prune failed", err) end
          ns.realm.lastScan = state.scanTime
          state.running = false
          state.phase = nil
          local seconds = math.floor(GetTime() - state.startedAt)
          Scan.Status(("Scan done: %d auctions, %d items in %ds"):format(state.total, state.items or 0, seconds))
          ns.Print("Scan complete: %d auctions across %d items in %d seconds.", state.total, state.items or 0, seconds)
          ns.Fire("SCAN_COMPLETE")
        end)
      end)
    end)
  end)
end

local function Retry(attempt)
  if not state.running then return end
  if #state.pending == 0 or attempt > 5 then
    if #state.pending > 0 then ns.Debug("Skipped auctions without item data:", #state.pending) end
    Finish()
    return
  end
  Scan.Status(("Waiting for item data (%d left)..."):format(#state.pending))
  C_Timer.After(1.0, function()
    if not state.running then return end
    local still = {}
    for _, i in ipairs(state.pending) do
      if Ingest(i) == nil then table.insert(still, i) end
    end
    state.pending = still
    Retry(attempt + 1)
  end)
end

local function Process(n)
  state.phase = "process"
  state.total = n
  state.index = 0
  state.pending = {}
  state.byKey = {}
  state.byName = {}
  local function step()
    if not state.running then return end
    local stop = math.min(state.index + BATCH, n)
    local ok, err = pcall(function()
      for i = state.index, stop - 1 do
        if Ingest(i) == nil then table.insert(state.pending, i) end
      end
    end)
    if not ok then
      Scan.Abort("Scan failed while reading auctions: " .. tostring(err))
      return
    end
    state.index = stop
    Scan.Status(("Processing %d / %d"):format(stop, n))
    if stop < n then
      C_Timer.After(0, step)
    else
      Retry(1)
    end
  end
  step()
end

frame:SetScript("OnEvent", function(_, event)
  if event ~= "REPLICATE_ITEM_LIST_UPDATE" or not state.running then return end
  frame:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
  local n = C_AuctionHouse.GetNumReplicateItems() or 0
  if n == 0 then
    Scan.Abort("The server returned no auctions. The full-scan throttle is probably active; try again later.")
    return
  end
  Process(n)
end)

-- Removes a listing you just bought so it stops showing as an opportunity.
ns.On("LISTING_BOUGHT", function(listing, quantity)
  local agg = listing and state.byKey[listing.key]
  if not agg then return end
  for i, l in ipairs(agg.listings) do
    if l == listing then
      if quantity and quantity < l.count then
        l.count = l.count - quantity
        l.buyout = l.unit * l.count
        agg.qty = agg.qty - quantity
      else
        table.remove(agg.listings, i)
        agg.qty = agg.qty - l.count
        agg.n = agg.n - 1
      end
      break
    end
  end
  ns.Analysis.Invalidate()
end)
