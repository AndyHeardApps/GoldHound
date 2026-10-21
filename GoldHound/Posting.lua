-- GoldHound: posting helper shown next to the Blizzard sell tab. Suggests a
-- price from market value and current undercuts, shows deposits and sale rate.
local ADDON, ns = ...
local Posting = {}
ns.Posting = Posting

local panel, current

local function Line(parent, y)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", 10, y)
  fs:SetPoint("RIGHT", -10, 0)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(true)
  return fs
end

local function Build()
  if panel then return end
  panel = CreateFrame("Frame", "GoldHoundPostingPanel", AuctionHouseFrame, "BackdropTemplate")
  panel:SetSize(250, 210)
  panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 2, -10)
  panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  panel:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
  panel:SetFrameStrata("HIGH")
  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 10, -8)
  title:SetText("|cffffd100GoldHound|r posting helper")
  panel.item = Line(panel, -26)
  panel.market = Line(panel, -44)
  panel.cheapest = Line(panel, -60)
  panel.rate = Line(panel, -76)
  panel.deposit = Line(panel, -92)
  panel.suggest = Line(panel, -124)
  panel.warning = Line(panel, -156)
  panel.warning:SetTextColor(1, 0.5, 0.3)
  panel.use = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  panel.use:SetSize(110, 22)
  panel.use:SetPoint("BOTTOMLEFT", 10, 10)
  panel.use:SetText("Use price")
  panel.use:SetScript("OnClick", function() Posting.UseSuggested() end)
  panel:Hide()
end

local function SellFrame()
  if not current then return nil end
  return current.commodity and AuctionHouseFrame.CommoditiesSellFrame or AuctionHouseFrame.ItemSellFrame
end

local function Durations(itemID, location, qty, commodity)
  local out = {}
  for duration = 1, 3 do
    local ok, deposit
    if commodity then
      ok, deposit = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, duration, qty)
    else
      ok, deposit = pcall(C_AuctionHouse.CalculateItemDeposit, location, duration, qty)
    end
    table.insert(out, ok and deposit and ns.Money(deposit) or "?")
  end
  local labels = { AUCTION_DURATION_ONE or "short", AUCTION_DURATION_TWO or "medium", AUCTION_DURATION_THREE or "long" }
  return ("%s: %s, %s: %s, %s: %s"):format(labels[1], out[1], labels[2], out[2], labels[3], out[3])
end

local function Refresh()
  if not panel or not current then return end
  local c = current
  local key = ns.KeyFor(c.itemID, c.suffix)
  local market, source = ns.Pricing.GetMarket(key)
  local rate = ns.Pricing.Rate(key)
  local cheapest = c.cheapest
  panel.item:SetText(c.link or ("item " .. c.itemID))
  panel.market:SetText("Market value: " .. (market and (ns.Money(market) .. " each (" .. source .. ")") or "|cff9d9d9dunknown, scan first|r"))
  panel.cheapest:SetText("Cheapest listed now: " .. (cheapest and (ns.Money(cheapest) .. " each") or "|cff9d9d9dnone|r"))
  panel.rate:SetText("Sale rate: " .. ns.Pricing.RateText(rate) .. (rate and (" (" .. ("%.1f"):format(ns.Pricing.DaysToSell(rate, c.count) or 0) .. " days for " .. c.count .. ")") or ""))
  panel.deposit:SetText("Deposit " .. Durations(c.itemID, c.location, c.count, c.commodity))
  local suggested
  if cheapest and market then
    suggested = math.min(cheapest - 1, market)
    if cheapest < market * (1 - ns.settings.flipDiscount) then
      panel.warning:SetText(("The current cheapest listing is %d%% under the market value. Consider waiting or buying it out."):format((1 - cheapest / market) * 100))
    else
      panel.warning:SetText("")
    end
  elseif cheapest then
    suggested = cheapest - 1
    panel.warning:SetText("")
  elseif market then
    suggested = market
    panel.warning:SetText("Nothing else is listed; price from market history.")
  else
    panel.warning:SetText("No price data yet. Run a full scan.")
  end
  if suggested and suggested < 1 then suggested = 1 end
  c.suggested = suggested
  panel.suggest:SetText(suggested and ("Suggested: |cff33ff33" .. ns.Money(suggested) .. "|r each, net " .. ns.Money(suggested * c.count * (1 - ns.settings.ahCut)) .. " for the stack") or "")
  panel.use:SetEnabled(suggested ~= nil)
  panel:Show()
end

function Posting.UseSuggested()
  local sell = SellFrame()
  if not sell or not current or not current.suggested then return end
  local price = math.floor(current.suggested)
  local ok = false
  if sell.PriceInput and sell.PriceInput.SetAmount then
    ok = pcall(sell.PriceInput.SetAmount, sell.PriceInput, price)
  end
  if ok and sell.SecondaryPriceInput and sell.SecondaryPriceInput.SetAmount and not current.commodity then
    pcall(sell.SecondaryPriceInput.SetAmount, sell.SecondaryPriceInput, price)
  end
  if not ok then ns.Print("Could not set the price automatically; enter %s manually.", ns.Money(price)) end
end

local function OnItem(frameObj, location, commodity)
  if not location then
    current = nil
    if panel then panel:Hide() end
    return
  end
  local okID, itemID = pcall(C_Item.GetItemID, location)
  if not okID or not itemID then return end
  local _, link = pcall(C_Item.GetItemLink, location)
  local _, count = pcall(C_Item.GetStackCount, location)
  current = { itemID = itemID, link = link, suffix = ns.SuffixFromLink(link), count = count or 1, location = location, commodity = commodity, cheapest = nil }
  Refresh()
end

local function ReadCheapest(itemKey, commodity)
  if not current or not itemKey or itemKey.itemID ~= current.itemID then return end
  local cheapest
  if commodity then
    local n = C_AuctionHouse.GetNumCommoditySearchResults(itemKey.itemID)
    for i = 1, n do
      local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemKey.itemID, i)
      if r and not r.containsOwnerItem and (not cheapest or r.unitPrice < cheapest) then cheapest = r.unitPrice end
    end
  else
    local n = C_AuctionHouse.GetNumItemSearchResults(itemKey)
    for i = 1, n do
      local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
      if r and not r.containsOwnerItem and r.buyoutAmount and r.buyoutAmount > 0 then
        local unit = r.buyoutAmount / math.max(1, r.quantity or 1)
        if not cheapest or unit < cheapest then cheapest = unit end
      end
    end
  end
  current.cheapest = cheapest
  Refresh()
end

ns.RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
  if current and not current.commodity then ReadCheapest(itemKey, false) end
end)
ns.RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
  if current and current.commodity then ReadCheapest({ itemID = itemID }, true) end
end)

local hooked = false
local function Setup()
  if hooked or not AuctionHouseFrame then return end
  hooked = true
  Build()
  local itemSell, commoditySell = AuctionHouseFrame.ItemSellFrame, AuctionHouseFrame.CommoditiesSellFrame
  if itemSell and itemSell.SetItem then
    hooksecurefunc(itemSell, "SetItem", function(self, location) OnItem(self, location, false) end)
    itemSell:HookScript("OnHide", function() if current and not current.commodity then current = nil; panel:Hide() end end)
  end
  if commoditySell and commoditySell.SetItem then
    hooksecurefunc(commoditySell, "SetItem", function(self, location) OnItem(self, location, true) end)
    commoditySell:HookScript("OnHide", function() if current and current.commodity then current = nil; panel:Hide() end end)
  end
  AuctionHouseFrame:HookScript("OnHide", function() current = nil; panel:Hide() end)
end

ns.RegisterEvent("ADDON_LOADED", function(name)
  if name == "Blizzard_AuctionHouseUI" then C_Timer.After(0, Setup) end
end)
ns.On("AH_OPEN", function() C_Timer.After(0, Setup) end)
ns.On("SCAN_COMPLETE", function() if current then Refresh() end end)
ns.On("REFRESH_COMPLETE", function() if current then Refresh() end end)
