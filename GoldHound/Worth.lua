-- GoldHound: net worth over time. Liquid gold across your characters on the
-- realm, plus the market value of what they carry, bank, have in the mail and
-- have listed on the auction house. Sampled whenever any of that changes.
local ADDON, ns = ...
local Worth = {}
ns.Worth = Worth

local BUCKET = 10 * 60     -- at most one stored point per ten-minute window; later samples in the window replace it
local KEEP_DAYS = 120

local function Value(itemID)
  return ns.Pricing.GetMarket(ns.KeyFor(itemID, 0))
end

-- Returns liquid gold, inventory value and auction value in copper.
function Worth.Compute()
  local gold, inventory, auctions = 0, 0, 0
  local names = {}
  for key, rec in pairs(ns.db.chars or {}) do
    if rec.realm == ns.realmName then
      if key == ns.charKey then gold = gold + ns.Budget() else gold = gold + (rec.money or 0) end
      for _, held in ipairs({ rec.bags, rec.bank, rec.incoming }) do
        for itemID, count in pairs(held or {}) do
          local v = Value(itemID)
          if v then inventory = inventory + v * count end
        end
      end
      if rec.auctionsValue then
        auctions = auctions + rec.auctionsValue
      elseif rec.name then
        names[rec.name] = true -- no exact figure yet; count their listings from the scan
      end
    end
  end
  for _, agg in pairs(ns.scan and ns.scan.byKey or {}) do
    for _, l in ipairs(agg.listings or {}) do
      if l.owner and names[l.owner] and (l.buyout or 0) > 0 then auctions = auctions + l.buyout end
    end
  end
  return gold, inventory, auctions
end

function Worth.Sample()
  if not ns.realm or not ns.Pricing then return end
  local ok, gold, inventory, auctions = pcall(Worth.Compute)
  if not ok then ns.Debug("worth sample failed", gold); return end
  local list = ns.realm.worth
  local now = time()
  local point = { t = now, g = ns.Round(gold), i = ns.Round(inventory), a = ns.Round(auctions) }
  local last = list[#list]
  -- Compare windows, not the distance to the last point: a point whose time
  -- kept being refreshed would otherwise swallow every later sample.
  if last and math.floor(last.t / BUCKET) == math.floor(now / BUCKET) then
    list[#list] = point
  else
    table.insert(list, point)
  end
  local cutoff = now - KEEP_DAYS * 86400
  while list[1] and list[1].t < cutoff do table.remove(list, 1) end
  ns.Fire("WORTH_UPDATED")
end

function Worth.Points()
  return ns.realm and ns.realm.worth or {}
end

local function Schedule()
  ns.Debounce("worth", 4, Worth.Sample)
end

for _, ev in ipairs({ "CHARS_UPDATED", "INVENTORY_UPDATED", "SCAN_COMPLETE", "REFRESH_COMPLETE", "LEDGER_UPDATED" }) do
  ns.On(ev, Schedule)
end
ns.On("READY", function() C_Timer.After(12, Worth.Sample) end)
ns.RegisterEvent("PLAYER_LOGOUT", function() if ns.realm then Worth.Sample() end end)

-- Exact value of this character's auctions whenever the auction house reports them.
local function CaptureOwnedAuctions()
  local rec = ns.db and ns.db.chars[ns.charKey]
  if not rec or not C_AuctionHouse.GetNumOwnedAuctions then return end
  local okn, n = pcall(C_AuctionHouse.GetNumOwnedAuctions)
  if not okn or type(n) ~= "number" then return end
  local total = 0
  for i = 1, n do
    local ok, a = pcall(C_AuctionHouse.GetOwnedAuctionInfo, i)
    if ok and type(a) == "table" then
      local qty = a.quantity or 1
      local value = 0
      if a.unitPrice and a.unitPrice > 0 then value = a.unitPrice * qty
      elseif a.buyoutAmount and a.buyoutAmount > 0 then value = a.buyoutAmount
      else value = a.bidAmount or a.minBid or 0 end
      total = total + value
    end
  end
  rec.auctionsValue = total
  rec.auctionsT = time()
  Schedule()
end
ns.RegisterEvent("OWNED_AUCTIONS_UPDATED", CaptureOwnedAuctions)
ns.On("AH_OPEN", function()
  C_Timer.After(1.5, function()
    if ns.ahOpen and C_AuctionHouse.QueryOwnedAuctions then pcall(C_AuctionHouse.QueryOwnedAuctions, {}) end
  end)
end)
