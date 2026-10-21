-- GoldHound: price lines on item tooltips.
local ADDON, ns = ...

local GREY = "|cff9d9d9d"
local R = "|r"

local function AddLines(tooltip, link)
  if not ns.realm or not ns.settings.showTooltip then return end
  local itemID = ns.ItemIDFromLink(link)
  if not itemID then return end
  local key = ns.KeyFor(itemID, ns.SuffixFromLink(link))
  local entry = ns.Pricing.GetEntry(key)
  local market, source = ns.Pricing.GetMarket(key)
  local rate, rateSource = ns.Pricing.Rate(key)
  local craft = ns.Analysis.CraftCostFor(itemID)
  local vendorBuy = ns.db.vendorBuy[itemID]
  local de = nil
  if ns.Chars.HasProfession("Enchanting") then de = ns.Pricing.GetDisenchantValue(itemID) end
  if not (entry or market or craft or vendorBuy or de) then return end
  tooltip:AddLine(" ")
  tooltip:AddLine("|cffffd100GoldHound|r", 1, 1, 1)
  if market then
    tooltip:AddDoubleLine("Market value (" .. source .. ")", ns.Money(market), 0.8, 0.8, 0.8, 1, 1, 1)
  end
  if entry and entry.m then
    local age = ns.realm.lastScan and entry.t and entry.t < ns.realm.lastScan
    tooltip:AddDoubleLine("Cheapest at last scan", ns.Money(entry.m) .. (age and (GREY .. " (older scan)" .. R) or ""), 0.8, 0.8, 0.8, 1, 1, 1)
    tooltip:AddDoubleLine("Listed", tostring(ns.Pricing.Listed(key)), 0.8, 0.8, 0.8, 1, 1, 1)
  end
  tooltip:AddDoubleLine("Sale rate", ns.Pricing.RateText(rate) .. (rateSource == "yours" and (GREY .. " (your sales)" .. R) or ""), 0.8, 0.8, 0.8, 1, 1, 1)
  if craft then
    tooltip:AddDoubleLine("Craft cost", ns.Money(craft.perUnit), 0.8, 0.8, 0.8, 1, 1, 1)
  end
  if vendorBuy then
    local meta = ns.db.vendorInfo[itemID]
    tooltip:AddDoubleLine("Vendor sells for", ns.Money(vendorBuy) .. (meta and meta.limited and (GREY .. " (limited)" .. R) or ""), 0.8, 0.8, 0.8, 1, 1, 1)
  end
  if de and de > 0 then
    tooltip:AddDoubleLine("Disenchant value", ns.Money(de), 0.8, 0.8, 0.8, 1, 1, 1)
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
