-- GoldHound: reads recipe items (scrolls, patterns, plans) from their tooltips so
-- recipes on the auction house can be evaluated before you own them.
local ADDON, ns = ...
local Recipes = {}
ns.Recipes = Recipes

local minSkillPattern = ns.PatternFromFormat(ITEM_MIN_SKILL or "Requires %s (%d)")
local knownText = ITEM_SPELL_KNOWN or "Already known"

local function LineText(line)
  if type(line) ~= "table" then return nil end
  local text = line.leftText
  if type(text) ~= "string" then return nil end
  return text
end

local function StripArticle(name)
  name = ns.Trim(name)
  name = name:gsub("^an? ", ""):gsub("^the ", "")
  name = name:gsub("%.$", "")
  return name
end

local function ParseReagents(text)
  local out = {}
  for part in text:gmatch("[^,]+") do
    part = ns.Trim(part)
    local name, qty = part:match("^(.-)%s*%((%d+)%)$")
    if not name then name, qty = part, 1 end
    name = ns.Trim(name)
    if name ~= "" then table.insert(out, { name = name, qty = tonumber(qty) or 1 }) end
  end
  return out
end

-- Returns parsed data for a recipe item or nil when the tooltip is not cached yet.
-- { prof, skill, product, reagents = { {name, qty} }, known }
local RETRY = 3600 -- tooltips read before the item was cached are read again after this long

function Recipes.Parse(itemID)
  local cached = ns.db.recipeItems[itemID]
  if cached and cached.prof and (cached.product or (cached.t or 0) > time() - RETRY) then return cached end
  if not C_TooltipInfo or not C_TooltipInfo.GetItemByID then return nil end
  local ok, data = pcall(C_TooltipInfo.GetItemByID, itemID)
  if not ok or not data or not data.lines or #data.lines == 0 then
    C_Item.RequestLoadItemDataByID(itemID)
    return nil
  end
  local result = { prof = nil, skill = 0, product = nil, reagents = {}, t = time() }
  local lastRequires = nil
  for _, line in ipairs(data.lines) do
    local text = LineText(line)
    if text then
      local profName, skill = text:match(minSkillPattern)
      if profName and ns.Data.ProfessionSet[profName] then
        result.prof = profName
        result.skill = tonumber(skill) or 0
      elseif text:find("Teaches you how to", 1, true) then
        local product = text:match("Teaches you how to %a+ (.+)$")
        if product then result.product = StripArticle(product) end
      elseif text:match("^Requires ") and not text:match("^Requires Level") then
        -- The reagent list is the last "Requires" line on a recipe tooltip.
        lastRequires = text:gsub("^Requires ", "")
      elseif text == knownText then
        result.knownByViewer = true
      end
    end
  end
  if lastRequires then result.reagents = ParseReagents(lastRequires) end
  if not result.prof then
    local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
    if classID == ns.Data.CLASS_RECIPE then
      result.prof = ns.Data.RecipeSubclassProfession[subclassID]
    end
  end
  if not result.prof then return nil end
  ns.db.recipeItems[itemID] = result
  return result
end

-- Finds an item ID for a product or reagent name using scan data and known recipes.
function Recipes.ItemIDByName(name)
  return ns.ItemIDByName(name)
end

-- True when one of your characters already knows a recipe producing this product.
function Recipes.AlreadyKnown(prof, productName)
  for _, r in pairs(ns.db.recipes) do
    if r.prof == prof and r.name == productName then return true end
  end
  return false
end

-- Materials for the recipe a recipe item teaches, read from the profession
-- window (known or unlearned recipes): { name, out, qmin, qmax, reagents } or nil.
local function Lower(text) return type(text) == "string" and text:lower() or nil end

function Recipes.Schematic(parsed)
  if not parsed or not parsed.product then return nil end
  local product = Lower(parsed.product)
  local productID = ns.ItemIDByName(parsed.product)
  local best
  for _, store in ipairs({ ns.db.unlearned or {}, ns.db.recipes or {} }) do
    for _, r in pairs(store) do
      if r.reagents and #r.reagents > 0 and (not parsed.prof or not r.prof or r.prof == parsed.prof) then
        if (productID and r.out == productID) or Lower(r.name) == product then
          best = r
          if r.out then return r end
        end
      end
    end
  end
  return best
end
