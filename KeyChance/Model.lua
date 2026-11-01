local _, KC = ...

local Model = {}
KC.Model = Model

local exp, log, sqrt, abs, max, min = math.exp, math.log, math.sqrt, math.abs, math.max, math.min

-- Параметры модели. Темп группы описывается коэффициентом r = (наше время) / (время эталонного забега);
-- работаем с ln(r), чтобы ускорение и замедление были симметричны.
local SIGMA_PRIOR  = 0.13   -- разброс темпа до старта (примерно ±13% по времени)
local SIGMA_FLOOR  = 0.03
local LEVEL_STEP   = 0.045  -- насколько медленнее каждый +1 уровень ключа относительно эталона
local DPS_ALPHA    = 0.5    -- доля времени ключа, которая масштабируется уроном (остальное — пулы, бег, механики)
local META_BETA    = 0.08   -- влияние "меты" состава на темп
local KAPPA        = 0.2    -- как быстро наблюдаемый темп вытесняет априорную оценку
local LOCAL_WEIGHT = 2.0    -- свои забеги весят больше (в них есть и проваленные ключи)

-- Нормальная функция распределения (аппроксимация Абрамовица–Стиган для erf).
local function Phi(z)
    local t = 1 / (1 + 0.3275911 * abs(z) / sqrt(2))
    local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t
        * exp(-z * z / 2)
    return z >= 0 and 0.5 * (1 + y) or 0.5 * (1 - y)
end
Model.Phi = Phi

-- Доля общих спеков между двумя составами (мультимножества), 0..1.
function Model.Similarity(a, b)
    if not a or not b or #a == 0 or #b == 0 then return 0 end
    local pool, hits = {}, 0
    for _, s in ipairs(b) do pool[s] = (pool[s] or 0) + 1 end
    for _, s in ipairs(a) do
        if (pool[s] or 0) > 0 then
            hits = hits + 1
            pool[s] = pool[s] - 1
        end
    end
    return hits / max(#a, #b)
end

local function MetaTable(level)
    local meta = KC.Data.meta
    if not meta then return end
    if meta[level] then return meta[level] end
    -- ближайший уровень, для которого есть статистика
    local best, bestD
    for l, t in pairs(meta) do
        local d = abs(l - level)
        if not bestD or d < bestD then best, bestD = t, d end
    end
    return best
end

local metaCache = {}

-- Насколько спек популярен в тайм-забегах на этом уровне относительно самого популярного спека своей роли (0..1).
function Model.SpecMeta(specKey, level)
    if not specKey then return nil end
    local ck = level .. specKey
    if metaCache[ck] == nil then
        metaCache[ck] = Model.ComputeSpecMeta(specKey, level) or false
    end
    return metaCache[ck] or nil
end

function Model.ComputeSpecMeta(specKey, level)
    local t = MetaTable(level)
    if not t or not t.specs or not specKey then return nil end
    local role = KC.SpecRoleByKey[specKey]
    local top = 0
    for key, s in pairs(t.specs) do
        if KC.SpecRoleByKey[key] == role and s.n > top then top = s.n end
    end
    local s = t.specs[specKey]
    if top == 0 then return nil end
    return s and s.n / top or 0
end

function Model.MetaTier(score)
    if not score then return "?" end
    if score >= 0.6 then return "S" elseif score >= 0.35 then return "A" elseif score >= 0.15 then return "B" end
    return "C"
end

-- Средняя "мета-оценка" состава 0..1 (nil, если данных нет).
function Model.MetaScore(specs, level)
    local sum, n = 0, 0
    for _, key in ipairs(specs or {}) do
        local m = Model.SpecMeta(key, level)
        if m then sum, n = sum + m, n + 1 end
    end
    return n > 0 and sum / n or nil
end

function Model.SpecAvgDPS(specKey, level)
    local t = MetaTable(level)
    local s = t and t.specs and t.specs[specKey]
    return s and s.dps
end

-- Эталонные забеги для данжа/уровня: WCL-данные + собственная история.
function Model.GetRefs(instanceID, level, specs)
    local refs = {}
    local function add(runs, baseW, maxD)
        for _, r in ipairs(runs or {}) do
            local d = abs((r.l or level) - level)
            if r.t and r.t > 0 and d <= maxD then
                local sim = Model.Similarity(specs, r.s)
                refs[#refs + 1] = { run = r, w = baseW * 0.5 ^ d * (1 + 1.5 * sim), sim = sim }
            end
        end
    end

    local dungeon = KC.Data.dungeons and KC.Data.dungeons[instanceID]
    local history = KC.db and KC.db.history and KC.db.history[instanceID]
    for _, maxD in ipairs({ 2, 4, 8 }) do
        wipe(refs)
        add(dungeon and dungeon.runs, 1, maxD)
        add(history, LOCAL_WEIGHT, maxD)
        if #refs >= 15 then break end
    end
    return refs, dungeon
end

local function WeightedMedian(values)
    table.sort(values, function(a, b) return a.v < b.v end)
    local total = 0
    for _, x in ipairs(values) do total = total + x.w end
    local acc = 0
    for _, x in ipairs(values) do
        acc = acc + x.w
        if acc >= total / 2 then return x.v end
    end
end

--[[
state = {
    instanceID, level, timeLimit (сек),
    elapsed (сек), kills = { время 1-го убитого босса, 2-го, ... },
    bossCount, forces (0..1), specs = { "Mage-Fire", ... }, groupDPS (может быть nil),
    bias (поправка: насколько обычная группа медленнее залогированных тайм-забегов)
}
]]
function Model.Estimate(state)
    local level = state.level or 0
    local refs, dungeon = Model.GetRefs(state.instanceID, level, state.specs)
    if #refs == 0 then return nil end

    local limit = state.timeLimit
    local elapsed = state.elapsed or 0
    local kills = state.kills or {}
    local k = #kills
    local bossCount = state.bossCount or (dungeon and dungeon.bossCount) or 0
    local forces = state.forces or 0
    local bias = state.bias or 0
    local myMeta = Model.MetaScore(state.specs, level)
    local dpsTrust = state.groupDPS and min(1, elapsed / 300) or 0
    local lastT = k > 0 and kills[k] or 0

    local sumW, sumP = 0, 0
    local projections, finish = {}, {}
    local bossAvg, bossW = {}, {}
    local compT, compW, compN = 0, 0, 0
    local allT, allW = 0, 0
    local dpsSum, dpsW = 0, 0
    local levels = {}

    for _, ref in ipairs(refs) do
        local r, w = ref.run, ref.w
        local T = r.t
        local rk = r.k or {}

        -- априорный темп: смещение логов + разница уровней + мета + урон
        local mu = bias + LEVEL_STEP * (level - (r.l or level))
        if myMeta and r.s then
            local refMeta = Model.MetaScore(r.s, level)
            if refMeta then mu = mu - META_BETA * (myMeta - refMeta) end
        end
        if dpsTrust > 0 and r.d and r.d > 0 then
            local term = -DPS_ALPHA * log(state.groupDPS / r.d)
            mu = mu + dpsTrust * max(-0.4, min(0.4, term))
        end

        -- наблюдаемый темп по последнему убитому боссу
        local refLast = k > 0 and (rk[k] or T * k / (bossCount + 0.5)) or 0
        local phi = refLast / T
        local m, lambda = mu, 0
        if k > 0 and rk[k] and lastT > 0 then
            lambda = phi / (phi + KAPPA)
            m = (1 - lambda) * mu + lambda * log(lastT / rk[k])
        end
        local s = max(SIGMA_FLOOR, SIGMA_PRIOR * sqrt(1 - min(phi, 0.95)) * (1 - 0.5 * lambda))
        local rate = exp(m)

        -- сколько "эталонного" времени осталось с текущего момента
        local refRem
        if bossCount > 0 and k >= bossCount then
            refRem = forces >= 1 and 0 or (1 - forces) * T * 0.9
            s = max(s, 0.25)
        else
            local nextKill = rk[k + 1] or T
            local spent = (elapsed - lastT) / rate
            refRem = max((T - refLast) - spent, (T - nextKill) + 0.15 * (nextKill - refLast))
        end

        local budget = limit - elapsed
        local p
        if budget <= 0 then
            p = 0
        elseif refRem <= 0 then
            p = 1
        else
            -- успеваем, если реальный темп не хуже необходимого: ln(budget/refRem) >= ln(r)
            p = Phi((log(budget / refRem) - m) / s)
        end

        sumW, sumP = sumW + w, sumP + w * p
        projections[#projections + 1] = { v = elapsed + rate * max(refRem, 0), w = w }
        finish[#finish + 1] = { v = T, w = w }

        -- средние времена считаем только по тайм-забегам (в своей истории бывают и проваленные)
        if r.timed ~= false then
            for i, t in ipairs(rk) do
                bossAvg[i] = (bossAvg[i] or 0) + w * t
                bossW[i] = (bossW[i] or 0) + w
            end
            if ref.sim >= 0.6 then
                compT, compW, compN = compT + w * T, compW + w, compN + 1
            end
            allT, allW = allT + w * T, allW + w
        end
        if r.d and (r.l or level) == level then dpsSum, dpsW = dpsSum + w * r.d, dpsW + w end
        levels[r.l or level] = true
    end

    local res = {
        chance = sumP / sumW,
        projected = WeightedMedian(projections),
        refFinish = WeightedMedian(finish),
        avgFinish = allW > 0 and allT / allW or nil,
        compFinish = compN > 0 and compT / compW or nil,
        compN = compN,
        avgDPS = dpsW > 0 and dpsSum / dpsW or nil,
        samples = #refs,
        meta = myMeta,
        bossAvg = {},
    }
    for i, v in pairs(bossAvg) do res.bossAvg[i] = v / bossW[i] end
    local lo, hi
    for l in pairs(levels) do
        lo, hi = min(lo or l, l), max(hi or l, l)
    end
    res.levelLo, res.levelHi = lo, hi
    return res
end
