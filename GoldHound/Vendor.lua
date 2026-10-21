-- GoldHound: remembers what merchants sell, at what price, and whether stock is limited.
local ADDON, ns = ...
local Vendor = {}
ns.Vendor = Vendor

local function MerchantName()
  local ok, name = pcall(UnitName, "npc")
  if not ok or type(name) ~= "string" then name = "Vendor" end
  local okz, zone = pcall(GetZoneText)
  if okz and type(zone) == "string" and zone ~= "" then return name .. " (" .. zone .. ")" end
  return name
end

local function Capture()
  if not ns.db then return end
  local okn, n = pcall(GetMerchantNumItems)
  if not okn or type(n) ~= "number" then return end
  local where = MerchantName()
  local changed = 0
  for i = 1, n do
    local oki, info = pcall(C_MerchantFrame.GetItemInfo, i)
    local okl, link = pcall(GetMerchantItemLink, i)
    if oki and okl and info and link and info.price and info.price > 0 and not info.hasExtendedCost then
      local itemID = ns.ItemIDFromLink(link)
      if itemID then
        local per = info.price / math.max(1, info.stackCount or 1)
        local limited = info.numAvailable ~= nil and info.numAvailable >= 0
        local old = ns.db.vendorBuy[itemID]
        if not old or per < old then
          ns.db.vendorBuy[itemID] = per
          changed = changed + 1
        end
        local meta = ns.db.vendorInfo[itemID] or {}
        meta.where = where
        meta.limited = limited
        meta.t = time()
        local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
        meta.classID = classID
        ns.db.vendorInfo[itemID] = meta
      end
    end
  end
  if changed > 0 then
    ns.Fire("VENDOR_UPDATED")
  end
end

ns.RegisterEvent("MERCHANT_SHOW", function() C_Timer.After(0.4, Capture) end)
ns.RegisterEvent("MERCHANT_UPDATE", function() ns.Debounce("merchant", 0.6, Capture) end)
