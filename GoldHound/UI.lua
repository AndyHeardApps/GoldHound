-- GoldHound: the main window. Tabs for opportunities, crafting, restocks, the
-- sales ledger and a shopping list for a chosen craft.
local ADDON, ns = ...
local UI = {}
ns.UI = UI

local ROW_HEIGHT, NUM_ROWS = 22, 18
local WIDTH = 920
local LIST_TOP = -118
local CHART_ROWS = 9   -- rows of the list given to the net worth chart on the Ledger tab
local HEIGHT = -LIST_TOP + 22 + NUM_ROWS * ROW_HEIGHT + 40
local GREY, GREEN, RED, R = "|cff9d9d9d", "|cff33ff33", "|cffff4444", "|r"

local frame
local state = { tab = "opps", filter = "all", offset = 0, sortIndex = nil, sortDesc = true, search = "", rows = {}, shopping = {} }

local function ChartRows() return state.tab == "ledger" and CHART_ROWS or 0 end

local function Unknown() return GREY .. "?" .. R end
local function Money(v) if v == nil then return Unknown() end return ns.Money(v) end
local function ProfitText(v) if v == nil then return Unknown() end return (v >= 0 and GREEN or RED) .. ns.Money(v) .. R end
local function Pct(v) if v == nil then return Unknown() end return ("%d%%"):format(v * 100) end
local function Days(v) if v == nil then return Unknown() end if v < 0.1 then return "<0.1" end if v >= 100 then return "99+" end return ("%.1f"):format(v) end
local function Qty(v) if v == nil then return "" end if v == math.floor(v) then return tostring(v) end return ("%.1f"):format(v) end

-------------------------------------------------------------------------------
-- Tab and column definitions
-------------------------------------------------------------------------------
local function CommonTooltip(row, tt)
  if row.who then tt:AddDoubleLine("Character", row.who, 0.8, 0.8, 0.8, 1, 1, 1) end
  for _, line in ipairs(row.lines or {}) do tt:AddDoubleLine(line[1], line[2], 0.8, 0.8, 0.8, 1, 1, 1) end
  tt:AddDoubleLine("Cost", Money(row.cost), 0.8, 0.8, 0.8, 1, 1, 1)
  tt:AddDoubleLine("Profit after AH cut", ProfitText(row.profit), 0.8, 0.8, 0.8, 1, 1, 1)
  local rateText = ns.Pricing.RateText(row.rate)
  if row.rateSource == "yours" then rateText = rateText .. GREY .. " (your sales)" .. R end
  if row.rateSource == "vendor" then rateText = "instant (vendor)" end
  tt:AddDoubleLine("Sale rate", rateText, 0.8, 0.8, 0.8, 1, 1, 1)
  if row.days then tt:AddDoubleLine("Days to sell", Days(row.days), 0.8, 0.8, 0.8, 1, 1, 1) end
  if row.t then
    tt:AddDoubleLine(row.refreshed and "Prices refreshed" or "Prices scanned", ("%s (%s ago)"):format(date("%d %b %H:%M", row.t), ns.AgeText(row.t)), 0.8, 0.8, 0.8, 1, 1, 1)
  end
end

local function Age(r) if not r.t then return Unknown() end return ns.AgeText(r.t) end

local OPP_COLUMNS = {
  { label = "Type", width = 66, text = function(r) return r.catLabel end, value = function(r) return r.catLabel end },
  { label = "Item", width = 206, item = true, text = function(r) return r.link or r.name or "?" end, value = function(r) return r.name or "" end },
  { label = "Who", width = 72, text = function(r) return r.who or "" end, value = function(r) return r.who or "" end },
  { label = "Qty", width = 36, align = "RIGHT", text = function(r) return Qty(r.qty) end, value = function(r) return r.qty or 0 end },
  { label = "Cost", width = 90, align = "RIGHT", text = function(r) if r.overBudget then return RED .. ns.Money(r.cost) .. R end return Money(r.cost) end, value = function(r) return r.cost or 0 end },
  { label = "Profit", width = 90, align = "RIGHT", text = function(r) return ProfitText(r.profit) end, value = function(r) return r.profit or 0 end },
  { label = "ROI", width = 44, align = "RIGHT", text = function(r) return Pct(r.roi) end, value = function(r) return r.roi or 0 end },
  { label = "Sales/day", width = 66, align = "RIGHT", text = function(r) return r.rateSource == "vendor" and "instant" or ns.Pricing.RateText(r.rate) end, value = function(r) return r.rate or -1 end },
  { label = "Days", width = 42, align = "RIGHT", text = function(r) return Days(r.days) end, value = function(r) return r.days or 9999 end },
  { label = "Age", width = 46, align = "RIGHT", text = Age, value = function(r) return r.t or 0 end },
  { label = "", width = 62, button = true },
}

local CRAFT_COLUMNS = {
  { label = "Recipe", width = 200, item = true, text = function(r) return r.link or r.name or "?" end, value = function(r) return r.name or "" end },
  { label = "Profession", width = 74, text = function(r) return r.prof or "" end, value = function(r) return r.prof or "" end },
  { label = "Who", width = 64, text = function(r) return r.who or "" end, value = function(r) return r.who or "" end },
  { label = "Mats/craft", width = 90, align = "RIGHT", text = function(r) return Money(r.cost) .. (r.partial and GREY .. "*" .. R or "") end, value = function(r) return r.cost or 0 end },
  { label = "Sells for", width = 90, align = "RIGHT", text = function(r) return Money(r.market) end, value = function(r) return r.market or 0 end },
  { label = "Profit", width = 90, align = "RIGHT", text = function(r) return ProfitText(r.profit) end, value = function(r) return r.profit or 0 end },
  { label = "ROI", width = 44, align = "RIGHT", text = function(r) return Pct(r.roi) end, value = function(r) return r.roi or 0 end },
  { label = "Sales/day", width = 66, align = "RIGHT", text = function(r) return ns.Pricing.RateText(r.rate) end, value = function(r) return r.rate or -1 end },
  { label = "Age", width = 46, align = "RIGHT", text = Age, value = function(r) return r.t or 0 end },
  { label = "", width = 62, button = true },
}

local RESTOCK_COLUMNS = {
  { label = "Item", width = 230, item = true, text = function(r) return r.link or r.name or "?" end, value = function(r) return r.name or "" end },
  { label = "Listed", width = 50, align = "RIGHT", text = function(r) return tostring(r.listed or 0) end, value = function(r) return r.listed or 0 end },
  { label = "Market", width = 90, align = "RIGHT", text = function(r) return Money(r.market) end, value = function(r) return r.market or 0 end },
  { label = "Your avg", width = 90, align = "RIGHT", text = function(r) return Money(r.avg) end, value = function(r) return r.avg or 0 end },
  { label = "Sold", width = 50, align = "RIGHT", text = function(r) return tostring(r.sold or 0) end, value = function(r) return r.sold or 0 end },
  { label = "Sales/day", width = 66, align = "RIGHT", text = function(r) return ns.Pricing.RateText(r.rate) end, value = function(r) return r.rate or -1 end },
  { label = "Craft cost", width = 90, align = "RIGHT", text = function(r) return Money(r.cost) end, value = function(r) return r.cost or 0 end },
  { label = "Profit", width = 90, align = "RIGHT", text = function(r) return ProfitText(r.profit) end, value = function(r) return r.profit or 0 end },
  { label = "", width = 62, button = true },
}

local LEDGER_COLUMNS = {
  { label = "When", width = 110, text = function(r) return date("%d %b %H:%M", r.t) end, value = function(r) return r.t end },
  { label = "Item", width = 250, text = function(r) return r.name end, value = function(r) return r.name or "" end },
  { label = "Qty", width = 50, align = "RIGHT", text = function(r) return tostring(r.units or 1) end, value = function(r) return r.units or 1 end },
  { label = "Gross", width = 96, align = "RIGHT", text = function(r) return Money(r.gross) end, value = function(r) return r.gross or 0 end },
  { label = "Net", width = 96, align = "RIGHT", text = function(r) return ProfitText(r.net) end, value = function(r) return r.net or 0 end },
  { label = "Buyer", width = 110, text = function(r) return r.buyer or "" end, value = function(r) return r.buyer or "" end },
  { label = "Character", width = 100, text = function(r) return r.char or "" end, value = function(r) return r.char or "" end },
}


local function StepText(r)
  if r.type == "buy_ah" then return ("Buy %d x %s"):format(r.qty, r.name) end
  if r.type == "buy_vendor" then return ("Buy %d x %s from a vendor"):format(r.qty, r.name) end
  if r.type == "mail" then return ("Mail %d x %s to %s"):format(r.qty, r.name, r.to) end
  if r.type == "craft" then return ("Craft %d x %s"):format(r.qty, r.name) end
  if r.type == "post" then return ("Post %d x %s"):format(r.qty, r.name) end
  return r.name or "?"
end

local PLAN_COLUMNS = {
  { label = "#", width = 28, align = "RIGHT", text = function(r) return tostring(r.n) end, value = function(r) return r.n end },
  { label = "Step", width = 280, item = true, text = function(r)
      if r.kind == "recipe" then
        local done = r.done or 0
        local text = "|cffffd100" .. (r.name or "?") .. "|r  x" .. r.crafts .. " crafts"
        if r.posted and r.posted > 0 then text = text .. GREY .. ("  (%d posted)"):format(r.posted) .. R end
        if done >= r.crafts then return text .. GREEN .. "  all crafted" .. R end
        if done > 0 then return text .. GREY .. ("  (%d crafted)"):format(done) .. R end
        return text
      end
      local t = StepText(r)
      if r.done then return GREY .. t .. R end
      return t
    end, value = function(r) return r.n or 0 end },
  { label = "Character", width = 90, text = function(r) return r.char or "" end, value = function(r) return r.char or "" end },
  { label = "Where", width = 120, text = function(r) return r.where or "" end, value = function(r) return r.where or "" end },
  { label = "Status", width = 120, text = function(r)
      if r.kind == "recipe" then return "" end
      local status = ns.Plan.Context(r)
      if status == "ready" then return GREEN .. "ready" .. R end
      if status == "done" then return GREY .. "done" .. R end
      return status
    end, value = function(r) return r.kind == "recipe" and "" or (ns.Plan.Context(r)) end },
  { label = "Profit/item", width = 90, align = "RIGHT", text = function(r)
      if r.profitUnit == nil then return "" end
      return ProfitText(r.profitUnit) .. (r.partial and GREY .. "*" .. R or "")
    end, value = function(r) return r.profitUnit or -math.huge end },
  { label = "", width = 62, button = true },
}

-- Current craft profit for a recipe: per item made, per craft, and the inputs.
local function CraftProfit(recipeID)
  local r = ns.db.recipes[recipeID]
  if not r or not r.out then return nil end
  local cost = ns.Pricing.CraftCost(recipeID)
  local value = ns.Pricing.ItemValue(r.out)
  if not cost or not value then return nil end
  local keep = 1 - (ns.settings.ahCut or 0)
  return {
    perItem = value * keep - cost.perUnit,
    perCraft = value * cost.avgOut * keep - cost.total,
    value = value, cost = cost, partial = not cost.complete,
  }
end

-- Adds profit fields and tooltip lines for a craft of `crafts` crafts to a plan row.
local function AddCraftProfit(row, recipeID, crafts)
  local cp = CraftProfit(recipeID)
  if not cp then return end
  row.profitUnit, row.profitCraft, row.partial = cp.perItem, cp.perCraft, cp.partial
  row.lines = row.lines or {}
  table.insert(row.lines, { "Sells for", ns.Money(cp.value) .. (cp.cost.avgOut ~= 1 and (" each, makes %.1f"):format(cp.cost.avgOut) or "") })
  table.insert(row.lines, { "Materials per craft", ns.Money(cp.cost.total) .. (cp.partial and " (some unknown)" or "") })
  table.insert(row.lines, { "Profit per craft", ProfitText(cp.perCraft) })
  table.insert(row.lines, { "Profit per item", ProfitText(cp.perItem) })
  if crafts and crafts > 0 then
    table.insert(row.lines, { ("Profit for %d crafts"):format(crafts), ProfitText(cp.perCraft * crafts) })
  end
end

local TABS = {
  { id = "opps", label = "Opportunities", columns = OPP_COLUMNS, sort = 6,
    rows = function() return ns.Analysis.Opportunities(state.filter) end,
    empty = "No opportunities yet. Open the auction house and press Scan. Flips and resets need a few scans of history.",
    tooltip = CommonTooltip },
  { id = "crafts", label = "Crafting", columns = CRAFT_COLUMNS, sort = 6,
    rows = function() return ns.Analysis.Crafts() end,
    empty = "No profitable crafts. Open each profession window once so recipes are recorded, then scan the auction house or press Refresh crafts.",
    tooltip = CommonTooltip },
  { id = "restock", label = "Restock", columns = RESTOCK_COLUMNS, sort = 8,
    rows = function() return ns.Analysis.Restock() end,
    empty = "Nothing to restock. Items you have sold at least twice appear here when they are scarce on the auction house.",
    tooltip = CommonTooltip },
  { id = "ledger", label = "Ledger", columns = LEDGER_COLUMNS, sort = 1, chart = true,
    rows = function() return ns.realm and ns.realm.ledger.recent or {} end,
    empty = "No sales recorded yet. Sales are recorded when you collect auction gold from the mailbox.",
    tooltip = function(row, tt) tt:AddDoubleLine("Net after cut and deposit", ProfitText(row.net), 0.8, 0.8, 0.8, 1, 1, 1) end },
  { id = "plan", label = "Plan", columns = PLAN_COLUMNS, sort = nil,
    rows = function() return UI.PlanRows() end,
    empty = "Nothing planned. Press Add on a craft in the Crafting tab.",
    tooltip = function(row, tt)
      if row.kind == "recipe" then
        tt:AddDoubleLine("Crafts planned", tostring(row.crafts), 0.8, 0.8, 0.8, 1, 1, 1)
        tt:AddDoubleLine("Crafter", row.char or "?", 0.8, 0.8, 0.8, 1, 1, 1)
        for _, line in ipairs(row.lines or {}) do tt:AddDoubleLine(line[1], line[2], 0.8, 0.8, 0.8, 1, 1, 1) end
        tt:AddLine("Type a count in the box, or left-click for one more craft and right-click for one fewer. Ctrl changes by ten. Remove drops it.", 0.8, 0.8, 0.8, true)
        return
      end
      for _, line in ipairs(row.lines or {}) do tt:AddDoubleLine(line[1], line[2], 0.8, 0.8, 0.8, 1, 1, 1) end
      tt:AddDoubleLine("Character", row.char or "?", 0.8, 0.8, 0.8, 1, 1, 1)
      tt:AddDoubleLine("Where", row.where or "?", 0.8, 0.8, 0.8, 1, 1, 1)
      if row.makes then tt:AddDoubleLine("Makes", tostring(row.makes), 0.8, 0.8, 0.8, 1, 1, 1) end
      if row.to then tt:AddDoubleLine("Recipient", row.to, 0.8, 0.8, 0.8, 1, 1, 1) end
      tt:AddLine(" ")
      tt:AddLine("Right-click to mark done or undo. Steps also vanish by themselves once inventory shows they are complete.", 0.8, 0.8, 0.8, true)
    end },
  { id = "settings", label = "Settings", columns = {}, sort = nil, settings = true,
    rows = function() return {} end, empty = "" },
}

-- Settings shown on the Settings tab: key, label, kind, hint.
local SETTINGS = {
  { key = "minProfit", label = "Minimum profit", kind = "money", hint = "Suggestions below this profit are hidden. Example: 1g 50s. Set 0 to use only the ROI threshold." },
  { key = "minRoi", label = "Minimum ROI %", kind = "ratio", hint = "Suggestions returning less than this on what you spend are hidden. 0 switches it off; both thresholds apply when set." },
  { key = "flipDiscount", label = "Flip discount %", kind = "percent", hint = "A flip or snipe must be at least this far below market value." },
  { key = "resetDiscount", label = "Reset discount %", kind = "percent", hint = "Cheap listings must be this far below the price history to count as a reset." },
  { key = "resetMaxDays", label = "Reset max days", kind = "number", hint = "A reset must be sellable within this many days when the sale rate is known." },
  { key = "ahCut", label = "Auction house cut %", kind = "percent", hint = "Taken off every sale estimate. 5 for a faction auction house." },
  { key = "restockMin", label = "Restock threshold", kind = "number", hint = "Warn when fewer units than this of something you sell are listed." },
  { key = "scanCooldown", label = "Scan cooldown (minutes)", kind = "minutes", hint = "Local wait between full scans. The server throttles at about 15." },
  { key = "craftCooldown", label = "Craft refresh cooldown (minutes)", kind = "minutes", hint = "Local wait between craft refreshes. These are per-item searches with no server throttle; 0 allows back-to-back refreshes." },
  { key = "historySize", label = "Price history (points)", kind = "number", hint = "Price observations kept per item for the price chart and the market median. Each full scan or refresh adds one." },
  { key = "showTooltip", label = "Tooltip lines", kind = "toggle", hint = "Show GoldHound prices on item tooltips." },
}

local FILTERS = {
  { id = "all", label = "All" }, { id = "flip", label = "Flips" }, { id = "reset", label = "Resets" },
  { id = "snipe", label = "Snipes" }, { id = "arbitrage", label = "Arbitrage" }, { id = "recipe", label = "Recipes" },
  { id = "vendorflip", label = "Vendor" },
}

local function CurrentTab()
  for _, t in ipairs(TABS) do if t.id == state.tab then return t end end
  return TABS[1]
end

-------------------------------------------------------------------------------
-- Shopping list: several recipes at once, reagents merged, intermediates expanded.
-------------------------------------------------------------------------------
local function ShoppingList()
  if ns.realm then
    ns.realm.shopping = ns.realm.shopping or {}
    return ns.realm.shopping
  end
  state.shopping = state.shopping or {}
  return state.shopping
end

function UI.PlannedCrafts(recipeID)
  for _, entry in ipairs(ShoppingList()) do
    if entry.recipeID == recipeID then return entry.crafts end
  end
  return 0
end

function UI.ShowShopping(recipeID, amount)
  amount = amount or (IsControlKeyDown() and 10 or 1)
  local list = ShoppingList()
  local found
  for _, entry in ipairs(list) do
    if entry.recipeID == recipeID then found = entry break end
  end
  if found then found.crafts = found.crafts + amount else table.insert(list, { recipeID = recipeID, crafts = amount }) end
  ns.Fire("PLAN_CHANGED")
  UI.Refresh()
end

function UI.SetShoppingCount(recipeID, count)
  local list = ShoppingList()
  for i, entry in ipairs(list) do
    if entry.recipeID == recipeID then
      if count <= 0 then table.remove(list, i) else entry.crafts = count end
      ns.Fire("PLAN_CHANGED")
      UI.Refresh()
      return
    end
  end
end

function UI.AdjustShopping(recipeID, delta)
  local list = ShoppingList()
  for i, entry in ipairs(list) do
    if entry.recipeID == recipeID then
      entry.crafts = entry.crafts + delta
      if entry.crafts <= 0 then table.remove(list, i) end
      break
    end
  end
  UI.Refresh()
end

function UI.ClearShopping()
  local list = ShoppingList()
  for i = #list, 1, -1 do list[i] = nil end
  ns.Plan.ClearDone()
  UI.Refresh()
end

local function AvgOut(recipe)
  return recipe and (((recipe.qmin or 1) + (recipe.qmax or recipe.qmin or 1)) / 2) or 1
end

function UI.PlanRows()
  local rows = {}
  for _, entry in ipairs(ShoppingList()) do
    local r = ns.db.recipes[entry.recipeID]
    if r then
      local info = r.out and ns.ItemInfo(r.out)
      local recipeID = entry.recipeID
      local row = {
        kind = "recipe", recipeID = recipeID, name = r.name, link = info and info.link, icon = r.icon,
        crafts = entry.crafts, done = entry.done or 0, posted = entry.posted or 0, char = ns.Chars.WhoKnows(r), where = r.prof,
        action = { label = "Remove", fn = function() UI.AdjustShopping(recipeID, -entry.crafts) end, enabled = true },
      }
      AddCraftProfit(row, recipeID, entry.crafts)
      table.insert(rows, row)
    end
  end
  for _, step in ipairs(ns.Plan.Build()) do
    local _, label, enabled = ns.Plan.Context(step)
    local info = step.itemID and ns.ItemInfo(step.itemID)
    step.link = info and info.link
    step.icon = info and info.icon
    if step.type == "craft" then
      local r = ns.db.recipes[step.recipeID]
      step.icon = r and r.icon or step.icon
    end
    step.profitUnit, step.profitCraft, step.partial = nil, nil, nil
    if step.itemID then
      step.lines = {}
      for _, who, count in ns.Inventory.Breakdown(step.itemID) do table.insert(step.lines, { "Held by " .. who, tostring(count) }) end
      local market = ns.Pricing.ItemValue(step.itemID)
      if market then table.insert(step.lines, { "Market value", ns.Money(market) .. " each" }) end
      if step.type == "buy_ah" then
        local avg, dearest, available, source = ns.Pricing.AcquireCost(ns.KeyFor(step.itemID, 0), step.qty)
        if avg and source == "listings" then
          table.insert(step.lines, { ("Buy now, cheapest %d units"):format(available), ns.Money(avg) .. " each average, up to " .. ns.Money(dearest) })
          if available < step.qty then table.insert(step.lines, { "Short", ("only %d listed at the last check"):format(available) }) end
        elseif avg then
          table.insert(step.lines, { "Buy now", "no current listings in the scan data; " .. source .. " price " .. ns.Money(avg) })
        end
      end
    end
    if step.type == "craft" and step.recipeID then AddCraftProfit(step, step.recipeID, step.qty) end
    step.action = { label = label, fn = function() ns.Plan.Run(step) end, enabled = enabled }
    table.insert(rows, step)
  end
  return rows
end

-------------------------------------------------------------------------------
-- Window construction
-------------------------------------------------------------------------------
local rows, headers, tabButtons, filterButtons, secureButtons, countBoxes = {}, {}, {}, {}, {}, {}

local function SetBackdrop(f, r, g, b, a)
  f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  f:SetBackdropColor(r, g, b, a)
end

-- Price key for a row, if it is about an item.
function UI.RowKey(data)
  if not data then return nil end
  if data.key then return data.key end
  local id = data.itemID or data.item
  if id then return ns.KeyFor(id, 0) end
  return nil
end

-- Items to re-price for a row: a craft and its reagents, or the one item.
local function RowRefreshItems(data)
  if data.recipeID and (data.cat == "craft" or data.kind == "recipe" or data.type == "craft") then
    return ns.Refresh.RecipeItems(data.recipeID), (data.name or "craft") .. " and its reagents"
  end
  local items, seen = {}, {}
  local function Add(id) if id and not seen[id] then seen[id] = true; table.insert(items, id) end end
  Add(data.itemID or data.item)
  if data.key then Add(ns.ItemIDFromKey(data.key)) end
  return items, data.name or "item"
end

local function RefreshReady()
  return ns.ahOpen and not ns.Refresh.IsRunning() and not ns.Scan.IsRunning() and not ns.Buy.IsBusy()
end

-- Shift-click on a row: put the item link where Blizzard would put it. Into the open chat
-- box if there is one, otherwise into the auction house search box (Buy tab only) and run the
-- search, otherwise open the chat box with the link in it.
local function InsertLink(link)
  if not link then return false end
  local util = ChatFrameUtil
  local insert = util and util.InsertLink or ChatEdit_InsertLink
  local getActive = util and util.GetActiveWindow or ChatEdit_GetActiveWindow
  local openChat = util and util.OpenChat or ChatFrame_OpenChat
  local chatActive = getActive and getActive()
  local ok, done = pcall(insert, link)
  if ok and done then
    if not chatActive and AuctionHouseFrame and AuctionHouseFrame:IsVisible() and AuctionHouseFrame.SearchBar then
      pcall(AuctionHouseFrame.SearchBar.StartSearch, AuctionHouseFrame.SearchBar)
    end
    return true
  end
  if openChat then pcall(openChat, link) return true end
  return false
end
UI.InsertLink = InsertLink

local function CreateRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(WIDTH - 36, ROW_HEIGHT)
  row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  if index % 2 == 0 then
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.03)
  end
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(18, 18)
  row.cells = {}
  row.button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  row.button:SetSize(58, 19)
  row.button:SetScript("OnClick", function()
    if row.data and row.data.action then row.data.action.fn(row.data) end
  end)
  row.refresh = CreateFrame("Button", nil, row)
  row.refresh:SetSize(16, 16)
  row.refresh:SetPoint("RIGHT", row, "RIGHT", -2, 0)
  row.refresh:SetNormalTexture("Interface\\Buttons\\UI-RefreshButton")
  row.refresh:SetHighlightTexture("Interface\\Buttons\\UI-RefreshButton", "ADD")
  row.refresh:SetScript("OnClick", function()
    if not row.data then return end
    local items, label = RowRefreshItems(row.data)
    ns.Refresh.Items(items, label)
  end)
  row.refresh:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local data = row.data
    local craft = data and data.recipeID and (data.cat == "craft" or data.kind == "recipe" or data.type == "craft")
    GameTooltip:SetText(craft and "Refresh this craft's prices" or "Refresh this price")
    GameTooltip:AddLine(craft and "Searches the auction house for the product and every reagent, including intermediates you craft yourself." or "Searches the auction house for this item now.", 0.8, 0.8, 0.8, true)
    if not ns.ahOpen then GameTooltip:AddLine("Needs the auction house open.", 1, 0.8, 0.4)
    elseif not RefreshReady() then GameTooltip:AddLine("Wait for the current scan, refresh or purchase to finish.", 1, 0.8, 0.4) end
    GameTooltip:Show()
  end)
  row.refresh:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function(_, button)
    local data = row.data
    if not data then return end
    if button == "LeftButton" and IsModifiedClick("CHATLINK") and data.link then
      InsertLink(data.link)
      return
    end
    if data.kind == "recipe" then
      local step = IsControlKeyDown() and 10 or 1
      UI.AdjustShopping(data.recipeID, button == "RightButton" and -step or step)
    elseif data.id and button == "RightButton" and state.tab == "plan" then
      ns.Plan.ToggleDone(data)
    elseif button == "LeftButton" then
      local key = UI.RowKey(data)
      if key then UI.ShowItemChart(key, data.link or data.name) end
    end
  end)
  row:SetScript("OnEnter", function()
    if not row.data then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local shown = false
    if row.data.link then
      local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, row.data.link)
      shown = ok
    end
    if not shown then GameTooltip:SetText(row.data.name or "?") end
    local tab = CurrentTab()
    if tab.tooltip then
      GameTooltip:AddLine(" ")
      pcall(tab.tooltip, row.data, GameTooltip)
    end
    if row.data.kind ~= "recipe" and UI.RowKey(row.data) then
      GameTooltip:AddLine("Click for the price chart.", 0.6, 0.6, 0.6)
    end
    if row.data.link then
      GameTooltip:AddLine("Shift-click to link it in chat or the auction house search.", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return row
end

local function LayoutColumns(columns)
  local x = 0
  for i, col in ipairs(columns) do
    local h = headers[i]
    if not h then
      h = CreateFrame("Button", nil, frame.list)
      h:SetHeight(20)
      h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      h.text:SetAllPoints()
      h:SetScript("OnClick", function() UI.SortBy(i) end)
      headers[i] = h
    end
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", frame.list, "TOPLEFT", x + 2, 22 - ChartRows() * ROW_HEIGHT)
    h:SetWidth(col.width)
    h.text:SetJustifyH(col.align or "LEFT")
    local label = col.label
    if state.sortIndex == i then label = label .. (state.sortDesc and " v" or " ^") end
    h.text:SetText(label)
    h:Show()
    x = x + col.width + 4
  end
  for i = #columns + 1, #headers do headers[i]:Hide() end
  for _, row in ipairs(rows) do
    local rx = 0
    row.hasIcon = false
    for i, col in ipairs(columns) do
      local cell = row.cells[i]
      if not cell then
        cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.cells[i] = cell
      end
      cell:ClearAllPoints()
      cell:SetHeight(ROW_HEIGHT)
      cell:SetJustifyH(col.align or "LEFT")
      cell:SetWordWrap(false)
      if col.item then
        row.hasIcon = true
        row.icon:ClearAllPoints()
        row.icon:SetPoint("LEFT", row, "LEFT", rx + 2, 0)
        cell:SetPoint("LEFT", row, "LEFT", rx + 24, 0)
        cell:SetWidth(col.width - 24)
      else
        cell:SetPoint("LEFT", row, "LEFT", rx + 2, 0)
        cell:SetWidth(col.width)
      end
      if col.button then
        row.button:ClearAllPoints()
        row.button:SetPoint("LEFT", row, "LEFT", rx + 2, 0)
        cell:Hide()
      else
        cell:Show()
      end
      rx = rx + col.width + 4
    end
    for i = #columns + 1, #row.cells do row.cells[i]:Hide() end
  end
end

local function Build()
  if frame then return end
  frame = CreateFrame("Frame", "GoldHoundFrame", UIParent, "BackdropTemplate")
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)
  SetBackdrop(frame, 0.04, 0.04, 0.04, 0.95)
  table.insert(UISpecialFrames, "GoldHoundFrame")

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("|cffffd100GoldHound|r")
  frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.subtitle:SetPoint("LEFT", title, "RIGHT", 10, -1)

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  frame.scan = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.scan:SetSize(100, 22)
  frame.scan:SetPoint("TOPRIGHT", -36, -10)
  frame.scan:SetText("Scan AH")
  frame.scan:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  frame.scan:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      ns.Scan.SetAuto(not ns.Scan.AutoEnabled())
      UI.UpdateScanButton()
      if GameTooltip:GetOwner() == self then self:GetScript("OnEnter")(self) end
    else
      ns.Scan.Start(IsShiftKeyDown())
    end
  end)
  frame.scan:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText("Full auction house scan")
    GameTooltip:AddLine("Needs the auction house open. Shift-click to ignore the cooldown.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Right-click to toggle auto-scan: while the auction house stays open, a new scan starts each time the cooldown ends, so price history builds while you stand there.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine(ns.Scan.AutoEnabled() and "Auto-scan is on." or "Auto-scan is off.", 1, 1, 1)
    local wait = ns.Scan.CooldownRemaining()
    if wait > 0 then GameTooltip:AddLine(("Cooldown: %d:%02d remaining"):format(math.floor(wait / 60), wait % 60), 1, 0.8, 0.4) end
    GameTooltip:Show()
  end)
  -- Keep the button label current while the window is open.
  frame.scan.elapsed = 0
  frame.scan:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = self.elapsed + elapsed
    if self.elapsed >= 1 then
      self.elapsed = 0
      UI.UpdateScanButton()
    end
  end)
  frame.scan:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.refresh:SetSize(110, 22)
  frame.refresh:SetPoint("RIGHT", frame.scan, "LEFT", -6, 0)
  frame.refresh:SetText("Refresh crafts")
  frame.refresh:SetScript("OnClick", function()
    if ns.Refresh.IsRunning() then ns.Refresh.Abort() else ns.Refresh.Start(IsShiftKeyDown()) end
  end)
  frame.refresh:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText("Refresh crafting prices")
    GameTooltip:AddLine("Searches the auction house for every item your recipes make or use, one item at a time. Not limited by the 15 minute full-scan throttle. Needs the auction house open. Shift-click to ignore the cooldown; click again while running to stop.", 0.8, 0.8, 0.8, true)
    local n = ns.db and #ns.Refresh.Targets() or 0
    GameTooltip:AddLine(("%d items to check"):format(n), 1, 1, 1)
    local last = ns.realm and ns.realm.lastRefresh and date("%d %b %H:%M", ns.realm.lastRefresh) or "never"
    GameTooltip:AddLine("Last refresh: " .. last, 1, 1, 1)
    local wait = ns.Refresh.CooldownRemaining()
    if wait > 0 then GameTooltip:AddLine(("Cooldown: %d:%02d remaining"):format(math.floor(wait / 60), wait % 60), 1, 0.8, 0.4) end
    GameTooltip:Show()
  end)
  frame.refresh:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.status:SetPoint("RIGHT", frame.refresh, "LEFT", -10, 0)
  frame.status:SetJustifyH("RIGHT")
  frame.status:SetWidth(300)

  for i, tab in ipairs(TABS) do
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(104, 22)
    b:SetPoint("TOPLEFT", 14 + (i - 1) * 108, -42)
    b:SetText(tab.label)
    b:SetScript("OnClick", function() UI.SelectTab(tab.id) end)
    tabButtons[tab.id] = b
  end

  frame.filterLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.filterLabel:SetPoint("TOPLEFT", 14, -74)
  frame.filterLabel:SetText("Show:")
  for i, f in ipairs(FILTERS) do
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(76, 20)
    b:SetPoint("TOPLEFT", 54 + (i - 1) * 80, -70)
    b:SetText(f.label)
    b:SetScript("OnClick", function() state.filter = f.id; state.offset = 0; UI.Refresh() end)
    filterButtons[f.id] = b
  end

  frame.shopLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.shopLabel:SetPoint("TOPLEFT", 14, -74)
  frame.clearShop = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.clearShop:SetSize(90, 20)
  frame.clearShop:SetText("Clear list")
  frame.clearShop:SetScript("OnClick", function() UI.ClearShopping() end)

  frame.searchBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  frame.searchBox:SetSize(180, 20)
  frame.searchBox:SetPoint("TOPRIGHT", -36, -70)
  frame.searchBox:SetAutoFocus(false)
  frame.searchBox:SetScript("OnTextChanged", function(self)
    state.search = self:GetText():lower()
    state.offset = 0
    UI.Refresh()
  end)
  frame.searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  frame.searchLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.searchLabel:SetPoint("RIGHT", frame.searchBox, "LEFT", -6, 0)
  frame.searchLabel:SetText("Filter:")

  frame.list = CreateFrame("Frame", nil, frame)
  frame.list:SetPoint("TOPLEFT", 14, LIST_TOP)
  frame.list:SetSize(WIDTH - 36, NUM_ROWS * ROW_HEIGHT)
  frame.list:EnableMouseWheel(true)
  frame.list:SetScript("OnMouseWheel", function(_, delta)
    state.offset = state.offset - delta * 3
    UI.Render()
  end)
  for i = 1, NUM_ROWS do rows[i] = CreateRow(frame.list, i) end

  -- Net worth over time, shown above the sales list on the Ledger tab.
  frame.worth = ns.Chart.New(frame.list, WIDTH - 36, CHART_ROWS * ROW_HEIGHT - 4)
  frame.worth:SetPoint("TOPLEFT", frame.list, "TOPLEFT", 0, 22)
  frame.worth:Hide()

  frame.slider = CreateFrame("Slider", nil, frame.list)
  frame.slider:SetOrientation("VERTICAL")
  frame.slider:SetSize(12, NUM_ROWS * ROW_HEIGHT)
  frame.slider:SetPoint("TOPLEFT", frame.list, "TOPRIGHT", 4, 0)
  frame.slider:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
  local track = frame.slider:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(1, 1, 1, 0.06)
  frame.slider:SetMinMaxValues(0, 0)
  frame.slider:SetValueStep(1)
  frame.slider:SetObeyStepOnDrag(true)
  frame.slider:SetScript("OnValueChanged", function(_, value)
    local v = math.floor(value + 0.5)
    if v ~= state.offset then state.offset = v; UI.Render() end
  end)

  frame.empty = frame.list:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.empty:SetPoint("CENTER")
  frame.empty:SetWidth(600)
  frame.empty:SetJustifyH("CENTER")

  frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.footer:SetPoint("BOTTOMLEFT", 14, 12)
  frame.footer:SetPoint("RIGHT", -14, 0)
  frame.footer:SetJustifyH("LEFT")

  frame.settings = CreateFrame("Frame", nil, frame)
  frame.settings:SetPoint("TOPLEFT", 14, -80)
  frame.settings:SetSize(WIDTH - 36, HEIGHT + LIST_TOP)
  frame.settings.fields = {}
  for i, def in ipairs(SETTINGS) do
    local y = -(i - 1) * 34
    local label = frame.settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 10, y - 4)
    label:SetWidth(190)
    label:SetJustifyH("LEFT")
    label:SetText(def.label)
    local hint = frame.settings:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 340, y - 6)
    hint:SetWidth(500)
    hint:SetJustifyH("LEFT")
    hint:SetText(def.hint)
    local field
    if def.kind == "toggle" then
      field = CreateFrame("CheckButton", nil, frame.settings, "UICheckButtonTemplate")
      field:SetPoint("TOPLEFT", 206, y + 2)
      field:SetScript("OnClick", function(self)
        ns.settings[def.key] = self:GetChecked() and true or false
      end)
    else
      field = CreateFrame("EditBox", nil, frame.settings, "InputBoxTemplate")
      field:SetSize(110, 20)
      field:SetPoint("TOPLEFT", 212, y - 2)
      field:SetAutoFocus(false)
      field:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
      field:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
      field:SetScript("OnEditFocusLost", function(self) UI.ApplySetting(def, self) end)
    end
    frame.settings.fields[def.key] = field
  end
  local note = frame.settings:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  note:SetPoint("TOPLEFT", 10, -(#SETTINGS) * 34 - 10)
  note:SetWidth(WIDTH - 60)
  note:SetJustifyH("LEFT")
  note:SetText("Changes apply when you press Enter or leave the box. The same values can be set with /gh commands.")
  frame.settings:Hide()

  frame:SetScript("OnShow", function() UI.Refresh() end)
  frame:SetScript("OnHide", function()
    if not InCombatLockdown() then
      for _, b in pairs(secureButtons) do b:Hide() end
    end
    for _, box in pairs(countBoxes) do box:Hide() end
  end)
  frame:Hide()
end

local function SettingText(def)
  local v = ns.settings[def.key]
  if def.kind == "money" then return ns.MoneyPlain(v) end
  if def.kind == "percent" or def.kind == "ratio" then return tostring(math.floor((v or 0) * 100 + 0.5)) end
  if def.kind == "minutes" then return tostring(math.floor((v or 0) / 60 + 0.5)) end
  return tostring(v or "")
end

function UI.ApplySetting(def, box)
  local text = ns.Trim(box:GetText())
  local value
  if def.kind == "money" then
    value = ns.ParseMoney(text)
  elseif def.kind == "percent" then
    local n = tonumber(text)
    if n and n >= 0 and n < 100 then value = n / 100 end
  elseif def.kind == "ratio" then
    local n = tonumber(text)
    if n and n >= 0 then value = n / 100 end
  elseif def.kind == "minutes" then
    local n = tonumber(text)
    if n and n >= 0 then value = n * 60 end
  else
    local n = tonumber(text)
    if n and n >= 0 then value = n end
  end
  if value == nil then
    ns.Print("%s: could not read '%s'.", def.label, text)
    box:SetText(SettingText(def))
    return
  end
  if ns.settings[def.key] ~= value then
    ns.settings[def.key] = value
    ns.Analysis.Invalidate()
  end
  box:SetText(SettingText(def))
end

local function RefreshSettings()
  for _, def in ipairs(SETTINGS) do
    local field = frame.settings.fields[def.key]
    if def.kind == "toggle" then
      field:SetChecked(ns.settings[def.key] and true or false)
    elseif not field:HasFocus() then
      field:SetText(SettingText(def))
    end
  end
end

-------------------------------------------------------------------------------
-- Rendering
-------------------------------------------------------------------------------
-- Secure buttons that cast a profession spell to open its window. Plain addon
-- code cannot open profession windows, but a secure button can cast the spell.
local function SecureButton(index)
  local b = secureButtons[index]
  if not b then
    b = CreateFrame("Button", "GoldHoundOpenProfession" .. index, frame.list, "SecureActionButtonTemplate, UIPanelButtonTemplate")
    b:SetSize(58, 19)
    b:SetText("Open")
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("type", "spell")
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Open " .. (self.spell or "profession"))
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    secureButtons[index] = b
  end
  return b
end

local function CountBox(index)
  local box = countBoxes[index]
  if not box then
    box = CreateFrame("EditBox", nil, frame.list, "InputBoxTemplate")
    box:SetSize(54, 18)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(4)
    box:SetJustifyH("CENTER")
    local function Apply(self)
      local n = tonumber(self:GetText())
      if n and self.recipeID and n ~= UI.PlannedCrafts(self.recipeID) then UI.SetShoppingCount(self.recipeID, n) end
      self:ClearFocus()
    end
    box:SetScript("OnEnterPressed", Apply)
    box:SetScript("OnEditFocusLost", Apply)
    box:SetScript("OnEscapePressed", function(self) self:SetText(tostring(UI.PlannedCrafts(self.recipeID) or 0)); self:ClearFocus() end)
    box:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Crafts to make. Type a number and press Enter.")
      GameTooltip:Show()
    end)
    box:SetScript("OnLeave", function() GameTooltip:Hide() end)
    countBoxes[index] = box
  end
  return box
end

local function PlaceCountBoxes(tab, list)
  for i, row in ipairs(rows) do
    local data = list[state.offset + i]
    local box = countBoxes[i]
    if tab.id == "plan" and data and data.kind == "recipe" then
      box = CountBox(i)
      box.recipeID = data.recipeID
      if not box:HasFocus() then box:SetText(tostring(data.crafts)) end
      box:ClearAllPoints()
      box:SetPoint("LEFT", row.cells[5], "LEFT", 6, 0)
      box:SetFrameLevel(row:GetFrameLevel() + 10)
      box:Show()
    elseif box then
      box.recipeID = nil
      box:Hide()
    end
  end
end

local function PlaceSecureButtons(tab, list)
  PlaceCountBoxes(tab, list)
  local combat = InCombatLockdown()
  for i, row in ipairs(rows) do
    local data = list[state.offset + i]
    local secure = secureButtons[i]
    local wantSpell = nil
    if tab.id == "plan" and data and data.type == "craft" and data.action and data.action.label == "Open" and data.char == ns.charName then
      wantSpell = ns.Plan.OpenSpell(data)
    end
    if wantSpell and not combat then
      secure = SecureButton(i)
      secure.spell = wantSpell
      secure:SetAttribute("spell", wantSpell)
      secure:ClearAllPoints()
      secure:SetPoint("LEFT", row.button, "LEFT", 0, 0)
      secure:SetFrameStrata(frame:GetFrameStrata())
      secure:SetFrameLevel(row:GetFrameLevel() + 10)
      secure:Show()
      row.button:Hide()
    elseif secure and not combat then
      secure:Hide()
    end
  end
end

local function UpdateRefreshButton()
  local b = frame.refresh
  if not b then return end
  if ns.Refresh.IsRunning() then
    b:SetText("Stop refresh")
    b:SetEnabled(true)
    return
  end
  local wait = ns.Refresh.CooldownRemaining()
  if wait > 0 then
    b:SetText(("Refresh %d:%02d"):format(math.floor(wait / 60), wait % 60))
  else
    b:SetText("Refresh crafts")
  end
  b:SetEnabled(ns.ahOpen and not ns.Scan.IsRunning())
end

local function UpdateRowButtons()
  local ready = RefreshReady()
  for _, row in ipairs(rows) do
    if row.data and row.refresh:IsShown() then
      row.refresh:SetEnabled(ready)
      row.refresh:SetAlpha(ready and 1 or 0.35)
    end
  end
end

function UI.UpdateScanButton()
  if not frame then return end
  UpdateRefreshButton()
  UpdateRowButtons()
  if ns.Scan.IsRunning() then
    frame.scan:SetText("Scanning...")
    frame.scan:SetEnabled(false)
    return
  end
  local wait = ns.Scan.CooldownRemaining()
  local auto = ns.Scan.AutoEnabled()
  if wait > 0 then
    frame.scan:SetText(("%s %d:%02d"):format(auto and "Auto" or "Scan", math.floor(wait / 60), wait % 60))
  else
    frame.scan:SetText(auto and "Auto scan" or "Scan AH")
  end
  frame.scan:SetEnabled(ns.ahOpen or auto)
end

function UI.SortBy(index)
  if state.sortIndex == index then state.sortDesc = not state.sortDesc else state.sortIndex = index; state.sortDesc = true end
  UI.Refresh()
end

local function SortRows(list, columns)
  local col = state.sortIndex and columns[state.sortIndex]
  if not col or not col.value then return end
  local desc = state.sortDesc
  table.sort(list, function(a, b)
    local va, vb = col.value(a), col.value(b)
    if type(va) ~= type(vb) then va, vb = tostring(va), tostring(vb) end
    if va == vb then return (a.name or "") < (b.name or "") end
    if desc then return va > vb end
    return va < vb
  end)
end

function UI.Refresh()
  if not frame or not frame:IsShown() then return end
  local tab = CurrentTab()
  for id, b in pairs(tabButtons) do
    if id == tab.id then b:LockHighlight() else b:UnlockHighlight() end
  end
  local showFilters = tab.id == "opps"
  frame.filterLabel:SetShown(showFilters)
  for id, b in pairs(filterButtons) do
    b:SetShown(showFilters)
    if id == state.filter then b:LockHighlight() else b:UnlockHighlight() end
  end
  local showPlan = tab.id == "plan"
  frame.shopLabel:SetShown(showPlan)
  frame.clearShop:SetShown(showPlan)
  if showPlan then
    local n = #ShoppingList()
    frame.shopLabel:SetText(n == 0 and "Plan is empty." or ("Plan for %s: %d recipe%s. Steps marked ready can be done now; right-click a step to mark it done."):format(ns.charName or "you", n, n == 1 and "" or "s"))
    frame.clearShop:SetText("Clear plan")
    frame.clearShop:SetScript("OnClick", function() UI.ClearShopping() end)
    frame.clearShop:ClearAllPoints()
    frame.clearShop:SetPoint("LEFT", frame.shopLabel, "RIGHT", 10, 0)
  end
  local showSettings = tab.settings == true
  frame.settings:SetShown(showSettings)
  frame.list:SetShown(not showSettings)
  frame.worth:SetShown(not showSettings and tab.chart == true)
  frame.empty:ClearAllPoints()
  frame.empty:SetPoint("CENTER", frame.list, "CENTER", 0, -ChartRows() * ROW_HEIGHT / 2)
  frame.searchBox:SetShown(not showSettings)
  frame.searchLabel:SetShown(not showSettings)
  for _, h in ipairs(headers) do h:SetShown(not showSettings) end
  if showSettings then
    RefreshSettings()
    frame.footer:SetText("")
    return
  end
  if tab.chart then UI.DrawWorth() end
  if state.sortIndex == nil or state.sortIndex > #tab.columns then state.sortIndex = tab.sort; state.sortDesc = true end
  local ok, list = pcall(tab.rows)
  if not ok then
    geterrorhandler()(list)
    list = {}
  end
  local filtered = {}
  for _, row in ipairs(list) do
    if state.search == "" or (row.name and row.name:lower():find(state.search, 1, true)) then
      table.insert(filtered, row)
    end
  end
  SortRows(filtered, tab.columns)
  state.rows = filtered
  LayoutColumns(tab.columns)
  frame.empty:SetText(#filtered == 0 and tab.empty or "")
  UI.Render()
  local net7, n7 = ns.Mail.NetForDays(7)
  local net30 = ns.Mail.NetForDays(30)
  local last = ns.realm and ns.realm.lastScan and date("%d %b %H:%M", ns.realm.lastScan) or "never"
  local refreshed = ns.realm and ns.realm.lastRefresh and date("%d %b %H:%M", ns.realm.lastRefresh) or "never"
  local roi = (ns.settings.minRoi or 0) > 0 and (", min ROI %d%%"):format(ns.settings.minRoi * 100) or ""
  frame.footer:SetText(("%d rows. Last scan: %s. Crafts refreshed: %s. Gold: %s. Sales last 7 days: %s (%d), 30 days: %s. Min profit %s%s, flip discount %d%%, AH cut %d%%."):format(
    #filtered, last, refreshed, ns.Money(ns.Budget()), ns.Money(net7), n7, ns.Money(net30), ns.Money(ns.settings.minProfit), roi, ns.settings.flipDiscount * 100, ns.settings.ahCut * 100))
  UI.UpdateScanButton()
end

function UI.Render()
  if not frame or not frame:IsShown() then return end
  local tab = CurrentTab()
  local list = state.rows
  local placeSecure = function() PlaceSecureButtons(tab, list) end
  local skip = ChartRows()
  local maxOffset = math.max(0, #list - (NUM_ROWS - skip))
  if state.offset > maxOffset then state.offset = maxOffset end
  if state.offset < 0 then state.offset = 0 end
  frame.slider:SetMinMaxValues(0, maxOffset)
  frame.slider:SetValue(state.offset)
  frame.slider:SetShown(maxOffset > 0)
  local ready = RefreshReady()
  local hasButton = false
  for _, col in ipairs(tab.columns) do
    if col.button then hasButton = true end
  end
  for i, row in ipairs(rows) do
    local data = i > skip and list[state.offset + i - skip] or nil
    row.data = data
    if data then
      -- Tabs without an action column must not keep the previous tab's button.
      if not hasButton then row.button:Hide() end
      for c, col in ipairs(tab.columns) do
        if col.text then
          local ok, text = pcall(col.text, data)
          row.cells[c]:SetText(ok and tostring(text or "") or "?")
        end
        if col.button then
          if data.action then
            local label = data.action.label
            if label == "Add" and data.recipeID then
              local planned = UI.PlannedCrafts(data.recipeID)
              if planned > 0 then label = ("Add (%d)"):format(planned) end
            end
            row.button:SetText(label)
            row.button:SetEnabled(data.action.enabled ~= false)
            row.button:Show()
          else
            row.button:Hide()
          end
        end
      end
      local icon = data.icon
      if not icon and data.itemID then
        local info = ns.ItemInfo(data.itemID)
        icon = info and info.icon
      end
      row.icon:SetTexture(icon or 134400)
      row.icon:SetShown(row.hasIcon)
      local canRefresh = data.kind ~= "recipe" and UI.RowKey(data) ~= nil or (data.kind == "recipe" and data.recipeID ~= nil)
      row.refresh:SetShown(canRefresh)
      row.refresh:SetEnabled(ready)
      row.refresh:SetAlpha(ready and 1 or 0.35)
      row:Show()
      if ns.ahOpen and data.itemID and C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo then
        pcall(C_AuctionHouse.GetItemKeyInfo, C_AuctionHouse.MakeItemKey(data.itemID))
      end
    else
      row:Hide()
    end
  end
  placeSecure()
end

function UI.SelectTab(id)
  state.tab = id
  state.offset = 0
  state.sortIndex = nil
  UI.Refresh()
end

function UI.Show()
  Build()
  frame:Show()
  UI.Refresh()
end

function UI.Toggle()
  Build()
  if frame:IsShown() then frame:Hide() else UI.Show() end
end

-------------------------------------------------------------------------------
-- Charts: net worth on the Ledger tab, and a price history popup per item.
-------------------------------------------------------------------------------
function UI.DrawWorth()
  if not frame or not frame.worth then return end
  local raw = ns.Worth.Points()
  local gold, assets = {}, {}
  for _, p in ipairs(raw) do
    table.insert(gold, { p.t, p.g or 0 })
    table.insert(assets, { p.t, (p.i or 0) + (p.a or 0) })
  end
  ns.Chart.DrawLines(frame.worth, {
    { name = "Gold", color = { 1, 0.82, 0.2 }, points = gold },
    { name = "Assets (inventory + auctions at market value)", color = { 0.35, 0.65, 1 }, points = assets },
  }, {
    empty = "Net worth is sampled as you play: gold across your characters, plus bags, bank, mail and auctions at market value.",
    extra = function(t, lines)
      local best
      for _, p in ipairs(raw) do
        if not best or math.abs(p.t - t) < math.abs(best.t - t) then best = p end
      end
      if not best then return end
      for i = #lines, 1, -1 do lines[i] = nil end
      table.insert(lines, { "Gold", ns.Money(best.g or 0) })
      table.insert(lines, { "Inventory at market value", ns.Money(best.i or 0) })
      table.insert(lines, { "Auctions listed", ns.Money(best.a or 0) })
      table.insert(lines, { "Total", ns.Money((best.g or 0) + (best.i or 0) + (best.a or 0)) })
    end,
  })
end

local itemChart
local function BuildItemChart()
  if itemChart then return end
  local f = CreateFrame("Frame", "GoldHoundItemChart", UIParent, "BackdropTemplate")
  f:SetSize(660, 410)
  f:SetPoint("CENTER", 0, 40)
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  SetBackdrop(f, 0.04, 0.04, 0.04, 0.97)
  table.insert(UISpecialFrames, "GoldHoundItemChart")
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetPoint("TOPLEFT", 14, -12)
  f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.sub:SetPoint("TOPLEFT", 14, -36)
  f.sub:SetPoint("RIGHT", -14, 0)
  f.sub:SetJustifyH("LEFT")
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)
  f.refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.refresh:SetSize(110, 22)
  f.refresh:SetPoint("TOPRIGHT", -34, -10)
  f.refresh:SetText("Refresh price")
  f.refresh:SetScript("OnClick", function()
    local itemID = f.key and ns.ItemIDFromKey(f.key)
    if itemID then ns.Refresh.Items({ itemID }, f.name or "item") end
  end)
  f.chart = ns.Chart.New(f, 660 - 28, 410 - 112)
  f.chart:SetPoint("TOPLEFT", 14, -62)
  f.legend = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.legend:SetPoint("BOTTOMLEFT", 14, 10)
  f.legend:SetPoint("RIGHT", -14, 0)
  f.legend:SetJustifyH("LEFT")
  f.legend:SetText("Grey area: lowest to highest listing. Blue area: 25th to 75th percentile of the units listed. White line with dots: median at each observation. Yellow line: mean. A red tick at the top means the highest listing was off the scale. Hover for the numbers.")
  itemChart = f
end

function UI.ShowItemChart(key, name)
  BuildItemChart()
  local f = itemChart
  f.key, f.name = key, name
  local itemID = ns.ItemIDFromKey(key)
  local info = itemID and ns.ItemInfo(itemID)
  f.title:SetText(info and info.link or name or ("item " .. tostring(key)))
  local entry = ns.Pricing.GetEntry(key)
  local points = {}
  for _, h in ipairs(entry and entry.h or {}) do
    table.insert(points, { t = h.t, min = h.m, p25 = h.l or h.m, med = h.d or h.m, p75 = h.u or h.m, max = h.x or h.m, mean = h.a or h.m, qty = h.q, n = h.n })
  end
  if #points == 0 then
    f.sub:SetText("No price history for this item yet. A point is added by every full scan and by each refresh of the item.")
  else
    local market = ns.Pricing.GetMarket(key)
    f.sub:SetText(("%d observations, %s to %s. Market value now %s. Cheapest at last check %s, %d listed."):format(
      #points, date("%d %b %H:%M", points[1].t or 0), date("%d %b %H:%M", points[#points].t or 0),
      market and ns.Money(market) or "unknown", entry and entry.m and ns.Money(entry.m) or "?", ns.Pricing.Listed(key)))
  end
  ns.Chart.DrawBands(f.chart, points, { empty = "No price history for this item yet." })
  f.refresh:SetEnabled(itemID ~= nil and RefreshReady())
  f:Show()
end

-- Alt-click on any item link (chat, bags, bank, merchant, auction house...)
-- opens the price chart. Blizzard routes every modified click on an item
-- through HandleModifiedItemClick, and Alt counts as a modified click because
-- the self-cast key defaults to it. Chat links are also hooked directly in
-- case that binding has been changed.
local lastAltClick = -1
local function AltClickLink(link)
  if not link or not IsAltKeyDown() or IsShiftKeyDown() or IsControlKeyDown() then return end
  if GetTime() == lastAltClick then return end -- the same click reached both hooks
  local itemID = ns.ItemIDFromLink(link)
  if not itemID then return end
  lastAltClick = GetTime()
  UI.ShowItemChart(ns.KeyFor(itemID, ns.SuffixFromLink(link)), link)
end

ns.On("READY", function()
  if HandleModifiedItemClick then hooksecurefunc("HandleModifiedItemClick", function(link) AltClickLink(link) end) end
  if SetItemRef then hooksecurefunc("SetItemRef", function(link, text) AltClickLink(text or link) end) end
end)

ns.On("ANALYSIS_DIRTY", function()
  if itemChart and itemChart:IsShown() and itemChart.key then
    ns.Debounce("item-chart", 0.3, function() UI.ShowItemChart(itemChart.key, itemChart.name) end)
  end
end)
ns.On("WORTH_UPDATED", function()
  if frame and frame:IsShown() and state.tab == "ledger" then ns.Debounce("worth-chart", 0.3, UI.DrawWorth) end
end)

function UI.IsShown()
  return frame and frame:IsShown()
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
ns.On("SCAN_STATUS", function(text)
  if frame then frame.status:SetText(text or ""); UI.UpdateScanButton() end
end)
ns.On("BUY_STATUS", function(text)
  if frame then frame.status:SetText(text or "") end
end)
ns.On("ANALYSIS_DIRTY", function() ns.Debounce("ui-refresh", 0.2, function() UI.Refresh() end) end)
ns.On("INVENTORY_UPDATED", function() if state.tab == "plan" then ns.Debounce("ui-refresh", 0.1, function() UI.Refresh() end) end end)
ns.On("PLAN_CHANGED", function() if state.tab == "plan" then ns.Debounce("ui-refresh", 0.1, function() UI.Refresh() end) end end)
ns.On("LISTING_BOUGHT", function() if state.tab == "plan" then ns.Debounce("ui-refresh", 1.0, function() UI.Refresh() end) end end)
ns.On("AH_OPEN", function() if frame then UI.Refresh() end end)
ns.On("AH_CLOSED", function() if frame then UI.Refresh() end end)

-- A small button on the Blizzard auction house frame, in the tab row below it
-- so it never overlaps the search bar.
local function AddAHButton()
  if UI.ahButton or not AuctionHouseFrame then return end
  local b = CreateFrame("Button", "GoldHoundAHButton", AuctionHouseFrame, "UIPanelButtonTemplate")
  b:SetSize(90, 24)
  b:SetPoint("TOPRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -6, -3)
  b:SetText("GoldHound")
  b:SetScript("OnClick", function() UI.Toggle() end)
  UI.ahButton = b
end
ns.On("AH_OPEN", function() C_Timer.After(0, AddAHButton) end)

-------------------------------------------------------------------------------
-- Minimap button. Drag it around the ring; left-click toggles the window,
-- right-click starts a scan when the auction house is open.
-------------------------------------------------------------------------------
local function MinimapPosition(angle)
  local radius = (Minimap:GetWidth() / 2) + 5
  local rad = math.rad(angle)
  return math.cos(rad) * radius, math.sin(rad) * radius
end

local function CreateMinimapButton()
  if UI.minimapButton or not Minimap then return end
  local b = CreateFrame("Button", "GoldHoundMinimapButton", Minimap)
  b:SetSize(32, 32)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetSize(20, 20)
  icon:SetPoint("CENTER", 0, 1)
  icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(54, 54)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  local function Place()
    local x, y = MinimapPosition(ns.settings.minimapAngle or 220)
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", x, y)
  end

  local function DragUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    ns.settings.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
    Place()
  end

  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", DragUpdate)
    GameTooltip:Hide()
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  b:SetScript("OnClick", function(_, button)
    if button == "RightButton" and IsShiftKeyDown() then
      ns.Refresh.Start(true)
    elseif button == "RightButton" then
      ns.Scan.Start(false)
    else
      UI.Toggle()
    end
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("|cffffd100GoldHound|r")
    GameTooltip:AddLine("Left-click: open the window", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: scan the auction house (when open)", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Shift-right-click: refresh crafting prices only", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag: move the button", 0.8, 0.8, 0.8)
    local last = ns.realm and ns.realm.lastScan and date("%d %b %H:%M", ns.realm.lastScan) or "never"
    GameTooltip:AddLine("Last scan: " .. last, 1, 1, 1)
    local wait = ns.Scan.CooldownRemaining()
    if wait > 0 then GameTooltip:AddLine(("Next scan in %d:%02d"):format(math.floor(wait / 60), wait % 60), 1, 0.8, 0.4) end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  Place()
  UI.minimapButton = b
end
ns.On("READY", CreateMinimapButton)
