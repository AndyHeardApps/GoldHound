-- GoldHound: remembers each character's professions, skill levels and gold.
local ADDON, ns = ...
local Chars = {}
ns.Chars = Chars

local function Record()
  if not ns.db or not ns.charKey then return end
  local rec = ns.db.chars[ns.charKey] or {}
  ns.db.chars[ns.charKey] = rec
  rec.name = ns.charName
  rec.realm = ns.realmName
  rec.realmKey = ns.realmKey
  rec.money = ns.Budget()
  rec.lastSeen = time()
  rec.professions = {}
  if GetProfessions and GetProfessionInfo then
    -- GetProfessions returns primary 1, primary 2, (archaeology slot, unused on
    -- Forever), fishing, cooking, first aid. ipairs stops at the first nil, so
    -- the slots are collected explicitly.
    local ok, p1, p2, slot3, fishing, cooking, firstAid = pcall(GetProfessions)
    if ok then
      for _, index in pairs({ p1, p2, slot3, fishing, cooking, firstAid }) do
        if index then
          local ok2, name, _, skill, maxSkill, _, _, skillLine = pcall(GetProfessionInfo, index)
          if ok2 and name then
            rec.professions[name] = { skill = skill or 0, max = maxSkill or 0, skillLine = skillLine }
          end
        end
      end
    end
  end
  if ns.Pricing then ns.Pricing.InvalidateRecipeIndex() end
  ns.Fire("CHARS_UPDATED")
end

ns.On("READY", function() C_Timer.After(2, Record) end)
ns.RegisterEvent("SKILL_LINES_CHANGED", function() ns.Debounce("chars", 2, Record) end)
ns.RegisterEvent("PLAYER_MONEY", function() ns.Debounce("chars-money", 5, Record) end)
ns.RegisterEvent("PLAYER_LOGOUT", Record)

-- All characters on this realm (any faction) that have the profession.
-- Returns a list of { key, name, skill, max } sorted by skill, highest first.
function Chars.WithProfession(profName)
  local out = {}
  if not ns.db or not profName then return out end
  for key, rec in pairs(ns.db.chars) do
    if rec.realm == ns.realmName and rec.professions and rec.professions[profName] then
      local p = rec.professions[profName]
      table.insert(out, { key = key, name = rec.name or key, skill = p.skill or 0, max = p.max or 0 })
    end
  end
  table.sort(out, function(a, b) return a.skill > b.skill end)
  return out
end

-- Best character for a profession at a given minimum skill, or nil.
function Chars.CanDo(profName, minSkill)
  for _, c in ipairs(Chars.WithProfession(profName)) do
    if c.skill >= (minSkill or 0) then return c end
  end
  return nil
end

function Chars.HasProfession(profName)
  return Chars.CanDo(profName, 0) ~= nil
end

-- Name of the character record that knows a recipe (prefers the current character).
function Chars.WhoKnows(recipe)
  if not recipe or not recipe.chars then return nil end
  if recipe.chars[ns.charKey] then return ns.charName end
  for key in pairs(recipe.chars) do
    local rec = ns.db.chars[key]
    if rec and rec.realm == ns.realmName then return rec.name or key end
  end
  return nil
end

-- Skill of a character in a profession, or 0.
function Chars.Skill(charKey, profName)
  local rec = ns.db.chars[charKey]
  local p = rec and rec.professions and rec.professions[profName]
  return p and p.skill or 0
end
