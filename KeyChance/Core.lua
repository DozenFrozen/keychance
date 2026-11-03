local ADDON, KC = ...
local L = KC.L

local DEFAULTS = {
    -- стартовая поправка: обычная группа ~10% медленнее базы WCL. Дальше аддон сам подстраивает её
    -- по вашим завершённым ключам; вручную: /kc bias 0.05
    bias = 0.10,
    locked = false,
    shown = true,
    scale = 1.0,
    alpha = 0.6,
    minimap = { hide = false, angle = 215 },
    graphAuto = false,
    language = "auto", -- "auto": русский, если клиент на русском, иначе английский; "ru"; "en"
    -- какие строки показывать в окне (настраивается в Esc → Настройки → AddOns → KeyChance)
    show = {
        forecast = true, mobs = true, bosses = true, bossFight = true, bossDPS = true,
        damage = true, interrupts = true, deaths = true, meta = true, avgFinish = true, comp = true,
        stats = true, chanceSteps = true, hints = true, graph = true, preview = true,
    },
}
KC.DEFAULTS = DEFAULTS

local CHANCE_LOG_STEP = 5 -- как часто (сек) записывать шанс для графика

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

-- Возвращает: число боссов, сколько убито, прогресс мобов 0..1, мобов набрано, мобов нужно
local function ReadCriteria()
    local numCriteria
    if C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo then
        local info = C_ScenarioInfo.GetScenarioStepInfo()
        numCriteria = info and info.numCriteria
    end
    if not numCriteria and C_Scenario and C_Scenario.GetStepInfo then
        numCriteria = select(3, C_Scenario.GetStepInfo())
    end
    local bosses, killed, forces, cur, total = 0, 0, 0, nil, nil
    for i = 1, numCriteria or 0 do
        local c = C_ScenarioInfo.GetCriteriaInfo(i)
        if c then
            if c.isWeightedProgress then
                -- quantityString содержит "сырое" количество мобов ("245%"), totalQuantity — нужное количество
                cur = c.quantityString and tonumber(c.quantityString:match("(%d+)"))
                total = c.totalQuantity
                if cur and total and total > 0 then
                    forces = cur / total
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
    return bosses, killed, math.min(forces, 1), cur, total
end

-- Смерти в ключе и сколько секунд штрафа они добавили к таймеру.
local function ReadDeaths()
    if not C_ChallengeMode.GetDeathCount then return end
    local ok, deaths, timeLost = pcall(C_ChallengeMode.GetDeathCount)
    if ok and type(deaths) == "number" then return deaths, timeLost or 0 end
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
        bosses = {},     -- по порядку убийства: { name, dur, dmg, dps, int, wipes }
        chanceLog = {},  -- { { t = секунда ключа, p = шанс }, ... } — для графика
        wipes = 0,
    }
    -- восстановление после /reload посреди ключа
    local saved = KC.db.current
    if saved and saved.mapID == mapID and saved.level == run.level and ElapsedSeconds() >= (saved.kills[#saved.kills] or 0) then
        run.kills = saved.kills
        run.bosses = saved.bosses or run.bosses
        run.chanceLog = saved.chanceLog or run.chanceLog
        run.wipes = saved.wipes or 0
        run.startChance = run.chanceLog[1] and run.chanceLog[1].p
    else
        KC.Damage.Start()
    end
    KC.db.current = {
        mapID = mapID, level = run.level, kills = run.kills, bosses = run.bosses, chanceLog = run.chanceLog,
        wipes = run.wipes,
    }
    KC.run = run
    InspectNext()
end

-- Сводный урон группы по боссам (урон / время боя по всем боссам с известным уроном).
local function BossDPSTotal(bosses)
    local dmg, dur = 0, 0
    for _, b in ipairs(bosses) do
        if b.dmg and b.dur and b.dur > 0 then dmg, dur = dmg + b.dmg, dur + b.dur end
    end
    return dur > 0 and dmg / dur or nil
end

local function BossDPSList(bosses)
    local list = {}
    for i, b in ipairs(bosses) do list[i] = b.dps end
    return list
end

local ResolveBosses
local summaryHist -- запись истории последнего ключа: дописывается, когда станут известны урон и кики последнего боя

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
        -- последний босс обычно умирает в ту же секунду, что и завершается ключ, — раньше, чем тикер
        -- успевает это заметить; ключ завершён, значит, убиты все боссы
        local _, killed = ReadCriteria()
        for _ = #run.kills + 1, math.max(killed, run.bossCount or 0) do
            run.kills[#run.kills + 1] = t
            if run.chanceAt then run.chanceAt[#run.kills] = onTime and 1 or 0 end
        end
        local dmg = KC.Damage.Sample()
        local ints = KC.Damage.Interrupts() or run.interrupts
        local specs = KC.GetGroupSpecs()
        local deaths, deathTime = ReadDeaths()
        deaths, deathTime = deaths or run.deaths, deathTime or run.deathTime
        local bt, bp = {}, BossDPSList(run.bosses)
        for i, b in ipairs(run.bosses) do bt[i] = b.dur end
        local hist = KC.db.history[run.instanceID] or {}
        KC.db.history[run.instanceID] = hist
        summaryHist = {
            l = run.level, t = t, timed = onTime and true or false,
            s = specs, k = run.kills,
            d = dmg and dmg > 0 and dmg / t or nil,
            i = ints, bt = bt, bp = bp, dd = deaths,
            date = date("%Y-%m-%d"),
        }
        hist[#hist + 1] = summaryHist
        run.chanceLog[#run.chanceLog + 1] = { t = t, p = onTime and 1 or 0 }
        -- итоги показываются, пока игрок не выйдет из подземелья; график — и позже (/kc graph)
        KC.summary = {
            instanceID = run.instanceID, name = run.name, level = run.level, timeLimit = run.timeLimit,
            time = t, onTime = onTime, upgrades = upgrades, kills = run.kills, specs = specs,
            groupDPS = dmg and dmg > 0 and dmg / t or run.groupDPS,
            bosses = run.bosses, bossDPS = BossDPSTotal(run.bosses), interrupts = ints, wipes = run.wipes,
            deaths = deaths, deathTime = deathTime,
            result = run.result, startChance = run.startChance, chanceAt = run.chanceAt or {},
            chanceLog = run.chanceLog, date = date("%Y-%m-%d %H:%M"), pending = true,
        }
        KC.db.lastRun = KC.summary
        KC.Model.ResetPersonal()
        print((L["|cff33ff99KeyChance|r: %s +%d — %s за %s"]):format(KC.DungeonName(run.instanceID, run.name) or "?", run.level,
            onTime and L["|cff00ff00в тайм|r"] or L["|cffff4040не в тайм|r"], KC.FormatTime(t)))
        if KC.db.graphAuto then KC.Graph.Show(KC.summary) end
    end
    KC.run = nil
    KC.db.current = nil
end

local function EncounterStart(id, name)
    local run = KC.run
    if not run then return end
    run.encounter = { id = id, name = name, start = GetTime() }
    KC.Damage.BossStart()
end

local function EncounterEnd(name, success)
    local run = KC.run
    local enc = run and run.encounter
    if not enc then return end
    run.encounter = nil
    local meter = KC.Damage.BossStop()
    if success ~= 1 then
        run.wipes = run.wipes + 1
        KC.db.current.wipes = run.wipes
        run.pendingWipes = (run.pendingWipes or 0) + 1
        return
    end
    local now = GetTime()
    run.bosses[#run.bosses + 1] = {
        id = enc.id, name = name, dur = now - enc.start, wipes = run.pendingWipes, meter = meter, endAt = now,
    }
    run.pendingWipes = nil
end

-- Урон и кики по боссу становятся известны только после выхода из боя (в бою значения "секретные").
function ResolveBosses(run)
    for _, b in ipairs(run.bosses) do
        if b.meter then
            local dmg, ints = KC.Damage.BossResult(b.meter, b.endAt)
            if dmg then
                b.dmg, b.int = dmg, ints
                b.dps = b.dur > 0 and dmg / b.dur or nil
                b.meter = nil
            elseif GetTime() - b.endAt > 180 then
                b.meter = nil -- так и не дождались значений
            end
        end
    end
end

-- Последний босс обычно убит прямо перед финишем: его урон и итоговые кики дочитываем уже в итогах.
local function RefreshSummary(s)
    if not s.pending then return end
    KC.Damage.Sample()
    local ints = KC.Damage.Interrupts()
    ResolveBosses(s)
    if ints and (not s.interrupts or ints > s.interrupts) then s.interrupts = ints end
    s.bossDPS = BossDPSTotal(s.bosses)
    if summaryHist then summaryHist.i, summaryHist.bp = s.interrupts, BossDPSList(s.bosses) end
    for _, b in ipairs(s.bosses) do
        if b.meter then return end
    end
    s.pending = nil
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
    KC.Keys.OnTick()
    local run = KC.run
    if KC.demo then
        -- демо для скриншотов (/kc demo) перекрывает всё остальное, пока не выключено
        if KC.demo.live then KC.UI.ShowRun(KC.demo) else KC.UI.ShowSummary(KC.demo) end
    elseif run then
        local elapsed = ElapsedSeconds()
        local bossCount, killed, forces, forcesCur, forcesTotal = ReadCriteria()
        while #run.kills < killed do
            run.kills[#run.kills + 1] = elapsed
        end
        run.elapsed, run.bossCount, run.forces = elapsed, bossCount, forces
        run.forcesCur, run.forcesTotal = forcesCur, forcesTotal
        run.specs = KC.GetGroupSpecs()
        local dmg = KC.Damage.Sample()
        run.groupDPS = dmg and elapsed > 30 and dmg / elapsed or nil
        run.interrupts = KC.Damage.Interrupts()
        run.fightInterrupts = KC.Damage.FightInterrupts()
        local deaths, deathTime = ReadDeaths()
        if deaths then run.deaths, run.deathTime = deaths, deathTime end
        ResolveBosses(run)
        run.bossDPS = BossDPSTotal(run.bosses)
        local enc = run.encounter
        if enc then
            enc.elapsed = GetTime() - enc.start
            enc.hp = KC.Damage.BossHealth()
            enc.dps = KC.Damage.BossLiveDPS()
        end
        run.result = KC.Model.Estimate({
            encounter = enc,
            instanceID = run.instanceID, level = run.level, timeLimit = run.timeLimit,
            elapsed = elapsed, kills = run.kills, bossCount = bossCount, forces = forces,
            specs = run.specs, groupDPS = run.groupDPS, bossDPS = BossDPSList(run.bosses),
            interrupts = run.interrupts, bias = KC.db.bias,
            deaths = run.deaths,
            deathPenalty = run.deaths and run.deaths > 0 and run.deathTime > 0 and run.deathTime / run.deaths or nil,
        })
        if run.result then
            run.chanceAt = run.chanceAt or {}
            run.startChance = run.startChance or run.result.chance
            for i = 1, #run.kills do
                run.chanceAt[i] = run.chanceAt[i] or run.result.chance
            end
            local last = run.chanceLog[#run.chanceLog]
            if not last or elapsed - last.t >= CHANCE_LOG_STEP then
                run.chanceLog[#run.chanceLog + 1] = { t = elapsed, p = run.result.chance }
            end
        end
        KC.UI.ShowRun(run)
    elseif KC.summary then
        RefreshSummary(KC.summary)
        KC.UI.ShowSummary(KC.summary)
    else
        KC.UI.ShowPreview(KC.Preview())
    end
end
KC.Update = Update

-- Оценка до старта: для ключа лидера группы (или своего, если вы одни или вы лидер).
function KC.Preview()
    local target = KC.Keys.Target()
    local groupSize = IsInGroup() and GetNumGroupMembers() or 1
    local p = { owner = target.owner, unknown = target.unknown, groupSize = groupSize, groupReady = groupSize >= 5 }
    if target.unknown or not target.mapID or not target.level then
        return (target.unknown or IsInGroup()) and p or nil
    end
    local mapID, level = target.mapID, target.level
    local name, _, timeLimit = C_ChallengeMode.GetMapUIInfo(mapID)
    local instanceID = InstanceForChallengeMap(mapID)
    local specs = KC.GetGroupSpecs()
    p.name, p.level, p.timeLimit, p.specs, p.instanceID = name, level, timeLimit, specs, instanceID
    p.result = instanceID and KC.Model.Estimate({
        instanceID = instanceID, level = level, timeLimit = timeLimit, elapsed = 0,
        kills = {}, specs = specs, bias = KC.db.bias,
    })
    return p
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
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("ENCOUNTER_START")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")

local function ApplyDefaults(db, defaults)
    for k, v in pairs(defaults) do
        if db[k] == nil then
            db[k] = type(v) == "table" and CopyTable(v) or v
        elseif type(v) == "table" and type(db[k]) == "table" then
            ApplyDefaults(db[k], v)
        end
    end
end

frame:SetScript("OnEvent", function(_, event, arg1, arg2, ...)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        -- игра читает список файлов из .toc только при запуске: после обновления аддона с новыми файлами
        -- /reload их не подхватит
        if not (KC.L and KC.Keys and KC.Graph and KC.Options) then
            print("|cffff4040KeyChance|r: аддон обновлён — перезапустите игру полностью (/reload недостаточно). "
                .. "KeyChance updated — please restart the game client.")
            frame:UnregisterAllEvents()
            return
        end
        KeyChanceDB = KeyChanceDB or {}
        KC.db = KeyChanceDB
        ApplyDefaults(KC.db, DEFAULTS)
        if KC.db.bias == 0.06 then KC.db.bias = DEFAULTS.bias end -- старое значение по умолчанию
        KC.db.history = KC.db.history or {}
        KC.db.cmToInstance = KC.db.cmToInstance or {}
        KC.UI.Init()
        KC.Options.Init()
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
    elseif event == "ENCOUNTER_START" then
        EncounterStart(arg1, arg2)
    elseif event == "ENCOUNTER_END" then
        EncounterEnd(arg2, select(3, ...))
    elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
        KC.Damage.RefreshBossUnits()
    elseif event == "PLAYER_REGEN_DISABLED" then
        if KC.run then KC.Damage.FightStart() end
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
-- Демо для скриншотов: итоги (или середина) случайного ключа из базы WCL
------------------------------------------------------------------------
local function DemoMapInfo(instanceID)
    for _, mapID in ipairs(C_ChallengeMode.GetMapTable() or {}) do
        local name, _, timeLimit, _, _, inst = C_ChallengeMode.GetMapUIInfo(mapID)
        if inst == instanceID or KC.db.cmToInstance[mapID] == instanceID then return name, timeLimit end
    end
end

-- Имена боссов из журнала приключений (порядок журнала может не совпадать с порядком убийства — для демо не важно)
local function DemoBossNames(instanceID)
    local names, ids = {}, {}
    pcall(function()
        local current = EJ_GetCurrentTier and EJ_GetCurrentTier()
        for tier = EJ_GetNumTiers(), 1, -1 do
            EJ_SelectTier(tier)
            for index = 1, 100 do
                local journalID = EJ_GetInstanceByIndex(index, false)
                if not journalID then break end
                if select(11, EJ_GetInstanceByIndex(index, false)) == instanceID then
                    for n = 1, 10 do
                        local bossName, _, _, _, _, _, encounterID = EJ_GetEncounterInfoByIndex(n, journalID)
                        if not bossName then break end
                        names[n], ids[n] = bossName, encounterID
                    end
                    break
                end
            end
            if #names > 0 then break end
        end
        if current then EJ_SelectTier(current) end
    end)
    return names, ids
end

local function BuildDemo(live)
    local ids = {}
    for id, d in pairs(KC.Data.dungeons or {}) do
        if #d.runs > 0 then ids[#ids + 1] = id end
    end
    if #ids == 0 then return end
    local instanceID = ids[math.random(#ids)]
    local dungeon = KC.Data.dungeons[instanceID]
    local r = dungeon.runs[math.random(#dungeon.runs)]
    local name, timeLimit = DemoMapInfo(instanceID)
    name = name or dungeon.name
    timeLimit = timeLimit or math.ceil(r.t * 1.2 / 60) * 60

    local names, bossIDs = DemoBossNames(instanceID)
    local bosses = {}
    for i in ipairs(r.k) do
        local dur = r.bt and r.bt[i] or (90 + math.random(60))
        local dps = r.bp and r.bp[i] or (r.d and r.d * (1.1 + math.random() * 0.4))
        bosses[i] = { id = bossIDs[i], name = names[i], dur = dur, dps = dps, dmg = dps and dps * dur, int = math.random(2, 7) }
    end
    local function Encounter(t)
        for i, kt in ipairs(r.k) do
            local start = kt - bosses[i].dur
            if t >= start and t < kt then return i, t - start end
        end
    end

    -- live: середина боя со 2-м боссом (или с последним, если боссов меньше)
    local liveBoss = math.min(2, #r.k)
    local stop = live and (r.k[liveBoss] - bosses[liveBoss].dur * 0.45) or r.t
    local log, chanceAt, res = {}, {}, nil
    local kills, step = {}, 10
    for t = 0, stop, step do
        wipe(kills)
        for _, kt in ipairs(r.k) do
            if kt <= t then kills[#kills + 1] = kt end
        end
        local ei, fightT = Encounter(t)
        local deathsSoFar = math.floor((r.dd or 5) * t / r.t)
        res = KC.Model.Estimate({
            instanceID = instanceID, level = r.l, timeLimit = timeLimit, elapsed = t, kills = kills,
            bossCount = #r.k, forces = math.min(1, t / (r.t * 0.95)), specs = r.s,
            groupDPS = t > 30 and r.d or nil, deaths = deathsSoFar, bias = KC.db.bias,
            encounter = ei and { elapsed = fightT, hp = 1 - fightT / bosses[ei].dur } or nil,
        }) or res
        if res then
            log[#log + 1] = { t = t, p = res.chance }
            for i = 1, #kills do chanceAt[i] = chanceAt[i] or res.chance end
        end
    end
    if not res then return end
    local deaths = r.dd or math.random(2, 9)
    local onTime = r.t <= timeLimit

    if live then
        local killed = {}
        for i = 1, liveBoss - 1 do killed[i] = r.k[i] end
        local fightT = bosses[liveBoss].dur * 0.55
        local done = {}
        for i = 1, liveBoss - 1 do done[i] = bosses[i] end
        local d = math.floor(deaths * stop / r.t)
        return {
            live = true, instanceID = instanceID, name = name, level = r.l, timeLimit = timeLimit, result = res, elapsed = stop,
            forces = math.min(1, stop / (r.t * 0.95)), kills = killed, bossCount = #r.k, bosses = done,
            bossDPS = BossDPSTotal(done), groupDPS = r.d, specs = r.s,
            interrupts = math.floor((r.i or 45) * stop / r.t), fightInterrupts = math.random(1, 4),
            deaths = d, deathTime = d * 15, chanceLog = log,
            encounter = { id = bossIDs[liveBoss], name = names[liveBoss], start = GetTime() - fightT, hp = 0.45 },
        }
    end
    log[#log + 1] = { t = r.t, p = onTime and 1 or 0 }
    return {
        instanceID = instanceID, name = name, level = r.l, timeLimit = timeLimit, time = r.t, onTime = onTime,
        upgrades = onTime and (r.b and r.b > 0 and r.b or 1) or 0, kills = r.k, specs = r.s, groupDPS = r.d,
        bosses = bosses, bossDPS = BossDPSTotal(bosses), interrupts = r.i or math.random(25, 60), wipes = 0,
        deaths = deaths, deathTime = deaths * 15, result = res, startChance = log[1].p, chanceAt = chanceAt,
        chanceLog = log, date = date("%Y-%m-%d %H:%M"),
    }
end

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
        print(L["KeyChance: окно "] .. (KC.db.locked and L["закреплено"] or L["откреплено"]))
    elseif cmd == "bias" and tonumber(arg) then
        KC.db.bias = tonumber(arg)
        print((L["KeyChance: поправка темпа = %.3f"]):format(KC.db.bias))
    elseif cmd == "reset" then
        KC.UI.ResetPosition()
    elseif cmd == "config" or cmd == "options" then
        KC.Options.Open()
    elseif cmd == "demo" then
        if arg == "off" then
            KC.demo = nil
            print(L["KeyChance: демо выключено"])
        else
            KC.demo = BuildDemo(arg == "live")
            if KC.demo then
                KC.db.shown = true
                KC.UI.SetShown(true)
                print((L["KeyChance: демо — %s +%d. Ещё раз: /kc demo, в процессе: /kc demo live, выключить: /kc demo off"])
                    :format(KC.DungeonName(KC.demo.instanceID, KC.demo.name) or "?", KC.demo.level))
            else
                print(L["KeyChance: в базе нет забегов для демо"])
            end
        end
    elseif cmd == "graph" then
        KC.Graph.ShowLatest()
    elseif cmd == "lang" and (arg == "auto" or arg == "ru" or arg == "en") then
        KC.Options.SetLanguage(arg)
    elseif cmd == "minimap" then
        KC.db.minimap.hide = not KC.db.minimap.hide
        KC.Options.UpdateMinimap()
    elseif cmd == "history" then
        local n = 0
        for _, runs in pairs(KC.db.history) do n = n + #runs end
        print((L["KeyChance: сохранено своих забегов: %d. Данные WCL: %s"]):format(n, KC.Data.generated or L["нет"]))
    elseif cmd == "clearhistory" then
        wipe(KC.db.history)
        print(L["KeyChance: история очищена"])
    elseif cmd == "" then
        KC.UI.Toggle()
    else
        print(L["KeyChance: /kc — показать/скрыть, /kc config — настройки, /kc graph — график шанса, "]
            .. L["/kc lock, /kc reset, /kc minimap, /kc lang auto/ru/en, /kc bias <число>, /kc history, /kc clearhistory"])
    end
    Update()
end
