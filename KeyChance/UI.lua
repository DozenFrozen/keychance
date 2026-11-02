local _, KC = ...

local UI = {}
KC.UI = UI

local FT = function(s) return KC.FormatTime(s) end
local frame, title, chance, lines

local function ChanceColor(p)
    if p >= 0.7 then return "|cff40ff40" elseif p >= 0.4 then return "|cffffd040" end
    return "|cffff4040"
end

local function ShortNumber(v)
    if not v then return "?" end
    if v >= 1e6 then return ("%.2fM"):format(v / 1e6) end
    return ("%.0fK"):format(v / 1e3)
end

local function SignedTime(d)
    return (d > 0 and "+" or "") .. FT(d)
end

function UI.Init()
    frame = CreateFrame("Frame", "KeyChanceFrame", UIParent, "BackdropTemplate")
    frame:SetSize(260, 60)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
    })
    frame:SetBackdropColor(0, 0, 0, 0.6)
    frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
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
    title:SetPoint("TOPRIGHT", -8, -6)
    title:SetJustifyH("LEFT")

    chance = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    chance:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)

    lines = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lines:SetPoint("TOPLEFT", chance, "BOTTOMLEFT", 0, -4)
    lines:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
    lines:SetJustifyH("LEFT")
    lines:SetSpacing(2)

    UI.ResetPosition(KC.db.point)
    UI.SetShown(KC.db.shown)
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

local function Layout()
    frame:SetHeight(title:GetStringHeight() + chance:GetStringHeight() + lines:GetStringHeight() + 22)
end

local function MetaLine(specs, level, res)
    local tiers = {}
    for _, key in ipairs(specs or {}) do
        tiers[#tiers + 1] = KC.Model.MetaTier(KC.Model.SpecMeta(key, level))
    end
    local metaText = res and res.meta and ("%d%%"):format(res.meta * 100) or "?"
    return ("Мета состава: %s  [%s]%s"):format(metaText, table.concat(tiers, " "),
        #tiers < 5 and ("  |cff888888спеки: %d/5|r"):format(#tiers) or "")
end

local function SampleLine(res)
    local lv = res.levelLo == res.levelHi and ("+" .. res.levelLo) or ("+%d..+%d"):format(res.levelLo, res.levelHi)
    return ("|cff888888Статистика: %d забегов, %s|r"):format(res.samples, lv)
end

local function CommonLines(out, res, specs, level)
    out[#out + 1] = MetaLine(specs, level, res)
    out[#out + 1] = ("Средний финиш в тайм: %s"):format(FT(res.avgFinish))
    if res.compFinish then
        out[#out + 1] = ("Похожий состав (3+ спека): %s  |cff888888n=%d|r"):format(FT(res.compFinish), res.compN)
    end
    out[#out + 1] = SampleLine(res)
end

local function BossLines(out, kills, bossAvg, bossCount)
    local bosses = {}
    for i = 1, math.max(bossCount or 0, #bossAvg) do
        local avg, mine = bossAvg[i], kills[i]
        if mine and avg then
            local d = mine - avg
            bosses[#bosses + 1] = ("  %d) %s  ср. %s  %s%s|r"):format(i, FT(mine), FT(avg),
                d <= 0 and "|cff40ff40" or "|cffff4040", SignedTime(d))
        elseif avg then
            bosses[#bosses + 1] = ("  %d) --:--  ср. %s"):format(i, FT(avg))
        end
    end
    if #bosses > 0 then
        out[#out + 1] = "Боссы (у тайм-забегов):"
        for _, b in ipairs(bosses) do out[#out + 1] = b end
    end
end

local function DamageLine(out, groupDPS, res)
    if groupDPS then
        local ref = res and res.avgDPS
        out[#out + 1] = ("Урон группы: %s/с%s  |cff888888%s|r"):format(ShortNumber(groupDPS),
            ref and ("  (ср. %s/с)"):format(ShortNumber(ref)) or "", KC.Damage.source or "")
    else
        out[#out + 1] = "|cff888888Урон группы: недоступен|r"
    end
end

function UI.ShowSummary(s)
    if not frame:IsShown() then return end
    title:SetText(("Итог: %s +%d"):format(s.name or "?", s.level))
    if s.onTime then
        chance:SetText(("|cff40ff40В ТАЙМ%s|r"):format(s.upgrades and s.upgrades > 0
            and ("  +%d"):format(s.upgrades) or ""))
    else
        chance:SetText("|cffff4040НЕ В ТАЙМ|r")
    end

    local out = {}
    local margin = s.timeLimit - s.time
    out[#out + 1] = ("Время: %s / %s  (%s%s|r)"):format(FT(s.time), FT(s.timeLimit),
        margin >= 0 and "|cff40ff40запас " or "|cffff4040опоздание ", FT(math.abs(margin)))

    local res = s.result
    if res and res.avgFinish then
        local d = s.time - res.avgFinish
        out[#out + 1] = ("Средний финиш в тайм: %s  (%s%s %s|r)"):format(FT(res.avgFinish),
            d <= 0 and "|cff40ff40" or "|cffff4040", d <= 0 and "быстрее на" or "медленнее на", FT(math.abs(d)))
    end
    if res and res.compFinish then
        out[#out + 1] = ("Похожий состав (3+ спека): %s  |cff888888n=%d|r"):format(FT(res.compFinish), res.compN)
    end
    if res then BossLines(out, s.kills, res.bossAvg, #s.kills) end

    if s.startChance then
        local pct = function(p) return math.floor(p * 100 + 0.5) end
        local steps = { ("старт %d%%"):format(pct(s.startChance)) }
        for i = 1, #s.kills do
            if s.chanceAt[i] then steps[#steps + 1] = ("%d) %d%%"):format(i, pct(s.chanceAt[i])) end
        end
        out[#out + 1] = "Шанс по ходу: " .. table.concat(steps, " → ")
    end

    DamageLine(out, s.groupDPS, res)
    out[#out + 1] = MetaLine(s.specs, s.level, res)
    out[#out + 1] = "|cff888888Итог исчезнет после выхода из подземелья|r"
    lines:SetText(table.concat(out, "\n"))
    Layout()
end

function UI.ShowRun(run)
    if not frame:IsShown() then return end
    title:SetText(("%s +%d"):format(run.name or "?", run.level))
    local res = run.result
    local out = {}
    if not res then
        chance:SetText("|cff888888нет данных|r")
        out[1] = "Нет статистики для этого данжа.\nЗапустите tools/wcl_fetch.py"
    else
        chance:SetText(("%sШанс тайма: %d%%|r"):format(ChanceColor(res.chance), math.floor(res.chance * 100 + 0.5)))
        local margin = run.timeLimit - res.projected
        out[#out + 1] = ("Прогноз: %s / %s  (%s%s|r)"):format(FT(res.projected), FT(run.timeLimit),
            margin >= 0 and "|cff40ff40запас " or "|cffff4040опоздание ", FT(math.abs(margin)))
        out[#out + 1] = ("Мобы: %.1f%%   Таймер: %s"):format(run.forces * 100, FT(run.elapsed))
        if #run.kills == 0 and not run.groupDPS then
            out[#out + 1] = "|cff888888Шанс уточняется: ждём данные об уроне и первого босса|r"
        end

        BossLines(out, run.kills, res.bossAvg, run.bossCount)
        DamageLine(out, run.groupDPS, res)
        CommonLines(out, res, run.specs, run.level)
    end
    lines:SetText(table.concat(out, "\n"))
    Layout()
end

function UI.ShowPreview(p)
    if not frame:IsShown() then return end
    if not p then
        title:SetText("KeyChance")
        chance:SetText("|cff888888нет ключа|r")
        lines:SetText(KC.Data.generated and ("Данные WCL от " .. KC.Data.generated) or "Данные WCL не загружены")
        Layout()
        return
    end
    title:SetText(("Ваш ключ: %s +%d"):format(p.name or "?", p.level))
    local res = p.result
    local out = {}

    if not p.groupReady then
        -- без полной группы считать нечего: только ключ и объём статистики
        chance:SetText(("|cffffd040Соберите группу (%d/5)|r"):format(p.groupSize))
        out[#out + 1] = "Прогноз появится, когда соберётся группа,"
        out[#out + 1] = "а шанс тайма — после старта ключа."
        out[#out + 1] = ("Лимит времени: %s"):format(FT(p.timeLimit))
        if res then
            out[#out + 1] = SampleLine(res)
        else
            out[#out + 1] = "|cff888888Нет статистики для этого данжа|r"
        end
    elseif not res then
        chance:SetText("|cffffd040Группа собрана|r")
        out[1] = "|cff888888Нет статистики для этого данжа|r"
    else
        -- предварительный расчёт по составу; динамический шанс — только после старта
        chance:SetText("|cffffd040Группа собрана — ждём старт|r")
        out[#out + 1] = "Предварительно (до старта):"
        out[#out + 1] = ("  Ожидаемый финиш: %s / %s"):format(FT(res.projected), FT(p.timeLimit))
        out[#out + 1] = ("  |cff888888Ориентир шанса: ~%d%% (уточнится после старта)|r"):format(
            math.floor(res.chance * 100 + 0.5))
        BossLines(out, {}, res.bossAvg, #res.bossAvg)
        CommonLines(out, res, p.specs, p.level)
    end
    lines:SetText(table.concat(out, "\n"))
    Layout()
end
