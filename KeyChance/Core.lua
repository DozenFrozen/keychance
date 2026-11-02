local ADDON, KC = ...

local DEFAULTS = {
    -- стартовая поправка: обычная группа ~10% медленнее базы WCL. Дальше аддон сам подстраивает её
    -- по вашим завершённым ключам; вручную: /kc bias 0.05
    bias = 0.10,
    locked = false,
    shown = true,
}

local frame = CreateFrame("Frame")
KC.run = nil            -- состояние текущего ключа
KC.partySpecs = {}      -- guid -> specID

------------------------------------------------------------------------
-- Состав группы
------------------------------------------------------------------------
local inspectPending

local function PartyUnits()
    local units = { "player" }
    for i = 1, 4 do
        if UnitExists("party" .. i) then units[#units + 1] = "party" .. i end
    end
    return units
end

function KC.GetGroupSpecs()
    local specs = {}
    local playerSpec = GetSpecialization() and GetSpecializationInfo(GetSpecialization())
    if playerSpec then KC.partySpecs[UnitGUID("player")] = playerSpec end
    for _, unit in ipairs(PartyUnits()) do
        local key = KC.SpecKey(KC.partySpecs[UnitGUID(unit)])
        if key then specs[#specs + 1] = key end
    end
    return specs
end

local function InspectNext()
    if inspectPending or InCombatLockdown() then return end
    for _, unit in ipairs(PartyUnits()) do
        local guid = UnitGUID(unit)
        if unit ~= "player" and guid and not KC.partySpecs[guid] and CanInspect(unit) and UnitIsConnected(unit) then
            inspectPending = guid
            NotifyInspect(unit)
            C_Timer.After(4, function()
                if inspectPending == guid then inspectPending = nil end
            end)
            return
        end
    end
end

------------------------------------------------------------------------
-- Чтение состояния ключа
------------------------------------------------------------------------
local function ElapsedSeconds()
    for i = 1, 3 do
        local _, elapsed, timerType = GetWorldElapsedTime(i)
        if timerType == LE_WORLD_ELAPSED_TIMER_TYPE_CHALLENGE_MODE then return elapsed or 0 end
    end
    local _, elapsed = GetWorldElapsedTime(1)
    return elapsed or 0
end

-- Возвращает: число боссов, сколько убито, прогресс мобов 0..1
local function ReadCriteria()
    local numCriteria
    if C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo then
        local info = C_ScenarioInfo.GetScenarioStepInfo()
        numCriteria = info and info.numCriteria
    end
    if not numCriteria and C_Scenario and C_Scenario.GetStepInfo then
        numCriteria = select(3, C_Scenario.GetStepInfo())
    end
    local bosses, killed, forces = 0, 0, 0
    for i = 1, numCriteria or 0 do
        local c = C_ScenarioInfo.GetCriteriaInfo(i)
        if c then
            if c.isWeightedProgress then
                -- quantityString содержит "сырое" количество мобов ("245%"), totalQuantity — нужное количество
                local cur = c.quantityString and tonumber(c.quantityString:match("(%d+)"))
                if cur and c.totalQuantity and c.totalQuantity > 0 then
                    forces = cur / c.totalQuantity
                else
                    forces = (c.quantity or 0) / 100
                end
                if c.completed then forces = 1 end
            else
                bosses = bosses + 1
                if c.completed then killed = killed + 1 end
            end
        end
    end
    return bosses, killed, math.min(forces, 1)
end

local function InstanceForChallengeMap(mapID)
    local _, _, _, _, _, instanceID = C_ChallengeMode.GetMapUIInfo(mapID)
    return instanceID or (KC.db.cmToInstance and KC.db.cmToInstance[mapID])
end

------------------------------------------------------------------------
-- Жизненный цикл ключа
------------------------------------------------------------------------
local function StartRun()
    local mapID = C_ChallengeMode.GetActiveChallengeMapID()
    if not mapID then return end
    local level = C_ChallengeMode.GetActiveKeystoneInfo()
    local name, _, timeLimit = C_ChallengeMode.GetMapUIInfo(mapID)
    local instanceID = select(8, GetInstanceInfo())
    KC.db.cmToInstance[mapID] = instanceID

    local run = {
        mapID = mapID, instanceID = instanceID, name = name,
        level = level or 0, timeLimit = timeLimit or 0, kills = {},
    }
    -- восстановление после /reload посреди ключа
    local saved = KC.db.current
    if saved and saved.mapID == mapID and saved.level == run.level and ElapsedSeconds() >= (saved.kills[#saved.kills] or 0) then
        run.kills = saved.kills
    else
        KC.Damage.Start()
    end
    KC.db.current = { mapID = mapID, level = run.level, kills = run.kills }
    KC.run = run
    InspectNext()
end

local function FinishRun()
    local run = KC.run
    if not run then return end
    local timeMs, onTime, upgrades
    if C_ChallengeMode.GetChallengeCompletionInfo then
        local info = C_ChallengeMode.GetChallengeCompletionInfo()
        if info then timeMs, onTime, upgrades = info.time, info.onTime, info.keystoneUpgradeLevels end
    end
    if not timeMs and C_ChallengeMode.GetCompletionInfo then
        local _, _, t, ot, up = C_ChallengeMode.GetCompletionInfo()
        timeMs, onTime, upgrades = t, ot, up
    end
    if timeMs and timeMs > 0 then
        local t = timeMs / 1000
        local dmg = KC.Damage.Sample()
        local specs = KC.GetGroupSpecs()
        local hist = KC.db.history[run.instanceID] or {}
        KC.db.history[run.instanceID] = hist
        hist[#hist + 1] = {
            l = run.level, t = t, timed = onTime and true or false,
            s = specs, k = run.kills,
            d = dmg and dmg > 0 and dmg / t or nil,
            date = date("%Y-%m-%d"),
        }
        -- итоги показываются, пока игрок не выйдет из подземелья
        KC.summary = {
            instanceID = run.instanceID, name = run.name, level = run.level, timeLimit = run.timeLimit,
            time = t, onTime = onTime, upgrades = upgrades, kills = run.kills, specs = specs,
            groupDPS = dmg and dmg > 0 and dmg / t or run.groupDPS,
            result = run.result, startChance = run.startChance, chanceAt = run.chanceAt or {},
        }
        KC.Model.ResetPersonal()
        print(("|cff33ff99KeyChance|r: %s +%d — %s за %s"):format(run.name or "?", run.level,
            onTime and "|cff00ff00в тайм|r" or "|cffff4040не в тайм|r", KC.FormatTime(t)))
    end
    KC.run = nil
    KC.db.current = nil
end

------------------------------------------------------------------------
-- Расчёт
------------------------------------------------------------------------
function KC.FormatTime(sec)
    if not sec then return "--:--" end
    local neg = sec < 0
    sec = math.floor(math.abs(sec) + 0.5)
    return ("%s%d:%02d"):format(neg and "-" or "", math.floor(sec / 60), sec % 60)
end

local function Update()
    local run = KC.run
    if run then
        local elapsed = ElapsedSeconds()
        local bossCount, killed, forces = ReadCriteria()
        while #run.kills < killed do
            run.kills[#run.kills + 1] = elapsed
        end
        run.elapsed, run.bossCount, run.forces = elapsed, bossCount, forces
        run.specs = KC.GetGroupSpecs()
        local dmg = KC.Damage.Sample()
        run.groupDPS = dmg and elapsed > 30 and dmg / elapsed or nil
        run.result = KC.Model.Estimate({
            instanceID = run.instanceID, level = run.level, timeLimit = run.timeLimit,
            elapsed = elapsed, kills = run.kills, bossCount = bossCount, forces = forces,
            specs = run.specs, groupDPS = run.groupDPS, bias = KC.db.bias,
        })
        if run.result then
            run.chanceAt = run.chanceAt or {}
            run.startChance = run.startChance or run.result.chance
            for i = 1, #run.kills do
                run.chanceAt[i] = run.chanceAt[i] or run.result.chance
            end
        end
        KC.UI.ShowRun(run)
    elseif KC.summary then
        KC.UI.ShowSummary(KC.summary)
    else
        KC.UI.ShowPreview(KC.Preview())
    end
end

-- Оценка для своего ключа с текущей группой (до старта).
function KC.Preview(mapID, level)
    mapID = mapID or C_MythicPlus.GetOwnedKeystoneChallengeMapID()
    level = level or C_MythicPlus.GetOwnedKeystoneLevel()
    if not mapID or not level then return nil end
    local name, _, timeLimit = C_ChallengeMode.GetMapUIInfo(mapID)
    local instanceID = InstanceForChallengeMap(mapID)
    local specs = KC.GetGroupSpecs()
    local res = instanceID and KC.Model.Estimate({
        instanceID = instanceID, level = level, timeLimit = timeLimit, elapsed = 0,
        kills = {}, specs = specs, bias = KC.db.bias,
    })
    local groupSize = IsInGroup() and GetNumGroupMembers() or 1
    return {
        name = name, level = level, timeLimit = timeLimit, specs = specs, result = res,
        groupSize = groupSize, groupReady = groupSize >= 5,
    }
end

------------------------------------------------------------------------
-- События
------------------------------------------------------------------------
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
frame:RegisterEvent("CHALLENGE_MODE_RESET")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("INSPECT_READY")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        KeyChanceDB = KeyChanceDB or {}
        KC.db = KeyChanceDB
        for k, v in pairs(DEFAULTS) do
            if KC.db[k] == nil then KC.db[k] = v end
        end
        if KC.db.bias == 0.06 then KC.db.bias = DEFAULTS.bias end -- старое значение по умолчанию
        KC.db.history = KC.db.history or {}
        KC.db.cmToInstance = KC.db.cmToInstance or {}
        KC.UI.Init()
        C_Timer.NewTicker(1, Update)
    elseif not KC.db then
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        if C_ChallengeMode.IsChallengeModeActive and C_ChallengeMode.IsChallengeModeActive() then
            StartRun()
        else
            KC.run = nil
            if KC.summary and select(8, GetInstanceInfo()) ~= KC.summary.instanceID then
                KC.summary = nil
            end
        end
        InspectNext()
    elseif event == "CHALLENGE_MODE_START" then
        KC.db.current = nil
        KC.summary = nil
        StartRun()
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        FinishRun()
    elseif event == "CHALLENGE_MODE_RESET" then
        KC.run, KC.db.current = nil, nil
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_REGEN_ENABLED" then
        InspectNext()
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        if arg1 and arg1 ~= "player" then
            KC.partySpecs[UnitGUID(arg1) or ""] = nil
        end
        InspectNext()
    elseif event == "INSPECT_READY" then
        for _, unit in ipairs(PartyUnits()) do
            if UnitGUID(unit) == arg1 then
                local spec = GetInspectSpecialization(unit)
                if spec and spec > 0 then KC.partySpecs[arg1] = spec end
            end
        end
        if inspectPending == arg1 then
            inspectPending = nil
            ClearInspectPlayer()
        end
        C_Timer.After(0.5, InspectNext)
    end
end)

------------------------------------------------------------------------
-- Команды
------------------------------------------------------------------------
SLASH_KEYCHANCE1 = "/kc"
SLASH_KEYCHANCE2 = "/keychance"
SlashCmdList.KEYCHANCE = function(msg)
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "lock" then
        KC.db.locked = not KC.db.locked
        print("KeyChance: окно " .. (KC.db.locked and "закреплено" or "откреплено"))
    elseif cmd == "bias" and tonumber(arg) then
        KC.db.bias = tonumber(arg)
        print(("KeyChance: поправка темпа = %.3f"):format(KC.db.bias))
    elseif cmd == "reset" then
        KC.UI.ResetPosition()
    elseif cmd == "history" then
        local n = 0
        for _, runs in pairs(KC.db.history) do n = n + #runs end
        print(("KeyChance: сохранено своих забегов: %d. Данные WCL: %s"):format(n, KC.Data.generated or "нет"))
    elseif cmd == "clearhistory" then
        wipe(KC.db.history)
        print("KeyChance: история очищена")
    elseif cmd == "" then
        KC.db.shown = not KC.db.shown
        KC.UI.SetShown(KC.db.shown)
    else
        print("KeyChance: /kc — показать/скрыть, /kc lock, /kc reset, /kc bias <число>, /kc history, /kc clearhistory")
    end
    Update()
end
