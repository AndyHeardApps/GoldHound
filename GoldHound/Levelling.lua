-- GoldHound: plans the cheapest way to level a profession from the recipes a
-- character already knows. Each craft is costed at the materials (vendor, AH
-- or crafted) less what the product brings back, and weighed by the chance of
-- a skill point from its colour.
local ADDON, ns = ...
local L = {}
ns.Levelling = L

-- Chance of a skill point per craft by colour: orange, yellow, green, grey.
-- The game does not publish these; they are the usual rule of thumb.
local CHANCE = { [0] = 1, [1] = 0.75, [2] = 0.33, [3] = 0 }
local NAME = { [0] = "orange", [1] = "yellow", [2] = "green", [3] = "grey" }
local CODE = { [0] = "|cffff8040", [1] = "|cffffff00", [2] = "|cff40c040", [3] = "|cff9d9d9d" }
-- Without observations, yellow and green are assumed this far below grey,
-- the spacing most recipes use.
local YELLOW_BELOW_GREY, GREEN_BELOW_GREY = 20, 10

L.CHANCE = CHANCE

function L.ColourText(d)
  if d == nil then return "|cff9d9d9d?|r" end
  return (CODE[d] or "") .. (NAME[d] or "?") .. "|r"
end

-- Character and profession pairs with recorded recipes on this realm.
-- Returns a list of { id, charKey, charName, prof, skill, max }.
function L.Options()
  local out, seen = {}, {}
  if not ns.db then return out end
  for _, r in pairs(ns.db.recipes or {}) do
    if r.prof then
      for charKey in pairs(r.chars or {}) do
        local rec = ns.db.chars[charKey]
        if rec and rec.realm == ns.realmName then
          local id = charKey .. "\n" .. r.prof
          if not seen[id] then
            seen[id] = true
            local p = rec.professions and rec.professions[r.prof]
            table.insert(out, { id = id, charKey = charKey, charName = rec.name or charKey, prof = r.prof, skill = p and p.skill or 0, max = p and p.max or 0 })
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.charName ~= b.charName then return a.charName < b.charName end
    return a.prof < b.prof
  end)
  return out
end

function L.Option(id)
  for _, o in ipairs(L.Options()) do if o.id == id then return o end end
  return nil
end

-- Where a recipe changes colour: yellow from Y, green from E, grey from G.
-- G comes from the game. Y and E are bracketed by every skill level a colour
-- has been seen at (the profession window records one each time it opens),
-- and otherwise assumed from the usual spacing below grey. Returns
-- Y, E, G, yExact, eExact, or nil when the grey level is unknown.
local function Thresholds(r, entry)
  local G = type(entry) == "table" and entry.g or nil
  if not G or G <= 0 then return nil end
  local seen = r.seen or {}
  local function lo(d) local o = seen[d]; return o and o.lo end
  local function hi(d) local o = seen[d]; return o and o.hi end
  local function Bracket(default, below, above)
    -- The colour `below` was seen up to hi(below); the next colour from lo(above).
    local v, exact = default, false
    local top, bottom = hi(below), lo(above)
    if top and bottom and bottom - top == 1 then return bottom, true end
    if top and v <= top then v = top + 1 end
    if bottom and v > bottom then v = bottom end
    return v, exact
  end
  local Y, yExact = Bracket(G - YELLOW_BELOW_GREY, 0, 1)
  local E, eExact = Bracket(G - GREEN_BELOW_GREY, 1, 2)
  if lo(2) and Y > lo(2) then Y = lo(2) end
  if Y > G then Y = G end
  if E > G then E = G end
  if E < Y then E = Y end
  if Y < 1 then Y = 1 end
  return Y, E, G, yExact, eExact
end

local function ColourAt(c, skill)
  if skill >= c.G then return 3 end
  if skill >= c.E then return 2 end
  if skill >= c.Y then return 1 end
  return 0
end

local function AvgOut(r)
  return ((r.qmin or 1) + (r.qmax or r.qmin or 1)) / 2
end

-- What one craft's product brings back and where that number comes from.
-- Market after the cut when the item is known to sell, otherwise the vendor
-- price; vendor only when the setting says so. Enchants bring nothing back.
local function ProductValue(r)
  if not r.out then return 0, "no product" end
  local out = AvgOut(r)
  local vendor = ns.Pricing.GetVendorSell(r.out) or 0
  if ns.settings.levelVendorOnly then return vendor * out, "vendor", vendor end
  local key = ns.KeyFor(r.out, 0)
  local rate = ns.Pricing.Rate(key)
  local market = ns.Pricing.ItemValue(r.out)
  if rate and rate > 0 and market then
    local net = market * (1 - (ns.settings.ahCut or 0))
    if net > vendor then return net * out, "market", net, rate end
  end
  if vendor > 0 then return vendor * out, "vendor", vendor, rate end
  return 0, market and "unsold" or "unknown", 0, rate
end

local function Candidate(recipeID, r, entry)
  local Y, E, G, yExact, eExact = Thresholds(r, entry)
  if not Y then return nil end
  local cost = ns.Pricing.CraftCost(recipeID)
  if not cost then return nil end
  local value, source, unit, rate = ProductValue(r)
  local owned, toBuy, anyOwned, held = 0, 0, false, {}
  for _, p in ipairs(cost.reagents) do
    local have = ns.Inventory.Count(p.item)
    held[p.item] = have
    if have > 0 then anyOwned = true end
    local used = math.min(have, p.qty)
    if p.unit then
      owned = owned + used * p.unit
      toBuy = toBuy + (p.qty - used) * p.unit
    end
  end
  return {
    recipeID = recipeID, r = r, cost = cost, value = value, source = source, unit = unit, rate = rate,
    net = cost.total - value, Y = Y, E = E, G = G, yExact = yExact, eExact = eExact,
    pts = math.max(1, entry.n or 1), owned = anyOwned and owned or nil, toBuy = anyOwned and toBuy or nil, held = held,
  }
end

-- Expected skill points from one craft at a skill level.
local function Points(c, skill)
  return CHANCE[ColourAt(c, skill)] * c.pts
end

-- Every recipe the character knows in the profession that can still give a
-- point before the target, with its cost at the current skill.
function L.Candidates(charKey, prof)
  local out, stale = {}, 0
  for recipeID, r in pairs(ns.db.recipes or {}) do
    if r.prof == prof and r.complete and r.chars and r.chars[charKey] then
      local entry = r.chars[charKey]
      if type(entry) ~= "table" then
        stale = stale + 1
      else
        local c = Candidate(recipeID, r, entry)
        if c then table.insert(out, c) end
      end
    end
  end
  return out, stale
end

-- The plan: for each point from the current skill to the target, the recipe
-- with the lowest net cost per expected point, merged into steps.
-- Returns { skill, target, steps, gap, crafts, mats, value, net, candidates, stale }.
function L.Plan(charKey, prof, target)
  local skill = ns.Chars.Skill(charKey, prof)
  local cands, stale = L.Candidates(charKey, prof)
  target = math.max(target or 0, skill)
  local plan = { skill = skill, target = target, steps = {}, crafts = 0, mats = 0, value = 0, net = 0, candidates = cands, stale = stale }
  local s = skill
  while s < target do
    local best, bestScore, bestPts
    for _, c in ipairs(cands) do
      local pts = Points(c, s)
      if pts > 0 then
        local score = c.net / pts
        if not best or score < bestScore or (score == bestScore and pts > bestPts) then
          best, bestScore, bestPts = c, score, pts
        end
      end
    end
    if not best then plan.gap = s; break end
    local crafts = 1 / bestPts
    local last = plan.steps[#plan.steps]
    if last and last.c == best then
      last.to, last.crafts = s + 1, last.crafts + crafts
      last.d2 = ColourAt(best, s)
    else
      last = { c = best, from = s, to = s + 1, crafts = crafts, d1 = ColourAt(best, s), d2 = ColourAt(best, s) }
      table.insert(plan.steps, last)
    end
    last.mats = (last.mats or 0) + best.cost.total * crafts
    last.value = (last.value or 0) + best.value * crafts
    last.net = (last.net or 0) + best.net * crafts
    plan.crafts, plan.mats = plan.crafts + crafts, plan.mats + best.cost.total * crafts
    plan.value, plan.net = plan.value + best.value * crafts, plan.net + best.net * crafts
    s = s + 1
  end
  return plan
end

local function SourceText(part)
  if part.source == "vendor" then return "vendor" end
  if part.source == "ah" then return "AH" end
  if part.source == "craft" then
    local r = ns.db.recipes[part.detail]
    return "craft: " .. (r and r.name or "?")
  end
  return "?"
end

local function ThresholdText(c)
  local function one(v, exact) return exact and tostring(v) or ("~" .. v) end
  return ("yellow %s, green %s, grey %d"):format(one(c.Y, c.yExact), one(c.E, c.eExact), c.G)
end

-- Tooltip lines shared by plan steps and the full recipe list.
local function Lines(c, skill)
  local r, cost = c.r, c.cost
  local d = ColourAt(c, skill)
  local lines = {
    { "Skill-up chance now", L.ColourText(d) .. (" (%d%%)"):format(math.floor(CHANCE[d] * 100 + 0.5)) },
    { "Colour changes at", ThresholdText(c) .. ((c.yExact and c.eExact) and "" or " (~ estimated; opening the profession window at other skill levels tightens it)") },
  }
  local valueText
  if c.source == "market" then
    valueText = ns.Money(c.unit) .. " each at market after the cut"
  elseif c.source == "vendor" then
    valueText = ns.Money(c.unit) .. " each at a vendor" .. (c.rate and "" or " (no sale rate yet, so the AH is not counted on)")
  elseif c.source == "no product" then
    valueText = "nothing (no item made)"
  elseif c.source == "unsold" then
    valueText = "nothing counted (no vendor price and no sale rate)"
  else
    valueText = "unknown"
  end
  table.insert(lines, { "Product brings back", valueText .. (cost.avgOut ~= 1 and (", makes %.1f"):format(cost.avgOut) or "") })
  local matsText = ns.Money(cost.total) .. (cost.complete and "" or " (partial)")
  if c.owned then matsText = matsText .. (" (owned %s, buy %s)"):format(ns.Money(c.owned), ns.Money(c.toBuy)) end
  table.insert(lines, { "Materials per craft", matsText })
  for _, p in ipairs(cost.reagents) do
    local mi = ns.ItemInfo(p.item)
    local have = c.held[p.item] or 0
    table.insert(lines, { ("  %s x%d (%s)%s"):format(mi and mi.name or ("item " .. p.item), p.qty, SourceText(p), have > 0 and (", have %d"):format(have) or ""), p.unit and ns.Money(p.unit * p.qty) or "|cff9d9d9dunknown|r" })
  end
  return lines
end

local function BaseRow(c, skill)
  local r = c.r
  local info = r.out and ns.ItemInfo(r.out)
  return {
    cat = "craft", recipeID = c.recipeID, itemID = r.out, key = r.out and ns.KeyFor(r.out, 0) or nil,
    link = info and info.link, name = r.name, icon = r.icon, prof = r.prof,
    cost = c.cost.total, ownedCost = c.owned, buyCost = c.toBuy, partial = not c.cost.complete,
    value = c.value, netCraft = c.net, grey = c.G, lines = Lines(c, skill),
  }
end

-- Rows for the plan view: one per step.
function L.PlanRows(plan)
  local rows = {}
  for i, step in ipairs(plan.steps) do
    local row = BaseRow(step.c, step.from)
    row.n = i
    row.from, row.to = step.from, step.to
    row.d1, row.d2 = step.d1, step.d2
    row.crafts = step.crafts
    row.netTotal = step.net
    row.netPoint = step.net / (step.to - step.from)
    local crafts = math.ceil(step.crafts - 0.001)
    row.addCrafts = crafts
    row.action = { label = "Add", fn = function() ns.UI.ShowShopping(step.c.recipeID, crafts) end }
    table.insert(row.lines, 1, { "Points", ("%d to %d, about %.1f crafts"):format(step.from, step.to, step.crafts) })
    table.insert(rows, row)
  end
  return rows
end

-- Rows for the full list: every recipe that can still give a point, at the current skill.
function L.AllRows(plan)
  local rows = {}
  for _, c in ipairs(plan.candidates) do
    local d = ColourAt(c, plan.skill)
    local row = BaseRow(c, plan.skill)
    row.d1, row.d2 = d, d
    local pts = Points(c, plan.skill)
    row.crafts = pts > 0 and 1 / pts or nil
    row.netPoint = pts > 0 and c.net / pts or nil
    row.addCrafts = 1
    row.action = { label = "Add", fn = function() ns.UI.ShowShopping(c.recipeID) end }
    table.insert(rows, row)
  end
  return rows
end

-- One-line summary of a plan for the window footer.
function L.Summary(plan, option)
  local who = option and (option.charName .. ", " .. option.prof) or ""
  if plan.stale > 0 and #plan.candidates == 0 then
    return ("%s: open the profession window on this character once so recipe colours are recorded."):format(who)
  end
  if plan.skill >= plan.target then
    return ("%s: skill %d is at the target."):format(who, plan.skill)
  end
  local reached = plan.gap or plan.target
  local text = ("%s: %d to %d in about %d crafts. Materials %s, products bring back %s, net %s%s."):format(
    who, plan.skill, reached, math.ceil(plan.crafts - 0.001), ns.Money(plan.mats), ns.Money(plan.value),
    plan.net < 0 and "profit " or "cost ", ns.Money(math.abs(plan.net)))
  if plan.gap then text = text .. (" No known recipe gives a point past %d; learn more recipes."):format(plan.gap) end
  if plan.stale > 0 then text = text .. (" %d recipes lack colour data; open the profession window on this character."):format(plan.stale) end
  return text
end
