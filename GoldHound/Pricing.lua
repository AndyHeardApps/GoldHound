-- GoldHound: market values, sale rates, reagent and crafting costs.
local ADDON, ns = ...
local Pricing = {}
ns.Pricing = Pricing

local function Median(values)
  local n = #values
  if n == 0 then return nil end
  table.sort(values)
  if n % 2 == 1 then return values[(n + 1) / 2] end
  return (values[n / 2] + values[n / 2 + 1]) / 2
end

function Pricing.GetEntry(key)
  return ns.realm and ns.realm.prices[key] or nil
end

-- Median of the cheapest buyout seen in the most recent scans.
function Pricing.HistoryMedian(key, minScans, maxScans)
  local e = Pricing.GetEntry(key)
  if not e or not e.h then return nil, 0 end
  local n = #e.h
  if n < (minScans or 1) then return nil, n end
  local values = {}
  local first = math.max(1, n - (maxScans or 10) + 1)
  for i = first, n do table.insert(values, e.h[i].m) end
  return Median(values), n
end

-- Quantity-weighted 25th percentile price of the current scan's listings for an
-- item, computed once per scan per item. `exclude` only affects the count of
-- other listings, which is what decides whether the value is trustworthy.
function Pricing.ScanReference(key, exclude)
  local agg = ns.scan and ns.scan.byKey and ns.scan.byKey[key]
  if not agg then return nil, 0 end
  if agg.ref == nil then
    local total = 0
    for _, l in ipairs(agg.listings) do
      if l.buyout > 0 then total = total + l.count end
    end
    local target, running, ref = total * 0.25, 0, false
    for _, l in ipairs(agg.listings) do -- sorted by unit price ascending
      if l.buyout > 0 then
        running = running + l.count
        ref = l.unit
        if running >= target then break end
      end
    end
    agg.ref = ref
  end
  if agg.ref == false then return nil, 0 end
  local others = agg.n - ((exclude and exclude.buyout > 0) and 1 or 0)
  if others <= 0 then return nil, 0 end
  return agg.ref, others
end

-- What it costs right now to buy `qty` units (default 1), from the cheapest
-- current listings upwards. Returns the average unit price over those units,
-- the dearest unit price among them, how many units were available and a
-- source tag. With no current listings it falls back to the cheapest price
-- seen at the last scan, then to the market value. Your own listings are
-- skipped since you cannot buy them.
function Pricing.AcquireCost(key, qty)
  qty = qty or 1
  local agg = ns.scan and ns.scan.byKey and ns.scan.byKey[key]
  local me = ns.charName
  if agg then
    local need, cost, dearest = qty, 0, nil
    for _, l in ipairs(agg.listings) do -- sorted by unit price ascending
      if l.buyout > 0 and l.owner ~= me then
        local take = math.min(l.count, need)
        cost = cost + take * l.unit
        dearest = l.unit
        need = need - take
        if need <= 0 then break end
      end
    end
    local got = qty - need
    if got > 0 then return cost / got, dearest, got, "listings" end
  end
  local e = Pricing.GetEntry(key)
  if e and e.m then return e.m, e.m, e.q or 0, "last scan" end
  local market = Pricing.GetMarket(key)
  if market then return market, market, 0, "market" end
  return nil
end

-- Best estimate of what one unit sells for. Returns copper and a source tag.
function Pricing.GetMarket(key, exclude)
  local hist = Pricing.HistoryMedian(key, 3)
  local ref = Pricing.ScanReference(key, exclude)
  if hist and ref then return math.min(hist, ref), "history" end
  if hist then return hist, "history" end
  if ref then return ref, "scan" end
  local e = Pricing.GetEntry(key)
  if e and e.m then return e.m, "last scan" end
  return nil
end

-- True when there is enough data to trust the market value for a flip.
function Pricing.HasEvidence(key, exclude)
  local _, scans = Pricing.HistoryMedian(key, 1)
  if scans >= 3 then return true end
  local _, others = Pricing.ScanReference(key, exclude)
  return others >= (ns.settings.minEvidence or 2)
end

-- Quantity-weighted statistics over listings sorted by unit price ascending.
-- Returns nil when nothing has a buyout, else { m = lowest, l = 25th percentile,
-- d = median, u = 75th percentile, x = highest, a = mean, q = units, n = listings }.
function Pricing.ListingStats(listings)
  local total, n = 0, 0
  for _, l in ipairs(listings) do
    if l.buyout > 0 then total = total + l.count; n = n + 1 end
  end
  if n == 0 or total <= 0 then return nil end
  local s = { q = total, n = n }
  local sum, run = 0, 0
  for _, l in ipairs(listings) do
    if l.buyout > 0 then
      s.m = s.m or l.unit
      sum = sum + l.unit * l.count
      run = run + l.count
      if not s.l and run >= total * 0.25 then s.l = l.unit end
      if not s.d and run >= total * 0.5 then s.d = l.unit end
      if not s.u and run >= total * 0.75 then s.u = l.unit end
      s.x = l.unit
    end
  end
  s.a = sum / total
  return s
end

-- Appends a price history point to a price entry and trims it to the configured
-- size. The spread fields are left out when a single listing makes them all equal.
function Pricing.RecordHistory(e, s, now)
  e.h = e.h or {}
  local point = { t = now, m = s.m, q = s.q, n = s.n }
  if s.n > 1 then
    point.a, point.d, point.l, point.u, point.x = ns.Round(s.a), s.d, s.l, s.u, s.x
  end
  table.insert(e.h, point)
  local size = ns.settings.historySize or 40
  while #e.h > size do table.remove(e.h, 1) end
end

function Pricing.GetMinBuyout(key)
  local e = Pricing.GetEntry(key)
  return e and e.m or nil
end

-- Units currently listed on the AH as of the last scan.
function Pricing.Listed(key)
  local e = Pricing.GetEntry(key)
  if not e then return 0 end
  if e.t and ns.realm.lastScan and e.t < ns.realm.lastScan then return 0 end
  return e.q or 0
end

-------------------------------------------------------------------------------
-- Sale rates (units per day), inferred from listings that vanished between scans
-- before they could have expired, plus your own mailbox invoices.
-------------------------------------------------------------------------------
local MIN_OBSERVED_HOURS = 12

function Pricing.SaleRate(key)
  local s = ns.realm and ns.realm.sales[key]
  if not s or (s.hrs or 0) < MIN_OBSERVED_HOURS then return nil end
  return (s.u or 0) / s.hrs * 24, s.hrs
end

function Pricing.OwnSaleRate(itemID)
  local l = ns.realm and ns.realm.ledger.items[itemID]
  if not l or not l.first or (l.n or 0) < 2 then return nil end
  local days = math.max(1, (time() - l.first) / 86400)
  return (l.units or 0) / days
end

-- Combined rate: inferred market rate when available, else your own sales.
function Pricing.Rate(key)
  local rate = Pricing.SaleRate(key)
  if rate then return rate, "market" end
  local own = Pricing.OwnSaleRate(ns.ItemIDFromKey(key))
  if own then return own, "yours" end
  return nil
end

function Pricing.RateText(rate)
  if rate == nil then return "|cff9d9d9dunknown|r" end
  if rate >= 10 then return ("%d/day"):format(rate) end
  if rate >= 1 then return ("%.1f/day"):format(rate) end
  if rate > 0 then return ("%.2f/day"):format(rate) end
  return "0/day"
end

function Pricing.DaysToSell(rate, qty)
  if not rate or rate <= 0 then return nil end
  return (qty or 1) / rate
end

-------------------------------------------------------------------------------
-- Item values
-------------------------------------------------------------------------------
function Pricing.ItemValue(itemID)
  return Pricing.GetMarket(ns.KeyFor(itemID, 0))
end

function Pricing.GetVendorSell(itemID)
  local info = ns.ItemInfo(itemID)
  if not info then return nil end
  return info.sellPrice
end

function Pricing.VendorBuy(itemID)
  local price = ns.db.vendorBuy[itemID]
  if price then
    local meta = ns.db.vendorInfo[itemID]
    if meta and meta.limited then return nil end -- limited stock is not a reliable source
    return price
  end
  return ns.Data.VendorSeed[itemID]
end

-- Deposit estimate for listing items (8 hour duration) when the AH is closed.
function Pricing.DepositEstimate(itemID, qty)
  local sell = Pricing.GetVendorSell(itemID) or 0
  return sell * (qty or 1) * 0.20
end

-------------------------------------------------------------------------------
-- Reagent and crafting costs. A reagent costs the cheapest of: vendor price,
-- what the auction house charges for it right now, or crafting it yourself
-- with a recipe you know. Products are valued at market (see GetMarket), so
-- profit is current cost against the expected sale price.
-------------------------------------------------------------------------------
local recipesByOutput = nil

function Pricing.InvalidateRecipeIndex()
  recipesByOutput = nil
end

local function RecipeIndex()
  if recipesByOutput then return recipesByOutput end
  recipesByOutput = {}
  for recipeID, r in pairs(ns.db.recipes) do
    -- Only recipes a character on this realm knows; any of your characters will do.
    if r.out and r.complete and ns.Chars.WhoKnows(r) then
      recipesByOutput[r.out] = recipesByOutput[r.out] or {}
      table.insert(recipesByOutput[r.out], recipeID)
    end
  end
  return recipesByOutput
end

function Pricing.RecipesFor(itemID)
  return RecipeIndex()[itemID] or {}
end

-- Returns cost per unit, source ("vendor", "ah", "craft"), and detail (recipe ID for crafts).
-- `qty` is how many units are needed; the auction house leg averages the
-- cheapest listings that cover it.
function Pricing.ReagentCost(itemID, depth, visited, qty)
  depth = depth or 0
  visited = visited or {}
  local best, source, detail
  local vendor = Pricing.VendorBuy(itemID)
  if vendor then best, source = vendor, "vendor" end
  local ah = Pricing.AcquireCost(ns.KeyFor(itemID, 0), qty or 1)
  if ah and (not best or ah < best) then best, source = ah, "ah" end
  if depth < 3 and not visited[itemID] then
    visited[itemID] = true
    for _, recipeID in ipairs(Pricing.RecipesFor(itemID)) do
      local craft = Pricing.CraftCost(recipeID, depth + 1, visited)
      if craft and craft.perUnit and (not best or craft.perUnit < best) then
        best, source, detail = craft.perUnit, "craft", recipeID
      end
    end
    visited[itemID] = nil
  end
  return best, source, detail
end

-- Cost of one craft of a recipe. Returns { total, perUnit, complete, reagents = {...} } or nil.
function Pricing.CraftCost(recipeID, depth, visited)
  local r = ns.db.recipes[recipeID]
  if not r or not r.reagents then return nil end
  local total, complete, parts = 0, true, {}
  for _, reagent in ipairs(r.reagents) do
    local itemID, qty = reagent[1], reagent[2] or 1
    local cost, source, detail = Pricing.ReagentCost(itemID, depth or 0, visited, qty)
    if cost then
      total = total + cost * qty
    else
      complete = false
    end
    table.insert(parts, { item = itemID, qty = qty, unit = cost, source = source, detail = detail })
  end
  if not complete and total == 0 then return nil end
  local avgOut = ((r.qmin or 1) + (r.qmax or r.qmin or 1)) / 2
  return { total = total, perUnit = total / math.max(avgOut, 0.0001), complete = complete, reagents = parts, avgOut = avgOut }
end

-- Expected auction value of the materials from disenchanting one item.
-- Returns total copper, a breakdown list, and whether any material price is unknown.
function Pricing.GetDisenchantValue(itemID)
  local info = ns.ItemInfo(itemID)
  if not info then return nil end
  local outcomes = ns.Data.Disenchant(info.quality, info.ilvl, info.classID)
  if not outcomes then return nil end
  local total, parts, missing = 0, {}, false
  for _, o in ipairs(outcomes) do
    local price = Pricing.GetMarket(tostring(o.item))
    if price then
      local avg = (o.min + o.max) / 2
      local value = price * avg * o.chance
      total = total + value
      table.insert(parts, { item = o.item, chance = o.chance, avg = avg, price = price, value = value })
    else
      missing = true
    end
  end
  if #parts == 0 then return nil end
  return total, parts, missing
end
