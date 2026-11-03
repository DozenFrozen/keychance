local _, KC = ...

-- Счётчики группы с начала ключа: урон и сбитые заклинания. Источники по приоритету:
--   1) встроенный измеритель Blizzard (C_DamageMeter, 12.0+)
--   2) Details!
--   3) собственный подсчёт по боевому логу (если клиент его ещё отдаёт аддонам)
-- В 12.0 значения в бою могут быть "секретными" — тогда пропускаем замер и держим последнее известное значение.
local Damage = { source = nil, boss = nil, fight = nil }
KC.Damage = Damage

local max = math.max

-- blizzard: имя в Enum.DamageMeterType; details: контейнер Details! и поле актёра
local METRICS = {
    damage     = { blizzard = "DamageDone", detailsAttr = DETAILS_ATTRIBUTE_DAMAGE or 1, field = "total" },
    interrupts = { blizzard = "Interrupts", detailsAttr = DETAILS_ATTRIBUTE_MISC or 4, field = "interrupt" },
}
-- baseline — значение источника на старте ключа, last — счётчик с начала ключа,
-- stamp — когда значение последний раз удалось прочитать, cleu — собственный подсчёт по боевому логу
local state = {}
for kind in pairs(METRICS) do state[kind] = { cleu = 0 } end

local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
end

local function FromBlizzard(kind)
    local meterType = Enum.DamageMeterType and Enum.DamageMeterType[METRICS[kind].blizzard]
    if not (C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and Enum.DamageMeterSessionType
        and meterType) then return end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
        Enum.DamageMeterSessionType.Overall, meterType)
    if not ok or type(session) ~= "table" or type(session.combatSources) ~= "table" then return end
    local total = 0
    for _, src in ipairs(session.combatSources) do
        local v = src.totalAmount
        if v == nil or IsSecret(v) then return end
        total = total + v
    end
    return total
end

local function FromDetails(kind)
    if not (Details and Details.GetCombat) then return end
    local m = METRICS[kind]
    local ok, total = pcall(function()
        local combat = Details:GetCombat(DETAILS_SEGMENTID_OVERALL or -1)
        local container = combat and combat:GetContainer(m.detailsAttr)
        if not container then return end
        local sum = 0
        for _, actor in container:ListActors() do
            if actor:IsGroupPlayer() then sum = sum + (actor[m.field] or 0) end
        end
        return sum
    end)
    if ok and total and not IsSecret(total) then return total end
end

local GROUP_MASK = 0x00000007 -- COMBATLOG_OBJECT_AFFILIATION_MINE | PARTY | RAID
local AMOUNT_AT_12 = { SWING_DAMAGE = true }
local AMOUNT_AT_15 = {
    SPELL_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true, RANGE_DAMAGE = true,
    DAMAGE_SHIELD = true, DAMAGE_SPLIT = true,
}
local cleuWorks = false -- боевой лог реально отдаёт значения

local cleuFrame = CreateFrame("Frame")
cleuFrame:SetScript("OnEvent", function()
    if not KC.run then return end
    local info = { CombatLogGetCurrentEventInfo() }
    local sub, flags, destGUID = info[2], info[6], info[8]
    if not flags or IsSecret(flags) or bit.band(flags, GROUP_MASK) == 0 then return end
    if sub == "SPELL_INTERRUPT" then
        state.interrupts.cleu = state.interrupts.cleu + 1
        cleuWorks = true
        return
    end
    local amount = AMOUNT_AT_12[sub] and info[12] or AMOUNT_AT_15[sub] and info[15]
    if type(amount) == "number" and not IsSecret(amount) then
        state.damage.cleu = state.damage.cleu + amount
        cleuWorks = true
        local b = Damage.boss
        if b and destGUID and b.guids[destGUID] then b.cleuDmg = b.cleuDmg + amount end
    end
end)
local cleuOK = CombatLogGetCurrentEventInfo
    and pcall(cleuFrame.RegisterEvent, cleuFrame, "COMBAT_LOG_EVENT_UNFILTERED")

local function Read(kind)
    local v = FromBlizzard(kind)
    if v then return v, "Blizzard" end
    v = FromDetails(kind)
    if v then return v, "Details" end
    if cleuOK and cleuWorks then return state[kind].cleu, "CombatLog" end
end

local function SampleMetric(kind)
    local s = state[kind]
    local v, source = Read(kind)
    if v then
        if source == "CombatLog" or not s.baseline or v < s.baseline then
            s.baseline = 0 -- сегмент сбросился на старте ключа
        end
        s.last = v - s.baseline
        s.stamp = GetTime()
        if kind == "damage" then Damage.source = source end
    end
    return s.last
end

function Damage.Start()
    for kind, s in pairs(state) do
        s.cleu = 0
        s.last, s.stamp = nil, nil
        s.baseline = Read(kind) or 0
    end
    Damage.boss, Damage.fight = nil, nil
end

-- Вызывается раз в секунду. Возвращает урон группы с начала ключа (или последнее известное значение).
function Damage.Sample()
    return SampleMetric("damage")
end

-- Сбитые заклинания группы с начала ключа (или последнее известное значение).
function Damage.Interrupts()
    return SampleMetric("interrupts")
end

------------------------------------------------------------------------
-- Текущий бой (от входа в бой до выхода)
------------------------------------------------------------------------
function Damage.FightStart()
    local i = state.interrupts
    Damage.fight = { int0 = i.last or 0, cleu0 = i.cleu }
end

function Damage.FightInterrupts()
    local f, i = Damage.fight, state.interrupts
    if not f then return end
    if cleuWorks then return i.cleu - f.cleu0 end
    return i.last and max(0, i.last - f.int0)
end

------------------------------------------------------------------------
-- Бой с боссом
------------------------------------------------------------------------
function Damage.BossStart()
    local d, i = state.damage, state.interrupts
    Damage.boss = { dmg0 = d.last or 0, int0 = i.last or 0, cleuInt = i.cleu, cleuDmg = 0, guids = {},
        start = GetTime() }
    Damage.RefreshBossUnits()
end

function Damage.RefreshBossUnits()
    local b = Damage.boss
    if not b then return end
    for n = 1, 5 do
        local guid = UnitGUID("boss" .. n)
        if guid and not IsSecret(guid) then b.guids[guid] = true end
    end
end

-- Урон группы в секунду по боссу прямо во время боя (только если боевой лог доступен — иначе значения
-- в бою "секретные" и урон известен лишь после боя).
function Damage.BossLiveDPS()
    local b = Damage.boss
    local t = b and GetTime() - b.start
    if b and b.cleuDmg > 0 and t >= 5 then return b.cleuDmg / t end
end

-- Доля оставшегося HP босса 0..1 (по самому "толстому" из boss1..5: умереть должны все).
-- nil, если игра не отдаёт здоровье (в 12.0 оно в бою может быть "секретным").
function Damage.BossHealth()
    local best
    for n = 1, 5 do
        local unit = "boss" .. n
        if UnitExists(unit) and not UnitIsDead(unit) then
            local ok, hp, hpMax = pcall(function() return UnitHealth(unit), UnitHealthMax(unit) end)
            if ok and hp and hpMax and not IsSecret(hp) and not IsSecret(hpMax) and hpMax > 0 then
                best = max(best or 0, hp / hpMax)
            end
        end
    end
    return best
end

-- Отцепляет замер боя с боссом; итог читается позже через BossResult.
function Damage.BossStop()
    local b = Damage.boss
    Damage.boss = nil
    return b
end

-- Итог боя с боссом: урон (по боевому логу — только по самому боссу, иначе весь урон группы за бой)
-- и сбитые заклинания. Возвращает nil, пока значения после боя ещё не удалось прочитать.
function Damage.BossResult(b, endAt)
    local d, i = state.damage, state.interrupts
    if b.cleuDmg > 0 then
        return b.cleuDmg, i.cleu - b.cleuInt, true
    end
    if not d.stamp or d.stamp <= endAt then return end
    local ints = i.stamp and i.stamp > endAt and max(0, i.last - b.int0) or nil
    return max(0, d.last - b.dmg0), ints, false
end
