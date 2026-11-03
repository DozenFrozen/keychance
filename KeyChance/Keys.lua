local _, KC = ...
local L = KC.L

-- Ключи участников группы. Чужой ключ аддону напрямую не виден, поэтому он передаётся сообщениями:
--   * свой протокол KeyChance ("K:mapID:level", запрос — "R");
--   * протокол LibKeystone (BigWigs/LittleWigs и др.: "level,mapID,rating", запрос — "R") —
--     на запрос отвечают все, у кого стоит любой из этих аддонов.
local Keys = { party = {} } -- "Имя-Сервер" -> { mapID, level }
KC.Keys = Keys

local PREFIX, LIBKS = "KeyChance", "LibKS"
C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
C_ChatInfo.RegisterAddonMessagePrefix(LIBKS)

local function Normalize(name)
    if not name then return end
    if name:find("-", 1, true) then return name end
    return name .. "-" .. (GetNormalizedRealmName() or "")
end

function Keys.FullName(unit)
    local name, realm = UnitFullName(unit)
    if not name then return end
    return Normalize(realm and realm ~= "" and (name .. "-" .. realm) or name)
end

local function OwnKey()
    return C_MythicPlus.GetOwnedKeystoneChallengeMapID(), C_MythicPlus.GetOwnedKeystoneLevel()
end

-- Свой ответ по протоколу LibKeystone нужен, только если самой библиотеки нет (иначе ответит она).
local function HasLibKeystone()
    return LibStub and LibStub("LibKeystone", true) ~= nil
end

local function Send(prefix, msg)
    if not IsInGroup(LE_PARTY_CATEGORY_HOME) or IsInRaid() then return end
    pcall(C_ChatInfo.SendAddonMessage, prefix, msg, "PARTY")
end

local lastSent
function Keys.Broadcast()
    local mapID, level = OwnKey()
    lastSent = ("%d:%d"):format(mapID or 0, level or 0)
    Send(PREFIX, "K:" .. lastSent)
    if not HasLibKeystone() then
        local rating = C_ChallengeMode.GetOverallDungeonScore and C_ChallengeMode.GetOverallDungeonScore() or 0
        Send(LIBKS, ("%d,%d,%d"):format(level or 0, mapID or 0, rating))
    end
end

local requestAt = 0
function Keys.Request()
    if GetTime() - requestAt < 5 then return end
    requestAt = GetTime()
    Send(PREFIX, "R")
    Send(LIBKS, "R")
    Keys.Broadcast()
end

-- Раз в секунду: если свой ключ сменился (получен, улучшен, понижен) — сообщаем группе.
function Keys.OnTick()
    if not IsInGroup() or KC.run then return end
    local mapID, level = OwnKey()
    if lastSent ~= ("%d:%d"):format(mapID or 0, level or 0) then Keys.Broadcast() end
end

local function Store(sender, mapID, level)
    mapID, level = tonumber(mapID), tonumber(level)
    if not mapID or not level then return end
    local key = Normalize(sender)
    local known = Keys.party[key]
    Keys.party[key] = { mapID = mapID > 0 and mapID or nil, level = level > 0 and level or nil }
    if not known or known.mapID ~= Keys.party[key].mapID or known.level ~= Keys.party[key].level then
        if KC.db and KC.Update then KC.Update() end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event, prefix, msg, channel, sender)
    if event == "CHAT_MSG_ADDON" then
        if (prefix ~= PREFIX and prefix ~= LIBKS) or channel ~= "PARTY" then return end
        if Normalize(sender) == Keys.FullName("player") then return end
        if msg == "R" then
            if prefix == PREFIX or not HasLibKeystone() then
                C_Timer.After(math.random() * 2, Keys.Broadcast)
            end
        elseif prefix == PREFIX then
            local mapID, level = msg:match("^K:(%d+):(%d+)$")
            Store(sender, mapID, level)
        else
            local level, mapID = strsplit(",", msg)
            Store(sender, mapID, level)
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- забываем тех, кто вышел из группы
        local present = {}
        for i = 1, 4 do
            local name = UnitExists("party" .. i) and Keys.FullName("party" .. i)
            if name then present[name] = true end
        end
        for name in pairs(Keys.party) do
            if not present[name] then Keys.party[name] = nil end
        end
        C_Timer.After(1, Keys.Request)
    else
        C_Timer.After(3, Keys.Request)
    end
end)

local function LeaderUnit()
    if not IsInGroup() or UnitIsGroupLeader("player") then return "player" end
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) and UnitIsGroupLeader(unit) then return unit end
    end
end

-- Чей ключ показывать до старта:
--   1) уже вставленный в чашу ключ — его и будут проходить;
--   2) в группе — ключ лидера (свой, только если лидер вы или вы один);
-- Возвращает { mapID, level, owner = "Ваш ключ"/"Ключ лидера (Имя)", unknown = true, если ключ лидера неизвестен }.
function Keys.Target()
    if C_ChallengeMode.GetSlottedKeystoneInfo then
        local mapID, _, level = C_ChallengeMode.GetSlottedKeystoneInfo()
        if mapID and level and level > 0 then
            return { mapID = mapID, level = level, owner = L["Ключ в чаше"] }
        end
    end
    local leader = LeaderUnit()
    if not leader or leader == "player" then
        local mapID, level = OwnKey()
        return { mapID = mapID, level = level, owner = L["Ваш ключ"] }
    end
    local name = UnitName(leader) or "?"
    local key = Keys.party[Keys.FullName(leader) or ""]
    local owner = (L["Ключ лидера (%s)"]):format(name)
    if not key then return { owner = owner, unknown = true } end
    return { mapID = key.mapID, level = key.level, owner = owner }
end
