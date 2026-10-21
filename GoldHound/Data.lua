-- GoldHound: static data. Classic-era disenchant tables, skill requirements and vendor seeds.
local ADDON, ns = ...
local Data = {}
ns.Data = Data

Data.CLASS_WEAPON = 2
Data.CLASS_ARMOR = 4
Data.CLASS_RECIPE = 9

-- Enchanting material item IDs (classic era).
local STRANGE_DUST, SOUL_DUST, VISION_DUST, DREAM_DUST, ILLUSION_DUST = 10940, 11083, 11137, 11176, 16204
local L_MAGIC, G_MAGIC, L_ASTRAL, G_ASTRAL = 10938, 10939, 10998, 11082
local L_MYSTIC, G_MYSTIC, L_NETHER, G_NETHER, L_ETERNAL, G_ETERNAL = 11134, 11135, 11174, 11175, 16202, 16203
local S_GLIMMER, L_GLIMMER, S_GLOW, L_GLOW, S_RADIANT, L_RADIANT, S_BRILLIANT, L_BRILLIANT = 10978, 11084, 11138, 11139, 11177, 11178, 14343, 14344
local NEXUS = 20725

-- Uncommon (green) items by item level bracket: {minIlvl, maxIlvl, dust, essence, shard}
-- Each material is {itemID, minQty, maxQty}.
local UNCOMMON = {
  { 5, 15,  { STRANGE_DUST, 1, 2 },  { L_MAGIC, 1, 2 },   nil },
  { 16, 20, { STRANGE_DUST, 2, 3 },  { G_MAGIC, 1, 2 },   { S_GLIMMER, 1, 1 } },
  { 21, 25, { STRANGE_DUST, 4, 6 },  { L_ASTRAL, 1, 2 },  { S_GLIMMER, 1, 1 } },
  { 26, 30, { SOUL_DUST, 1, 2 },     { G_ASTRAL, 1, 2 },  { L_GLIMMER, 1, 1 } },
  { 31, 35, { SOUL_DUST, 2, 5 },     { L_MYSTIC, 1, 2 },  { S_GLOW, 1, 1 } },
  { 36, 40, { VISION_DUST, 1, 2 },   { G_MYSTIC, 1, 2 },  { L_GLOW, 1, 1 } },
  { 41, 45, { VISION_DUST, 2, 5 },   { L_NETHER, 1, 2 },  { S_RADIANT, 1, 1 } },
  { 46, 50, { DREAM_DUST, 1, 2 },    { G_NETHER, 1, 2 },  { L_RADIANT, 1, 1 } },
  { 51, 55, { DREAM_DUST, 2, 5 },    { L_ETERNAL, 1, 2 }, { S_BRILLIANT, 1, 1 } },
  { 56, 60, { ILLUSION_DUST, 1, 2 }, { G_ETERNAL, 1, 2 }, { L_BRILLIANT, 1, 1 } },
  { 61, 99, { ILLUSION_DUST, 2, 5 }, { G_ETERNAL, 2, 3 }, { L_BRILLIANT, 1, 1 } },
}

-- Rare (blue) items: one shard.
local RARE = {
  { 5, 25, S_GLIMMER }, { 26, 30, L_GLIMMER }, { 31, 35, S_GLOW }, { 36, 40, L_GLOW },
  { 41, 45, S_RADIANT }, { 46, 50, L_RADIANT }, { 51, 55, S_BRILLIANT }, { 56, 99, L_BRILLIANT },
}

-- Epic (purple) items.
local EPIC = {
  { 5, 45, { S_RADIANT, 2, 4 } }, { 46, 50, { L_RADIANT, 2, 4 } },
  { 51, 55, { NEXUS, 1, 1 } }, { 56, 99, { NEXUS, 1, 2 } },
}

-- Enchanting skill needed to disenchant an item of a given item level.
local DE_SKILL = {
  { 1, 20, 1 }, { 21, 25, 25 }, { 26, 30, 50 }, { 31, 35, 75 }, { 36, 40, 100 },
  { 41, 45, 125 }, { 46, 50, 150 }, { 51, 55, 175 }, { 56, 60, 200 }, { 61, 99, 225 },
}

local function Bracket(list, ilvl)
  for _, b in ipairs(list) do
    if ilvl >= b[1] and ilvl <= b[2] then return b end
  end
end

function Data.DisenchantSkill(ilvl)
  local b = Bracket(DE_SKILL, ilvl or 0)
  return b and b[3] or 1
end

-- Returns a list of { item = itemID, chance = 0..1, min = n, max = n } or nil when
-- the item cannot be disenchanted. Armor favours dust, weapons favour essence.
function Data.Disenchant(quality, ilvl, classID)
  if classID ~= Data.CLASS_WEAPON and classID ~= Data.CLASS_ARMOR then return nil end
  if not ilvl or ilvl < 5 then return nil end
  if quality == 2 then
    local b = Bracket(UNCOMMON, ilvl)
    if not b then return nil end
    local dust, ess, shard = b[3], b[4], b[5]
    local isWeapon = classID == Data.CLASS_WEAPON
    local shardChance = shard and 0.05 or 0
    local major = shard and 0.75 or 0.80
    local minor = 0.20
    local out = {
      { item = dust[1], chance = isWeapon and minor or major, min = dust[2], max = dust[3] },
      { item = ess[1], chance = isWeapon and major or minor, min = ess[2], max = ess[3] },
    }
    if shard then table.insert(out, { item = shard[1], chance = shardChance, min = shard[2], max = shard[3] }) end
    return out
  elseif quality == 3 then
    local b = Bracket(RARE, ilvl)
    if not b then return nil end
    return { { item = b[3], chance = 1, min = 1, max = 1 } }
  elseif quality == 4 then
    local b = Bracket(EPIC, ilvl)
    if not b then return nil end
    return { { item = b[3][1], chance = 1, min = b[3][2], max = b[3][3] } }
  end
  return nil
end

-- Seed prices (copper per unit) for reagents sold by vendors. Real prices seen at
-- a merchant overwrite these, so they only need to be roughly right.
Data.VendorSeed = {
  [2320] = 10,     -- Coarse Thread
  [2321] = 100,    -- Fine Thread
  [4291] = 500,    -- Silken Thread
  [8343] = 2000,   -- Heavy Silken Thread
  [14341] = 5000,  -- Rune Thread
  [2880] = 10,     -- Weak Flux
  [3466] = 2000,   -- Strong Flux
  [3857] = 500,    -- Coal
  [3371] = 20,     -- Empty Vial
  [3372] = 200,    -- Leaded Vial
  [8925] = 2000,   -- Crystal Vial
  [4470] = 8,      -- Simple Wood
  [2678] = 10,     -- Mild Spices
  [2692] = 20,     -- Hot Spices
  [3713] = 40,     -- Soothing Spices
  [159] = 25,      -- Refreshing Spring Water
  [1179] = 125,    -- Ice Cold Milk
  [18567] = 20000, -- Elemental Flux
}

-- Profession names used to recognise "Requires <profession> (<skill>)" tooltip lines.
Data.ProfessionNames = {
  "Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Leatherworking", "Tailoring",
  "Cooking", "First Aid", "Mining", "Herbalism", "Skinning", "Fishing", "Jewelcrafting",
  "Inscription", "Smelting", "Poisons",
}
Data.ProfessionSet = {}
for _, n in ipairs(Data.ProfessionNames) do Data.ProfessionSet[n] = true end

-- Recipe item subclasses map to the profession that uses them (Enum.ItemRecipeSubclass).
Data.RecipeSubclassProfession = {
  [1] = "Leatherworking", [2] = "Tailoring", [3] = "Engineering", [4] = "Blacksmithing",
  [5] = "Cooking", [6] = "Alchemy", [7] = "First Aid", [8] = "Enchanting", [9] = "Fishing",
  [10] = "Jewelcrafting", [11] = "Inscription",
}
