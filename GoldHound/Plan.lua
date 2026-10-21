-- GoldHound: turns the shopping list into an ordered, clickable checklist of
-- steps across your characters: buy, mail, craft intermediates, craft, post.
-- Steps are rebuilt from live inventory, so finished steps disappear by themselves.
local ADDON, ns = ...
local Plan = {}
ns.Plan = Plan

local MAX_ATTACHMENTS = 12
local PHASE = { buy_ah = 1, buy_vendor = 2, mail = 3, craft = 4, post = 5 }
local WHERE = { buy_ah = "Auction house", buy_vendor = "Vendor", mail = "Mailbox", craft = "Profession window", post = "Auction house" }

local function AvgOut(recipe)
  return recipe and (((recipe.qmin or 1) + (recipe.qmax or recipe.qmin or 1)) / 2) or 1
end

local function ItemName(itemID)
  local info = ns.ItemInfo(itemID)
  return info and info.name or ("item " .. itemID), info and info.link, info and info.icon
end

-------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------
local function Builder()
  local b = { steps = {}, index = {}, stock = {} }

  -- Remaining stock of an item per character, counted once.
  function b:Stock(itemID)
    local s = self.stock[itemID]
    if not s then
      s = {}
      for _, who, count in ns.Inventory.Breakdown(itemID) do s[who] = count end
      self.stock[itemID] = s
    end
    return s
  end

  function b:Take(itemID, who, qty)
    local s = self:Stock(itemID)
    local take = math.min(s[who] or 0, qty)
    if take > 0 then s[who] = s[who] - take end
    return take
  end

  function b:Step(step)
    local key = table.concat({ step.type, step.itemID or step.recipeID or "", step.char or "", step.to or "" }, "|")
    local existing = self.index[key]
    if existing then
      existing.qty = existing.qty + step.qty
      return existing
    end
    step.id = key
    step.qty = step.qty
    self.index[key] = step
    table.insert(self.steps, step)
    return step
  end

  -- Makes sure `who` ends up holding qty of itemID, adding whatever steps that takes.
  function b:Require(itemID, qty, who, depth)
    if qty <= 0 or depth > 4 then return end
    local name = ItemName(itemID)
    qty = qty - self:Take(itemID, who, qty)
    if qty <= 0 then return end
    -- Other characters' stock first, mailed over.
    for other, count in pairs(self:Stock(itemID)) do
      if qty > 0 and other ~= who and count > 0 then
        local take = self:Take(itemID, other, qty)
        if take > 0 then
          self:Step({ type = "mail", itemID = itemID, name = name, qty = take, char = other, to = who })
          qty = qty - take
        end
      end
    end
    if qty <= 0 then return end
    local _, source, detail = ns.Pricing.ReagentCost(itemID)
    if source == "craft" and detail then
      local sub = ns.db.recipes[detail]
      local crafter = sub and ns.Chars.WhoKnows(sub)
      if sub and crafter then
        local crafts = math.ceil(qty / AvgOut(sub))
        for _, reagent in ipairs(sub.reagents or {}) do
          self:Require(reagent[1], (reagent[2] or 1) * crafts, crafter, depth + 1)
        end
        self:Step({ type = "craft", recipeID = detail, itemID = itemID, name = sub.name, qty = crafts, char = crafter, profID = sub.profID, prof = sub.prof, makes = qty })
        if crafter ~= who then
          self:Step({ type = "mail", itemID = itemID, name = name, qty = qty, char = crafter, to = who })
        end
        return
      end
    end
    local buyer = ns.charName
    local plannedUnit = select(1, ns.Pricing.ReagentCost(itemID, 0, nil, qty))
    if source == "vendor" then
      local meta = ns.db.vendorInfo[itemID]
      self:Step({ type = "buy_vendor", itemID = itemID, name = name, qty = qty, char = buyer, where = meta and meta.where or "any vendor that sells it" })
    else
      self:Step({ type = "buy_ah", itemID = itemID, name = name, qty = qty, char = buyer, unit = plannedUnit })
    end
    if buyer ~= who then
      self:Step({ type = "mail", itemID = itemID, name = name, qty = qty, char = buyer, to = who })
    end
  end

  return b
end

function Plan.Build()
  local list = ns.realm and ns.realm.shopping or {}
  local b = Builder()
  for _, entry in ipairs(list) do
    local r = ns.db.recipes[entry.recipeID]
    local crafter = r and ns.Chars.WhoKnows(r)
    local remaining = entry.crafts - (entry.done or 0)
    if r and crafter and remaining > 0 then
      for _, reagent in ipairs(r.reagents or {}) do
        b:Require(reagent[1], (reagent[2] or 1) * remaining, crafter, 0)
      end
      b:Step({ type = "craft", recipeID = entry.recipeID, itemID = r.out, name = r.name, qty = remaining, char = crafter, profID = r.profID, prof = r.prof, final = true })
    end
    if r and crafter and r.out then
      local toPost = math.floor(AvgOut(r) * entry.crafts + 0.5) - (entry.posted or 0)
      if toPost > 0 then
        local productName = ItemName(r.out)
        b:Step({ type = "post", itemID = r.out, name = productName, qty = toPost, char = crafter })
      end
    end
  end
  -- Buying first (one auction house visit), then everything in dependency order.
  local ordered = {}
  for _, s in ipairs(b.steps) do if s.type == "buy_ah" then table.insert(ordered, s) end end
  for _, s in ipairs(b.steps) do if s.type == "buy_vendor" then table.insert(ordered, s) end end
  for _, s in ipairs(b.steps) do if s.type ~= "buy_ah" and s.type ~= "buy_vendor" then table.insert(ordered, s) end end
  local done = ns.realm and ns.realm.planDone or {}
  for i, s in ipairs(ordered) do
    s.n = i
    s.where = s.where or WHERE[s.type]
    s.done = done[s.id] or false
  end
  return ordered
end

function Plan.ToggleDone(step)
  if not ns.realm then return end
  ns.realm.planDone = ns.realm.planDone or {}
  ns.realm.planDone[step.id] = not ns.realm.planDone[step.id] or nil
  ns.Fire("PLAN_CHANGED")
end

function Plan.ClearDone()
  if ns.realm then ns.realm.planDone = {} end
  ns.Fire("PLAN_CHANGED")
end

-------------------------------------------------------------------------------
-- Context: can the step be performed right now?
-------------------------------------------------------------------------------
local mailOpen, merchantOpen = false, false
ns.RegisterEvent("MAIL_SHOW", function() mailOpen = true; ns.Fire("PLAN_CHANGED") end)
ns.RegisterEvent("MAIL_CLOSED", function() mailOpen = false; ns.Fire("PLAN_CHANGED") end)
ns.RegisterEvent("MERCHANT_SHOW", function() merchantOpen = true; ns.Fire("PLAN_CHANGED") end)
ns.RegisterEvent("MERCHANT_CLOSED", function() merchantOpen = false; ns.Fire("PLAN_CHANGED") end)
ns.RegisterEvent("TRADE_SKILL_SHOW", function() ns.Fire("PLAN_CHANGED") end)
ns.RegisterEvent("TRADE_SKILL_CLOSE", function() ns.Fire("PLAN_CHANGED") end)
ns.On("AH_OPEN", function() ns.Fire("PLAN_CHANGED") end)
ns.On("AH_CLOSED", function() ns.Fire("PLAN_CHANGED") end)

local function ProfessionOpen(step)
  local ok, ready = pcall(C_TradeSkillUI.IsTradeSkillReady)
  if not ok or not ready then return false end
  local okr, info = pcall(C_TradeSkillUI.GetRecipeInfo, step.recipeID)
  return okr and type(info) == "table" and info.learned == true
end

-- Returns status text, button label, and whether the button is enabled.
function Plan.Context(step)
  if step.done then return "done", "Undo", true end
  if step.char ~= ns.charName then return "switch to " .. step.char, "on " .. step.char, false end
  if step.type == "buy_ah" then
    if ns.ahOpen then return "ready", "Buy", true end
    return "go to the auction house", "Buy", false
  elseif step.type == "buy_vendor" then
    if merchantOpen then return "ready", "Buy", true end
    return "visit " .. (step.where or "a vendor"), "Buy", false
  elseif step.type == "mail" then
    if mailOpen then return "ready", "Send", true end
    return "go to a mailbox", "Send", false
  elseif step.type == "craft" then
    if ProfessionOpen(step) then return "ready", "Craft", true end
    return "open " .. (step.prof or "profession"), "Open", true
  elseif step.type == "post" then
    if ns.ahOpen then return "ready", "Sell tab", true end
    return "go to the auction house", "Sell tab", false
  end
  return "", "", false
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------
local function FindInBags(itemID)
  local found = {}
  local BagIndex = Enum.BagIndex or {}
  for bag = (BagIndex.Backpack or 0), (BagIndex.ReagentBag or 5) do
    local okn, slots = pcall(C_Container.GetContainerNumSlots, bag)
    if okn and type(slots) == "number" then
      for slot = 1, slots do
        local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
        if ok and type(info) == "table" and info.itemID == itemID and not info.isLocked then
          table.insert(found, { bag = bag, slot = slot, count = info.stackCount or 1 })
        end
      end
    end
  end
  return found
end

-- Expected profit of everything still planned, at planned material prices.
function Plan.Profit()
  local total = 0
  local cut = ns.settings.ahCut or 0
  for _, entry in ipairs(ns.realm and ns.realm.shopping or {}) do
    local r = ns.db.recipes[entry.recipeID]
    local remaining = entry.crafts - (entry.done or 0)
    if r and r.out and remaining > 0 then
      local cost = ns.Pricing.CraftCost(entry.recipeID)
      local value = ns.Pricing.ItemValue(r.out)
      if cost and value then
        total = total + (value * cost.avgOut * (1 - cut) - cost.total) * remaining
      end
    end
  end
  return total
end

local function DoBuyAH(step)
  if ns.IsCommodity(step.itemID) then
    local qty = step.qty
    -- Buy at today's listings: the cap is the dearest of the cheapest units
    -- that cover the quantity, not the historical market value.
    local avg, dearest, available, source = ns.Pricing.AcquireCost(ns.KeyFor(step.itemID, 0), qty)
    if not avg then ns.Print("No price for %s yet; scan or refresh first, or search for it manually.", step.name) return end
    if source ~= "listings" then
      ns.Print("No current listings of %s in the scan data; using the %s price of %s as the cap.", step.name, source, ns.Money(avg))
    elseif available < qty then
      ns.Print("Only %d of %d x %s were listed at the last check.", available, qty, step.name)
    end
    local base = Plan.Profit()
    ns.Buy.Commodity(step.itemID, qty, dearest, step.name, {
      expectedUnit = avg, baseProfit = base,
      profitAt = function(unit) return base - (unit - avg) * qty end,
    })
  else
    if AuctionHouseFrame and AuctionHouseFrame.SearchBar then
      pcall(function()
        AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
        AuctionHouseFrame.SearchBar:SetSearchText(step.name)
        AuctionHouseFrame.SearchBar:StartSearch()
      end)
    end
    ns.Print("%s is not a commodity; it has been searched for in the auction house window.", step.name)
  end
end

local function DoBuyVendor(step)
  local okn, n = pcall(GetMerchantNumItems)
  if not okn then return end
  for i = 1, n do
    local okl, link = pcall(GetMerchantItemLink, i)
    if okl and ns.ItemIDFromLink(link) == step.itemID then
      local info = C_MerchantFrame.GetItemInfo(i)
      local bundle = (info and info.stackCount and info.stackCount > 0) and info.stackCount or 1
      local wanted = math.ceil(step.qty / bundle)
      local okm, maxStack = pcall(GetMerchantItemMaxStack, i)
      maxStack = (okm and type(maxStack) == "number" and maxStack > 0) and maxStack or 20
      local bought = 0
      while wanted > 0 and bought < 50 do
        local batch = math.min(wanted, maxStack)
        BuyMerchantItem(i, batch)
        wanted = wanted - batch
        bought = bought + 1
      end
      ns.Print("Bought %d x %s from the vendor.", step.qty, step.name)
      return
    end
  end
  ns.Print("This vendor does not sell %s.", step.name)
end

local function DoMail(step)
  if not SendMailNameEditBox or not SendMailSubjectEditBox then ns.Print("The mail window is not available.") return end
  pcall(MailFrameTab_OnClick, MailFrame, 2)
  pcall(ClearSendMail)
  SendMailNameEditBox:SetText(step.to)
  SendMailSubjectEditBox:SetText("GoldHound: " .. step.name)
  local remaining = step.qty
  local attached = 0
  for _, stack in ipairs(FindInBags(step.itemID)) do
    if remaining <= 0 or attached >= MAX_ATTACHMENTS then break end
    if stack.count > remaining then
      C_Container.SplitContainerItem(stack.bag, stack.slot, remaining)
    else
      C_Container.PickupContainerItem(stack.bag, stack.slot)
    end
    ClickSendMailItemButton()
    attached = attached + 1
    remaining = remaining - math.min(stack.count, remaining)
  end
  if attached == 0 then ns.Print("None of %s found in your bags.", step.name) return end
  local sent = step.qty - remaining
  SendMail(step.to, "GoldHound: " .. step.name, "")
  ns.Inventory.NoteIncoming(step.to, step.itemID, sent)
  if remaining > 0 then
    ns.Print("Sent %d x %s to %s; %d more need another mail (12 attachments per mail).", sent, step.name, step.to, remaining)
  else
    ns.Print("Sent %d x %s to %s.", sent, step.name, step.to)
  end
end

-- Spell that opens each profession window (Mining's window is Smelting).
local OPEN_SPELL = { Mining = "Smelting" }
function Plan.OpenSpell(step)
  if not step.prof then return nil end
  return OPEN_SPELL[step.prof] or step.prof
end

local function DoCraft(step)
  if not ProfessionOpen(step) then
    local ok, opened = pcall(C_TradeSkillUI.OpenTradeSkill, step.profID or 0)
    if not (ok and opened) then
      ns.Print("Open your %s window (spellbook or the Open button), then press Craft.", step.prof or "profession")
    end
    return
  end
  local okc, craftable = pcall(C_TradeSkillUI.GetCraftableCount, step.recipeID)
  craftable = (okc and type(craftable) == "number") and craftable or step.qty
  local count = math.min(step.qty, craftable)
  if count <= 0 then ns.Print("Missing materials for %s.", step.name) return end
  C_TradeSkillUI.CraftRecipe(step.recipeID, count)
  ns.Print("Crafting %d x %s.", count, step.name)
end

local function DoPost(step)
  local stacks = FindInBags(step.itemID)
  if #stacks == 0 then ns.Print("None of %s in your bags.", step.name) return end
  if not AuctionHouseFrame or not AuctionHouseFrame.SetPostItem then ns.Print("The auction house window is not available.") return end
  local location = ItemLocation:CreateFromBagAndSlot(stacks[1].bag, stacks[1].slot)
  local ok, err = pcall(AuctionHouseFrame.SetPostItem, AuctionHouseFrame, location)
  if not ok then ns.Print("Could not open the sell tab: %s", tostring(err)) return end
  ns.Print("%s is on the sell tab. Use the GoldHound price suggestion, then post.", step.name)
end

function Plan.Run(step)
  if step.done then Plan.ToggleDone(step) return end
  if step.type == "buy_ah" then DoBuyAH(step)
  elseif step.type == "buy_vendor" then DoBuyVendor(step)
  elseif step.type == "mail" then DoMail(step)
  elseif step.type == "craft" then DoCraft(step)
  elseif step.type == "post" then DoPost(step) end
end

-- Count finished crafts against the plan so they are not planned again.
local lastRecipe
ns.RegisterEvent("TRADE_SKILL_CRAFT_BEGIN", function(recipeSpellID) lastRecipe = recipeSpellID end)
ns.RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", function(data)
  local itemID = type(data) == "table" and data.itemID or nil
  local list = ns.realm and ns.realm.shopping or {}
  for _, entry in ipairs(list) do
    local r = ns.db.recipes[entry.recipeID]
    local matches = (lastRecipe and entry.recipeID == lastRecipe) or (not lastRecipe and r and r.out and r.out == itemID)
    if matches and (entry.done or 0) < entry.crafts then
      entry.done = (entry.done or 0) + 1
      break
    end
  end
  ns.Inventory.CaptureBags()
  ns.Fire("PLAN_CHANGED")
end)
ns.RegisterEvent("UPDATE_TRADESKILL_CAST_STOPPED", function()
  ns.Inventory.CaptureBags()
end)

-- Posting: when an auction is created and a planned product leaves the bags,
-- the difference counts as posted. A recipe leaves the plan once all its
-- output has been posted.
local watched = {}
local lastPostTime = 0

local function RefreshWatch()
  local list = ns.realm and ns.realm.shopping or {}
  local recent = (GetTime() - lastPostTime) < 5
  local finished = {}
  for i, entry in ipairs(list) do
    local r = ns.db.recipes[entry.recipeID]
    if r and r.out then
      local ok, live = pcall(C_Item.GetItemCount, r.out, true)
      if ok and type(live) == "number" then
        local old = watched[r.out]
        if recent and old and live < old then
          entry.posted = (entry.posted or 0) + (old - live)
          local expected = math.floor(AvgOut(r) * entry.crafts + 0.5)
          if entry.posted >= expected then table.insert(finished, i) end
        end
        watched[r.out] = live
      end
    end
  end
  for j = #finished, 1, -1 do
    local entry = table.remove(list, finished[j])
    local r = ns.db.recipes[entry.recipeID]
    ns.Print("%s: all %d posted, removed from the plan.", r and r.name or "Recipe", entry.posted or 0)
  end
  if #finished > 0 then ns.Fire("PLAN_CHANGED") end
end

ns.RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED", function()
  lastPostTime = GetTime()
  ns.Inventory.CaptureBags()
  C_Timer.After(0.6, function() RefreshWatch(); ns.Fire("PLAN_CHANGED") end)
end)
ns.On("INVENTORY_UPDATED", RefreshWatch)
ns.On("READY", function() C_Timer.After(4, RefreshWatch) end)
