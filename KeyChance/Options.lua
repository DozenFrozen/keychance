local _, KC = ...
local L = KC.L

-- Панель настроек (Esc → Настройки → AddOns → KeyChance) и кнопка у мини-карты.
local Options = {}
KC.Options = Options

local ICON = "Interface\\Icons\\INV_Relics_Hourglass"
local category, langSetting

local function LanguageOptions()
    local c = Settings.CreateControlTextContainer()
    c:Add("auto", L["Авто (по языку клиента)"])
    c:Add("ru", L["Русский"])
    c:Add("en", "English")
    return c:GetData()
end

local function Refresh()
    KC.UI.ApplyStyle()
    KC.UI.SetShown(KC.db.shown)
    if KC.Update then KC.Update() end
end

------------------------------------------------------------------------
-- Панель настроек
------------------------------------------------------------------------
local function Register(tbl, key, name, default)
    local setting = Settings.RegisterAddOnSetting(category, "KeyChance_" .. key, key, tbl, type(default), name, default)
    setting:SetValueChangedCallback(Refresh)
    return setting
end

local function Checkbox(tbl, key, name, tooltip, default)
    Settings.CreateCheckbox(category, Register(tbl, key, name, default), tooltip)
end

local function Slider(key, name, tooltip, lo, hi, step, fmt)
    local options = Settings.CreateSliderOptions(lo, hi, step)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, fmt)
    Settings.CreateSlider(category, Register(KC.db, key, name, KC.DEFAULTS[key]), options, tooltip)
end

local function Header(layout, text)
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
end

local function Button(layout, name, text, onClick, tooltip)
    if CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer(name, text, onClick, tooltip, true))
    end
end

-- функция, а не таблица: подписи переводятся при открытии настроек, когда язык уже известен
local function ShowSections() return {
    { L["Окно"], {
        { "forecast",    L["Прогноз финиша"],            L["Ожидаемое время финиша и запас/опоздание"] },
        { "mobs",        L["Мобы и таймер"],             L["Процент убитых мобов (и сколько набрано из нужного) и таймер ключа"] },
        { "preview",     L["Окно до старта ключа"],      L["Предварительная оценка по ключу лидера и составу группы"] },
        { "hints",       L["Подсказки"],                 L["Серые пояснения внизу окна"] },
    } },
    { L["Боссы"], {
        { "bosses",      L["Спидран боссов"],            L["На какой минуте убит каждый босс в сравнении со средним у тайм-забегов"] },
        { "bossFight",   L["Длительность боя с боссом"], L["Сколько бьют босса (и идущий бой) в сравнении со средним"] },
        { "bossDPS",     L["Урон по боссу"],             L["Урон группы в секунду на каждом боссе и в сумме по боссам"] },
    } },
    { L["Группа"], {
        { "damage",      L["Урон группы"],               L["Урон группы в секунду за весь ключ в сравнении со средним"] },
        { "interrupts",  L["Сбитые заклинания"],         L["Сколько заклинаний сбила группа за ключ, в текущем бою и на каждом боссе"] },
        { "deaths",      L["Смерти"],                    L["Сколько раз умерла группа, сколько времени это стоило и сколько смертей ещё ожидается"] },
        { "meta",        L["Мета состава"],              L["Оценка состава и тир каждого спека по популярности в тайм-забегах"] },
    } },
    { L["Статистика"], {
        { "avgFinish",   L["Средний финиш"],             L["Среднее время тайм-забегов этого данжа и уровня"] },
        { "comp",        L["Похожий состав"],            L["Средний финиш групп с 3+ такими же спеками"] },
        { "stats",       L["Статистика и ваш темп"],     L["Объём выборки и насколько ваши группы быстрее/медленнее базы"] },
        { "chanceSteps", L["Шанс по ходу (итог)"],       L["Как менялся шанс после каждого босса — в итогах ключа"] },
        { "graph",       L["Кнопка графика"],            L["Кнопка «График» в итогах ключа"] },
    } },
} end

function Options.Init()
    local layout
    category, layout = Settings.RegisterVerticalLayoutCategory("KeyChance")

    Header(layout, L["Общие"])
    langSetting = Register(KC.db, "language", L["Язык"], "auto")
    langSetting:SetValueChangedCallback(function() Options.SetLanguage(KC.db.language, true) end)
    local CreateDropdown = Settings.CreateDropdown or Settings.CreateDropDown -- до 11.0 называлась CreateDropDown
    CreateDropdown(category, langSetting, LanguageOptions, L["Язык аддона. «Авто»: русский, если клиент игры на русском, иначе английский. Панель настроек переведётся после /reload."])
    Checkbox(KC.db, "shown", L["Показывать окно"], L["То же, что /kc"], true)
    Checkbox(KC.db, "locked", L["Закрепить окно"], L["Запретить перетаскивание мышью"], false)
    Checkbox(KC.db, "graphAuto", L["Открывать график после ключа"], L["Автоматически показать график шанса после завершения ключа"], false)
    local mm = Register(KC.db.minimap, "hide", L["Скрыть кнопку у мини-карты"], false)
    mm:SetValueChangedCallback(Options.UpdateMinimap)
    Settings.CreateCheckbox(category, mm, L["Кнопку можно вернуть командой /kc minimap"])
    Slider("scale", L["Масштаб окна"], nil, 0.6, 1.6, 0.05, function(v) return ("%d%%"):format(v * 100 + 0.5) end)
    Slider("alpha", L["Прозрачность фона"], nil, 0, 1, 0.05, function(v) return ("%d%%"):format(v * 100 + 0.5) end)
    Slider("bias", L["Поправка темпа"], L["Насколько обычная группа медленнее залогированных тайм-забегов WCL. "]
        .. L["Аддон сам уточняет её по вашим завершённым ключам."], 0, 0.3, 0.01,
        function(v) return ("%d%%"):format(v * 100 + 0.5) end)
    Button(layout, L["Положение окна"], L["Сбросить"], function() KC.UI.ResetPosition() end, L["Вернуть окно на место по умолчанию"])
    Button(layout, L["Последний ключ"], L["График"], KC.Graph.ShowLatest, L["График шанса последнего ключа"])

    -- демо-данные: случайный ключ из базы, чтобы посмотреть окно и настроить, какие строки показывать
    Header(layout, L["Демо-данные"])
    Button(layout, L["Итоги ключа"], L["Показать"], function() KC.SetDemo("summary") end,
        L["Итоги случайного ключа из базы WCL. Галочки ниже сразу меняют окно"])
    Button(layout, L["Ключ в процессе"], L["Показать"], function() KC.SetDemo("live") end,
        L["Случайный момент случайного ключа из базы WCL — так окно выглядит во время прохождения"])
    Button(layout, L["Выключить демо"], L["Выключить"], function() KC.SetDemo("off") end,
        L["Вернуть окно к реальным данным"])

    for _, section in ipairs(ShowSections()) do
        Header(layout, section[1])
        for _, item in ipairs(section[2]) do
            Checkbox(KC.db.show, item[1], item[2], item[3], KC.DEFAULTS.show[item[1]])
        end
    end

    Settings.RegisterAddOnCategory(category)
    Options.CreateMinimapButton()
end

local LANG_NAMES = { auto = "Авто (по языку клиента)", ru = "Русский", en = "English" } -- переводятся при выводе

-- Окно переводится сразу, панель настроек — после /reload (её подписи создаются один раз).
function Options.SetLanguage(value, fromPanel)
    if langSetting and not fromPanel then
        langSetting:SetValue(value) -- сам вызовет SetLanguage(value, true)
        return
    end
    KC.db.language = value
    print((L["KeyChance: язык — %s. Панель настроек переведётся после /reload."]):format(L[LANG_NAMES[value] or value]))
    Refresh()
end

function Options.Open()
    Settings.OpenToCategory(category:GetID())
end

------------------------------------------------------------------------
-- Кнопка у мини-карты
------------------------------------------------------------------------
local button

local function Place()
    local angle = math.rad(KC.db.minimap.angle or 215)
    local r = (Minimap:GetWidth() / 2) + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function OnClick(_, mouse)
    if mouse == "RightButton" then
        Options.Open()
    elseif IsShiftKeyDown() then
        KC.Graph.ShowLatest()
    else
        KC.UI.Toggle()
        if KC.Update then KC.Update() end
    end
end

local function ShowTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine("KeyChance")
    GameTooltip:AddLine(L["ЛКМ: показать/скрыть окно"], 1, 1, 1)
    GameTooltip:AddLine(L["Shift+ЛКМ: график шанса"], 1, 1, 1)
    GameTooltip:AddLine(L["ПКМ: настройки"], 1, 1, 1)
    GameTooltip:Show()
end

function Options.CreateMinimapButton()
    button = CreateFrame("Button", "KeyChanceMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", OnClick)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", GameTooltip_Hide)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            KC.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            Place()
        end)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    Place()
    Options.UpdateMinimap()
end

function Options.UpdateMinimap()
    if button then button:SetShown(not KC.db.minimap.hide) end
end

-- Меню аддонов у мини-карты (## AddonCompartmentFunc в .toc)
function KeyChance_OnAddonCompartmentClick(_, mouse)
    OnClick(nil, mouse)
end

function KeyChance_OnAddonCompartmentEnter(_, owner)
    ShowTooltip(owner)
end

function KeyChance_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
