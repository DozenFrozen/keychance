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
local BOSS_DPS_W   = 0.5    -- вес сравнения урона по боссам (точнее общего урона: на треше много бега и простоя)
local INT_BETA     = 0.05   -- влияние частоты сбитых заклинаний (мало киков -> больше смертей и вайпов)
local INT_CAP      = 0.08
local META_BETA    = 0.08   -- влияние "меты" состава на темп
-- Смерти: штраф за уже случившиеся смерти уже сидит в таймере, а будущие оцениваются по темпу смертей группы.
-- Эталонные забеги тоже умирали, поэтому учитываем только разницу: "мы умираем чаще/реже эталона".
local DEATH_PENALTY    = 15        -- секунд за смерть, если игра не сказала точнее
local DEATH_PRIOR_RATE = 1 / 300   -- смертей в секунду у эталона без данных о смертях (~6 за 30 минут)
local DEATH_PRIOR_SEC  = 600       -- вес априорного темпа смертей: столько секунд "виртуального" ключа
local KAPPA        = 0.2    -- как быстро наблюдаемый темп вытесняет априорную оценку
local LOCAL_WEIGHT = 2.0    -- свои забеги весят больше (в них есть и проваленные ключи)
local PERSONAL_K   = 3      -- сколько "виртуальных" ключей весит значение по умолчанию при подстройке под историю
local PERSONAL_CAP = 0.6    -- ограничение поправки: не больше чем в ~1.8 раза медленнее/быстрее базы

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
                refs[#refs + 1] = { run = r, w = baseW * 0.5 ^ d * (1 + 1.5 * sim), sim = sim,
                    isLocal = baseW == LOCAL_WEIGHT }
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

-- Насколько ваши группы медленнее (>0) или быстрее (<0) базы WCL, в ln-единицах темпа.
-- Каждый ваш завершённый ключ сравнивается с медианой базы по тому же данжу (с поправкой на уровень);
-- результат сглаживается к значению по умолчанию, пока ключей мало.
local personalCache
function Model.PersonalBias(default)
    if personalCache and personalCache.default == default then return personalCache.bias, personalCache.n end
    local sum, n = 0, 0
    for instanceID, runs in pairs(KC.db and KC.db.history or {}) do
        local dungeon = KC.Data.dungeons and KC.Data.dungeons[instanceID]
        for _, mine in ipairs(runs) do
            local refT = {}
            for _, r in ipairs(dungeon and dungeon.runs or {}) do
                if r.t and r.l and abs(r.l - mine.l) <= 2 then
                    refT[#refT + 1] = r.t * exp(LEVEL_STEP * (mine.l - r.l))
                end
            end
            if #refT >= 5 and mine.t and mine.t > 0 then
                table.sort(refT)
                local median = refT[math.floor(#refT / 2) + 1]
                sum, n = sum + max(-PERSONAL_CAP, min(PERSONAL_CAP, log(mine.t / median))), n + 1
            end
        end
    end
    local bias = (sum + PERSONAL_K * default) / (n + PERSONAL_K)
    personalCache = { default = default, bias = bias, n = n }
    return bias, n
end

-- Сбрасывается после каждого завершённого ключа.
function Model.ResetPersonal()
    personalCache = nil
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
    bossDPS = { урон группы в секунду на 1-м убитом боссе, ... } (может быть пустым),
    interrupts (сбито заклинаний с начала ключа, может быть nil),
    encounter = { elapsed = сек боя с боссом, hp = доля HP босса 0..1 или nil } — только во время боя,
    deaths (смертей с начала ключа), deathPenalty (секунд штрафа за смерть),
    bias (поправка: насколько обычная группа медленнее залогированных тайм-забегов)
}
]]

local function Clamp(v, cap)
    return max(-cap, min(cap, v))
end

-- Сколько ещё (в наших секундах) продлится идущий бой с боссом и относительная неопределённость этой оценки.
-- expected — ожидаемая длительность всего боя. По HP босса оценка тем точнее, чем больше уже снято:
-- при 5% HP за 2 минуты боя осталось ~6 секунд, а не "средний бой минус прошедшее".
local function FightRemaining(enc, expected)
    local done = enc.elapsed
    local byTime = max(expected - done, 0.15 * expected)
    local hp = enc.hp
    if hp and hp < 0.98 and done >= 5 then
        local byHP = done * hp / (1 - hp)
        local w = min(1, (1 - hp) * 1.5)
        return w * byHP + (1 - w) * byTime, 0.1 + 0.3 * hp
    end
    return byTime, done > expected and 0.5 or 0.35
end

-- Средний ln(наш урон / урон эталона) по боссам, где известны оба значения.
local function BossDPSRatio(mine, ref)
    if not mine or not ref then return end
    local sum, n = 0, 0
    for i, v in pairs(mine) do
        if v and v > 0 and ref[i] and ref[i] > 0 then sum, n = sum + log(v / ref[i]), n + 1 end
    end
    return n > 0 and sum / n or nil
end
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
    local bias, personalN = Model.PersonalBias(state.bias or 0)
    local myMeta = Model.MetaScore(state.specs, level)
    local dpsTrust = state.groupDPS and min(1, elapsed / 300) or 0
    local lastT = k > 0 and kills[k] or 0

    local sumW, sumP = 0, 0
    local projections, finish = {}, {}
    local bossAvg, bossW = {}, {}
    local compT, compW, compN = 0, 0, 0
    local allT, allW = 0, 0
    local dpsSum, dpsW = 0, 0
    local fightAvg, fightW = {}, {}
    local bdAvg, bdW = {}, {}
    local intSum, intW = 0, 0
    local intRate = state.interrupts and elapsed >= 300 and state.interrupts / elapsed
    local levels = {}
    local fightRems = {}
    local deaths = state.deaths or 0
    local penalty = state.deathPenalty or DEATH_PENALTY
    local deathSum, deathW = 0, 0
    local futureDeaths = {}

    -- идёт бой с боссом k+1: средняя длительность этого боя у эталонов (для тех, где она не записана)
    local enc = state.encounter
    local fightRef
    if enc then
        local sum, wsum = 0, 0
        for _, ref in ipairs(refs) do
            local bt = ref.run.bt and ref.run.bt[k + 1]
            if bt then sum, wsum = sum + ref.w * bt, wsum + ref.w end
        end
        fightRef = wsum > 0 and sum / wsum or nil
    end

    for _, ref in ipairs(refs) do
        local r, w = ref.run, ref.w
        local T = r.t
        local rk = r.k or {}

        -- априорный темп: смещение логов + разница уровней + мета + урон
        -- поправка "база WCL -> ваши группы" нужна только эталонам из WCL: свои забеги уже в вашем темпе
        local mu = (ref.isLocal and 0 or bias) + LEVEL_STEP * (level - (r.l or level))
        if myMeta and r.s then
            local refMeta = Model.MetaScore(r.s, level)
            if refMeta then mu = mu - META_BETA * (myMeta - refMeta) end
        end
        if dpsTrust > 0 and r.d and r.d > 0 then
            mu = mu + dpsTrust * Clamp(-DPS_ALPHA * log(state.groupDPS / r.d), 0.4)
        end
        local bossRatio = BossDPSRatio(state.bossDPS, r.bp)
        if bossRatio then
            mu = mu + BOSS_DPS_W * Clamp(-DPS_ALPHA * bossRatio, 0.4)
        end
        if intRate and r.i and r.t then
            mu = mu + Clamp(-INT_BETA * log((intRate + 0.01) / (r.i / r.t + 0.01)), INT_CAP)
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

        -- сколько времени осталось с текущего момента: refRem — в "эталонных" секундах,
        -- realRem — сразу в наших (во время боя с боссом, где темп виден по самому бою)
        local refRem, realRem, realS
        local nextKill = rk[k + 1] or T
        if bossCount > 0 and k >= bossCount then
            refRem = forces >= 1 and 0 or (1 - forces) * T * 0.9
            s = max(s, 0.25)
        elseif enc then
            local fightRem, sF = FightRemaining(enc, rate * ((r.bt and r.bt[k + 1]) or fightRef or 0.08 * T))
            local after = max(0, T - nextKill)
            if k + 1 >= bossCount and forces < 1 then after = after + (1 - forces) * T * 0.9 end
            local rest = rate * after
            realRem = fightRem + rest
            realS = max(SIGMA_FLOOR, sqrt((fightRem * sF) ^ 2 + (rest * s) ^ 2) / max(realRem, 1))
            fightRems[#fightRems + 1] = { v = fightRem, w = w }
        else
            -- даже если отрезок до босса затянулся, впереди ещё сам бой с ним
            local spent = (elapsed - lastT) / rate
            local nextFight = (r.bt and r.bt[k + 1]) or 0.25 * (nextKill - refLast)
            refRem = max((T - refLast) - spent, (T - nextKill) + max(0.6 * nextFight, 0.05 * (nextKill - refLast)))
        end

        -- будущие смерти: наш темп смертей (сглаженный к темпу эталона, пока ключ короткий) против эталонного;
        -- лишние смерти съедают бюджет времени штрафами
        local remaining = realRem or rate * max(refRem, 0)
        local refDeathRate = r.dd and T > 0 and r.dd / T or DEATH_PRIOR_RATE
        local myDeathRate = (deaths + refDeathRate * DEATH_PRIOR_SEC) / (elapsed + DEATH_PRIOR_SEC)
        local extra = max(-0.05 * remaining, min(0.5 * remaining,
            (myDeathRate - refDeathRate) * remaining * penalty))
        futureDeaths[#futureDeaths + 1] = { v = myDeathRate * remaining, w = w }

        local budget = limit - elapsed
        local net = budget - extra
        local p
        if budget <= 0 then
            p = 0
        elseif (realRem or refRem) <= 0 then
            p = 1
        elseif net <= 0 then
            p = 0
        elseif realRem then
            p = Phi(log(net / realRem) / realS)
        else
            -- успеваем, если реальный темп не хуже необходимого: ln(net/refRem) >= ln(r)
            p = Phi((log(net / refRem) - m) / s)
        end

        sumW, sumP = sumW + w, sumP + w * p
        projections[#projections + 1] = { v = elapsed + remaining + extra, w = w }
        finish[#finish + 1] = { v = T, w = w }

        -- средние времена считаем только по тайм-забегам (в своей истории бывают и проваленные)
        if r.timed ~= false then
            for i, t in ipairs(rk) do
                bossAvg[i] = (bossAvg[i] or 0) + w * t
                bossW[i] = (bossW[i] or 0) + w
            end
            for i, t in ipairs(r.bt or {}) do
                fightAvg[i] = (fightAvg[i] or 0) + w * t
                fightW[i] = (fightW[i] or 0) + w
            end
            if r.i then intSum, intW = intSum + w * r.i, intW + w end
            if r.dd then deathSum, deathW = deathSum + w * r.dd, deathW + w end
            if ref.sim >= 0.6 then
                compT, compW, compN = compT + w * T, compW + w, compN + 1
            end
            allT, allW = allT + w * T, allW + w
        end
        if (r.l or level) == level then
            if r.d then dpsSum, dpsW = dpsSum + w * r.d, dpsW + w end
            for i, v in pairs(r.bp or {}) do
                if v and v > 0 then
                    bdAvg[i] = (bdAvg[i] or 0) + w * v
                    bdW[i] = (bdW[i] or 0) + w
                end
            end
        end
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
        personalBias = bias,
        personalN = personalN,
        meta = myMeta,
        avgInterrupts = intW > 0 and intSum / intW or nil,
        fightRem = #fightRems > 0 and WeightedMedian(fightRems) or nil, -- сколько ещё бить текущего босса
        avgDeaths = deathW > 0 and deathSum / deathW or nil,  -- смертей за ключ у тайм-забегов
        futureDeaths = WeightedMedian(futureDeaths),          -- сколько ещё смертей ожидается до конца
        deathPenalty = penalty,
        bossAvg = {},       -- на какой секунде ключа убит i-й босс
        bossFightAvg = {},  -- сколько длится бой с i-м боссом
        bossDPSAvg = {},    -- урон группы в секунду на i-м боссе
    }
    for i, v in pairs(bossAvg) do res.bossAvg[i] = v / bossW[i] end
    for i, v in pairs(fightAvg) do res.bossFightAvg[i] = v / fightW[i] end
    for i, v in pairs(bdAvg) do res.bossDPSAvg[i] = v / bdW[i] end
    local lo, hi
    for l in pairs(levels) do
        lo, hi = min(lo or l, l), max(hi or l, l)
    end
    res.levelLo, res.levelHi = lo, hi
    return res
end
