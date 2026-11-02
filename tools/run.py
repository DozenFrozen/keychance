"""Простой запуск: спрашивает ключи (один раз), качает данные и копирует аддон в папку игры."""

import json
import os
import shutil
import sys

import wcl_fetch

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SETTINGS = os.path.join(HERE, "settings.json")


def load_settings():
    if os.path.exists(SETTINGS):
        with open(SETTINGS, encoding="utf-8") as fh:
            return json.load(fh)
    return {}


def save_settings(s):
    with open(SETTINGS, "w", encoding="utf-8") as fh:
        json.dump(s, fh, ensure_ascii=False, indent=2)


def ask(prompt):
    value = ""
    while not value:
        value = input(prompt).strip().strip('"')
    return value


def find_addons_dir(settings):
    candidates = []
    if settings.get("addons_dir"):
        candidates.append(settings["addons_dir"])
    try:
        import winreg
        for key in (r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
                    r"SOFTWARE\Blizzard Entertainment\World of Warcraft"):
            try:
                with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key) as k:
                    path = winreg.QueryValueEx(k, "InstallPath")[0]
                    # InstallPath указывает на ...\World of Warcraft\_retail_\
                    candidates.append(os.path.join(path, "Interface", "AddOns"))
                    candidates.append(os.path.join(path, "_retail_", "Interface", "AddOns"))
            except OSError:
                pass
    except ImportError:
        pass
    for drive in "CDEFG":
        for base in (r"Program Files (x86)\World of Warcraft", r"Program Files\World of Warcraft",
                     r"World of Warcraft", r"Games\World of Warcraft"):
            candidates.append(os.path.join(f"{drive}:\\", base, "_retail_", "Interface", "AddOns"))
    for c in candidates:
        if os.path.isdir(c):
            return c

    print("\nНе нашёл папку игры.")
    print(r"Вставьте путь к папке World of Warcraft (например D:\Games\World of Warcraft) и нажмите Enter:")
    while True:
        path = ask("> ")
        for c in (os.path.join(path, "_retail_", "Interface", "AddOns"),
                  os.path.join(path, "Interface", "AddOns"), path):
            if os.path.isdir(os.path.join(c, "..", "..")) and c.lower().endswith("addons"):
                os.makedirs(c, exist_ok=True)
                return c
        print("Такой папки нет, попробуйте ещё раз:")


def gh_exe():
    return shutil.which("gh") or r"C:\Program Files\GitHub CLI\gh.exe"


def print_stats():
    """Статистика по KeyChance/Data.lua: сколько забегов на каждом уровне ключа и в каждом данже."""
    import re
    from collections import Counter
    path = os.path.join(ROOT, "KeyChance", "Data.lua")
    if not os.path.exists(path):
        print("Файл данных не найден")
        return
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    text = text.split("\n    meta = {")[0]  # дальше идёт сводка по спекам, не забеги

    generated = re.search(r'generated = "([^"]+)"', text)
    starts = [(m.start(), m.group(1)) for m in re.finditer(r'\[\d+\] = \{\s+name = "([^"]+)"', text)]
    per_level, per_dungeon = Counter(), {}
    for i, (pos, name) in enumerate(starts):
        block = text[pos:starts[i + 1][0] if i + 1 < len(starts) else len(text)]
        levels = [int(x) for x in re.findall(r"\bl = (\d+),", block)]
        per_dungeon[name] = len(levels)
        per_level.update(levels)

    total = sum(per_level.values())
    print("\n================ БАЗА ЗАБЕГОВ ================")
    print(f"Данные от: {generated.group(1) if generated else '?'}    Всего забегов: {total}\n")
    top = max(per_level.values(), default=1)
    print(" Ключ  Забегов")
    for level in range(2, 31):
        n = per_level.get(level, 0)
        bar = "█" * round(20 * n / top) if n else ""
        print(f"  +{level:<3} {n:>5}  {bar if n else '— ещё не скачано'}")
    print("\n Данж                       Забегов")
    for name, n in sorted(per_dungeon.items(), key=lambda x: -x[1]):
        print(f"  {name:<26} {n:>5}")


def print_server_status(repo):
    """Последний запуск сервера (GitHub Actions)."""
    import subprocess
    from datetime import datetime, timezone
    r = subprocess.run([gh_exe(), "run", "list", "-R", repo, "--limit", "1",
                        "--json", "status,conclusion,createdAt"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip().startswith("["):
        return
    runs = json.loads(r.stdout)
    if not runs:
        return
    run = runs[0]
    started = datetime.fromisoformat(run["createdAt"].replace("Z", "+00:00"))
    minutes = int((datetime.now(timezone.utc) - started).total_seconds() // 60)
    ago = f"{minutes} мин назад" if minutes < 120 else f"{minutes // 60} ч назад"
    if run["status"] != "completed":
        state = "идёт прямо сейчас"
    else:
        state = {"success": "успешно", "cancelled": "прерван", "failure": "ОШИБКА"}.get(run["conclusion"], run["conclusion"])
    print(f"\nСервер: последний запуск {ago} — {state}")


def main():
    print("==============================================")
    print("  KeyChance: загрузка данных с WarcraftLogs")
    print("==============================================\n")

    s = load_settings()
    if s.get("data_repo"):
        # готовые данные, которые собирает сервер (GitHub Actions) — ключи WCL не нужны.
        # Репозиторий приватный, поэтому качаем через GitHub CLI (gh auth login).
        import subprocess
        addons = find_addons_dir(s)
        s["addons_dir"] = addons
        save_settings(s)
        print("Скачиваю свежие данные с GitHub...")
        r = subprocess.run([gh_exe(), "api", f"repos/{s['data_repo']}/contents/KeyChance/Data.lua",
                            "-H", "Accept: application/vnd.github.raw"], capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.decode("utf-8", "replace").strip())
        with open(os.path.join(ROOT, "KeyChance", "Data.lua"), "wb") as fh:
            fh.write(r.stdout)
        dest = os.path.join(addons, "KeyChance")
        shutil.copytree(os.path.join(ROOT, "KeyChance"), dest, dirs_exist_ok=True)
        print(f"Аддон обновлён: {dest}")
        print_stats()
        print_server_status(s["data_repo"])
        return

    if not s.get("client_id") or not s.get("client_secret"):
        print("Вставить текст в это окно: правая кнопка мыши (или Ctrl+V), потом Enter.\n")
        s["client_id"] = ask("Client ID: ")
        s["client_secret"] = ask("Client Secret: ")

    addons = find_addons_dir(s)
    s["addons_dir"] = addons
    save_settings(s)
    print(f"Папка аддонов: {addons}\n")

    print("Качаю данные, это может занять долго. Не закрывайте окно.\n")
    sys.argv = [
        "wcl_fetch.py", "--client-id", s["client_id"], "--client-secret", s["client_secret"],
        "--levels", "10-22,2-9,23-30", "--runs", "25", "--region", "EU",
    ]
    try:
        wcl_fetch.main()
    except Exception as e:
        if "401" in str(e) or "invalid_client" in str(e):
            os.remove(SETTINGS)
            print("\nКлючи не подошли. Запустите ещё раз и вставьте их заново.")
        raise

    dest = os.path.join(addons, "KeyChance")
    shutil.copytree(os.path.join(ROOT, "KeyChance"), dest, dirs_exist_ok=True)
    print(f"Аддон скопирован в: {dest}")
    print_stats()


if __name__ == "__main__":
    ok = False
    try:
        main()
        ok = True
    except SystemExit as e:
        ok = e.code in (None, 0)
        if not ok:
            print(f"\nОШИБКА: {e.code}")
    except Exception as e:
        print(f"\nОШИБКА: {e}")
    print("\n==============================================")
    if ok:
        print("  ИТОГ: УСПЕШНО. В игре напишите /reload")
    else:
        print("  ИТОГ: НЕ УДАЛОСЬ. Сделайте скриншот окна и пришлите")
    print("==============================================")
    input("\nНажмите Enter, чтобы закрыть окно...")
