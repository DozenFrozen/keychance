local _, KC = ...

-- Суммарный урон группы с начала ключа. Источники по приоритету:
--   1) встроенный измеритель урона Blizzard (C_DamageMeter, 12.0+)
--   2) Details!
--   3) собственный подсчёт по боевому логу (если клиент его ещё отдаёт аддонам)
-- В 12.0 значения в бою могут быть "секретными" — тогда пропускаем замер и держим последнее известное значение.
local Damage = { baseline = nil, last = nil, source = nil, cleu = 0 }
KC.Damage = Damage

local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
end

local function FromBlizzard()
    if not (C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and Enum.DamageMeterSessionType
        and Enum.DamageMeterType) then return end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
        Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.DamageDone)
    if not ok or type(session) ~= "table" or type(session.combatSources) ~= "table" then return end
    local total = 0
    for _, src in ipairs(session.combatSources) do
        local v = src.totalAmount
        if v == nil or IsSecret(v) then return end
        total = total + v
    end
    return total
end

local function FromDetails()
    if not (Details and Details.GetCombat) then return end
    local ok, total = pcall(function()
        local combat = Details:GetCombat(DETAILS_SEGMENTID_OVERALL or -1)
        local container = combat and combat:GetContainer(DETAILS_ATTRIBUTE_DAMAGE or 1)
        if not container then return end
        local sum = 0
        for _, actor in container:ListActors() do
            if actor:IsGroupPlayer() then sum = sum + (actor.total or 0) end
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

local cleuFrame = CreateFrame("Frame")
cleuFrame:SetScript("OnEvent", function()
    if not KC.run then return end
    local info = { CombatLogGetCurrentEventInfo() }
    local sub, flags = info[2], info[6]
    if not flags or bit.band(flags, GROUP_MASK) == 0 then return end
    local amount = AMOUNT_AT_12[sub] and info[12] or AMOUNT_AT_15[sub] and info[15]
    if type(amount) == "number" and not IsSecret(amount) then
        Damage.cleu = Damage.cleu + amount
    end
end)
local cleuOK = CombatLogGetCurrentEventInfo
    and pcall(cleuFrame.RegisterEvent, cleuFrame, "COMBAT_LOG_EVENT_UNFILTERED")

local function Read()
    local v = FromBlizzard()
    if v then return v, "Blizzard" end
    v = FromDetails()
    if v then return v, "Details" end
    if cleuOK and Damage.cleu > 0 then return Damage.cleu, "CombatLog" end
end

function Damage.Start()
    Damage.cleu = 0
    Damage.last = nil
    Damage.baseline = Read() or 0
end

-- Вызывается раз в секунду. Возвращает урон группы с начала ключа (или последнее известное значение).
function Damage.Sample()
    local v, source = Read()
    if v then
        if source == "CombatLog" then
            Damage.baseline = 0
        elseif not Damage.baseline or v < Damage.baseline then
            Damage.baseline = 0 -- сегмент сбросился на старте ключа
        end
        Damage.last = v - Damage.baseline
        Damage.source = source
    end
    return Damage.last
end
