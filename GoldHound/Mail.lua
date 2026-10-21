-- GoldHound: records auction sales from mailbox invoices when you collect the gold.
local ADDON, ns = ...
local Mail = {}
ns.Mail = Mail

local MAX_RECENT = 400
local collected = {}

local function Record(index)
  if not ns.realm then return end
  local ok, invoiceType, itemName, playerName, bid, buyout, deposit, consignment, _, _, _, count = pcall(GetInboxInvoiceInfo, index)
  if not ok or invoiceType ~= "seller" or not itemName then return end
  local okh, _, _, sender, subject, money = pcall(GetInboxHeaderInfo, index)
  local signature = ("%s|%s|%s|%s"):format(itemName, tostring(bid), tostring(playerName), tostring(okh and money or 0))
  if collected[signature] then return end
  collected[signature] = GetTime()
  local price = (bid and bid > 0) and bid or (buyout or 0)
  if price <= 0 then return end
  local units = count or 1
  local net = price - (consignment or 0) + (deposit or 0)
  local itemID = ns.scan.byName[itemName]
  if not itemID then
    for id, r in pairs(ns.db.recipes) do
      if r.out and r.name == itemName then itemID = r.out break end
    end
  end
  local ledger = ns.realm.ledger
  local entry = { t = time(), name = itemName, item = itemID, units = units, gross = price, net = net,
                  buyer = playerName, char = ns.charName }
  table.insert(ledger.recent, 1, entry)
  while #ledger.recent > MAX_RECENT do table.remove(ledger.recent) end
  if itemID then
    local l = ledger.items[itemID] or { n = 0, units = 0, gross = 0, net = 0, first = time() }
    l.n = l.n + 1
    l.units = l.units + units
    l.gross = l.gross + price
    l.net = l.net + net
    l.last = time()
    l.name = itemName
    ledger.items[itemID] = l
  end
  local day = date("%Y%m%d")
  local d = ledger.days[day] or { net = 0, n = 0 }
  d.net = d.net + net
  d.n = d.n + 1
  ledger.days[day] = d
  ns.Fire("LEDGER_UPDATED")
end

local function Hook()
  if Mail.hooked then return end
  Mail.hooked = true
  if type(TakeInboxMoney) == "function" then
    hooksecurefunc("TakeInboxMoney", function(index) Record(index) end)
  end
  if type(AutoLootMailItem) == "function" then
    hooksecurefunc("AutoLootMailItem", function(index) Record(index) end)
  end
end

ns.On("READY", Hook)

-- Net gold from sales in the last N days.
function Mail.NetForDays(days)
  local total, n = 0, 0
  if not ns.realm then return 0, 0 end
  local cutoff = time() - days * 86400
  for _, e in ipairs(ns.realm.ledger.recent or {}) do
    if e.t >= cutoff then total = total + (e.net or 0); n = n + 1 end
  end
  return total, n
end
