-- GoldHound: buying, bidding and commodity purchases through the modern AH API.
-- Every purchase is confirmed by a popup click so the final call runs from a
-- hardware event, which the client requires.
local ADDON, ns = ...
local Buy = {}
ns.Buy = Buy

local SORT_PRICE = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
local SORT_BUYOUT = { { sortOrder = Enum.AuctionHouseSortOrder.Buyout, reverseSort = false } }
local TOLERANCE = 1.0001
local UNIT_SLACK = 1.10     -- commodities: only units up to this much over the scanned price are bought
local ITEM_SLACK = 1.50     -- items: the cheapest listing is offered when within this much of the scanned price
local QUOTE_CANCEL = 2.0    -- a direct quote above this multiple of the scanned price is refused outright
local EVENTS = {
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_FAILURE", "ITEM_SEARCH_RESULTS_UPDATED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
  "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_PURCHASE_COMPLETED",
  "AUCTION_HOUSE_SHOW_ERROR", "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_NEW_BID_RECEIVED",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
}
local MAX_SENDS = 3

local frame = CreateFrame("Frame")
local active = nil

StaticPopupDialogs["GOLDHOUND_CONFIRM"] = {
  text = "%s",
  button1 = "Buy",
  button2 = CANCEL,
  OnAccept = function(_, data) if data and data.accept then data.accept() end end,
  OnCancel = function(_, data) if data and data.cancel then data.cancel() end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function Status(text)
  ns.Fire("BUY_STATUS", text)
end

local function Finish(msg)
  if active and active.timer then active.timer:Cancel() end
  active = nil
  for _, e in ipairs(EVENTS) do frame:UnregisterEvent(e) end
  if msg then ns.Print(msg) end
  Status(nil)
end

-- Sends a query and remembers it so it can be resent if the server drops it.
local function Send(state, phase, fn)
  state.phase = phase
  state.lastSend = fn
  state.sends = (state.sends or 0) + 1
  state.sentAt = GetTime()
  ns.Debug("Buy send", phase, "attempt", state.sends)
  fn()
end

local function Resend(state, why)
  if state.lastSend and (state.sends or 0) < MAX_SENDS then
    ns.Debug("Buy resend after", why)
    Status(("%s (retrying after %s)..."):format(state.phase or "Working", why))
    state.sends = state.sends + 1
    state.sentAt = GetTime()
    state.lastSend()
    return true
  end
  return false
end

local function Timeout(seconds, state)
  if state.timer then state.timer:Cancel() end
  state.timer = C_Timer.NewTimer(seconds, function()
    if active ~= state then return end
    if state.lastSend and (state.sends or 0) < MAX_SENDS then
      Resend(state, "no reply")
      Timeout(seconds, state)
    else
      Finish(("Timed out during '%s' after %d attempts. The auction house sometimes ignores searches for a minute after a full scan; try again shortly."):format(state.phase or "purchase", state.sends or 1))
    end
  end)
end

local function Begin(state)
  if active then ns.Print("A purchase is already in progress."); return false end
  if ns.Refresh and ns.Refresh.IsRunning() then ns.Print("Wait for the craft refresh to finish (or /gh refresh stop)."); return false end
  if not ns.ahOpen then ns.Print("Open the auction house first."); return false end
  if not C_AuctionHouse.IsThrottledMessageSystemReady() then
    ns.Print("The auction house is still busy with the last request; click again in a second.")
    return false
  end
  active = state
  for _, e in ipairs(EVENTS) do pcall(frame.RegisterEvent, frame, e) end
  Timeout(8, state)
  return true
end

local function WhenReady(state, fn, tries)
  if active ~= state then return end
  tries = tries or 0
  if C_AuctionHouse.IsThrottledMessageSystemReady() then
    fn()
  elseif tries > 60 then
    Finish("The auction house is busy; try again in a moment.")
  else
    C_Timer.After(0.2, function() WhenReady(state, fn, tries + 1) end)
  end
end

local function SameKey(a, b)
  return a and b and a.itemID == b.itemID and (a.itemSuffix or 0) == (b.itemSuffix or 0)
    and (a.itemLevel or 0) == (b.itemLevel or 0) and (a.battlePetSpeciesID or 0) == (b.battlePetSpeciesID or 0)
end

local function Confirm(text, accept, cancel)
  StaticPopup_Show("GOLDHOUND_CONFIRM", text, nil, { accept = accept, cancel = cancel })
end

-- Describes how the actual price compares with what the scan expected, and
-- what that does to the profit of the opportunity or plan behind the purchase.
local function PriceChangeText(s, actualUnit, actualTotal)
  local lines = {}
  local expected = s.expectedUnit
  if expected and expected > 0 then
    local change = (actualUnit - expected) / expected
    if math.abs(change) >= 0.005 then
      local colour = change > 0 and "|cffff8844" or "|cff33ff33"
      table.insert(lines, ("%sPrice changed %s%d%% since the scan|r (expected %s each)."):format(colour, change > 0 and "+" or "", change * 100, ns.Money(expected)))
    end
  end
  if s.profitAt then
    local ok, newProfit = pcall(s.profitAt, actualUnit, actualTotal)
    if ok and newProfit then
      local base = s.baseProfit
      local minProfit = ns.settings.minProfit or 0
      if newProfit < 0 then
        table.insert(lines, ("|cffff4444WARNING: no longer profitable. Expected loss %s|r%s."):format(ns.Money(-newProfit), base and (" (was +" .. ns.Money(base) .. ")") or ""))
      elseif newProfit < minProfit then
        table.insert(lines, ("|cffff4444WARNING: profit now %s, below your minimum of %s|r%s."):format(ns.Money(newProfit), ns.Money(minProfit), base and (" (was " .. ns.Money(base) .. ")") or ""))
      elseif base and math.abs(newProfit - base) >= 1 then
        table.insert(lines, ("Profit now %s (was %s)."):format(ns.Money(newProfit), ns.Money(base)))
      else
        table.insert(lines, ("Profit %s."):format(ns.Money(newProfit)))
      end
    end
  end
  if #lines == 0 then return "" end
  return "\n\n" .. table.concat(lines, "\n")
end

-------------------------------------------------------------------------------
-- Commodities
-------------------------------------------------------------------------------
local function SearchKey(s, key, phase, sorts, tries)
  if active ~= s then return end
  tries = tries or 0
  if C_AuctionHouse.GetItemKeyInfo(key) or tries > 15 then
    WhenReady(s, function()
      Send(s, phase, function() C_AuctionHouse.SendSearchQuery(key, sorts, false) end)
    end)
  else
    C_Timer.After(0.3, function() SearchKey(s, key, phase, sorts, tries + 1) end)
  end
end

local function StartCommoditySearch(state)
  Status("Searching for " .. state.name .. "...")
  SearchKey(state, C_AuctionHouse.MakeItemKey(state.itemID), "searching for " .. state.name, SORT_PRICE)
end

-- Asks the server for a quote straight away, inside the click that started the
-- purchase. The quote reply carries the real price, which is confirmed by popup.
local function StartCommodityQuote(state, expectedUnit)
  state.quoted = true
  state.direct = true
  state.sends = 0
  Status("Requesting a price quote for " .. state.name .. "...")
  Send(state, "price quote", function() C_AuctionHouse.StartCommoditiesPurchase(state.itemID, state.quantity, math.ceil(expectedUnit)) end)
end

-- opts: expectedUnit (price the scan saw), baseProfit, profitAt(unit, total) -> profit
function Buy.Commodity(itemID, quantity, maxUnit, name, opts)
  opts = opts or {}
  local state = { kind = "commodity", itemID = itemID, quantity = quantity, maxUnit = maxUnit, name = name or ("item " .. itemID),
                  expectedUnit = opts.expectedUnit or maxUnit, baseProfit = opts.baseProfit, profitAt = opts.profitAt }
  if not Begin(state) then return end
  StartCommodityQuote(state, state.expectedUnit)
end

local function OnCommodityResults(s, itemID)
  if itemID ~= s.itemID or s.quoted then return end
  local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID)
  local qty, total = 0, 0
  for i = 1, n do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if not r then break end
    if r.unitPrice > s.maxUnit * UNIT_SLACK then break end
    if not r.containsOwnerItem then
      local take = math.min(r.quantity, s.quantity - qty)
      qty = qty + take
      total = total + take * r.unitPrice
    end
    if qty >= s.quantity then break end
  end
  if qty == 0 then
    Finish(("No %s left at or below %s each."):format(s.name, ns.Money(s.maxUnit)))
    return
  end
  local short = qty < s.quantity
  s.quoted = true
  s.quantity = qty
  s.expectedTotal = total
  local expectedUnit = math.ceil(total / qty)
  if s.timer then s.timer:Cancel() end
  Status("Waiting for confirmation...")
  Confirm(("%d x %s available for about %s (%s each).%s Request the purchase?"):format(qty, s.name, ns.Money(total), ns.Money(expectedUnit),
      short and (" |cffff8844Only %d of the %d units expected are still near the scanned price.|r"):format(qty, s.quantity) or ""),
    function()
      if active ~= s then return end
      -- Forever's client passes the expected unit price as a third argument.
      s.sends = 0
      Send(s, "price quote", function() C_AuctionHouse.StartCommoditiesPurchase(itemID, qty, expectedUnit) end)
      Timeout(8, s)
    end,
    function() if active == s then Finish("Purchase cancelled.") end end)
end

local function OnCommodityQuote(s, unitPrice, totalPrice)
  if unitPrice > s.maxUnit * QUOTE_CANCEL then
    C_AuctionHouse.CancelCommoditiesPurchase()
    Finish(("Price is now %s each, more than double the expected %s; purchase cancelled."):format(ns.Money(unitPrice), ns.Money(s.maxUnit)))
    return
  end
  if s.timer then s.timer:Cancel() end
  Status("Waiting for confirmation...")
  local text = ("Buy %d x %s for %s (%s each)?"):format(s.quantity, s.name, ns.Money(totalPrice), ns.Money(unitPrice)) .. PriceChangeText(s, unitPrice, totalPrice)
  Confirm(text,
    function()
      if active ~= s then return end
      s.phase, s.lastSend, s.sends = "confirming purchase", nil, MAX_SENDS
      Timeout(15, s)
      Status("Buying...")
      C_AuctionHouse.ConfirmCommoditiesPurchase(s.itemID, s.quantity)
    end,
    function()
      if active ~= s then return end
      C_AuctionHouse.CancelCommoditiesPurchase()
      Finish("Purchase cancelled.")
    end)
end

-------------------------------------------------------------------------------
-- Items (non-stackable): browse by exact name, then search each matching key.
-------------------------------------------------------------------------------
local function NextKey(s)
  s.keyIndex = (s.keyIndex or 0) + 1
  if s.keyIndex > #s.keys then
    s.choose(s)
    return
  end
  Status(("Searching listings (%d/%d)..."):format(s.keyIndex, #s.keys))
  s.sends = 0
  SearchKey(s, s.keys[s.keyIndex], ("searching listings %d/%d"):format(s.keyIndex, #s.keys), SORT_BUYOUT)
end

local function StartItemSearch(state)
  state.keys, state.candidates = {}, {}
  Status("Searching for " .. state.name .. "...")
  WhenReady(state, function()
    Send(state, "browsing for " .. state.name, function()
      C_AuctionHouse.SendBrowseQuery({ searchString = state.name, sorts = SORT_PRICE, filters = { Enum.AuctionHouseFilter.ExactMatch } })
    end)
  end)
end

local function OnBrowseResults(s)
  if s.browsed then return end
  s.browsed = true
  local results = C_AuctionHouse.GetBrowseResults() or {}
  for _, r in ipairs(results) do
    local k = r.itemKey
    if k and k.itemID == s.itemID and (s.suffix == 0 or math.abs(k.itemSuffix or 0) == s.suffix) then
      table.insert(s.keys, k)
    end
  end
  if #s.keys == 0 then
    Finish(("No auctions of %s were found; it may have sold."):format(s.name))
    return
  end
  NextKey(s)
end

local function OnItemResults(s, itemKey)
  local cur = s.keys[s.keyIndex]
  if not cur or not SameKey(itemKey, cur) then return end
  if not C_AuctionHouse.HasFullItemSearchResults(cur) then
    C_AuctionHouse.RequestMoreItemSearchResults(cur)
    return
  end
  local n = C_AuctionHouse.GetNumItemSearchResults(cur)
  for i = 1, n do
    local r = C_AuctionHouse.GetItemSearchResultInfo(cur, i)
    if r and not r.containsOwnerItem then
      table.insert(s.candidates, {
        auctionID = r.auctionID, buyout = r.buyoutAmount or 0, minBid = r.minBid or 0, bidAmount = r.bidAmount or 0,
        quantity = r.quantity or 1, link = r.itemLink, timeLeft = r.timeLeft,
      })
    end
  end
  NextKey(s)
end

local function ChooseBuyout(s)
  local best
  for _, c in ipairs(s.candidates) do
    if c.buyout > 0 and c.buyout / c.quantity <= s.maxUnit * ITEM_SLACK then
      if not best or c.buyout < best.buyout then best = c end
    end
  end
  if not best then
    Finish(("%s is no longer listed anywhere near %s."):format(s.name, ns.Money(s.maxUnit)))
    return
  end
  if s.timer then s.timer:Cancel() end
  Status("Waiting for confirmation...")
  local unit = best.buyout / math.max(1, best.quantity)
  local text = ("Buy %s%s for %s?"):format(best.link or s.name, best.quantity > 1 and (" x" .. best.quantity) or "", ns.Money(best.buyout)) .. PriceChangeText(s, unit, best.buyout)
  Confirm(text,
    function()
      if active ~= s then return end
      s.phase, s.lastSend, s.sends = "buying", nil, MAX_SENDS
      Timeout(15, s)
      Status("Buying...")
      s.pendingAuction = best.auctionID
      C_AuctionHouse.PlaceBid(best.auctionID, best.buyout)
    end,
    function() if active == s then Finish("Purchase cancelled.") end end)
end

local function ChooseBid(s)
  local best
  for _, c in ipairs(s.candidates) do
    local required = (c.bidAmount > 0) and (c.bidAmount + math.max(s.listing.minIncrement or 1, 1)) or c.minBid
    if required > 0 and required <= s.maxBid * TOLERANCE and (c.timeLeft == nil or c.timeLeft <= 1) then
      c.required = required
      if not best or required < best.required then best = c end
    end
  end
  if not best then
    Finish(("No auction of %s still accepts a bid of %s."):format(s.name, ns.Money(s.maxBid)))
    return
  end
  if s.timer then s.timer:Cancel() end
  Status("Waiting for confirmation...")
  Confirm(("Bid %s on %s%s? You win only if nobody outbids you before it ends."):format(ns.Money(best.required), best.link or s.name, best.quantity > 1 and (" x" .. best.quantity) or ""),
    function()
      if active ~= s then return end
      C_AuctionHouse.PlaceBid(best.auctionID, best.required)
      ns.Fire("LISTING_BOUGHT", s.listing)
      Finish(("Bid of %s placed on %s."):format(ns.Money(best.required), s.name))
    end,
    function() if active == s then Finish("Bid cancelled.") end end)
end

-- Buys a listing found in the last scan at its scanned unit price or less.
function Buy.Listing(listing, opts)
  if not listing then return end
  opts = opts or {}
  if ns.IsCommodity(listing.itemID) then
    local s = { kind = "commodity", itemID = listing.itemID, quantity = listing.count, maxUnit = listing.unit, name = listing.name or ("item " .. listing.itemID), listing = listing,
                expectedUnit = listing.unit, baseProfit = opts.baseProfit, profitAt = opts.profitAt }
    if not Begin(s) then return end
    StartCommodityQuote(s, listing.unit)
    return
  end
  local s = { kind = "item", itemID = listing.itemID, suffix = listing.suffix or 0, maxUnit = listing.unit, name = listing.name or "", listing = listing, choose = ChooseBuyout,
              expectedUnit = listing.unit, baseProfit = opts.baseProfit, profitAt = opts.profitAt }
  if s.name == "" then ns.Print("That listing has no name yet; try again in a moment."); return end
  if not Begin(s) then return end
  StartItemSearch(s)
end

-- Places a bid on an auction found in the last scan.
function Buy.Bid(listing, amount)
  if not listing then return end
  local s = { kind = "bid", itemID = listing.itemID, suffix = listing.suffix or 0, maxBid = amount, name = listing.name or "", listing = listing, choose = ChooseBid }
  if s.name == "" then ns.Print("That listing has no name yet; try again in a moment."); return end
  if not Begin(s) then return end
  StartItemSearch(s)
end

function Buy.IsBusy()
  return active ~= nil
end

frame:SetScript("OnEvent", function(_, event, ...)
  local s = active
  if not s then return end
  ns.Debug("Buy event", event, ...)
  if event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    if not Resend(s, "the server dropped the request") then Finish("The auction house dropped the request repeatedly; try again in a minute.") end
  elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
    -- nothing to do; queued sends go out through WhenReady
  elseif event == "AUCTION_HOUSE_CLOSED" then
    Finish("Auction house closed.")
  elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
    Finish("The auction house search failed; try again.")
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
    local err = ...
    Finish("Auction house error " .. tostring(err) .. ".")
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" and (s.kind == "item" or s.kind == "bid") then
    OnBrowseResults(s)
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" and (s.kind == "item" or s.kind == "bid") then
    OnItemResults(s, ...)
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" and s.kind == "commodity" then
    OnCommodityResults(s, ...)
  elseif event == "COMMODITY_PRICE_UPDATED" and s.kind == "commodity" then
    OnCommodityQuote(s, ...)
  elseif event == "COMMODITY_PRICE_UNAVAILABLE" and s.kind == "commodity" then
    C_AuctionHouse.CancelCommoditiesPurchase()
    if s.direct then
      s.direct, s.quoted = false, false
      Status("Checking current listings...")
      StartCommoditySearch(s)
    else
      Finish("Could not get a price quote; the listings may have changed. Try again.")
    end
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" and s.kind == "commodity" then
    ns.Inventory.NoteIncoming(ns.charName, s.itemID, s.quantity)
    if s.listing then ns.Fire("LISTING_BOUGHT", s.listing, s.quantity) else ns.Analysis.Invalidate() end
    Finish(("Bought %d x %s."):format(s.quantity, s.name))
  elseif event == "COMMODITY_PURCHASE_FAILED" and s.kind == "commodity" then
    Finish("The purchase failed.")
  elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" and s.kind == "item" then
    ns.Inventory.NoteIncoming(ns.charName, s.itemID, s.listing and s.listing.count or 1)
    ns.Fire("LISTING_BOUGHT", s.listing)
    Finish(("Bought %s."):format(s.name))
  end
end)
