local _, KC = ...
local L = KC.L

-- График: как менялся шанс тайма по ходу ключа. Отметки — убийства боссов и лимит времени.
local Graph = {}
KC.Graph = Graph

local PLOT_W, PLOT_H = 460, 200
local frame, plot, header, footer
local lines, texts, marks = {}, {}, {}

local function Line(i)
    local l = lines[i]
    if not l then
        l = plot:CreateLine(nil, "ARTWORK")
        lines[i] = l
    end
    l:Show()
    return l
end

local function Text(i)
    local t = texts[i]
    if not t then
        t = plot:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        texts[i] = t
    end
    t:Show()
    return t
end

local function Mark(i)
    local m = marks[i]
    if not m then
        m = plot:CreateTexture(nil, "BORDER")
        marks[i] = m
    end
    m:Show()
    return m
end

local function Create()
    frame = CreateFrame("Frame", "KeyChanceGraph", UIParent, "BackdropTemplate")
    frame:SetSize(PLOT_W + 60, PLOT_H + 80)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
    })
    frame:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "KeyChanceGraph") -- закрывается по Esc

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", 12, -10)
    header:SetPoint("TOPRIGHT", -30, -10)
    header:SetJustifyH("LEFT")

    plot = CreateFrame("Frame", nil, frame)
    plot:SetSize(PLOT_W, PLOT_H)
    plot:SetPoint("TOPLEFT", 40, -34)
    local bg = plot:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.04)

    footer = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer:SetPoint("BOTTOMLEFT", 12, 8)
    footer:SetPoint("BOTTOMRIGHT", -12, 8)
    footer:SetJustifyH("LEFT")
end

local function Hex(code)
    return tonumber(code:sub(5, 6), 16) / 255, tonumber(code:sub(7, 8), 16) / 255, tonumber(code:sub(9, 10), 16) / 255
end

local function Draw(s)
    for _, l in ipairs(lines) do l:Hide() end
    for _, t in ipairs(texts) do t:Hide() end
    for _, m in ipairs(marks) do m:Hide() end
    local log = s.chanceLog
    local FT = KC.FormatTime
    local tMax = math.max(s.timeLimit or 0, s.time or 0, log[#log].t, 60)
    local X = function(t) return t / tMax * PLOT_W end
    -- отступы сверху и снизу, чтобы линия на 100% и 0% не сливалась с краем
    local PAD_TOP, PAD_BOTTOM = 22, 8 -- сверху больше: там ещё номера боссов
    local Y = function(p) return PAD_BOTTOM + p * (PLOT_H - PAD_TOP - PAD_BOTTOM) end
    local nl, nt, nm = 0, 0, 0

    -- сетка по шансу
    for _, p in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
        nl = nl + 1
        local l = Line(nl)
        l:SetDrawLayer("ARTWORK")
        l:SetThickness(1)
        l:SetColorTexture(1, 1, 1, p == 0.5 and 0.25 or 0.1)
        l:SetStartPoint("BOTTOMLEFT", plot, 0, Y(p))
        l:SetEndPoint("BOTTOMLEFT", plot, PLOT_W, Y(p))
        nt = nt + 1
        local t = Text(nt)
        t:SetText(("%d%%"):format(p * 100))
        t:ClearAllPoints()
        t:SetPoint("RIGHT", plot, "BOTTOMLEFT", -4, Y(p))
    end

    -- время по оси X: каждые 5 минут
    for m = 0, tMax, 300 do
        nt = nt + 1
        local t = Text(nt)
        t:SetText(FT(m))
        t:ClearAllPoints()
        t:SetPoint("TOP", plot, "BOTTOMLEFT", X(m), -3)
    end

    -- лимит времени
    if s.timeLimit and s.timeLimit > 0 then
        nm = nm + 1
        local m = Mark(nm)
        m:SetColorTexture(1, 0.3, 0.3, 0.6)
        m:ClearAllPoints()
        m:SetSize(2, PLOT_H)
        m:SetPoint("BOTTOM", plot, "BOTTOMLEFT", X(s.timeLimit), 0)
        nt = nt + 1
        local t = Text(nt)
        t:SetText(L["|cffff6060лимит|r"])
        t:ClearAllPoints()
        t:SetPoint("BOTTOM", plot, "TOPLEFT", X(s.timeLimit), 2)
    end

    -- убийства боссов
    for i, kt in ipairs(s.kills or {}) do
        nm = nm + 1
        local m = Mark(nm)
        m:SetColorTexture(1, 0.82, 0.25, 0.35)
        m:ClearAllPoints()
        m:SetSize(1, PLOT_H)
        m:SetPoint("BOTTOM", plot, "BOTTOMLEFT", X(kt), 0)
        nt = nt + 1
        local t = Text(nt)
        t:SetText(("|cffffd040%d|r"):format(i))
        t:ClearAllPoints()
        t:SetPoint("TOP", plot, "TOPLEFT", X(kt), -2)
    end

    -- сам шанс, цвет отрезка — по шансу. Точки пишутся раз в 5 с (~1 пиксель), а такие короткие отрезки
    -- игра может не нарисовать: прореживаем до отрезков от 3 пикселей и склеиваем ровные участки
    local pts = { log[1] }
    for i = 2, #log do
        local last, cur, nxt = pts[#pts], log[i], log[i + 1]
        local flat = nxt and math.abs(cur.p - last.p) < 0.003 and math.abs(nxt.p - cur.p) < 0.003
        if not nxt or (not flat and X(cur.t) - X(last.t) >= 3) then pts[#pts + 1] = cur end
    end
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        nl = nl + 1
        local l = Line(nl)
        l:SetDrawLayer("OVERLAY")
        l:SetThickness(2.5)
        l:SetColorTexture(Hex(KC.UI.ChanceColor((a.p + b.p) / 2)))
        l:SetStartPoint("BOTTOMLEFT", plot, X(a.t), Y(a.p))
        l:SetEndPoint("BOTTOMLEFT", plot, X(b.t), Y(b.p))
    end

    header:SetText((L["Шанс тайма: %s +%d  %s"]):format(KC.DungeonName(s.instanceID, s.name) or "?", s.level or 0,
        s.time and (s.onTime and L["|cff40ff40в тайм|r"] or L["|cffff4040не в тайм|r"]) or L["|cffffd040идёт|r"]))
    local lo, hi = 1, 0
    for _, pt in ipairs(log) do lo, hi = math.min(lo, pt.p), math.max(hi, pt.p) end
    local pct = function(p) return math.floor(p * 100 + 0.5) end
    footer:SetText((L["Старт %d%%   мин. %d%%   макс. %d%%%s%s"]):format(pct(log[1].p), pct(lo), pct(hi),
        s.time and (L["   финиш %s / %s"]):format(FT(s.time), FT(s.timeLimit)) or "",
        s.date and ("   |cff888888%s|r"):format(s.date) or ""))
end

function Graph.Show(s)
    if not s or not s.chanceLog or #s.chanceLog < 2 then
        print(L["KeyChance: для графика пока нет данных — он строится по ходу ключа"])
        return
    end
    if not frame then Create() end
    Draw(s)
    frame:Show()
end

function Graph.Toggle(s)
    if frame and frame:IsShown() then frame:Hide() else Graph.Show(s) end
end

-- Текущий ключ (если идёт), иначе последний завершённый.
function Graph.ShowLatest()
    Graph.Show(KC.demo or KC.run or KC.summary or KC.db.lastRun)
end
