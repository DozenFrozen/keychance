local _, KC = ...
local L = KC.L

local UI = {}
KC.UI = UI

local FT = function(s) return KC.FormatTime(s) end
local frame, title, chance, lines, graphButton

-- Показывать ли строку (Esc → Настройки → AddOns → KeyChance)
local function On(key)
    return KC.db.show[key] ~= false
end
UI.On = On

local function ChanceColor(p)
    if p >= 0.7 then return "|cff40ff40" elseif p >= 0.4 then return "|cffffd040" end
    return "|cffff4040"
end
UI.ChanceColor = ChanceColor

local function ShortNumber(v)
    if not v then return "?" end
    if v >= 1e6 then return ("%.2fM"):format(v / 1e6) end
    return ("%.0fK"):format(v / 1e3)
end

local function SignedTime(d)
    return (d > 0 and "+" or "") .. FT(d)
end

-- Зелёный, если наше значение лучше среднего (lowerIsBetter — для времени)
local function Diff(mine, avg, lowerIsBetter)
    local good = lowerIsBetter and mine <= avg or not lowerIsBetter and mine >= avg
    return good and "|cff40ff40" or "|cffff4040"
end

function UI.Init()
    frame = CreateFrame("Frame", "KeyChanceFrame", UIParent, "BackdropTemplate")
    frame:SetSize(280, 60)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
    })
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetScript("OnDragStart", function(self)
        if not KC.db.locked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        KC.db.point = { point, relPoint, x, y }
    end)

    title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -6)
    title:SetPoint("TOPRIGHT", -72, -6) -- справа место под кнопку графика
    title:SetJustifyH("LEFT")

    chance = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    chance:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)

    lines = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lines:SetPoint("TOPLEFT", chance, "BOTTOMLEFT", 0, -4)
    lines:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
    lines:SetJustifyH("LEFT")
    lines:SetSpacing(2)

    graphButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    graphButton:SetSize(64, 18)
    graphButton:SetPoint("TOPRIGHT", -4, -4)
    graphButton:SetText(L["График"])
    graphButton:SetScript("OnClick", function() KC.Graph.Toggle(UI.current or KC.db.lastRun) end)
    graphButton:Hide()

    UI.ResetPosition(KC.db.point)
    UI.ApplyStyle()
    UI.SetShown(KC.db.shown)
end

function UI.ApplyStyle()
    graphButton:SetText(L["График"]) -- язык мог смениться
    frame:SetScale(KC.db.scale or 1)
    frame:SetBackdropColor(0, 0, 0, KC.db.alpha or 0.6)
    frame:SetBackdropBorderColor(0.3, 0.3, 0.3, math.min(1, (KC.db.alpha or 0.6) + 0.2))
end

function UI.ResetPosition(p)
    frame:ClearAllPoints()
    if p then
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        KC.db.point = nil
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 120)
    end
end

function UI.SetShown(shown)
    frame:SetShown(shown)
end

function UI.Toggle()
    KC.db.shown = not KC.db.shown
    UI.SetShown(KC.db.shown)
end

local function Layout()
    frame:SetHeight(title:GetStringHeight() + chance:GetStringHeight() + lines:GetStringHeight() + 22)
end

local function MetaLine(specs, level, res)
    local tiers = {}
    for _, key in ipairs(specs or {}) do
        tiers[#tiers + 1] = KC.Model.MetaTier(KC.Model.SpecMeta(key, level))
    end
    local metaText = res and res.meta and ("%d%%"):format(res.meta * 100) or "?"
    return (L["Мета состава: %s  [%s]%s"]):format(metaText, table.concat(tiers, " "),
        #tiers < 5 and (L["  |cff888888спеки: %d/5|r"]):format(#tiers) or "")
end

local function SampleLine(res)
    local lv = res.levelLo == res.levelHi and ("+" .. res.levelLo) or ("+%d..+%d"):format(res.levelLo, res.levelHi)
    local text = (L["|cff888888Статистика: %d забегов, %s"]):format(res.samples, lv)
    if res.personalBias then
        local pct = math.floor((math.exp(res.personalBias) - 1) * 100 + 0.5)
        local pace = pct >= 0 and (L["медленнее базы на %d%%"]):format(pct) or (L["быстрее базы на %d%%"]):format(-pct)
        text = text .. (L["\nВаш темп: %s (%s)"]):format(pace,
            res.personalN > 0 and (L["по %d ваш. ключам"]):format(res.personalN) or L["пока по умолчанию"])
    end
    return text .. "|r"
end

local function CommonLines(out, res, specs, level)
    if On("meta") then out[#out + 1] = MetaLine(specs, level, res) end
    if On("avgFinish") then out[#out + 1] = (L["Средний финиш в тайм: %s"]):format(FT(res.avgFinish)) end
    if On("comp") and res.compFinish then
        out[#out + 1] = (L["Похожий состав (3+ спека): %s  |cff888888n=%d|r"]):format(FT(res.compFinish), res.compN)
    end
    if On("stats") then out[#out + 1] = SampleLine(res) end
end

-- Вторая строка босса: длительность боя, урон группы по боссу, кики
local function BossDetail(b, fightAvg, dpsAvg)
    local parts = {}
    if On("bossFight") then
        if b and b.dur then
            parts[#parts + 1] = (L["бой %s%s%s"]):format(fightAvg and Diff(b.dur, fightAvg, true) or "", FT(b.dur),
                fightAvg and (L["|r |cff888888(ср. %s)|r"]):format(FT(fightAvg)) or "")
        elseif fightAvg then
            parts[#parts + 1] = (L["|cff888888бой ср. %s|r"]):format(FT(fightAvg))
        end
    end
    if On("bossDPS") and b then
        if b.dps then
            parts[#parts + 1] = (L["%s%s/с%s"]):format(dpsAvg and Diff(b.dps, dpsAvg) or "", ShortNumber(b.dps),
                dpsAvg and (L["|r |cff888888(ср. %s)|r"]):format(ShortNumber(dpsAvg)) or "")
        elseif b.meter then
            parts[#parts + 1] = L["|cff888888урон после боя...|r"]
        end
    elseif On("bossDPS") and dpsAvg then
        parts[#parts + 1] = (L["|cff888888урон ср. %s/с|r"]):format(ShortNumber(dpsAvg))
    end
    if On("interrupts") and b and b.int then
        parts[#parts + 1] = (L["кики %d"]):format(b.int)
    end
    if b and b.wipes and b.wipes > 0 then
        parts[#parts + 1] = (L["|cffff8040вайпов %d|r"]):format(b.wipes)
    end
    return #parts > 0 and table.concat(parts, "  ") or nil
end

local function BossLines(out, kills, bosses, res, bossCount)
    if not On("bosses") then return end
    local bossAvg = res and res.bossAvg or {}
    local fightAvg = res and res.bossFightAvg or {}
    local dpsAvg = res and res.bossDPSAvg or {}
    local rows = {}
    for i = 1, math.max(bossCount or 0, #bossAvg, #kills) do
        local avg, mine, b = bossAvg[i], kills[i], bosses and bosses[i]
        local row
        if mine and avg then
            local d = mine - avg
            row = (L["  %d) %s  ср. %s  %s%s|r"]):format(i, FT(mine), FT(avg),
                d <= 0 and "|cff40ff40" or "|cffff4040", SignedTime(d))
        elseif mine then
            row = ("  %d) %s"):format(i, FT(mine))
        elseif avg then
            row = (L["  %d) --:--  ср. %s"]):format(i, FT(avg))
        end
        if row then
            if b and b.name then row = row .. ("  |cff888888%s|r"):format(KC.BossName(b.id, b.name)) end
            rows[#rows + 1] = row
            local detail = BossDetail(b, fightAvg[i], dpsAvg[i])
            if detail then rows[#rows + 1] = "      " .. detail end
        end
    end
    if #rows > 0 then
        out[#out + 1] = L["Боссы (у тайм-забегов):"]
        for _, r in ipairs(rows) do out[#out + 1] = r end
    end
end

-- Идёт бой с боссом: сколько уже бьём и сколько обычно длится этот бой
local function EncounterLine(out, run, res)
    local enc = run.encounter
    if not enc then return end
    local i = #run.kills + 1
    if On("bossFight") then
        local avg = res and res.bossFightAvg[i]
        local text = (L["|cffffd040Бой: %s  %s%s|r"]):format(KC.BossName(enc.id, enc.name) or L["босс"], FT(GetTime() - enc.start),
            avg and (L[" / ср. %s"]):format(FT(avg)) or "")
        if enc.hp then text = text .. ("  HP %d%%"):format(math.floor(enc.hp * 100 + 0.5)) end
        if res and res.fightRem then
            text = text .. (L["  |cff888888~%s до убийства|r"]):format(FT(res.fightRem))
        end
        out[#out + 1] = text
    end
    local dpsAvg = res and res.bossDPSAvg[i]
    if On("bossDPS") and (enc.dps or dpsAvg) then
        out[#out + 1] = (L["      Урон по боссу: %s%s"]):format(
            enc.dps and (dpsAvg and Diff(enc.dps, dpsAvg) or "") .. ShortNumber(enc.dps) .. L["/с|r  "] or "",
            dpsAvg and (L["|cff888888ср. %s/с|r"]):format(ShortNumber(dpsAvg)) or "")
    end
end

local function DamageLine(out, groupDPS, res)
    if not On("damage") then return end
    if groupDPS then
        local ref = res and res.avgDPS
        out[#out + 1] = (L["Урон группы: %s/с%s  |cff888888%s|r"]):format(ShortNumber(groupDPS),
            ref and (L["  (ср. %s/с)"]):format(ShortNumber(ref)) or "", KC.Damage.source or "")
    else
        out[#out + 1] = L["|cff888888Урон группы: недоступен|r"]
    end
end

-- Сводный урон по боссам в сравнении со средним (взвешенным по длительности наших боёв)
local function BossDamageLine(out, bosses, bossDPS, res)
    if not On("bossDPS") or not bossDPS then return end
    local sum, dur = 0, 0
    for i, b in ipairs(bosses or {}) do
        local avg = res and res.bossDPSAvg[i]
        if avg and b.dur then sum, dur = sum + avg * b.dur, dur + b.dur end
    end
    local avg = dur > 0 and sum / dur or nil
    out[#out + 1] = (L["Урон по боссам: %s%s/с%s"]):format(avg and Diff(bossDPS, avg) or "", ShortNumber(bossDPS),
        avg and (L["|r  (ср. %s/с)"]):format(ShortNumber(avg)) or "")
end

local function InterruptLine(out, total, fight, res, elapsed, avgFinish)
    if not On("interrupts") then return end
    if not total then
        out[#out + 1] = L["|cff888888Сбито заклинаний: недоступно|r"]
        return
    end
    local text = (L["Сбито заклинаний: %d"]):format(total)
    local avg = res and res.avgInterrupts
    if avg then
        -- во время ключа сравниваем с тем, сколько обычно сбито к этой минуте
        local expected = elapsed and avgFinish and avg * math.min(1, elapsed / avgFinish) or avg
        text = text .. ("  %s(%s %d)|r"):format(Diff(total, expected), elapsed and L["ожид."] or L["ср."],
            math.floor(expected + 0.5))
    end
    if fight then text = text .. (L["  |cff888888в бою: %d|r"]):format(fight) end
    out[#out + 1] = text
end

-- Смерти: сколько и сколько времени они стоили; во время ключа — сколько ещё ожидается до конца
local function DeathLine(out, deaths, deathTime, res, live)
    if not On("deaths") or not deaths then return end
    local avg = res and res.avgDeaths
    local text = (L["Смерти: %d"]):format(deaths)
    if deathTime and deathTime > 0 then text = text .. ("  |cffff4040-%s|r"):format(FT(deathTime)) end
    if avg then
        text = text .. ("  %s(%s %d)|r"):format(Diff(deaths, avg, true), L["ср."], math.floor(avg + 0.5))
    end
    if live and res and res.futureDeaths then
        text = text .. (L["  |cff888888ещё ~%d (~%s)|r"]):format(math.floor(res.futureDeaths + 0.5),
            FT(res.futureDeaths * (res.deathPenalty or 15)))
    end
    out[#out + 1] = text
end

local function Hint(out, text)
    if On("hints") then out[#out + 1] = "|cff888888" .. text .. "|r" end
end

function UI.ShowSummary(s)
    UI.current = s -- итоги, график которых открывает кнопка
    if not frame:IsShown() then return end
    graphButton:SetShown(On("graph") and s.chanceLog and #s.chanceLog >= 2)
    title:SetText((L["Итог: %s +%d"]):format(KC.DungeonName(s.instanceID, s.name) or "?", s.level))
    if s.onTime then
        chance:SetText((L["|cff40ff40В ТАЙМ%s|r"]):format(s.upgrades and s.upgrades > 0
            and ("  +%d"):format(s.upgrades) or ""))
    else
        chance:SetText(L["|cffff4040НЕ В ТАЙМ|r"])
    end

    local out = {}
    local margin = s.timeLimit - s.time
    out[#out + 1] = (L["Время: %s / %s  (%s%s|r)"]):format(FT(s.time), FT(s.timeLimit),
        margin >= 0 and L["|cff40ff40запас "] or L["|cffff4040опоздание "], FT(math.abs(margin)))

    local res = s.result
    if On("avgFinish") and res and res.avgFinish then
        local d = s.time - res.avgFinish
        out[#out + 1] = (L["Средний финиш в тайм: %s  (%s%s %s|r)"]):format(FT(res.avgFinish),
            d <= 0 and "|cff40ff40" or "|cffff4040", d <= 0 and L["быстрее на"] or L["медленнее на"], FT(math.abs(d)))
    end
    if On("comp") and res and res.compFinish then
        out[#out + 1] = (L["Похожий состав (3+ спека): %s  |cff888888n=%d|r"]):format(FT(res.compFinish), res.compN)
    end
    BossLines(out, s.kills, s.bosses, res, #s.kills)
    if s.wipes and s.wipes > 0 then out[#out + 1] = (L["|cffff8040Вайпов на боссах: %d|r"]):format(s.wipes) end

    if On("chanceSteps") and s.startChance then
        local pct = function(p) return math.floor(p * 100 + 0.5) end
        local steps = { (L["старт %d%%"]):format(pct(s.startChance)) }
        for i = 1, #s.kills do
            if s.chanceAt[i] then steps[#steps + 1] = ("%d) %d%%"):format(i, pct(s.chanceAt[i])) end
        end
        out[#out + 1] = L["Шанс по ходу: "] .. table.concat(steps, "  >  ")
    end

    BossDamageLine(out, s.bosses, s.bossDPS, res)
    DamageLine(out, s.groupDPS, res)
    InterruptLine(out, s.interrupts, nil, res)
    DeathLine(out, s.deaths, s.deathTime, res)
    if On("meta") then out[#out + 1] = MetaLine(s.specs, s.level, res) end
    Hint(out, L["Итог исчезнет после выхода из подземелья. График: /kc graph"])
    lines:SetText(table.concat(out, "\n"))
    Layout()
end

function UI.ShowRun(run)
    if not frame:IsShown() then return end
    graphButton:Hide()
    title:SetText(("%s +%d"):format(KC.DungeonName(run.instanceID, run.name) or "?", run.level))
    local res = run.result
    local out = {}
    if not res then
        chance:SetText(L["|cff888888нет данных|r"])
        out[1] = L["Нет статистики для этого данжа.\nЗапустите tools/wcl_fetch.py"]
    else
        chance:SetText((L["%sШанс тайма: %d%%|r"]):format(ChanceColor(res.chance), math.floor(res.chance * 100 + 0.5)))
        if On("forecast") then
            local margin = run.timeLimit - res.projected
            out[#out + 1] = (L["Прогноз: %s / %s  (%s%s|r)"]):format(FT(res.projected), FT(run.timeLimit),
                margin >= 0 and L["|cff40ff40запас "] or L["|cffff4040опоздание "], FT(math.abs(margin)))
        end
        if On("mobs") then
            local count = run.forcesCur and run.forcesTotal
                and ("  |cff888888(%d/%d)|r"):format(run.forcesCur, run.forcesTotal) or ""
            out[#out + 1] = (L["Мобы: %.1f%%%s   Таймер: %s"]):format(run.forces * 100, count, FT(run.elapsed))
        end
        if #run.kills == 0 and not run.groupDPS then
            Hint(out, L["Шанс уточняется: ждём данные об уроне и первого босса"])
        end

        EncounterLine(out, run, res)
        BossLines(out, run.kills, run.bosses, res, run.bossCount)
        BossDamageLine(out, run.bosses, run.bossDPS, res)
        DamageLine(out, run.groupDPS, res)
        InterruptLine(out, run.interrupts, run.fightInterrupts, res, run.elapsed, res.avgFinish)
        DeathLine(out, run.deaths, run.deathTime, res, true)
        CommonLines(out, res, run.specs, run.level)
    end
    lines:SetText(table.concat(out, "\n"))
    Layout()
end

function UI.ShowPreview(p)
    UI.current = nil
    if not frame:IsShown() then return end
    graphButton:SetShown(On("graph") and KC.db.lastRun ~= nil)
    if not On("preview") then
        title:SetText("KeyChance")
        chance:SetText(L["|cff888888ожидание ключа|r"])
        lines:SetText("")
        Layout()
        return
    end
    if not p then
        title:SetText("KeyChance")
        chance:SetText(L["|cff888888нет ключа|r"])
        lines:SetText(KC.Data.generated and (L["Данные WCL от "] .. KC.Data.generated) or L["Данные WCL не загружены"])
        Layout()
        return
    end
    local out = {}
    if p.unknown then
        title:SetText(p.owner)
        chance:SetText(L["|cffffd040Ключ лидера неизвестен|r"])
        out[#out + 1] = L["Лидер не передал ключ: нужен KeyChance"]
        out[#out + 1] = L["или BigWigs/LittleWigs у лидера."]
        Hint(out, L["Ключ определится, когда его вставят в чашу."])
        lines:SetText(table.concat(out, "\n"))
        Layout()
        return
    end
    if not p.name then
        title:SetText(p.owner)
        chance:SetText(L["|cff888888нет ключа|r"])
        lines:SetText("")
        Layout()
        return
    end

    title:SetText(("%s: %s +%d"):format(p.owner, KC.DungeonName(p.instanceID, p.name), p.level))
    local res = p.result
    if not p.groupReady then
        -- без полной группы считать нечего: только ключ и объём статистики
        chance:SetText((L["|cffffd040Соберите группу (%d/5)|r"]):format(p.groupSize))
        Hint(out, L["Прогноз появится, когда соберётся группа,\nа шанс тайма — после старта ключа."])
        out[#out + 1] = (L["Лимит времени: %s"]):format(FT(p.timeLimit))
        if res then
            if On("stats") then out[#out + 1] = SampleLine(res) end
        else
            out[#out + 1] = L["|cff888888Нет статистики для этого данжа|r"]
        end
    elseif not res then
        chance:SetText(L["|cffffd040Группа собрана|r"])
        out[1] = L["|cff888888Нет статистики для этого данжа|r"]
    else
        -- предварительный расчёт по составу; динамический шанс — только после старта
        chance:SetText(L["|cffffd040Группа собрана — ждём старт|r"])
        out[#out + 1] = L["Предварительно (до старта):"]
        if On("forecast") then
            out[#out + 1] = (L["  Ожидаемый финиш: %s / %s"]):format(FT(res.projected), FT(p.timeLimit))
        end
        out[#out + 1] = (L["  |cff888888Ориентир шанса: ~%d%% (уточнится после старта)|r"]):format(
            math.floor(res.chance * 100 + 0.5))
        BossLines(out, {}, nil, res, #res.bossAvg)
        if On("interrupts") and res.avgInterrupts then
            out[#out + 1] = (L["Сбивают за ключ в среднем: %d"]):format(math.floor(res.avgInterrupts + 0.5))
        end
        if On("deaths") and res.avgDeaths then
            out[#out + 1] = (L["Смертей за ключ в среднем: %d"]):format(math.floor(res.avgDeaths + 0.5))
        end
        CommonLines(out, res, p.specs, p.level)
    end
    lines:SetText(table.concat(out, "\n"))
    Layout()
end
