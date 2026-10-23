-- GoldHound: captures recipes, reagents and outputs when a profession window opens.
local ADDON, ns = ...
local Professions = {}
ns.Professions = Professions

local REAGENT_BASIC = (Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 0
local RECIPE_ENCHANT = (Enum.TradeskillRecipeType and Enum.TradeskillRecipeType.Enchant) or 3

local function Say(verbose, ...)
  if verbose then ns.Print(...) end
end

local function Flag(fn)
  local ok, v = pcall(fn)
  return ok and v or false
end

-- Reads the open profession. With verbose=true every step is reported in chat.
local function Capture(verbose)
  if not ns.db or not ns.charKey then Say(verbose, "Not ready yet (no database)."); return end
  if not C_TradeSkillUI then Say(verbose, "C_TradeSkillUI is missing on this client."); return end
  local ready = Flag(C_TradeSkillUI.IsTradeSkillReady)
  Say(verbose, "Trade skill ready: %s", tostring(ready))
  if Flag(C_TradeSkillUI.IsTradeSkillLinked) then Say(verbose, "Skipped: this is a linked profession, not yours."); return end
  if Flag(C_TradeSkillUI.IsTradeSkillGuild) then Say(verbose, "Skipped: guild profession view."); return end
  if Flag(C_TradeSkillUI.IsNPCCrafting) then Say(verbose, "Skipped: NPC crafting."); return end

  local okp, prof = pcall(C_TradeSkillUI.GetChildProfessionInfo)
  if not okp or type(prof) ~= "table" then Say(verbose, "GetChildProfessionInfo failed: %s", tostring(prof)); return end
  local profName = prof.professionName
  if not profName or profName == "" then
    local okb, base = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    if okb and type(base) == "table" then profName = base.professionName end
  end
  if not profName or profName == "" then Say(verbose, "No profession is open (profession name empty)."); return end
  Say(verbose, "Profession: %s (id %s, skill %s/%s)", profName, tostring(prof.professionID), tostring(prof.skillLevel), tostring(prof.maxSkillLevel))

  local oki, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
  if not oki or type(ids) ~= "table" then Say(verbose, "GetAllRecipeIDs failed: %s", tostring(ids)); ids = {} end
  Say(verbose, "GetAllRecipeIDs: %d recipes", #ids)
  if #ids == 0 then
    local okf, filtered = pcall(C_TradeSkillUI.GetFilteredRecipeIDs)
    if okf and type(filtered) == "table" then ids = filtered end
    Say(verbose, "GetFilteredRecipeIDs: %d recipes", #ids)
  end
  if #ids == 0 then Say(verbose, "No recipe IDs returned; the window may still be loading. Try /gh recipes again."); return end

  local added, seen, unlearned, noInfo, noSchematic = 0, 0, 0, 0, 0
  local sample
  for _, recipeID in ipairs(ids) do
    local okr, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
    if not okr or type(info) ~= "table" then
      noInfo = noInfo + 1
      if verbose and not sample then sample = "GetRecipeInfo(" .. tostring(recipeID) .. ") -> " .. tostring(info) end
    elseif not info.learned then
      unlearned = unlearned + 1
    elseif info.isDummyRecipe or info.isGatheringRecipe or info.isSalvageRecipe then
      -- headers and gathering entries are not crafts
    else
      local oks, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
      if not oks or type(schematic) ~= "table" then
        noSchematic = noSchematic + 1
        if verbose and not sample then sample = "GetRecipeSchematic(" .. tostring(recipeID) .. ") -> " .. tostring(schematic) end
      else
        local reagents, complete = {}, true
        for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
          if (slot.reagentType == REAGENT_BASIC or slot.reagentType == nil) and slot.required ~= false then
            local first = slot.reagents and slot.reagents[1]
            if first and first.itemID then
              table.insert(reagents, { first.itemID, slot.quantityRequired or 1 })
            elseif first and first.currencyID then
              complete = false
            end
          end
        end
        local rec = ns.db.recipes[recipeID]
        if not rec then
          rec = {}
          ns.db.recipes[recipeID] = rec
          added = added + 1
        end
        seen = seen + 1
        rec.name = schematic.name or info.name
        rec.prof = profName
        rec.profID = prof.professionID
        rec.out = schematic.outputItemID
        rec.qmin = schematic.quantityMin or 1
        rec.qmax = schematic.quantityMax or rec.qmin
        rec.icon = schematic.icon or info.icon
        rec.reagents = reagents
        rec.complete = complete and #reagents > 0
        rec.enchant = (schematic.recipeType == RECIPE_ENCHANT) or info.isEnchantingRecipe or false
        rec.chars = rec.chars or {}
        -- Difficulty is per character: the same recipe is orange for one and
        -- grey for another. d is the colour now (0 orange, 1 yellow, 2 green,
        -- 3 grey), g the skill at which it goes grey, s the skill it was seen
        -- at, n the points a craft gives.
        local d, skill = info.relativeDifficulty, prof.skillLevel or 0
        rec.chars[ns.charKey] = { d = d, g = info.maxTrivialLevel, s = skill, n = info.numSkillUps, t = time() }
        -- Observed skill range for each colour, shared by all characters since
        -- the thresholds belong to the recipe. These bracket where the colour
        -- changes, which the game does not expose directly.
        if d ~= nil and skill > 0 then
          rec.seen = rec.seen or {}
          local o = rec.seen[d]
          if not o then rec.seen[d] = { lo = skill, hi = skill }
          else o.lo, o.hi = math.min(o.lo, skill), math.max(o.hi, skill) end
        end
        rec.difficulty, rec.trivial = nil, nil
        rec.t = time()
        if verbose and not sample then
          sample = ("%s -> item %s x%d-%d, %d reagents"):format(rec.name or "?", tostring(rec.out), rec.qmin, rec.qmax, #reagents)
        end
      end
    end
  end
  Say(verbose, "Recorded %d crafts (%d new). Unlearned: %d, no info: %d, no schematic: %d.", seen, added, unlearned, noInfo, noSchematic)
  if sample then Say(verbose, "Sample: %s", sample) end
  if seen > 0 then
    ns.Pricing.InvalidateRecipeIndex()
    if added > 0 and not verbose then
      ns.Print("Recorded %d new %s recipes (%d total for this profession).", added, profName, seen)
    end
    ns.Fire("RECIPES_UPDATED")
  end
end

function Professions.Capture(verbose)
  Capture(verbose)
end

local function Schedule(delay)
  ns.Debounce("recipes", delay or 1.0, function() Capture(false) end)
end

for _, ev in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_NAME_UPDATE", "NEW_RECIPE_LEARNED" }) do
  ns.RegisterEvent(ev, function() Schedule(1.0) end)
end

-- Also hook the profession window itself, in case the events differ on this client.
ns.RegisterEvent("ADDON_LOADED", function(name)
  if name == "Blizzard_Professions" and ProfessionsFrame and ProfessionsFrame.HookScript then
    ProfessionsFrame:HookScript("OnShow", function() Schedule(1.5) end)
  end
end)
