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
        gh = shutil.which("gh") or r"C:\Program Files\GitHub CLI\gh.exe"
        r = subprocess.run([gh, "api", f"repos/{s['data_repo']}/contents/KeyChance/Data.lua",
                            "-H", "Accept: application/vnd.github.raw"], capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.decode("utf-8", "replace").strip())
        with open(os.path.join(ROOT, "KeyChance", "Data.lua"), "wb") as fh:
            fh.write(r.stdout)
        dest = os.path.join(addons, "KeyChance")
        shutil.copytree(os.path.join(ROOT, "KeyChance"), dest, dirs_exist_ok=True)
        print(f"\nГОТОВО. Аддон обновлён: {dest}")
        print("В игре напишите /reload")
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
    print(f"\nГОТОВО. Аддон скопирован в: {dest}")
    print("В игре напишите /reload, затем /kc")


if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        if e.code not in (None, 0):
            print(f"\nОШИБКА: {e.code}")
    except Exception as e:
        print(f"\nОШИБКА: {e}")
        print("Сделайте скриншот этого окна и пришлите его.")
    input("\nНажмите Enter, чтобы закрыть окно...")
