-- GoldHound: targeted price refresh for crafting. Searches the auction house for
-- every item a known recipe makes or consumes, one item key at a time, and
-- replaces those items' listings in the scan data. Item searches are not
-- subject to the 15-minute full-scan throttle, so craft profits can be
-- rechecked whenever the auction house is open.
local ADDON, ns = ...
local Refresh = {}
ns.Refresh = Refresh

local SORT = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
local EVENTS = {
  "ITEM_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_SHOW_ERROR",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", "AUCTION_HOUSE_CLOSED",
}
local MAX_SENDS = 3        -- attempts per item before it is skipped
local MAX_PAGES = 3        -- result pages fetched per item (cheapest first)
local REPLY_TIMEOUT = 6    -- seconds to wait for the server before resending
local INVALIDATE_EVERY = 15 -- refreshed items between analysis refreshes

local frame = CreateFrame("Frame")
local state = nil

function Refresh.IsRunning()
  return state ~= nil
end

function Refresh.CooldownRemaining()
  if not ns.realm then return 0 end
  local wait = ((ns.realm.lastRefresh or 0) + (ns.settings.craftCooldown or 120)) - time()
  return wait > 0 and wait or 0
end

function Refresh.CanStart(force)
  if not ns.realm then return false, "Not ready yet." end
  if not ns.ahOpen then return false, "Open the auction house first." end
  if state then return false, "A craft refresh is already running." end
  if ns.Scan.IsRunning() then return false, "Wait for the full scan to finish." end
  if ns.Buy.IsBusy() then return false, "Wait for the purchase to finish." end
  local wait = Refresh.CooldownRemaining()
  if wait > 0 and not force then
    return false, ("Next craft refresh in %d min %d s (use /gh refresh force to try anyway)."):format(math.floor(wait / 60), wait % 60)
  end
  return true
end

local function Status(text)
  ns.Fire("SCAN_STATUS", text)
end

-- Every item a recipe your characters know produces or consumes. Products come
-- first so the Crafting tab improves early. Reagents with an unlimited vendor
-- price are skipped: the vendor sets their price.
function Refresh.Targets()
  local seen, list = {}, {}
  local function Add(itemID, priority)
    if not itemID or seen[itemID] then return end
    seen[itemID] = true
    if priority > 1 and ns.Pricing.VendorBuy(itemID) then return end
    table.insert(list, { id = itemID, p = priority })
  end
  for _, r in pairs(ns.db.recipes or {}) do
    if r.out and r.complete and ns.Chars.WhoKnows(r) then
      Add(r.out, 1)
      for _, reagent in ipairs(r.reagents or {}) do Add(reagent[1], 2) end
    end
  end
  table.sort(list, function(a, b)
    if a.p ~= b.p then return a.p < b.p end
    return a.id < b.id
  end)
  local out = {}
  for _, e in ipairs(list) do table.insert(out, e.id) end
  return out
end

local function Finish(text)
  if state and state.timer then state.timer:Cancel() end
  state = nil
  for _, e in ipairs(EVENTS) do frame:UnregisterEvent(e) end
  Status(text)
  ns.Print(text)
  ns.Analysis.Invalidate()
end

function Refresh.Abort(reason)
  if not state then return end
  Finish(reason or "Craft refresh stopped.")
  ns.Fire("REFRESH_FAILED", reason)
end

-------------------------------------------------------------------------------
-- Storing results in the same shape the full scan uses, so every analysis and
-- the Buy buttons work on refreshed listings without special cases.
-------------------------------------------------------------------------------
local function BandFromSeconds(seconds)
  if type(seconds) ~= "number" then return 3 end
  for band = 3, 1, -1 do
    if seconds >= ns.BandMinSeconds(band) then return band end
  end
  return 0
end

local function OwnerName(r)
  if r.containsOwnerItem then return ns.charName end
  local owners = r.owners
  if type(owners) == "table" and type(owners[1]) == "string" and owners[1] ~= "" then return owners[1] end
  return nil
end

local function SortListings(listings)
  table.sort(listings, function(a, b)
    if a.buyout > 0 and b.buyout > 0 then return a.unit < b.unit end
    return a.buyout > 0 and b.buyout == 0
  end)
end

-- Replaces the listings for one price key and updates the stored price.
local function StoreKey(key, itemID, listings, now)
  SortListings(listings)
  local info = ns.ItemInfo(itemID)
  local agg = { listings = listings, qty = 0, n = 0, itemID = itemID, name = info and info.name or (listings[1] and listings[1].name), refreshed = now, t = now }
  for _, l in ipairs(listings) do
    if l.buyout > 0 then agg.qty = agg.qty + l.count; agg.n = agg.n + 1 end
  end
  ns.scan.byKey[key] = agg
  if agg.name and not ns.scan.byName[agg.name] then ns.scan.byName[agg.name] = itemID end
  ns.Scan.SaveKey(key)
  local prices = ns.realm.prices
  local e = prices[key]
  if agg.n > 0 then
    e = e or {}
    local s = ns.Pricing.ListingStats(agg.listings)
    e.m, e.f, e.q, e.n, e.t = s.m, s.f, agg.qty, agg.n, now
    -- Add a price history point unless one was recorded moments ago.
    local lastPoint = e.h and e.h[#e.h]
    if not lastPoint or now - (lastPoint.t or 0) >= 300 then ns.Pricing.RecordHistory(e, s, now) end
    prices[key] = e
  elseif e then
    -- Nothing listed right now. Keep the price history; the quantity is what changed.
    e.q, e.n, e.t = 0, 0, now
  end
end

local function Listing(itemID, key, suffix, info, link, count, buyout, extra)
  count = (count and count > 0) and count or 1
  buyout = buyout or 0
  local l = {
    key = key, itemID = itemID, suffix = suffix, link = link or (info and info.link), name = info and info.name, icon = info and info.icon,
    count = count, buyout = buyout, unit = buyout / count, minBid = 0, minIncrement = 0, bidAmount = 0,
    timeLeft = 3, quality = info and info.quality, refreshed = true,
  }
  for k, v in pairs(extra or {}) do l[k] = v end
  return l
end

local function StoreCommodity(itemID)
  local now = time()
  local key = ns.KeyFor(itemID, 0)
  local info = ns.ItemInfo(itemID)
  local listings = {}
  local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
  for i = 1, n do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice and r.unitPrice > 0 then
      table.insert(listings, Listing(itemID, key, 0, info, nil, r.quantity, r.unitPrice * (r.quantity or 1), {
        owner = OwnerName(r), timeLeft = BandFromSeconds(r.timeLeftSeconds), auctionID = r.auctionID,
      }))
    end
  end
  StoreKey(key, itemID, listings, now)
  return #listings
end

local function StoreItem(itemID, itemKey)
  local now = time()
  local info = ns.ItemInfo(itemID)
  local byKey = { [ns.KeyFor(itemID, 0)] = {} }
  local n = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
  local total = 0
  for i = 1, n do
    local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    if r then
      local suffix = ns.SuffixFromLink(r.itemLink)
      if suffix == 0 and r.itemKey and r.itemKey.itemSuffix then suffix = math.abs(r.itemKey.itemSuffix) end
      local key = ns.KeyFor(itemID, suffix)
      byKey[key] = byKey[key] or {}
      local minBid = r.minBid or 0
      table.insert(byKey[key], Listing(itemID, key, suffix, info, r.itemLink, r.quantity, r.buyoutAmount, {
        minBid = minBid, minIncrement = math.max(1, math.floor(minBid * 0.05)), bidAmount = r.bidAmount or 0,
        owner = OwnerName(r), timeLeft = r.timeLeft or 3, auctionID = r.auctionID,
      }))
      total = total + 1
    end
  end
  for key, listings in pairs(byKey) do StoreKey(key, itemID, listings, now) end
  return total
end

-------------------------------------------------------------------------------
-- Driving the searches one item at a time.
-------------------------------------------------------------------------------
local Next

local function Progress(text)
  if not state then return end
  Status(("Refreshing %s (%d / %d): %s"):format(state.label, state.index, #state.items, text))
end

local function ArmTimeout()
  if not state then return end
  if state.timer then state.timer:Cancel() end
  local s = state
  s.timer = C_Timer.NewTimer(REPLY_TIMEOUT, function()
    if state ~= s then return end
    if s.sends < MAX_SENDS then
      ns.Debug("Refresh resend for item", s.current, "after no reply")
      s.resend()
    else
      s.failed = s.failed + 1
      Next()
    end
  end)
end

local function Send(fn)
  if not state then return end
  state.sends = state.sends + 1
  state.resend = function()
    if not state then return end
    state.sends = state.sends + 1
    fn()
    ArmTimeout()
  end
  fn()
  ArmTimeout()
end

local function Query(itemID, waited)
  local s = state
  if not s or s.items[s.index] ~= itemID then return end
  waited = waited or 0
  local key = s.key
  if not C_AuctionHouse.GetItemKeyInfo(key) and waited < 10 then
    C_Timer.After(0.3, function() Query(itemID, waited + 1) end)
    return
  end
  if not C_AuctionHouse.IsThrottledMessageSystemReady() then
    if waited > 100 then
      Finish("Craft refresh stopped: the auction house stayed busy. Try again in a minute.")
      return
    end
    C_Timer.After(0.2, function() Query(itemID, waited + 1) end)
    return
  end
  Send(function() C_AuctionHouse.SendSearchQuery(key, SORT, false) end)
end

local function Done()
  local s = state
  local seconds = math.floor(GetTime() - s.startedAt)
  if s.full then ns.realm.lastRefresh = time() end
  Finish(("Refreshed %s: %d item%s checked in %ds%s."):format(s.label, s.updated, s.updated == 1 and "" or "s", seconds, s.failed > 0 and (", %d skipped"):format(s.failed) or ""))
  ns.Fire("REFRESH_COMPLETE")
end

Next = function()
  local s = state
  if not s then return end
  if s.timer then s.timer:Cancel(); s.timer = nil end
  s.index = s.index + 1
  if s.index > #s.items then Done() return end
  local itemID = s.items[s.index]
  s.current = itemID
  s.sends = 0
  s.pages = 0
  s.key = C_AuctionHouse.MakeItemKey(itemID)
  s.commodity = ns.IsCommodity(itemID)
  local info = ns.ItemInfo(itemID)
  Progress(info and info.name or ("item " .. itemID))
  Query(itemID, 0)
end

local function Stored()
  local s = state
  s.updated = s.updated + 1
  if s.updated % INVALIDATE_EVERY == 0 then ns.Analysis.Invalidate() end
  Next()
end

local function Begin(items, label, full)
  state = { items = items, label = label, full = full, index = 0, updated = 0, failed = 0, sends = 0, startedAt = GetTime() }
  for _, e in ipairs(EVENTS) do pcall(frame.RegisterEvent, frame, e) end
  if #items > 1 then ns.Print("Refreshing prices for %d items (%s)...", #items, label) end
  Next()
  return true
end

-- Everything your known recipes make or use; honours the cooldown unless forced.
function Refresh.Start(force)
  local ok, why = Refresh.CanStart(force)
  if not ok then ns.Print(why); return false end
  local items = Refresh.Targets()
  if #items == 0 then
    ns.Print("No recipes recorded yet. Open each profession window once, then refresh.")
    return false
  end
  return Begin(items, "crafting items", true)
end

-- A specific list of item IDs, for example one row of the window. No cooldown.
function Refresh.Items(items, label)
  local ok, why = Refresh.CanStart(true)
  if not ok then ns.Print(why); return false end
  local list, seen = {}, {}
  for _, id in ipairs(items or {}) do
    id = tonumber(id)
    if id and not seen[id] then seen[id] = true; table.insert(list, id) end
  end
  if #list == 0 then ns.Print("Nothing to refresh for that row."); return false end
  return Begin(list, label or "item", false)
end

-- The product of a recipe, its reagents, and the reagents of any intermediate
-- you would craft yourself for it.
function Refresh.RecipeItems(recipeID)
  local seen, out = {}, {}
  local function Add(id)
    if id and not seen[id] then seen[id] = true; table.insert(out, id) end
  end
  local function Walk(id, depth)
    local r = ns.db.recipes[id]
    if not r or depth > 3 then return end
    Add(r.out)
    for _, reagent in ipairs(r.reagents or {}) do Add(reagent[1]) end
    local cost = ns.Pricing.CraftCost(id)
    for _, part in ipairs(cost and cost.reagents or {}) do
      if part.source == "craft" and part.detail then Walk(part.detail, depth + 1) end
    end
  end
  Walk(recipeID, 0)
  return out
end

frame:SetScript("OnEvent", function(_, event, arg1)
  local s = state
  if not s then return end
  if event == "AUCTION_HOUSE_CLOSED" then
    Refresh.Abort("Auction house closed before the craft refresh finished.")
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    if s.sends < MAX_SENDS and s.resend then
      ns.Debug("Refresh resend for item", s.current, "after a dropped request")
      s.resend()
    else
      s.failed = s.failed + 1
      Next()
    end
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
    ns.Debug("Refresh error", arg1, "for item", s.current)
    s.failed = s.failed + 1
    Next()
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    if arg1 ~= s.current or s.commodity == false then return end
    local full = C_AuctionHouse.HasFullCommoditySearchResults(s.current)
    if not full and s.pages < MAX_PAGES and C_AuctionHouse.IsThrottledMessageSystemReady() then
      s.pages = s.pages + 1
      C_AuctionHouse.RequestMoreCommoditySearchResults(s.current)
      ArmTimeout()
      return
    end
    StoreCommodity(s.current)
    Stored()
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    if s.commodity == true or type(arg1) ~= "table" or arg1.itemID ~= s.current then return end
    local full = C_AuctionHouse.HasFullItemSearchResults(arg1)
    if not full and s.pages < MAX_PAGES and C_AuctionHouse.IsThrottledMessageSystemReady() then
      s.pages = s.pages + 1
      C_AuctionHouse.RequestMoreItemSearchResults(arg1)
      ArmTimeout()
      return
    end
    StoreItem(s.current, arg1)
    Stored()
  end
end)
