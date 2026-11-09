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

-- Basic reagents of a recipe schematic as { {itemID, qty}, ... }, and whether
-- every one of them is an item (currency costs cannot be priced).
local function ReadReagents(schematic)
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
  return reagents, complete
end

-- Unlearned recipes are kept apart from known ones (they must not count as
-- crafts you can make), so recipe items on the auction house can be priced
-- with their real materials.
local function RecordUnlearned(recipeID, info, profName)
  local oks, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
  if not oks or type(schematic) ~= "table" then return end
  local reagents, complete = ReadReagents(schematic)
  if #reagents == 0 then return end
  ns.db.unlearned[recipeID] = {
    name = schematic.name or info.name, prof = profName, out = schematic.outputItemID,
    qmin = schematic.quantityMin or 1, qmax = schematic.quantityMax or schematic.quantityMin or 1,
    reagents = reagents, complete = complete, t = time(),
  }
  return true
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
  -- On tiered professions the child name is the expansion tier ("Khaz Algar
  -- Alchemy"); characters record the parent name ("Alchemy").
  local profName = prof.parentProfessionName
  if not profName or profName == "" then profName = prof.professionName end
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

  local added, seen, unlearned, unlearnedRead, noInfo, noSchematic = 0, 0, 0, 0, 0, 0
  local sample
  for _, recipeID in ipairs(ids) do
    local okr, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
    if not okr or type(info) ~= "table" then
      noInfo = noInfo + 1
      if verbose and not sample then sample = "GetRecipeInfo(" .. tostring(recipeID) .. ") -> " .. tostring(info) end
    elseif not info.learned then
      unlearned = unlearned + 1
      if not (info.isDummyRecipe or info.isGatheringRecipe or info.isSalvageRecipe) and RecordUnlearned(recipeID, info, profName) then
        unlearnedRead = unlearnedRead + 1
      end
    elseif info.isDummyRecipe or info.isGatheringRecipe or info.isSalvageRecipe then
      -- headers and gathering entries are not crafts
    else
      local oks, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
      if not oks or type(schematic) ~= "table" then
        noSchematic = noSchematic + 1
        if verbose and not sample then sample = "GetRecipeSchematic(" .. tostring(recipeID) .. ") -> " .. tostring(schematic) end
      else
        local reagents, complete = ReadReagents(schematic)
        ns.db.unlearned[recipeID] = nil
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
        local okc, spell = false, nil
        if C_Spell and C_Spell.GetSpellInfo then okc, spell = pcall(C_Spell.GetSpellInfo, recipeID) end
        if okc and type(spell) == "table" and type(spell.castTime) == "number" and spell.castTime > 0 then
          rec.cast = spell.castTime / 1000
        end
        rec.difficulty, rec.trivial = nil, nil
        rec.t = time()
        if verbose and not sample then
          sample = ("%s -> item %s x%d-%d, %d reagents"):format(rec.name or "?", tostring(rec.out), rec.qmin, rec.qmax, #reagents)
        end
      end
    end
  end
  Say(verbose, "Recorded %d crafts (%d new). Unlearned: %d (%d with materials read), no info: %d, no schematic: %d.", seen, added, unlearned, unlearnedRead, noInfo, noSchematic)
  if sample then Say(verbose, "Sample: %s", sample) end
  if seen > 0 or unlearnedRead > 0 then
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

-------------------------------------------------------------------------------
-- "Add to plan" on the profession window: a button beside Create All that puts
-- crafts of the selected recipe in the Plan tab. Same clicks as the Plan tab:
-- left one more, right one fewer, Ctrl for ten.
-------------------------------------------------------------------------------
local planButton

local function SelectedRecipe()
  local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
  local form = page and page.SchematicForm
  if not form or not form.GetRecipeInfo then return nil end
  local ok, info = pcall(form.GetRecipeInfo, form)
  if ok and type(info) == "table" then return info end
  return nil
end

-- Why the selected recipe cannot be planned, or nil when it can.
local function Blocked(info)
  if not info then return "Select a recipe first." end
  if Flag(C_TradeSkillUI.IsTradeSkillLinked) or Flag(C_TradeSkillUI.IsTradeSkillGuild) or Flag(C_TradeSkillUI.IsNPCCrafting) then
    return "Only your own professions can be planned."
  end
  if not info.learned then return "You have not learned this recipe." end
  if info.isDummyRecipe or info.isGatheringRecipe or info.isSalvageRecipe or info.isRecraft then return "This recipe cannot be planned." end
  return nil
end

local function UpdatePlanButton()
  if not planButton then return end
  local info = SelectedRecipe()
  planButton:SetEnabled(Blocked(info) == nil)
  local planned = info and ns.UI and ns.UI.PlannedCrafts and ns.UI.PlannedCrafts(info.recipeID) or 0
  planButton:SetText(planned > 0 and ("Planned: %d"):format(planned) or "Add to plan")
end

local function AddSelected(amount)
  local info = SelectedRecipe()
  local why = Blocked(info)
  if why then ns.Print(why) return end
  -- The recipe may not be recorded yet if the window opened a moment ago.
  if not ns.db.recipes[info.recipeID] then Capture(false) end
  local r = ns.db.recipes[info.recipeID]
  if not r or not r.reagents then ns.Print("%s is not recorded yet; try again in a moment.", info.name or "That recipe") return end
  if amount > 0 then
    ns.UI.ShowShopping(info.recipeID, amount)
  else
    ns.UI.AdjustShopping(info.recipeID, amount)
  end
  ns.Print("%s: %d crafts in the plan.", r.name or info.name or "?", ns.UI.PlannedCrafts(info.recipeID))
  UpdatePlanButton()
end

local function BuildPlanButton()
  local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
  if planButton or not page or not page.CreateAllButton then return end
  planButton = CreateFrame("Button", "GoldHoundPlanButton", page, "UIPanelButtonTemplate")
  planButton:SetSize(80, 22)
  planButton:SetPoint("RIGHT", page.CreateAllButton, "LEFT", -6, 0)
  planButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  planButton:SetMotionScriptsWhileDisabled(true) -- the tooltip says why it is disabled
  planButton:SetFrameLevel(page.CreateAllButton:GetFrameLevel() + 2)

  planButton:SetScript("OnClick", function(_, button)
    local n = IsControlKeyDown() and 10 or 1
    if button == "RightButton" then AddSelected(-n) else AddSelected(n) end
  end)
  planButton:SetScript("OnEnter", function(self)
    local info = SelectedRecipe()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("GoldHound plan")
    local why = Blocked(info)
    if why then
      GameTooltip:AddLine(why, 1, 0.3, 0.3, true)
    else
      GameTooltip:AddDoubleLine("In the plan", ("%d crafts"):format(ns.UI.PlannedCrafts(info.recipeID)), 0.8, 0.8, 0.8, 1, 1, 1)
      GameTooltip:AddLine("Left-click adds a craft, right-click removes one. Hold Ctrl for ten. The Plan tab lists the materials to buy.", 0.8, 0.8, 0.8, true)
    end
    GameTooltip:Show()
  end)
  planButton:SetScript("OnLeave", GameTooltip_Hide)
  planButton:SetScript("OnShow", UpdatePlanButton)

  if EventRegistry then
    EventRegistry:RegisterCallback("ProfessionsRecipeListMixin.Event.OnRecipeSelected", function()
      C_Timer.After(0, UpdatePlanButton)
    end, planButton)
  end
  UpdatePlanButton()
end

ns.On("PLAN_CHANGED", function() if planButton and planButton:IsVisible() then UpdatePlanButton() end end)

local function HookFrame()
  if not ProfessionsFrame or not ProfessionsFrame.HookScript or Professions.hooked then return end
  Professions.hooked = true
  -- Also hook the profession window itself, in case the events differ on this client.
  ProfessionsFrame:HookScript("OnShow", function()
    Schedule(1.5)
    BuildPlanButton()
    UpdatePlanButton()
  end)
  if ProfessionsFrame:IsShown() then BuildPlanButton() end
end

ns.RegisterEvent("ADDON_LOADED", function(name)
  if name == "Blizzard_Professions" then HookFrame() end
end)
ns.On("READY", HookFrame) -- in case another addon loaded the window before GoldHound
