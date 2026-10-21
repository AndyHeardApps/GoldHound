-- GoldHound: turns scan, recipe, vendor and ledger data into concrete suggestions.
-- Every suggestion carries cost, profit (after the AH cut), ROI, sale rate and
-- a breakdown for its tooltip.
local ADDON, ns = ...
local A = {}
ns.Analysis = A

local Pricing, Chars = nil, nil
local cache = {}

A.Labels = {
  flip = "Flip", reset = "Reset", snipe = "Snipe", vendor = "Vendor sell", disenchant = "Disenchant",
  recipe = "Recipe", vendorflip = "Vendor buy", craft = "Craft", restock = "Restock",
}

function A.Invalidate()
  cache = {}
  ns.Fire("ANALYSIS_DIRTY")
end

for _, ev in ipairs({ "SCAN_COMPLETE", "RECIPES_UPDATED", "VENDOR_UPDATED", "LEDGER_UPDATED", "CHARS_UPDATED", "INVENTORY_UPDATED" }) do
  ns.On(ev, function() ns.Debounce("analysis", 0.3, A.Invalidate) end)
end
-- Item data arrives in bursts of thousands after a scan; recompute rarely.
ns.On("ITEM_INFO", function() ns.Debounce("analysis-items", 4, A.Invalidate) end)

local function S() return ns.settings end

-- A suggestion must clear both the flat minimum profit and the minimum return
-- on investment; either can be 0 to switch it off. Free things always pass ROI.
function A.Passes(profit, cost)
  local s = S()
  if not profit or profit < (s.minProfit or 0) then return false end
  local minRoi = s.minRoi or 0
  if minRoi <= 0 or not cost or cost <= 0 then return true end
  return profit / cost >= minRoi
end

local function Finish(t)
  Pricing = Pricing or ns.Pricing
  t.catLabel = A.Labels[t.cat] or t.cat
  if t.cost and t.cost > 0 and t.profit then t.roi = t.profit / t.cost end
  if t.key and not t.rate then t.rate, t.rateSource = Pricing.Rate(t.key) end
  t.days = Pricing.DaysToSell(t.rate, t.sellQty or t.qty or 1)
  if t.t == nil and t.key then -- when the prices behind this row were seen
    local agg = ns.scan and ns.scan.byKey and ns.scan.byKey[t.key]
    if agg then t.t, t.refreshed = agg.t, agg.refreshed end
  end
  t.lines = t.lines or {}
  return t
end

local function ItemLines(t, listing)
  table.insert(t.lines, { "Buyout", ns.Money(listing.buyout) .. " (" .. ns.Money(listing.unit) .. " each)" })
  table.insert(t.lines, { "Time left", ns.TimeLeftText(listing.timeLeft) })
end

-------------------------------------------------------------------------------
-- Flips. For commodities the whole floor is one flip: every listing under the
-- discount threshold must be bought, or the rest keeps the price down. For
-- equipment each listing is separate, but competing listings are reported.
-------------------------------------------------------------------------------
local function CompetitionLines(agg, fromUnit, toUnit, me)
  local units, listings, lowest = 0, 0, nil
  for _, l in ipairs(agg.listings) do
    if l.buyout > 0 and l.owner ~= me and l.unit > fromUnit and l.unit < toUnit then
      units = units + l.count
      listings = listings + 1
      lowest = lowest or l.unit
    end
  end
  return units, listings, lowest
end

function A.Flips()
  if cache.flips then return cache.flips end
  Pricing = ns.Pricing
  local rows, s, me = {}, S(), ns.charName
  local budget = ns.Budget()
  for key, agg in pairs(ns.scan.byKey or {}) do
    if ns.IsCommodity(agg.itemID) then
      local market, source = Pricing.GetMarket(key)
      if market and market > 0 and Pricing.HasEvidence(key) then
        local threshold = market * (1 - s.flipDiscount)
        local cost, qty, n = 0, 0, 0
        for _, l in ipairs(agg.listings) do
          if l.buyout > 0 and l.owner ~= me then
            if l.unit <= threshold then
              cost, qty, n = cost + l.buyout, qty + l.count, n + 1
            else
              break
            end
          end
        end
        if qty > 0 then
          local resale = market * qty * (1 - s.ahCut)
          local profit = resale - cost
          if A.Passes(profit, cost) then
            local first = agg.listings[1]
            local itemID = agg.itemID
            local compUnits, compListings, compLow = CompetitionLines(agg, threshold, market, me)
            local clearCost = cost
            for _, l in ipairs(agg.listings) do
              if l.buyout > 0 and l.owner ~= me and l.unit > threshold and l.unit < market then clearCost = clearCost + l.buyout end
            end
            local lines = {
              { "Market value (" .. source .. ")", ns.Money(market) .. " each" },
              { ("Buy all %d listings under"):format(n), ns.Money(threshold) .. " each" },
              { "Average buy price", ns.Money(cost / qty) .. " each" },
              { "Resale after cut", ns.Money(resale) },
              { "Your gold", ns.Money(budget) .. (cost > budget and " |cffff4444(not enough)|r" or "") },
            }
            if compUnits > 0 then
              table.insert(lines, { "Also under market", ("%d units in %d listings from %s"):format(compUnits, compListings, ns.Money(compLow)) })
              table.insert(lines, { "To clear everything under market", ns.Money(clearCost) })
            else
              table.insert(lines, { "Also under market", "nothing" })
            end
            local maxUnit = threshold
            table.insert(rows, Finish({
              cat = "flip", key = key, itemID = itemID, link = first.link, name = first.name, icon = first.icon,
              qty = qty, cost = cost, revenue = resale, profit = profit, market = market, overBudget = cost > budget,
              competition = compUnits, clearCost = clearCost,
              action = { label = "Buy all", fn = function()
                ns.Buy.Commodity(itemID, qty, maxUnit, first.name, { expectedUnit = cost / qty, baseProfit = profit, profitAt = function(_, total) return resale - total end })
              end },
              lines = lines,
            }))
          end
        end
      end
    else
      for _, l in ipairs(agg.listings) do
        if l.buyout > 0 and l.owner ~= me then
          local market, source = Pricing.GetMarket(key, l)
          if market and market > 0 and Pricing.HasEvidence(key, l) then
            local resale = market * l.count * (1 - s.ahCut)
            local profit = resale - l.buyout
            if l.unit <= market * (1 - s.flipDiscount) and A.Passes(profit, l.buyout) then
              local compUnits, compListings = CompetitionLines(agg, l.unit, market, me)
              local t = Finish({
                cat = "flip", key = key, itemID = l.itemID, link = l.link, name = l.name, icon = l.icon,
                qty = l.count, cost = l.buyout, revenue = resale, profit = profit, market = market, listing = l,
                competition = compUnits, overBudget = l.buyout > budget,
                action = { label = "Buy", fn = function() ns.Buy.Listing(l, { baseProfit = profit, profitAt = function(_, total) return resale - total end }) end },
                lines = {
                  { "Market value (" .. source .. ")", ns.Money(market) .. " each" },
                  { "Resale after cut", ns.Money(resale) },
                  { "Others listed under market", compListings > 0 and ("%d listings (%d units)"):format(compListings, compUnits) or "none" },
                },
              })
              ItemLines(t, l)
              table.insert(rows, t)
            end
          end
        end
      end
    end
  end
  table.sort(rows, function(a, b) return a.profit > b.profit end)
  cache.flips = rows
  return rows
end

-------------------------------------------------------------------------------
-- Price resets: buy every listing that would undercut the historical price,
-- not only the deeply discounted ones, so the relist actually holds.
-------------------------------------------------------------------------------
function A.Resets()
  if cache.resets then return cache.resets end
  Pricing = ns.Pricing
  local rows, s, me = {}, S(), ns.charName
  local budget = ns.Budget()
  for key, agg in pairs(ns.scan.byKey or {}) do
    if ns.IsCommodity(agg.itemID) then
      local median, scans = Pricing.HistoryMedian(key, 3)
      if median and median > 0 then
        local relist = median
        local cost, qty, n, cheapCost, cheapQty = 0, 0, 0, 0, 0
        local threshold = median * (1 - s.resetDiscount)
        for _, l in ipairs(agg.listings) do
          if l.buyout > 0 and l.owner ~= me then
            if l.unit < relist then
              cost, qty, n = cost + l.buyout, qty + l.count, n + 1
              if l.unit <= threshold then cheapCost, cheapQty = cheapCost + l.buyout, cheapQty + l.count end
            else
              break
            end
          end
        end
        if qty > 0 and cheapQty > 0 then
          local avg = cost / qty
          local deposit = Pricing.DepositEstimate(agg.itemID, qty)
          local revenue = qty * relist * (1 - s.ahCut) - deposit
          local profit = revenue - cost
          local rate = Pricing.Rate(key)
          local days = Pricing.DaysToSell(rate, qty)
          if avg <= threshold and A.Passes(profit, cost) and cost <= budget and (not days or days <= s.resetMaxDays) then
            local first = agg.listings[1]
            local itemID = agg.itemID
            local maxUnit = relist
            table.insert(rows, Finish({
              cat = "reset", key = key, itemID = itemID, link = first.link, name = first.name, icon = first.icon,
              qty = qty, cost = cost, revenue = revenue, profit = profit, market = median,
              action = { label = "Buy all", fn = function()
                ns.Buy.Commodity(itemID, qty, maxUnit, first.name, { expectedUnit = avg, baseProfit = profit, profitAt = function(_, total) return revenue - total end })
              end },
              lines = {
                { ("Price history median (%d scans)"):format(scans), ns.Money(median) .. " each" },
                { ("Buy all %d listings under"):format(n), ns.Money(relist) .. " each" },
                { "Of which deeply discounted", ("%d units for %s"):format(cheapQty, ns.Money(cheapCost)) },
                { "Average buy price", ns.Money(avg) .. " each" },
                { "Relist at", ns.Money(relist) .. " each" },
                { "Estimated deposit", ns.Money(deposit) },
                { "Your gold", ns.Money(budget) },
              },
            }))
          end
        end
      end
    end
  end
  table.sort(rows, function(a, b) return a.profit > b.profit end)
  cache.resets = rows
  return rows
end

-------------------------------------------------------------------------------
-- Snipes: auctions ending soon where the required bid is far below market.
-------------------------------------------------------------------------------
function A.Snipes()
  if cache.snipes then return cache.snipes end
  Pricing = ns.Pricing
  local rows, s, me = {}, S(), ns.charName
  for key, agg in pairs(ns.scan.byKey or {}) do
    for _, l in ipairs(agg.listings) do
      if l.timeLeft == 0 and l.owner ~= me and (l.minBid or 0) > 0 then
        local required = (l.bidAmount > 0) and (l.bidAmount + math.max(l.minIncrement, 1)) or l.minBid
        local market, source = Pricing.GetMarket(key, l)
        if market and market > 0 and Pricing.HasEvidence(key, l) then
          local resale = market * l.count * (1 - s.ahCut)
          local profit = resale - required
          if required <= market * l.count * (1 - s.flipDiscount) and A.Passes(profit, required) then
            local t = Finish({
              cat = "snipe", key = key, itemID = l.itemID, link = l.link, name = l.name, icon = l.icon,
              qty = l.count, cost = required, revenue = resale, profit = profit, market = market, listing = l,
              action = { label = "Bid", fn = function() ns.Buy.Bid(l, required) end },
              lines = {
                { "Market value (" .. source .. ")", ns.Money(market) .. " each" },
                { "Current bid", l.bidAmount > 0 and ns.Money(l.bidAmount) or "none" },
                { "Bid needed", ns.Money(required) },
                { "Buyout", l.buyout > 0 and ns.Money(l.buyout) or "none" },
                { "Note", "Ends soon; you must stay logged in to collect from the mailbox." },
              },
            })
            table.insert(rows, t)
          end
        end
      end
    end
  end
  table.sort(rows, function(a, b) return a.profit > b.profit end)
  cache.snipes = rows
  return rows
end

-------------------------------------------------------------------------------
-- Arbitrage: listings worth more to a vendor or as disenchant materials.
-------------------------------------------------------------------------------
function A.Arbitrage()
  if cache.arbitrage then return cache.arbitrage end
  Pricing, Chars = ns.Pricing, ns.Chars
  local rows, s, me = {}, S(), ns.charName
  local enchanters = Chars.WithProfession("Enchanting")
  local deCache = {}
  local function DE(itemID)
    local c = deCache[itemID]
    if c == nil then
      local value, parts, missing = Pricing.GetDisenchantValue(itemID)
      c = { value = value, parts = parts, missing = missing }
      deCache[itemID] = c
    end
    return c.value, c.parts, c.missing
  end
  for key, agg in pairs(ns.scan.byKey or {}) do
    local info = ns.ItemInfo(agg.itemID)
    if info then
      for _, l in ipairs(agg.listings) do
        if l.buyout > 0 and l.owner ~= me then
          if info.sellPrice > 0 then
            local profit = info.sellPrice * l.count - l.buyout
            if A.Passes(profit, l.buyout) then
              local t = Finish({
                cat = "vendor", key = key, itemID = l.itemID, link = l.link, name = l.name, icon = l.icon,
                qty = l.count, cost = l.buyout, revenue = info.sellPrice * l.count, profit = profit, listing = l,
                rate = 1000000, rateSource = "vendor",
                action = { label = "Buy", fn = function() ns.Buy.Listing(l, { baseProfit = profit, profitAt = function(_, total) return info.sellPrice * l.count - total end }) end },
                lines = { { "Vendor pays", ns.Money(info.sellPrice) .. " each" } },
              })
              t.days = 0
              ItemLines(t, l)
              table.insert(rows, t)
            end
          end
          if #enchanters > 0 and info.quality >= 2 then
            local needed = ns.Data.DisenchantSkill(info.ilvl)
            local who = Chars.CanDo("Enchanting", needed)
            if who then
              local value, parts, missing = DE(agg.itemID)
              if value and value > 0 then
                local revenue = value * l.count * (1 - s.ahCut)
                local profit = revenue - l.buyout
                if A.Passes(profit, l.buyout) then
                  local lines = { { "Expected materials", ns.Money(value) .. " per item" } }
                  for _, p in ipairs(parts) do
                    local mi = ns.ItemInfo(p.item)
                    table.insert(lines, { ("  %s x%.1f (%d%%)"):format(mi and mi.name or ("item " .. p.item), p.avg, p.chance * 100), ns.Money(p.price) .. " each" })
                  end
                  if missing then table.insert(lines, { "Note", "Some material prices unknown; value is a lower bound." }) end
                  table.insert(lines, { "Needs Enchanting", tostring(needed) })
                  local t = Finish({
                    cat = "disenchant", key = key, itemID = l.itemID, link = l.link, name = l.name, icon = l.icon,
                    who = who.name, qty = l.count, cost = l.buyout, revenue = revenue, profit = profit, listing = l,
                    action = { label = "Buy", fn = function() ns.Buy.Listing(l, { baseProfit = profit, profitAt = function(_, total) return revenue - total end }) end }, lines = lines,
                  })
                  ItemLines(t, l)
                  table.insert(rows, t)
                end
              end
            end
          end
        end
      end
    end
  end
  table.sort(rows, function(a, b) return a.profit > b.profit end)
  cache.arbitrage = rows
  return rows
end

-------------------------------------------------------------------------------
-- Recipes on the AH that a character of yours could learn and profit from.
-------------------------------------------------------------------------------
local function ProfitForRecipeItem(parsed, s)
  local productID = ns.Recipes.ItemIDByName(parsed.product)
  if not productID then return nil, "product not priced yet" end
  local value = ns.Pricing.ItemValue(productID)
  if not value then return nil, "product not priced yet" end
  local cost, partial = 0, false
  local lines = {}
  for _, r in ipairs(parsed.reagents or {}) do
    local id = ns.Recipes.ItemIDByName(r.name)
    local unit, source = nil, nil
    if id then unit, source = ns.Pricing.ReagentCost(id) end
    if unit then
      cost = cost + unit * r.qty
      table.insert(lines, { ("  %s x%d (%s)"):format(r.name, r.qty, source or "?"), ns.Money(unit * r.qty) })
    else
      partial = true
      table.insert(lines, { ("  %s x%d"):format(r.name, r.qty), "|cff9d9d9dunknown|r" })
    end
  end
  local revenue = value * (1 - s.ahCut)
  return { productID = productID, value = value, cost = cost, partial = partial, profit = revenue - cost, lines = lines }
end

function A.Recipes()
  if cache.recipes then return cache.recipes end
  Pricing, Chars = ns.Pricing, ns.Chars
  local rows, s, me = {}, S(), ns.charName
  local best = {}
  for key, agg in pairs(ns.scan.byKey or {}) do
    local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(agg.itemID)
    if classID == ns.Data.CLASS_RECIPE then
      for _, l in ipairs(agg.listings) do
        if l.buyout > 0 and l.owner ~= me and (not best[agg.itemID] or l.unit < best[agg.itemID].unit) then
          best[agg.itemID] = l
        end
      end
    end
  end
  for itemID, l in pairs(best) do
    local parsed = ns.Recipes.Parse(itemID)
    if parsed and parsed.prof and parsed.product then
      local who = Chars.CanDo(parsed.prof, parsed.skill)
      if who and not ns.Recipes.AlreadyKnown(parsed.prof, parsed.product) then
        local calc = ProfitForRecipeItem(parsed, s)
        if calc and A.Passes(calc.profit, calc.cost) then
          local payback = math.ceil(l.unit / calc.profit)
          local productKey = ns.KeyFor(calc.productID, 0)
          local lines = {
            { "Teaches", parsed.product },
            { "Requires", ("%s (%d), %s has %d"):format(parsed.prof, parsed.skill, who.name, who.skill) },
            { "Product sells for", ns.Money(calc.value) },
            { "Materials per craft", ns.Money(calc.cost) .. (calc.partial and " (partial)" or "") },
          }
          for _, line in ipairs(calc.lines) do table.insert(lines, line) end
          table.insert(lines, { "Profit per craft", ns.Money(calc.profit) })
          table.insert(lines, { "Crafts to pay back the recipe", tostring(payback) })
          table.insert(rows, Finish({
            cat = "recipe", key = productKey, itemID = itemID, link = l.link, name = l.name, icon = l.icon,
            who = who.name, qty = 1, cost = l.unit, revenue = calc.profit, profit = calc.profit, listing = l,
            payback = payback, action = { label = "Buy", fn = function() ns.Buy.Listing(l, { baseProfit = calc.profit * payback - l.unit, profitAt = function(_, total) return calc.profit * payback - total end }) end }, lines = lines,
          }))
        end
      end
    end
  end
  table.sort(rows, function(a, b) return a.profit > b.profit end)
  cache.recipes = rows
  return rows
end

-------------------------------------------------------------------------------
-- Vendor buys: limited-stock vendor items and vendor recipes that resell on the AH.
-------------------------------------------------------------------------------
function A.VendorFlips()
  if cache.vendorflips then return cache.vendorflips end
  Pricing = ns.Pricing
  local rows, s = {}, S()
  for itemID, price in pairs(ns.db.vendorBuy or {}) do
    local meta = ns.db.vendorInfo[itemID]
    if meta and (meta.limited or meta.classID == ns.Data.CLASS_RECIPE) then
      local key = ns.KeyFor(itemID, 0)
      local market = Pricing.GetMarket(key)
      if market and Pricing.HasEvidence(key) then
        local revenue = market * (1 - s.ahCut)
        local profit = revenue - price
        if A.Passes(profit, price) then
          local info = ns.ItemInfo(itemID)
          table.insert(rows, Finish({
            cat = "vendorflip", key = key, itemID = itemID, link = info and info.link, name = info and info.name or ("item " .. itemID),
            icon = info and info.icon, qty = 1, cost = price, revenue = revenue, profit = profit, market = market,
            lines = { { "Sold by", meta.where or "?" }, { "Stock", meta.limited and "limited" or "unlimited" }, { "Market value", ns.Money(market) } },
          }))
        end
      end
    end
  end
  table.sort(rows, function(a, b) return a.profit > b.profit end)
  cache.vendorflips = rows
  return rows
end

-------------------------------------------------------------------------------
-- Crafting: recipes your characters know whose product sells for more than the
-- cheapest way to get the materials (vendor, AH, or crafting intermediates).
-------------------------------------------------------------------------------
local function SourceText(part)
  if part.source == "vendor" then return "vendor" end
  if part.source == "ah" then return "AH" end
  if part.source == "craft" then
    local r = ns.db.recipes[part.detail]
    local who = r and ns.Chars.WhoKnows(r)
    return "craft: " .. (r and r.name or "?") .. (who and (" by " .. who) or "")
  end
  return "?"
end

function A.Crafts()
  if cache.crafts then return cache.crafts end
  Pricing, Chars = ns.Pricing, ns.Chars
  local rows, s = {}, S()
  for recipeID, r in pairs(ns.db.recipes or {}) do
    if r.out and r.complete then
      local who = Chars.WhoKnows(r)
      if who then
        local cost = Pricing.CraftCost(recipeID)
        local value = Pricing.ItemValue(r.out)
        if cost and value then
          local revenue = value * cost.avgOut * (1 - s.ahCut)
          local profit = revenue - cost.total
          if A.Passes(profit, cost.total) then
            local info = ns.ItemInfo(r.out)
            local key = ns.KeyFor(r.out, 0)
            -- Materials already in your bags and banks (any character on the
            -- realm), as a cost split for one craft and as whole crafts covered.
            local owned, toBuy, ownedCrafts, anyOwned, held = 0, 0, math.huge, false, {}
            for _, p in ipairs(cost.reagents) do
              local have = ns.Inventory.Count(p.item)
              held[p.item] = have
              if have > 0 then anyOwned = true end
              local used = math.min(have, p.qty)
              if p.unit then
                owned = owned + used * p.unit
                toBuy = toBuy + (p.qty - used) * p.unit
              end
              ownedCrafts = math.min(ownedCrafts, math.floor(have / p.qty))
            end
            if ownedCrafts == math.huge then ownedCrafts = 0 end
            local ownedFrac = cost.total > 0 and owned / cost.total or 0
            local matsText = ns.Money(cost.total) .. (cost.complete and "" or " (partial)")
            if anyOwned then matsText = matsText .. (" (owned %s, buy %s)"):format(ns.Money(owned), ns.Money(toBuy)) end
            local lines = {
              { "Sells for", ns.Money(value) .. (cost.avgOut ~= 1 and (" each, makes %.1f"):format(cost.avgOut) or "") },
              { "Listed now", tostring(Pricing.Listed(key)) },
              { "Materials per craft", matsText },
            }
            if ownedCrafts > 0 then
              table.insert(lines, { "Crafts from what you own", ("%d (materials worth %s)"):format(ownedCrafts, ns.Money(cost.total * ownedCrafts)) })
            end
            for _, p in ipairs(cost.reagents) do
              local mi = ns.ItemInfo(p.item)
              local have = held[p.item] or 0
              table.insert(lines, { ("  %s x%d (%s)%s"):format(mi and mi.name or ("item " .. p.item), p.qty, SourceText(p), have > 0 and (", have %d"):format(have) or ""), p.unit and ns.Money(p.unit * p.qty) or "|cff9d9d9dunknown|r" })
            end
            local planned = ns.UI and ns.UI.PlannedCrafts and ns.UI.PlannedCrafts(recipeID) or 0
            if planned > 0 then table.insert(lines, 1, { "In plan", planned .. " crafts" }) end
            table.insert(rows, Finish({
              cat = "craft", key = key, recipeID = recipeID, itemID = r.out, link = info and info.link, name = r.name, icon = r.icon,
              prof = r.prof, who = who, qty = cost.avgOut, cost = cost.total, revenue = revenue, profit = profit, market = value,
              craftCost = cost, partial = not cost.complete,
              ownedCost = anyOwned and owned or nil, buyCost = anyOwned and toBuy or nil, ownedFrac = ownedFrac, ownedCrafts = ownedCrafts,
              action = { label = "Add", fn = function() ns.UI.ShowShopping(recipeID) end }, lines = lines,
            }))
          end
        end
      end
    end
  end
  table.sort(rows, function(a, b) return a.profit > b.profit end)
  cache.crafts = rows
  return rows
end

-- Cheapest known craft cost per unit for an item, for tooltips.
function A.CraftCostFor(itemID)
  local best
  for _, recipeID in ipairs(ns.Pricing.RecipesFor(itemID)) do
    local c = ns.Pricing.CraftCost(recipeID)
    if c and c.complete and (not best or c.perUnit < best.perUnit) then best = c end
  end
  return best
end

-------------------------------------------------------------------------------
-- Restock: things you have sold before that are now scarce on the AH.
-------------------------------------------------------------------------------
function A.Restock()
  if cache.restock then return cache.restock end
  Pricing = ns.Pricing
  local rows, s = {}, S()
  for itemID, l in pairs(ns.realm.ledger.items or {}) do
    if (l.n or 0) >= 2 then
      local key = ns.KeyFor(itemID, 0)
      local listed = Pricing.Listed(key)
      if listed < (s.restockMin or 3) then
        local market = Pricing.GetMarket(key)
        local info = ns.ItemInfo(itemID)
        local avg = l.units > 0 and (l.net / l.units) or 0
        local craft = A.CraftCostFor(itemID)
        local cost = craft and craft.perUnit or nil
        local revenue = (market or avg) * (1 - s.ahCut)
        local profit = cost and (revenue - cost) or nil
        local recipeID = craft and ns.Pricing.RecipesFor(itemID)[1] or nil
        table.insert(rows, Finish({
          cat = "restock", key = key, itemID = itemID, link = info and info.link, name = l.name or (info and info.name) or ("item " .. itemID),
          icon = info and info.icon, qty = 1, cost = cost, revenue = revenue, profit = profit, market = market,
          listed = listed, sold = l.units, soldN = l.n, avg = avg,
          action = recipeID and { label = "Add", fn = function() ns.UI.ShowShopping(recipeID) end } or nil,
          lines = {
            { "You sold", ("%d units in %d sales"):format(l.units, l.n) },
            { "Your average net", ns.Money(avg) },
            { "Listed now", tostring(listed) },
            { "Market value", market and ns.Money(market) or "unknown" },
            { "Craft cost", cost and ns.Money(cost) or "no known recipe" },
          },
        }))
      end
    end
  end
  table.sort(rows, function(a, b) return (a.profit or 0) > (b.profit or 0) end)
  cache.restock = rows
  return rows
end

-------------------------------------------------------------------------------
-- All buy-side opportunities together, optionally filtered by category.
-------------------------------------------------------------------------------
function A.Opportunities(filter)
  local out = {}
  local sources = {
    flip = A.Flips, reset = A.Resets, snipe = A.Snipes, arbitrage = A.Arbitrage, recipe = A.Recipes, vendorflip = A.VendorFlips,
  }
  for cat, fn in pairs(sources) do
    if not filter or filter == "all" or filter == cat then
      for _, row in ipairs(fn()) do table.insert(out, row) end
    end
  end
  table.sort(out, function(a, b) return (a.profit or 0) > (b.profit or 0) end)
  return out
end
