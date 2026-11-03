"""
Собирает статистику Мифик+ с WarcraftLogs (API v2) и пишет KeyChance/Data.lua.

Что собирается для каждого данжа и уровня ключа:
  * время прохождения тайм-забегов (keystoneTime, с учётом штрафов за смерти);
  * на какой секунде был убит 1-й, 2-й, ... босс;
  * состав группы (спеки) и суммарный урон группы в секунду;
  * мета: как часто каждый спек встречается в тайм-забегах этого уровня и его средний DPS.

Использование:
  1. Создайте клиент на https://www.warcraftlogs.com/api/clients/ (redirect URL любой, например http://localhost).
  2. set WCL_CLIENT_ID=...   и   set WCL_CLIENT_SECRET=...
  3. python tools/wcl_fetch.py --min-level 10 --max-level 16 --runs 25

Повторный запуск использует кэш (tools/wcl_cache.json) и докачивает только новые забеги.
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import date

TOKEN_URL = "https://www.warcraftlogs.com/oauth/token"
API_URL = "https://www.warcraftlogs.com/api/v2/client"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "KeyChance", "Data.lua")
DEFAULT_CACHE = os.path.join(HERE, "wcl_cache.json")

CLASSES = {
    "DeathKnight", "DemonHunter", "Druid", "Evoker", "Hunter", "Mage", "Monk",
    "Paladin", "Priest", "Rogue", "Shaman", "Warlock", "Warrior",
}


class OutOfPoints(Exception):
    """Очки API закончились, а ждать сброса не нужно (режим --no-wait на сервере)."""


class WCL:
    def __init__(self, client_id, client_secret, no_wait=False, max_minutes=None):
        self.no_wait = no_wait
        self.deadline = time.time() + max_minutes * 60 if max_minutes else None
        self.requests = 0
        self.token = self._token(client_id, client_secret)

    def _token(self, cid, secret):
        auth = base64.b64encode(f"{cid}:{secret}".encode()).decode()
        req = urllib.request.Request(
            TOKEN_URL, data=b"grant_type=client_credentials",
            headers={"Authorization": f"Basic {auth}", "Content-Type": "application/x-www-form-urlencoded"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)["access_token"]

    def query(self, q, variables=None):
        if self.deadline and time.time() > self.deadline:
            print("Время запуска истекло — сохраняю, следующий запуск продолжит")
            raise OutOfPoints()
        body = json.dumps({"query": q, "variables": variables or {}}).encode()
        for attempt in range(5):
            req = urllib.request.Request(API_URL, data=body, headers={
                "Authorization": f"Bearer {self.token}", "Content-Type": "application/json",
            })
            try:
                with urllib.request.urlopen(req, timeout=120) as resp:
                    data = json.load(resp)
            except urllib.error.HTTPError as e:
                if e.code == 429:
                    # на сервере не ждём: иначе сгорает время запуска, а забеги помечаются пропущенными
                    if self.no_wait or (self.deadline and time.time() + 60 > self.deadline):
                        raise OutOfPoints()
                    print("  лимит запросов, жду 60 с...")
                    time.sleep(60)
                    continue
                if e.code >= 500 and attempt < 4:
                    time.sleep(5 * (attempt + 1))
                    continue
                raise
            except (TimeoutError, ConnectionError, urllib.error.URLError) as e:
                if attempt < 4:
                    print(f"  сервер WCL не ответил ({e}), повторяю...")
                    time.sleep(10 * (attempt + 1))
                    continue
                raise
            if data.get("errors"):
                msg = json.dumps(data["errors"], ensure_ascii=False)
                if "points remaining" in msg and attempt < 4:
                    self.wait_for_reset()
                    continue
                raise RuntimeError(msg)
            self.requests += 1
            if self.requests % 25 == 0:
                self.check_rate_limit()
            return data["data"]
        raise RuntimeError("WCL API не отвечает")

    def wait_for_reset(self):
        if self.no_wait:
            raise OutOfPoints()
        d = self.query("{ rateLimitData { pointsResetIn } }")["rateLimitData"]
        wait = d["pointsResetIn"] + 30
        print(f"  лимит запросов WCL исчерпан, жду {wait // 60} мин до сброса (окно не закрывайте)...")
        time.sleep(wait)

    def check_rate_limit(self):
        d = self.query("{ rateLimitData { limitPerHour pointsSpentThisHour pointsResetIn } }")["rateLimitData"]
        left = d["limitPerHour"] - d["pointsSpentThisHour"]
        print(f"  [очки API: потрачено {d['pointsSpentThisHour']:.0f}/{d['limitPerHour']}]")
        if left < 60:
            if self.no_wait:
                raise OutOfPoints()
            wait = d["pointsResetIn"] + 5
            print(f"  очки API закончились, жду {wait} с до сброса...")
            time.sleep(wait)


def find_zone(api, zone_id):
    zones = api.query("""{ worldData { zones { id name frozen
        brackets { min max bucket type } encounters { id name } } } }""")["worldData"]["zones"]
    if zone_id:
        zone = next((z for z in zones if z["id"] == zone_id), None)
        if not zone:
            sys.exit(f"Зона {zone_id} не найдена")
        return zone
    mplus = [z for z in zones if "mythic+" in z["name"].lower() and not z.get("frozen")]
    if not mplus:
        mplus = [z for z in zones if "mythic+" in z["name"].lower()]
    if not mplus:
        sys.exit("Не удалось найти зону Mythic+. Укажите --zone ID вручную.")
    return max(mplus, key=lambda z: z["id"])


RANKINGS_Q = """query($id: Int!, $bracket: Int!, $page: Int!, $region: String) {
  worldData { encounter(id: $id) {
    characterRankings(bracket: $bracket, page: $page, serverRegion: $region)
  } } }"""

REPORT_Q = """query($code: String!, $fights: [Int]!) {
  reportData { report(code: $code) {
    fights(fightIDs: $fights) {
      id encounterID startTime endTime keystoneLevel keystoneTime keystoneBonus
      dungeonPulls { encounterID startTime endTime kill }
    }
    playerDetails(fightIDs: $fights)
    table(fightIDs: $fights, dataType: DamageDone)
    interrupts: table(fightIDs: $fights, dataType: Interrupts)
    deaths: table(fightIDs: $fights, dataType: Deaths)
  } } }"""

NAMES_Q = """query($code: String!, $fights: [Int]!) {
  reportData { report(code: $code) {
    fights(fightIDs: $fights) { dungeonPulls { encounterID name kill } }
  } } }"""

RUN_VERSION = 3  # 2: + сбитые заклинания, длительность боёв с боссами и урон по боссам; 3: + смерти


_debug_printed = False


PER_PAGE = 8                                   # сколько забегов брать с одной страницы рейтинга
PAGE_SCHEDULE = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 66, 78, 91, 105, 120]


def next_page(entry):
    """Следующая страница рейтинга: сначала всё глубже по расписанию (топ → средние → медленные группы),
    а когда известен конец рейтинга — заполняем самые большие промежутки между уже взятыми страницами."""
    visited, last = set(entry["visited"]), entry.get("last")
    for p in PAGE_SCHEDULE:
        if p not in visited and (last is None or p <= last):
            return p
    if last is None:
        return max(visited) + 15  # рейтинг длиннее расписания — идём ещё глубже
    free = [p for p in range(1, last + 1) if p not in visited]
    return max(free, key=lambda p: min(abs(p - v) for v in visited)) if free else None


def ranked_runs(api, encounter_id, level, want, region, entry=None):
    """Дополняет запись рейтинга из кэша до want уникальных забегов (код отчёта, id боя).
    Чтобы выборка была не только из топ-групп, берём по PER_PAGE забегов со страниц по всей глубине рейтинга.
    Запись: {"t": когда начали, "keys": [...], "visited": [страницы], "last": последняя существующая страница,
    "done": больше брать нечего}."""
    global _debug_printed
    entry = entry or {"t": time.time(), "keys": [], "visited": [], "done": False}
    if "visited" not in entry:
        # старый формат: страницы листались подряд и в выборке одни топ-группы —
        # оставляем лучших с первой страницы, остальное доберём с глубоких страниц
        entry["keys"] = entry["keys"][:PER_PAGE]
        entry["visited"] = [1]
        entry["done"] = False
    seen = [tuple(k) for k in entry["keys"]]
    while len(seen) < want and not entry.get("done"):
        page = next_page(entry)
        if page is None:
            entry["done"] = True
            break
        data = api.query(RANKINGS_Q, {"id": encounter_id, "bracket": level, "page": page, "region": region})
        rk = data["worldData"]["encounter"]["characterRankings"] or {}
        if isinstance(rk, str):
            rk = json.loads(rk)
        rankings = rk.get("rankings") or []
        entry["visited"].append(page)
        if not rankings:
            # перелетели за конец рейтинга: дальше берём страницы только до этой
            entry["last"] = min(entry.get("last") or page, page - 1)
            continue
        if not rk.get("hasMorePages"):
            entry["last"] = page
        added = 0
        for r in rankings:
            rep = r.get("report") or {}
            key = (rep.get("code"), rep.get("fightID"))
            if key[0] and key[1] is not None and key not in seen:
                seen.append(key)
                added += 1
                if added >= PER_PAGE:
                    break
        if rankings and not added and not _debug_printed:
            _debug_printed = True
            print("  [отладка] не понял формат рейтинга, первая запись:",
                  json.dumps(rankings[0], ensure_ascii=False)[:600])
    entry["keys"] = seen
    return entry


def spec_key(cls, spec):
    if not cls or not spec:
        return None
    return f"{cls.replace(' ', '')}-{spec.replace(' ', '')}"


def group_damage(table):
    """Суммарный урон игроков из таблицы DamageDone."""
    return sum(e.get("total", 0) for e in (table or {}).get("data", {}).get("entries", []) or []
               if e.get("type") in CLASSES)


def count_interrupts(table):
    """Сколько заклинаний сбила группа. Таблица Interrupts в WCL вложенная (заклинание -> игроки),
    поэтому берём готовый счётчик spellsInterrupted, а если его нет — суммируем записи игроков на любой глубине."""
    data = (table or {}).get("data", {})
    entries = data.get("entries") or []
    if entries and all(isinstance(e, dict) and "spellsInterrupted" in e for e in entries):
        return int(sum(e["spellsInterrupted"] or 0 for e in entries))
    total = 0

    def walk(node):
        nonlocal total
        if isinstance(node, dict):
            if node.get("type") in CLASSES and isinstance(node.get("total"), (int, float)):
                total += node["total"]
                return
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(entries)
    return int(total) if total else None


def count_deaths(table):
    """Смерти игроков группы: в таблице Deaths одна запись на каждую смерть."""
    entries = (table or {}).get("data", {}).get("entries")
    if not isinstance(entries, list):
        return None
    return sum(1 for e in entries if isinstance(e, dict) and e.get("type") in CLASSES)


def parse_run(report):
    fights = report.get("fights") or []
    if not fights:
        return None
    f = fights[0]
    if not f.get("keystoneLevel") or not f.get("keystoneTime"):
        return None

    total = f["keystoneTime"] / 1000.0
    raw = max((f["endTime"] - f["startTime"]) / 1000.0, 1.0)
    scale = total / raw  # переносим времена боссов на шкалу внутриигрового таймера (со штрафами)
    boss_pulls = sorted((p for p in (f.get("dungeonPulls") or []) if p.get("encounterID") and p.get("kill")),
                        key=lambda p: p["endTime"])
    kills = [(p["endTime"] - f["startTime"]) / 1000.0 * scale for p in boss_pulls]

    specs = []
    pd = (report.get("playerDetails") or {}).get("data", {}).get("playerDetails", {})
    names_spec = {}
    for role in ("tanks", "healers", "dps"):
        for p in pd.get(role, []) or []:
            sp = p.get("specs") or []
            spec = sp[0].get("spec") if sp and isinstance(sp[0], dict) else (sp[0] if sp else p.get("spec"))
            key = spec_key(p.get("type"), spec)
            if key:
                specs.append(key)
                names_spec[p.get("name")] = key

    table = (report.get("table") or {}).get("data", {})
    seconds = (table.get("totalTime") or (f["endTime"] - f["startTime"])) / 1000.0
    group_dmg, player_dps = 0, []
    for e in table.get("entries", []) or []:
        if e.get("type") not in CLASSES:
            continue
        group_dmg += e.get("total", 0)
        key = names_spec.get(e.get("name")) or (e.get("icon") if "-" in (e.get("icon") or "") else None)
        if key and seconds > 0:
            player_dps.append((key, e.get("total", 0) / seconds))

    return {
        "l": f["keystoneLevel"],
        "t": round(total, 1),
        "b": f.get("keystoneBonus") or 0,
        "k": [round(x, 1) for x in kills],
        "s": specs,
        "d": int(group_dmg / seconds) if seconds > 0 and group_dmg else None,
        "pd": [(k, int(v)) for k, v in player_dps],
        "i": count_interrupts(report.get("interrupts")),
        "dd": count_deaths(report.get("deaths")),
        "bt": [round((p["endTime"] - p["startTime"]) / 1000.0, 1) for p in boss_pulls],
        "v": RUN_VERSION,
        "_pulls": [(p["startTime"], p["endTime"]) for p in boss_pulls],
    }


def add_boss_damage(api, code, fid, run):
    """Урон группы в секунду на каждом боссе: таблица DamageDone за время каждого убийства, одним запросом."""
    pulls = run.pop("_pulls", [])
    if not pulls:
        return
    parts = " ".join(
        f"b{i}: table(fightIDs: [{fid}], dataType: DamageDone, startTime: {s}, endTime: {e})"
        for i, (s, e) in enumerate(pulls))
    rep = api.query(f"query($code: String!) {{ reportData {{ report(code: $code) {{ {parts} }} }} }}",
                    {"code": code})["reportData"]["report"] or {}
    run["bp"] = [int(group_damage(rep.get(f"b{i}")) / max((e - s) / 1000.0, 1.0)) or None
                 for i, (s, e) in enumerate(pulls)]


def to_lua(v, indent=0):
    pad = "    " * indent
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, (list, tuple)):
        if all(not isinstance(x, (dict, list, tuple)) for x in v):
            return "{" + ", ".join(to_lua(x) for x in v) + "}"
        return "{\n" + "".join(f"{pad}    {to_lua(x, indent + 1)},\n" for x in v) + pad + "}"
    if isinstance(v, dict):
        items = []
        for k, x in v.items():
            if x is None:
                continue
            key = f"[{k}]" if isinstance(k, int) else (k if str(k).isidentifier() else f"[{json.dumps(k)}]")
            items.append(f"{pad}    {key} = {to_lua(x, indent + 1)},\n")
        return "{\n" + "".join(items) + pad + "}"
    raise TypeError(type(v))


def parse_levels(spec, lo, hi):
    """"10-22,2-9,23-30" -> [10..22, 2..9, 23..30] в порядке важности, в пределах уровней зоны, без повторов."""
    order = []
    for part in spec.split(","):
        a, _, b = part.strip().partition("-")
        for level in range(int(a), int(b or a) + 1):
            if lo <= level <= hi and level not in order:
                order.append(level)
    return order


def collect_runs(zone, cache, levels, region, dungeons=None):
    """Все уже скачанные забеги нужных уровней, сгруппированные по данжам (в т.ч. от прошлых запусков)."""
    offset = cache.get("bracket_offset", 0)
    wanted = set(levels)
    result = {}
    for enc in zone["encounters"]:
        if dungeons and not any(d.lower() in enc["name"].lower() for d in dungeons):
            continue
        runs, seen = [], set()
        for level in levels:
            for code, fid in rk_keys(cache.get(f"rk:{enc['id']}:{level - offset}:{region}")):
                ck = f"{code}:{fid}"
                if ck not in seen and cache.get(ck) and cache[ck]["l"] in wanted:
                    seen.add(ck)
                    runs.append(cache[ck])
        result[enc["id"]] = {"name": enc["name"], "runs": runs}
    return result


def rk_keys(entry):
    """Запись рейтинга в кэше: {"t": время скачивания, "keys": [...]} (старый формат — просто список)."""
    if not entry:
        return []
    keys = entry["keys"] if isinstance(entry, dict) else entry
    return [tuple(k) for k in keys]


def fetch_boss_names(api, cache, encounters):
    """Английские имена боссов: encounterID Blizzard (тот же, что в ENCOUNTER_START в игре) -> имя.
    Нужны аддону для английского режима на неанглийском клиенте. Один отчёт на данж, результат кэшируется."""
    names = cache.setdefault("boss_names", {})
    for enc in encounters:
        if cache.get(f"bn_done:{enc['id']}"):
            continue
        keys = [k for key, v in cache.items() if key.startswith(f"rk:{enc['id']}:") for k in rk_keys(v)]
        for code, fid in keys[:3]:
            try:
                rep = api.query(NAMES_Q, {"code": code, "fights": [fid]})["reportData"]["report"] or {}
            except RuntimeError as e:
                print(f"    имена боссов {code}: {e}")
                continue
            found = 0
            for f in rep.get("fights") or []:
                for p in f.get("dungeonPulls") or []:
                    if p.get("encounterID") and p.get("name") and p.get("kill"):
                        names[str(p["encounterID"])] = p["name"]
                        found += 1
            if found:
                cache[f"bn_done:{enc['id']}"] = True
                print(f"  {enc['name']}: имена боссов ({found})")
                break
    return {int(k): v for k, v in names.items()}


def build_data(zone, runs_by_dungeon):
    dungeons, meta = {}, defaultdict(lambda: {"runs": 0, "specs": defaultdict(lambda: [0, 0.0, 0])})
    for enc, info in runs_by_dungeon.items():
        runs = [r for r in info["runs"] if r]
        if not runs:
            continue
        instance_id = enc % 10000  # WCL: префикс + ID инстанса (12825 -> 2825, 61762 -> 1762, 112521 -> 2521)
        boss_count = max((len(r["k"]) for r in runs), default=0)
        dungeons[instance_id] = {
            "name": info["name"],
            "encounter": enc,
            "bossCount": boss_count,
            "runs": [{"l": r["l"], "t": r["t"], "b": r["b"], "d": r["d"], "s": r["s"], "k": r["k"],
                      "i": r.get("i"), "dd": r.get("dd"), "bt": r.get("bt"), "bp": r.get("bp")} for r in runs],
        }
        for r in runs:
            m = meta[r["l"]]
            m["runs"] += 1
            for s in r["s"]:
                m["specs"][s][0] += 1
            for s, dps in r.get("pd", []):
                m["specs"][s][1] += dps
                m["specs"][s][2] += 1

    meta_out = {}
    for lvl, m in sorted(meta.items()):
        meta_out[lvl] = {
            "runs": m["runs"],
            "specs": {s: {"n": n, "dps": int(tot / c) if c else None} for s, (n, tot, c) in sorted(m["specs"].items())},
        }
    return {
        "generated": date.today().isoformat(),
        "zone": {"id": zone["id"], "name": zone["name"]},
        "dungeons": dungeons,
        "meta": meta_out,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--client-id", default=os.environ.get("WCL_CLIENT_ID"))
    ap.add_argument("--client-secret", default=os.environ.get("WCL_CLIENT_SECRET"))
    ap.add_argument("--zone", type=int, help="ID зоны Mythic+ на WCL (по умолчанию — текущий сезон)")
    ap.add_argument("--levels", default="10-22,2-9,23-30",
                    help="уровни ключей в порядке важности: сначала качается первая группа целиком, потом следующая")
    ap.add_argument("--runs", default="25,50,100",
                    help="забегов на данж и уровень, волнами: сначала все уровни до 25, потом все до 50 и т.д.")
    ap.add_argument("--region", help="регион серверов: EU, US, KR, TW, CN (по умолчанию все)")
    ap.add_argument("--dungeon", action="append", help="только эти данжи (часть названия), можно несколько")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--cache", default=DEFAULT_CACHE)
    ap.add_argument("--refresh-days", type=float, default=7, help="через сколько дней перекачивать рейтинг")
    ap.add_argument("--no-wait", action="store_true",
                    help="не ждать сброса лимита, а сохраниться и выйти (для запуска на сервере по расписанию)")
    ap.add_argument("--max-minutes", type=float, help="остановиться и сохраниться через столько минут")
    ap.add_argument("--no-boss-damage", action="store_true",
                    help="не качать урон по боссам (экономит очки API: один запрос на забег вместо двух)")
    ap.add_argument("--boss-names-only", action="store_true",
                    help="только докачать английские имена боссов и дописать их в уже готовый --out (забеги не трогаются)")
    ap.add_argument("--refetch-old", action="store_true",
                    help="перекачать забеги из кэша, скачанные старой версией скрипта (без киков и данных боссов)")
    args = ap.parse_args()

    if not args.client_id or not args.client_secret:
        sys.exit("Нужны WCL_CLIENT_ID и WCL_CLIENT_SECRET (https://www.warcraftlogs.com/api/clients/)")

    api = WCL(args.client_id, args.client_secret, no_wait=args.no_wait, max_minutes=args.max_minutes)
    zone = find_zone(api, args.zone)
    print(f"Зона: {zone['name']} (id {zone['id']}), данжей: {len(zone['encounters'])}")
    br = zone.get("brackets") or {}
    levels = parse_levels(args.levels, br.get("min") or 2, br.get("max") or 30)
    print(f"Порядок уровней: {', '.join(f'+{l}' for l in levels)}")

    cache = {}
    if os.path.exists(args.cache):
        with open(args.cache, encoding="utf-8") as fh:
            cache = json.load(fh)

    def save_cache():
        with open(args.cache, "w", encoding="utf-8") as fh:
            json.dump(cache, fh)

    encounters = [e for e in zone["encounters"]
                  if not args.dungeon or any(d.lower() in e["name"].lower() for d in args.dungeon)]
    if args.boss_names_only:
        names = fetch_boss_names(api, cache, encounters)
        save_cache()
        with open(args.out, encoding="utf-8") as fh:
            text = fh.read()
        text = text.split("\nKC.Data.bossNames = ")[0].rstrip("\n")
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n\nKC.Data.bossNames = " + to_lua(names) + "\n")
        print(f"Готово: {len(names)} имён боссов -> {os.path.abspath(args.out)}")
        return

    tiers = [int(x) for x in str(args.runs).split(",")]
    complete = True
    try:
        # имена боссов — в начале: на сервере запуск обычно обрывается лимитом API, до конца он не доходит
        fetch_boss_names(api, cache, encounters)
        # волна за волной (25, 50, 100 забегов), внутри волны — уровень за уровнем по всем данжам:
        # так самые важные уровни получают первую порцию данных раньше всех
        for tier, level in ((t, l) for t in tiers for l in levels):
            for enc in encounters:
                # номер "bracket" в рейтинге WCL не всегда равен уровню ключа (в S2 Midnight: bracket N = ключ +N+1);
                # смещение определяется по первому скачанному забегу
                bracket = level - cache.get("bracket_offset", 0)
                rk_key = f"rk:{enc['id']}:{bracket}:{args.region}"
                entry = cache.get(rk_key)
                if isinstance(entry, list):  # самый старый формат кэша — просто список
                    entry = cache[rk_key] = {"t": time.time(), "keys": entry}
                if entry and "visited" not in entry:  # переходим на выборку по всей глубине рейтинга
                    entry = cache[rk_key] = ranked_runs(api, enc["id"], bracket, 0, args.region, entry)
                if entry and time.time() - entry["t"] >= args.refresh_days * 86400:
                    entry = None  # рейтинг устарел — начинаем листать заново
                if not entry or (len(entry["keys"]) < tier and not entry.get("done")):
                    entry = cache[rk_key] = ranked_runs(api, enc["id"], bracket, tier, args.region, entry)
                keys = rk_keys(entry)[:tier]
                fetched = 0
                for code, fid in keys:
                    ck = f"{code}:{fid}"
                    outdated = args.refetch_old and cache.get(ck) and cache[ck].get("v", 1) < RUN_VERSION
                    if ck not in cache or outdated:
                        try:
                            rep = api.query(REPORT_Q, {"code": code, "fights": [fid]})["reportData"]["report"]
                            run = parse_run(rep or {})
                            if run and not args.no_boss_damage:
                                try:
                                    add_boss_damage(api, code, fid, run)
                                except RuntimeError as e:
                                    print(f"    урон по боссам {ck}: {e}")
                            if run:
                                run.pop("_pulls", None)
                            cache[ck] = run
                        except RuntimeError as e:
                            print(f"    пропуск {ck}: {e}")
                            if not outdated:  # старую версию забега оставляем как есть
                                cache[ck] = None
                        fetched += 1
                        if fetched % 10 == 0:
                            save_cache()
                    if cache[ck] and "bracket_offset" not in cache:
                        cache["bracket_offset"] = cache[ck]["l"] - bracket
                if fetched:
                    got = sorted({cache[f"{c}:{f}"]["l"] for c, f in keys if cache.get(f"{c}:{f}")})
                    shown = "/".join(f"+{l}" for l in got) or f"+{level}"
                    print(f"  {enc['name']} {shown}: {len(keys)} забегов (новых {fetched})")
    except OutOfPoints:
        complete = False
        print("Очки API на этот час закончились — сохраняю, следующий запуск продолжит")
    except KeyboardInterrupt:
        complete = False
        print("Прервано — сохраняю то, что уже скачано")
    finally:
        save_cache()

    data = build_data(zone, collect_runs(zone, cache, levels, args.region, args.dungeon))
    data["complete"] = complete
    data["bossNames"] = {int(k): v for k, v in cache.get("boss_names", {}).items()}
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("-- Сгенерировано tools/wcl_fetch.py — не редактируйте вручную\n")
        fh.write("local _, KC = ...\n\nKC.Data = ")
        fh.write(to_lua(data))
        fh.write("\n")
    total = sum(len(d["runs"]) for d in data["dungeons"].values())
    print(f"Готово: {total} забегов в {len(data['dungeons'])} данжах -> {os.path.abspath(args.out)}")


if __name__ == "__main__":
    main()
