-- GoldHound: price lines on item tooltips.
local ADDON, ns = ...

local GREY, WHITE, GREEN, RED, ORANGE, GOLD, R = "|cff9d9d9d", "|cffffffff", "|cff33ff33", "|cffff4444", "|cffffa040", "|cffffd100", "|r"
local LABEL = { 0.72, 0.82, 1 }   -- label colour for our lines
local SECTION = { 1, 0.82, 0 }    -- section headings

local function Line(tooltip, label, value)
  tooltip:AddDoubleLine(label, value, LABEL[1], LABEL[2], LABEL[3], 1, 1, 1)
end

local function Section(tooltip, text)
  tooltip:AddLine(text, SECTION[1], SECTION[2], SECTION[3])
end

-- "+1g20s" in green or "-30s" in red: how a price compares with the market value.
local function Versus(value, market)
  if not market or market <= 0 then return "" end
  local diff = value - market
  local pct = diff / market * 100
  if math.abs(pct) < 1 then return GREY .. " (at market)" .. R end
  local colour = diff < 0 and GREEN or RED
  return colour .. (" (%s%d%% vs market)"):format(diff > 0 and "+" or "-", math.floor(math.abs(pct) + 0.5)) .. R
end

local function RateColoured(rate, rateSource)
  local text = ns.Pricing.RateText(rate)
  if rate == nil then return text end
  local colour = rate >= 1 and GREEN or (rate >= 0.25 and WHITE or ORANGE)
  text = colour .. text .. R
  if rateSource == "yours" then text = text .. GREY .. " (your sales)" .. R end
  return text
end

local function AddLines(tooltip, link)
  if not ns.realm or not ns.settings.showTooltip then return end
  local itemID = ns.ItemIDFromLink(link)
  if not itemID then return end
  local key = ns.KeyFor(itemID, ns.SuffixFromLink(link))
  local entry = ns.Pricing.GetEntry(key)
  local market, source = ns.Pricing.GetMarket(key)
  local typical, scans = ns.Pricing.Typical(key)
  local rate, rateSource = ns.Pricing.Rate(key)
  local craft = ns.Analysis.CraftCostFor(itemID)
  local vendorBuy = ns.db.vendorBuy[itemID]
  local de = nil
  if ns.Chars.HasProfession("Enchanting") then de = ns.Pricing.GetDisenchantValue(itemID) end
  if not (entry or market or craft or vendorBuy or de) then return end

  tooltip:AddLine(" ")
  tooltip:AddLine(GOLD .. "GoldHound" .. R)

  -- Auction house prices.
  if market then
    local sourceText = source == "low floor" and (ORANGE .. "low floor" .. R) or (GREY .. source .. R)
    Line(tooltip, "Market value", WHITE .. ns.Money(market) .. R .. " " .. sourceText)
    if typical and math.abs(typical - market) > market * 0.02 then
      Line(tooltip, ("Typical (%d scans)"):format(scans), ns.Money(typical))
    end
  end
  if entry and entry.m then
    local stale = ns.realm.lastScan and entry.t and entry.t < ns.realm.lastScan
    local listed = ns.Pricing.Listed(key)
    Line(tooltip, stale and "Cheapest (older scan)" or "Cheapest listed",
      ns.Money(entry.m) .. GREY .. (listed > 0 and (" (%d listed)"):format(listed) or " (none listed now)") .. R)
  end
  Line(tooltip, "Sale rate", RateColoured(rate, rateSource))

  -- Other ways to get it or get rid of it, each compared with the market value.
  if craft or vendorBuy or (de and de > 0) then
    Section(tooltip, "Alternatives")
    if craft then
      Line(tooltip, "Craft cost", ns.Money(craft.perUnit) .. Versus(craft.perUnit, market))
    end
    if vendorBuy then
      local meta = ns.db.vendorInfo[itemID]
      Line(tooltip, "Vendor sells for", ns.Money(vendorBuy) .. (meta and meta.limited and (GREY .. " (limited)" .. R) or "") .. Versus(vendorBuy, market))
    end
    if de and de > 0 then
      local better = market and de > market
      Line(tooltip, "Disenchant value", ns.Money(de) .. (better and (GREEN .. " (more than selling)" .. R) or ""))
    end
  end
end

local function Hook()
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
      if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
      local link = data and data.hyperlink
      if not link and tooltip.GetItem then
        local ok, _, l = pcall(tooltip.GetItem, tooltip)
        if ok then link = l end
      end
      if link then pcall(AddLines, tooltip, link) end
    end)
  elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
      local ok, _, link = pcall(tooltip.GetItem, tooltip)
      if ok and link then pcall(AddLines, tooltip, link) end
    end)
  end
end

ns.On("READY", Hook)
