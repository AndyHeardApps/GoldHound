-- GoldHound: core namespace, saved variables, events and shared helpers.
local ADDON, ns = ...

ns.name = ADDON
ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "dev"
ns.debug = false

-- Default settings. Money values are in copper.
ns.DEFAULTS = {
  ahCut = 0.05,          -- auction house cut taken from sales (5% faction AH)
  minProfit = 5000,      -- 50s minimum profit before an opportunity is shown (0 disables)
  minRoi = 0,            -- minimum return on investment, as a fraction (0.2 = 20%; 0 disables)
  flipDiscount = 0.30,   -- a flip must be at least this far below market value
  floorDepth = 3,        -- units that must be available at a price before it counts as the floor
  floorShare = 0.05,     -- ...or this share of the units listed, when that is smaller
  outlierRatio = 0.6,    -- a floor below this fraction of the typical price is flagged as unusually low
  scanSound = true,      -- play a sound when a full scan completes
  levelVendorOnly = false, -- levelling planner values products at vendor price only
  resetDiscount = 0.35,  -- cheap listings must be this far below the price history to reset
  resetMaxDays = 7,      -- a reset must be sellable within this many days (when rate is known)
  scanCooldown = 900,    -- seconds between full scans (server throttle is ~15 min)
  autoScan = false,      -- start a full scan whenever the cooldown ends while the AH is open
  craftCooldown = 120,   -- seconds between targeted craft refreshes (per-item searches, no server throttle)
  buyoutMode = "auto",   -- how the full scan reports commodity buyouts: auto-detect, "unit" or "stack"
  historySize = 40,      -- price observations kept per item for the market median and price chart
  minEvidence = 2,       -- other listings (or earlier scans) needed to trust a market value
  restockMin = 3,        -- warn when fewer than this many units of an item you sell are listed
  showTooltip = true,    -- add price lines to item tooltips
  pruneDays = 30,        -- forget items not seen on the AH for this many days
  minimapAngle = 220,    -- where the minimap button sits, in degrees
}

-------------------------------------------------------------------------------
-- Logging
-------------------------------------------------------------------------------
local PREFIX = "|cffffd100GoldHound|r: "

function ns.Print(msg, ...)
  if select("#", ...) > 0 then msg = tostring(msg):format(...) end
  local chat = DEFAULT_CHAT_FRAME or ChatFrame1
  if chat then chat:AddMessage(PREFIX .. tostring(msg)) else print(PREFIX .. tostring(msg)) end
end

function ns.Debug(...)
  if ns.debug then print("|cff88ccff[GH]|r", ...) end
end

-------------------------------------------------------------------------------
-- Internal callbacks (addon-level events)
-------------------------------------------------------------------------------
local callbacks = {}

function ns.On(name, fn)
  callbacks[name] = callbacks[name] or {}
  table.insert(callbacks[name], fn)
end

function ns.Fire(name, ...)
  local list = callbacks[name]
  if not list then return end
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, ...)
    if not ok then geterrorhandler()(err) end
  end
end

-------------------------------------------------------------------------------
-- Game events. Registration is wrapped in pcall because Forever throws on
-- unknown event names.
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

function ns.RegisterEvent(event, fn)
  if not eventHandlers[event] then
    eventHandlers[event] = {}
    local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
    if not ok then
      ns.unavailableEvents = ns.unavailableEvents or {}
      table.insert(ns.unavailableEvents, event)
    end
  end
  table.insert(eventHandlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
  local list = eventHandlers[event]
  if not list then return end
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, ...)
    if not ok then geterrorhandler()(err) end
  end
end)

-------------------------------------------------------------------------------
-- Timers
-------------------------------------------------------------------------------
local timers = {}

-- Runs fn once, `delay` seconds after the last call with the same key.
function ns.Debounce(key, delay, fn)
  if timers[key] then timers[key]:Cancel() end
  timers[key] = C_Timer.NewTimer(delay, function()
    timers[key] = nil
    fn()
  end)
end

-------------------------------------------------------------------------------
-- Money
-------------------------------------------------------------------------------
function ns.Money(copper)
  copper = math.floor((tonumber(copper) or 0) + 0.5)
  local negative = copper < 0
  if negative then copper = -copper end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local parts = {}
  if g > 0 then table.insert(parts, ("%.0f|cffffd700g|r"):format(g)) end
  if g > 0 or s > 0 then table.insert(parts, ("%.0f|cffc7c7cfs|r"):format(s)) end
  if g == 0 or c > 0 then table.insert(parts, ("%.0f|cffeda55fc|r"):format(c)) end
  local text = table.concat(parts, " ")
  if negative then text = "-" .. text end
  return text
end

-- Plain "1g 50s 20c" text without colour codes, for edit boxes.
function ns.MoneyPlain(copper)
  copper = math.floor((tonumber(copper) or 0) + 0.5)
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local parts = {}
  if g > 0 then table.insert(parts, ("%.0f"):format(g) .. "g") end
  if s > 0 then table.insert(parts, ("%.0f"):format(s) .. "s") end
  if c > 0 or #parts == 0 then table.insert(parts, ("%.0f"):format(c) .. "c") end
  return table.concat(parts, " ")
end

-- Parses "1g 50s 20c", "1.5g", "250s" or a plain copper number into copper.
function ns.ParseMoney(text)
  if type(text) ~= "string" then return nil end
  text = text:lower():gsub("%s+", "")
  if text == "" then return nil end
  if text:match("^%d+$") then return tonumber(text) end
  local total, matched = 0, false
  for amount, unit in text:gmatch("([%d%.]+)([gsc])") do
    local n = tonumber(amount)
    if n then
      matched = true
      if unit == "g" then total = total + n * 10000
      elseif unit == "s" then total = total + n * 100
      else total = total + n end
    end
  end
  if not matched then return nil end
  return math.floor(total + 0.5)
end

-- Gold the current character can spend.
function ns.Budget()
  local ok, money = pcall(GetMoney)
  if ok and type(money) == "number" then return money end
  return 0
end

-------------------------------------------------------------------------------
-- Item helpers
-------------------------------------------------------------------------------
function ns.ItemIDFromLink(link)
  if type(link) ~= "string" then return nil end
  local id = link:match("item:(%d+)")
  return id and tonumber(id) or nil
end

-- item:itemID:enchant:gem1:gem2:gem3:gem4:suffixID:uniqueID:...
function ns.SuffixFromLink(link)
  if type(link) ~= "string" then return 0 end
  local suffix = link:match("item:%d*:%d*:%d*:%d*:%d*:%d*:(%-?%d*)")
  return math.abs(tonumber(suffix) or 0)
end

local infoCache = {}
local infoRequested = {}
local nameIndex = {}

-- Returns cached item info or nil (and requests a load) when the client has not
-- cached the item yet. Listen for ns.On("ITEM_INFO") to be told when it arrives.
function ns.ItemInfo(itemID)
  itemID = tonumber(itemID)
  if not itemID then return nil end
  local cached = infoCache[itemID]
  if cached then return cached end
  local name, link, quality, ilvl, minLevel, itemType, itemSubType, stack, equipLoc, icon,
        sellPrice, classID, subclassID = C_Item.GetItemInfo(itemID)
  if not name then
    if not infoRequested[itemID] then
      infoRequested[itemID] = true
      C_Item.RequestLoadItemDataByID(itemID)
    end
    return nil
  end
  local info = {
    id = itemID, name = name, link = link, quality = quality or 1, ilvl = ilvl or 0,
    minLevel = minLevel or 0, stack = stack or 1, equipLoc = equipLoc, icon = icon,
    sellPrice = sellPrice or 0, classID = classID, subclassID = subclassID,
    itemType = itemType, itemSubType = itemSubType,
  }
  infoCache[itemID] = info
  if not nameIndex[name] then nameIndex[name] = itemID end
  return info
end

-- Item ID for an item name, from items seen on the AH, known recipes or cached info.
function ns.ItemIDByName(name)
  if type(name) ~= "string" or name == "" then return nil end
  local id = ns.scan and ns.scan.byName and ns.scan.byName[name]
  if id then return id end
  if nameIndex[name] then return nameIndex[name] end
  for _, r in pairs(ns.db and ns.db.recipes or {}) do
    if r.out and r.name == name then return r.out end
  end
  return nil
end

local function OnItemInfoArrived(itemID)
  if itemID and infoRequested[itemID] then
    infoRequested[itemID] = nil
    ns.Debounce("iteminfo", 0.6, function() ns.Fire("ITEM_INFO") end)
  end
end
ns.RegisterEvent("GET_ITEM_INFO_RECEIVED", OnItemInfoArrived)
ns.RegisterEvent("ITEM_DATA_LOAD_RESULT", OnItemInfoArrived)

-- Stackable items trade as commodities on the modern auction house.
local commodityCache = {}
function ns.IsCommodity(itemID)
  local v = commodityCache[itemID]
  if v ~= nil then return v end
  local stack = C_Item.GetItemMaxStackSizeByID(itemID)
  if stack == nil then return nil end
  v = stack > 1
  commodityCache[itemID] = v
  return v
end

-- Price database key: commodities by item ID, equipment by item ID and suffix.
function ns.KeyFor(itemID, suffix)
  local commodity = ns.IsCommodity(itemID)
  if commodity ~= false then return tostring(itemID) end
  return itemID .. "|" .. math.abs(tonumber(suffix) or 0)
end

function ns.ItemIDFromKey(key)
  return tonumber(tostring(key):match("^(%d+)"))
end

local TIME_LEFT = { [0] = "Short", [1] = "Medium", [2] = "Long", [3] = "Very long" }
function ns.TimeLeftText(band)
  return TIME_LEFT[band] or "?"
end

-- Seconds a listing in a time-left band has at least left. Falls back to the
-- modern client's defaults when the API is unavailable.
local BAND_MIN_FALLBACK = { [0] = 0, [1] = 30 * 60, [2] = 2 * 3600, [3] = 12 * 3600 }
function ns.BandMinSeconds(band)
  if C_AuctionHouse and C_AuctionHouse.GetTimeLeftBandInfo then
    local ok, minSeconds = pcall(C_AuctionHouse.GetTimeLeftBandInfo, band)
    if ok and type(minSeconds) == "number" then return minSeconds end
  end
  return BAND_MIN_FALLBACK[band] or 0
end

function ns.Round(n) return math.floor((n or 0) + 0.5) end

-- How long ago a timestamp was, briefly: "now", "12m", "3h", "2d".
function ns.AgeText(t)
  if not t then return nil end
  local d = time() - t
  if d < 60 then return "now" end
  if d < 3600 then return ("%dm"):format(math.floor(d / 60)) end
  if d < 86400 then return ("%dh"):format(math.floor(d / 3600)) end
  return ("%dd"):format(math.floor(d / 86400))
end

function ns.Count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

function ns.Trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Converts a Blizzard format string such as "Requires %s (%d)" into a Lua pattern.
function ns.PatternFromFormat(fmt)
  local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
  p = p:gsub("%%%%s", "(.-)"):gsub("%%%%d", "(%%d+)")
  return "^" .. p .. "$"
end

-------------------------------------------------------------------------------
-- Saved variables
-------------------------------------------------------------------------------
ns.RegisterEvent("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  GoldHoundDB = GoldHoundDB or {}
  local db = GoldHoundDB
  db.settings = db.settings or {}
  for k, v in pairs(ns.DEFAULTS) do
    if db.settings[k] == nil then db.settings[k] = v end
  end
  -- The old default of 20 scans is too short for the price chart.
  if db.settings.historySize == 20 then db.settings.historySize = ns.DEFAULTS.historySize end
  db.realms = db.realms or {}
  db.recipes = db.recipes or {}      -- recipeID -> recipe known by one of your characters
  db.chars = db.chars or {}          -- charKey -> professions, money
  db.vendorBuy = db.vendorBuy or {}  -- itemID -> cheapest vendor price seen
  db.vendorInfo = db.vendorInfo or {}-- itemID -> { where = "NPC (zone)", limited = bool, classID = n }
  db.recipeItems = db.recipeItems or {} -- recipe item ID -> parsed tooltip data
  ns.db = db
  ns.settings = db.settings
  ns.Fire("DB_LOADED")
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
  if not ns.db then return end
  local realm = GetRealmName() or "Unknown"
  local faction = UnitFactionGroup("player") or "Neutral"
  ns.realmName = realm
  ns.realmKey = realm .. "-" .. faction
  ns.db.realms[ns.realmKey] = ns.db.realms[ns.realmKey] or {}
  ns.realm = ns.db.realms[ns.realmKey]
  ns.realm.prices = ns.realm.prices or {}
  ns.realm.sales = ns.realm.sales or {}
  ns.realm.ledger = ns.realm.ledger or { items = {}, recent = {}, days = {} }
  ns.realm.shopping = ns.realm.shopping or {}
  ns.realm.worth = ns.realm.worth or {}       -- net worth samples { t, g = gold, i = inventory, a = auctions }
  ns.charKey = (UnitName("player") or "Unknown") .. "-" .. realm
  ns.charName = UnitName("player") or "Unknown"
  for itemID in pairs(ns.Data.VendorSeed) do ns.ItemInfo(itemID) end
  for itemID in pairs(ns.db.vendorBuy) do ns.ItemInfo(itemID) end
  ns.Fire("READY")
  ns.Print("v%s loaded. /gh opens the window, /gh help lists commands.", ns.version)
end)

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
local function Help()
  local s = ns.settings
  ns.Print("Commands:")
  ns.Print("  /gh - toggle the window")
  ns.Print("  /gh scan [force] - full auction house scan (AH must be open)")
  ns.Print("  /gh auto [on|off] - auto-scan: rescan whenever the cooldown ends while the AH is open (now %s)", s.autoScan and "on" or "off")
  ns.Print("  /gh sound - toggle the sound played when a full scan completes (now %s)", s.scanSound and "on" or "off")
  ns.Print("  /gh refresh [force|stop] - re-price only the items your recipes make and use (no 15 minute wait)")
  ns.Print("  /gh minprofit <money> - minimum profit shown, e.g. 1g50s, 0 to disable (now %s)", ns.Money(s.minProfit))
  ns.Print("  /gh minroi <percent> - minimum return on investment, 0 to disable (now %d%%)", (s.minRoi or 0) * 100)
  ns.Print("  /gh discount <percent> - how far below market a flip must be (now %d%%)", s.flipDiscount * 100)
  ns.Print("  /gh resetdiscount <percent> - how far below history a reset buy must be (now %d%%)", s.resetDiscount * 100)
  ns.Print("  /gh cut <percent> - auction house cut on sales (now %d%%)", s.ahCut * 100)
  ns.Print("  /gh tooltip - toggle tooltip price lines")
  ns.Print("  /gh status - database summary")
  ns.Print("  /gh top [n] - priciest listings from the last scan, with raw values")
  ns.Print("  /gh units auto|unit|stack - how the full scan reports commodity prices (now %s%s)", s.buyoutMode or "auto", (s.buyoutMode or "auto") == "auto" and (", detected: " .. (ns.realm and ns.realm.perUnitBuyout == true and "per unit" or ns.realm and ns.realm.perUnitBuyout == false and "per stack" or "not yet")) or "")
  ns.Print("  /gh recipes - read the open profession window now and report each step")
  ns.Print("  /gh reset prices|recipes|vendors|ledger|worth - wipe stored data")
end

local function Status()
  local last = ns.realm.lastScan and date("%Y-%m-%d %H:%M", ns.realm.lastScan) or "never"
  ns.Print("%s: %d priced items, %d with sale data, last scan %s.", ns.realmKey, ns.Count(ns.realm.prices), ns.Count(ns.realm.sales), last)
  ns.Print("%d recipes known across %d characters, %d vendor prices seen, %d sales in the ledger.",
    ns.Count(ns.db.recipes), ns.Count(ns.db.chars), ns.Count(ns.db.vendorBuy), #(ns.realm.ledger.recent or {}))
  if ns.unavailableEvents and #ns.unavailableEvents > 0 then
    ns.Print("Events this client does not have: %s", table.concat(ns.unavailableEvents, ", "))
  end
end

local function SetPercent(field, value, label)
  local v = tonumber(value)
  if v and v >= 0 and v < 100 then
    ns.settings[field] = v / 100
    ns.Analysis.Invalidate()
    ns.Print("%s set to %d%%.", label, v)
  else
    ns.Print("Give a percentage between 0 and 99.")
  end
end

SLASH_GOLDHOUND1 = "/gh"
SLASH_GOLDHOUND2 = "/goldhound"
SlashCmdList.GOLDHOUND = function(msg)
  if not ns.db then return end
  msg = ns.Trim(msg)
  local cmd, rest = msg:match("^(%S+)%s*(.*)$")
  cmd = cmd and cmd:lower() or ""
  rest = rest or ""
  if cmd == "" then
    ns.UI.Toggle()
  elseif cmd == "help" then
    Help()
  elseif cmd == "scan" then
    ns.Scan.Start(rest == "force")
  elseif cmd == "sound" then
    ns.settings.scanSound = not ns.settings.scanSound
    ns.Print("Scan complete sound %s.", ns.settings.scanSound and "on" or "off")
  elseif cmd == "auto" then
    local on
    if rest == "on" then on = true elseif rest == "off" then on = false else on = not ns.settings.autoScan end
    ns.Scan.SetAuto(on)
  elseif cmd == "refresh" then
    if rest == "stop" then ns.Refresh.Abort() else ns.Refresh.Start(rest == "force") end
  elseif cmd == "minprofit" then
    local v = ns.ParseMoney(rest)
    if v then
      ns.settings.minProfit = v
      ns.Analysis.Invalidate()
      ns.Print("Minimum profit set to %s.", ns.Money(v))
    else
      ns.Print("Usage: /gh minprofit 1g50s")
    end
  elseif cmd == "minroi" then
    local v = tonumber(rest)
    if v and v >= 0 then
      ns.settings.minRoi = v / 100
      ns.Analysis.Invalidate()
      ns.Print("Minimum ROI set to %d%%%s.", v, v == 0 and " (off)" or "")
    else
      ns.Print("Usage: /gh minroi 25")
    end
  elseif cmd == "discount" then
    SetPercent("flipDiscount", rest, "Flip discount")
  elseif cmd == "resetdiscount" then
    SetPercent("resetDiscount", rest, "Reset discount")
  elseif cmd == "cut" then
    SetPercent("ahCut", rest, "Auction house cut")
  elseif cmd == "tooltip" then
    ns.settings.showTooltip = not ns.settings.showTooltip
    ns.Print("Tooltip lines %s.", ns.settings.showTooltip and "enabled" or "disabled")
  elseif cmd == "status" then
    Status()
  elseif cmd == "recipes" then
    ns.Professions.Capture(true)
  elseif cmd == "top" then
    -- Debug: the priciest listings from the last scan, with raw API values.
    local n = tonumber(rest) or 5
    local all = {}
    for _, agg in pairs(ns.scan.byKey or {}) do
      for _, l in ipairs(agg.listings) do table.insert(all, l) end
    end
    table.sort(all, function(a, b) return math.max(a.buyout, a.minBid or 0) > math.max(b.buyout, b.minBid or 0) end)
    ns.Print("%d listings in the last scan. Highest values:", #all)
    for i = 1, math.min(n, #all) do
      local l = all[i]
      ns.Print("  %s x%d: buyout %.0f copper (%s), min bid %.0f, bid %.0f, owner %s", l.name or "?", l.count, l.buyout, ns.Money(l.buyout), l.minBid or 0, l.bidAmount or 0, tostring(l.owner))
    end
  elseif cmd == "units" then
    if rest == "auto" or rest == "unit" or rest == "stack" then
      ns.settings.buyoutMode = rest
      ns.Print("Commodity buyouts from the full scan are now read as %s. Scan again to apply.", rest == "auto" and "auto-detected" or ("per " .. rest))
    else
      ns.Print("Usage: /gh units auto|unit|stack")
    end
  elseif cmd == "debug" then
    ns.debug = not ns.debug
    ns.Print("Debug %s.", ns.debug and "on" or "off")
  elseif cmd == "reset" then
    if rest == "prices" then
      ns.realm.prices, ns.realm.sales, ns.realm.snapshot, ns.realm.lastScan, ns.realm.lastRefresh = {}, {}, nil, nil, nil
      ns.realm.listings = nil
      ns.scan.byKey, ns.scan.byName = {}, {}
      ns.Analysis.Invalidate()
      ns.Print("Price and sale-rate data wiped for %s.", ns.realmKey)
    elseif rest == "recipes" then
      ns.db.recipes, ns.db.recipeItems = {}, {}
      ns.Print("Recipe data wiped.")
    elseif rest == "vendors" then
      ns.db.vendorBuy, ns.db.vendorInfo = {}, {}
      ns.Print("Vendor data wiped.")
    elseif rest == "ledger" then
      ns.realm.ledger = { items = {}, recent = {}, days = {} }
      ns.Print("Sales ledger wiped for %s.", ns.realmKey)
    elseif rest == "worth" then
      ns.realm.worth = {}
      ns.Print("Net worth history wiped for %s.", ns.realmKey)
    else
      ns.Print("Usage: /gh reset prices|recipes|vendors|ledger|worth")
      return
    end
    ns.Analysis.Invalidate()
  else
    Help()
  end
end

-- Report protected calls the client refuses, so the exact function is known.
local reportedBlocked = {}
local function OnBlocked(addonName, func)
  if addonName ~= ADDON or reportedBlocked[func] then return end
  reportedBlocked[func] = true
  ns.Print("The client blocked a protected call: %s. It must be made directly from a click; please report this.", tostring(func))
end
ns.RegisterEvent("ADDON_ACTION_FORBIDDEN", OnBlocked)
ns.RegisterEvent("ADDON_ACTION_BLOCKED", OnBlocked)

-- Addon compartment (the menu next to the minimap on the modern client).
function GoldHound_CompartmentClick()
  if ns.UI then ns.UI.Toggle() end
end
