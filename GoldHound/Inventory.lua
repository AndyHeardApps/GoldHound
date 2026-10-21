-- GoldHound: remembers what each character carries in bags and bank, so the
-- shopping list can count materials across all your characters on the realm.
local ADDON, ns = ...
local Inventory = {}
ns.Inventory = Inventory

local BagIndex = Enum.BagIndex or {}
local BACKPACK = BagIndex.Backpack or 0
local LAST_BAG = BagIndex.ReagentBag or 5
local BANK = BagIndex.Bank or -1
local REAGENT_BANK = BagIndex.Reagentbank or -3
local FIRST_BANK_BAG = BagIndex.BankBag_1 or 6
local LAST_BANK_BAG = BagIndex.BankBag_7 or 12

local function CountBag(bagID, into)
  local okn, slots = pcall(C_Container.GetContainerNumSlots, bagID)
  if not okn or type(slots) ~= "number" or slots <= 0 then return end
  for slot = 1, slots do
    local ok, info = pcall(C_Container.GetContainerItemInfo, bagID, slot)
    if ok and type(info) == "table" and info.itemID then
      into[info.itemID] = (into[info.itemID] or 0) + (info.stackCount or 1)
    end
  end
end

local function Rec()
  if not ns.db or not ns.charKey then return nil end
  local rec = ns.db.chars[ns.charKey]
  if not rec then
    rec = { name = ns.charName, realm = ns.realmName, realmKey = ns.realmKey, professions = {} }
    ns.db.chars[ns.charKey] = rec
  end
  return rec
end

local function CaptureBags()
  local rec = Rec()
  if not rec then return end
  local bags = {}
  for bagID = BACKPACK, LAST_BAG do CountBag(bagID, bags) end
  -- Items credited as incoming that have now shown up in the bags are no longer in transit.
  if rec.incoming and rec.bags then
    for itemID, qty in pairs(rec.incoming) do
      local gained = (bags[itemID] or 0) - (rec.bags[itemID] or 0)
      if gained >= qty then rec.incoming[itemID] = nil
      elseif gained > 0 then rec.incoming[itemID] = qty - gained end
    end
    if next(rec.incoming) == nil then rec.incoming = nil end
  end
  rec.bags = bags
  rec.bagsT = time()
  ns.Fire("INVENTORY_UPDATED")
end

local function CaptureBank()
  local rec = Rec()
  if not rec then return end
  local bank = {}
  CountBag(BANK, bank)
  pcall(CountBag, REAGENT_BANK, bank)
  for bagID = FIRST_BANK_BAG, LAST_BANK_BAG do CountBag(bagID, bank) end
  rec.bank = bank
  rec.bankT = time()
  ns.Fire("INVENTORY_UPDATED")
end

local bankOpen = false
ns.On("READY", function() C_Timer.After(3, CaptureBags) end)
ns.RegisterEvent("BAG_UPDATE_DELAYED", function()
  ns.Debounce("inv-bags", 0.3, CaptureBags)
  if bankOpen then ns.Debounce("inv-bank", 1.0, CaptureBank) end
end)
function Inventory.CaptureBags()
  ns.Debounce("inv-bags", 0.2, CaptureBags)
end
ns.RegisterEvent("BANKFRAME_OPENED", function()
  bankOpen = true
  C_Timer.After(0.5, CaptureBank)
end)
ns.RegisterEvent("BANKFRAME_CLOSED", function() bankOpen = false end)
ns.RegisterEvent("PLAYERBANKSLOTS_CHANGED", function()
  if bankOpen then ns.Debounce("inv-bank", 1.0, CaptureBank) end
end)
ns.RegisterEvent("PLAYER_LOGOUT", CaptureBags)

-- Units of an item held by one character record (bags, bank, and mail in transit).
local function Held(rec, itemID)
  local n = 0
  if rec.bags then n = n + (rec.bags[itemID] or 0) end
  if rec.bank then n = n + (rec.bank[itemID] or 0) end
  if rec.incoming then n = n + (rec.incoming[itemID] or 0) end
  return n
end

-- Records items mailed to another character so the plan counts them as theirs
-- until that character collects the mail.
function Inventory.NoteIncoming(charName, itemID, qty)
  if not ns.db then return end
  for key, rec in pairs(ns.db.chars) do
    if rec.realm == ns.realmName and rec.name == charName then
      rec.incoming = rec.incoming or {}
      rec.incoming[itemID] = (rec.incoming[itemID] or 0) + qty
      ns.Fire("INVENTORY_UPDATED")
      return
    end
  end
end

-- Once this character has been at a mailbox, mail in transit has been collected.
ns.RegisterEvent("MAIL_CLOSED", function()
  local rec = ns.db and ns.db.chars[ns.charKey]
  if rec and rec.incoming then
    rec.incoming = nil
    ns.Fire("INVENTORY_UPDATED")
  end
end)

-- Total held across all your characters on this realm. The logged-in character
-- is counted live (bags and bank) rather than from the snapshot.
function Inventory.Count(itemID)
  local total = 0
  for _, _, count in Inventory.Breakdown(itemID) do total = total + count end
  return total
end

-- Iterator over (charKey, name, count) for characters holding the item.
function Inventory.Breakdown(itemID)
  local list = {}
  if ns.db then
    for key, rec in pairs(ns.db.chars) do
      if rec.realm == ns.realmName then
        local count
        if key == ns.charKey then
          local ok, live = pcall(C_Item.GetItemCount, itemID, true)
          if ok and type(live) == "number" then
            -- Live bags and bank, plus purchases and mail still on their way.
            count = live + ((rec.incoming and rec.incoming[itemID]) or 0)
          else
            count = Held(rec, itemID)
          end
        else
          count = Held(rec, itemID)
        end
        if count > 0 then table.insert(list, { key, rec.name or key, count }) end
      end
    end
  end
  table.sort(list, function(a, b) return a[3] > b[3] end)
  local i = 0
  return function()
    i = i + 1
    local e = list[i]
    if e then return e[1], e[2], e[3] end
  end
end
