local _, KC = ...

-- specID -> ключ в формате WarcraftLogs ("Class-Spec") и роль.
-- Ключи совпадают с тем, что пишет tools/wcl_fetch.py, поэтому данные не зависят от языка клиента.
KC.Specs = {
    [250]  = { key = "DeathKnight-Blood",        role = "TANK" },
    [251]  = { key = "DeathKnight-Frost",        role = "DPS" },
    [252]  = { key = "DeathKnight-Unholy",       role = "DPS" },
    [577]  = { key = "DemonHunter-Havoc",        role = "DPS" },
    [581]  = { key = "DemonHunter-Vengeance",    role = "TANK" },
    [1480] = { key = "DemonHunter-Devourer",     role = "DPS" },  -- Midnight; проверьте ID, если спек не распознаётся
    [102]  = { key = "Druid-Balance",            role = "DPS" },
    [103]  = { key = "Druid-Feral",              role = "DPS" },
    [104]  = { key = "Druid-Guardian",           role = "TANK" },
    [105]  = { key = "Druid-Restoration",        role = "HEALER" },
    [1467] = { key = "Evoker-Devastation",       role = "DPS" },
    [1468] = { key = "Evoker-Preservation",      role = "HEALER" },
    [1473] = { key = "Evoker-Augmentation",      role = "DPS" },
    [253]  = { key = "Hunter-BeastMastery",      role = "DPS" },
    [254]  = { key = "Hunter-Marksmanship",      role = "DPS" },
    [255]  = { key = "Hunter-Survival",          role = "DPS" },
    [62]   = { key = "Mage-Arcane",              role = "DPS" },
    [63]   = { key = "Mage-Fire",                role = "DPS" },
    [64]   = { key = "Mage-Frost",               role = "DPS" },
    [268]  = { key = "Monk-Brewmaster",          role = "TANK" },
    [269]  = { key = "Monk-Windwalker",          role = "DPS" },
    [270]  = { key = "Monk-Mistweaver",          role = "HEALER" },
    [65]   = { key = "Paladin-Holy",             role = "HEALER" },
    [66]   = { key = "Paladin-Protection",       role = "TANK" },
    [70]   = { key = "Paladin-Retribution",      role = "DPS" },
    [256]  = { key = "Priest-Discipline",        role = "HEALER" },
    [257]  = { key = "Priest-Holy",              role = "HEALER" },
    [258]  = { key = "Priest-Shadow",            role = "DPS" },
    [259]  = { key = "Rogue-Assassination",      role = "DPS" },
    [260]  = { key = "Rogue-Outlaw",             role = "DPS" },
    [261]  = { key = "Rogue-Subtlety",           role = "DPS" },
    [262]  = { key = "Shaman-Elemental",         role = "DPS" },
    [263]  = { key = "Shaman-Enhancement",       role = "DPS" },
    [264]  = { key = "Shaman-Restoration",       role = "HEALER" },
    [265]  = { key = "Warlock-Affliction",       role = "DPS" },
    [266]  = { key = "Warlock-Demonology",       role = "DPS" },
    [267]  = { key = "Warlock-Destruction",      role = "DPS" },
    [71]   = { key = "Warrior-Arms",             role = "DPS" },
    [72]   = { key = "Warrior-Fury",             role = "DPS" },
    [73]   = { key = "Warrior-Protection",       role = "TANK" },
}

KC.SpecRoleByKey = {}
for _, s in pairs(KC.Specs) do
    KC.SpecRoleByKey[s.key] = s.role
end

function KC.SpecKey(specID)
    local s = specID and KC.Specs[specID]
    return s and s.key
end
