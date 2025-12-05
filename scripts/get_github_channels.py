# -*- coding: utf-8 -*-
import os
import sys
from datetime import datetime

# ==================== FORCE LOG FILE FIRST THING ====================
BASE = r"C:\Users\Lenovo\PROJECTS\get-epg-open-epg.com\get-epg-open-epg.com"
LOG_DIR    = os.path.join(BASE, "logs")
OUTPUT_DIR = os.path.join(BASE, "data", "output")

os.makedirs(LOG_DIR,    exist_ok=True)
os.makedirs(OUTPUT_DIR, exist_ok=True)

TS = datetime.now().strftime("%Y%m%d_%H%M%S")
LOG_FILE = os.path.join(LOG_DIR, f"get_channels_{TS}.log.txt")

# Create log file immediately and write first line
with open(LOG_FILE, "a", encoding="utf-8") as f:
    f.write(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] [INFO] LOG FILE CREATED SUCCESSFULLY\n")

def log(msg, level="INFO"):
    line = f"[{datetime.now():%Y-%m-%d %H:%M:%S}] [{level}] {msg}\n"
    print(line.strip())
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(line)

log(f"Python location: {sys.executable}")
log(f"Script running from: {os.getcwd()}")
log(f"Log file confirmed: {LOG_FILE}")
log(f"Output folder: {OUTPUT_DIR}")

# ==================== NOW IMPORT REQUESTS (safe) ====================
try:
    import requests
    log("requests module loaded successfully")
except ImportError as e:
    log("FATAL: requests not installed → pip install requests", "ERROR")
    log(f"Error details: {e}", "ERROR")
    input("\nPress ENTER to exit...")
    sys.exit(1)

# ==================== INTERNET CHECK ====================
log("Testing internet...")
try:
    requests.get("https://httpbin.org/ip", timeout=10)
    log("Internet connection OK")
except Exception as e:
    log(f"No internet: {e}", "ERROR")
    input("Press ENTER to exit...")
    sys.exit(1)

# ==================== REST OF SCRIPT (multi-threaded) ====================
import csv
import re
from concurrent.futures import ThreadPoolExecutor, as_completed

allowed_news = {"MSNBC", "CNN", "BBC", "CBC News", "CTV News"}

def parse_m3u(text):
    channels = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        if lines[i].startswith("#EXTINF:"):
            try:
                name = lines[i].split(",", 1)[1].split(" tvg-", 1)[0].strip()
                i += 1
                url = lines[i].strip()
                if not url.startswith("http"): continue

                group_match = re.search(r'group-title="([^"]*)"', lines[i-1])
                group_title = group_match.group(1) if group_match else ""

                country = ""
                if any(x in group_title for x in ["Canada","CA"]): country = "CA"
                elif any(x in group_title for x in ["United States","USA","US"]): country = "US"
                elif any(x in group_title for x in ["United Kingdom","UK","GB"]): country = "GB"
                elif any(x in group_title for x in ["Australia","AU"]): country = "AU"
                if not country: continue

                cats = [c.strip().lower() for c in re.split(r'[|/-]', group_title)]
                if any(w in " ".join(cats) for w in ["sport","kid","children","adult","xxx","porn"]): continue
                if "news" in " ".join(cats) and not any(n in name for n in allowed_news): continue

                channels.append({"name": name, "country": country, "group_title": group_title, "url": url})
            except: pass
        i += 1
    return channels

def run_task(name, url, filename, is_json=False):
    log(f"Starting → {name}")
    try:
        r = requests.get(url, timeout=40)
        r.raise_for_status()
        if is_json:
            data = r.json()
            filtered = []
            for ch in data:
                if ch.get("country") not in ["CA","US","GB","AU"]: continue
                if "eng" not in [l.get("code","") for l in ch.get("languages",[])]: continue
                if ch.get("is_nsfw"): continue
                cats = [c.get("name","").lower() for c in ch.get("categories",[])]
                if any(x in cats for x in ["sports","kids","adult","xxx"]): continue
                if "news" in cats and not any(n in ch.get("name","") for n in allowed_news): continue
                filtered.append({
                    "id": ch.get("id",""), "name": ch.get("name",""), "network": ch.get("network",""),
                    "country": ch.get("country",""), "logo": ch.get("logo","")
                })
            path = os.path.join(OUTPUT_DIR, filename)
            with open(path, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=filtered[0].keys() if filtered else ["name"])
                w.writeheader(); w.writerows(filtered)
            return f"{filename} → {len(filtered)} channels"
        else:
            chs = parse_m3u(r.text)
            path = os.path.join(OUTPUT_DIR, filename)
            with open(path, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=["name","country","group_title","url"])
                w.writeheader(); w.writerows(chs)
            return f"{filename} → {len(chs)} channels"
    except Exception as e:
        return f"{filename} FAILED: {e}"

# ==================== RUN ALL 4 TASKS IN PARALLEL ====================
log("Launching all 4 sources in parallel (multi-threaded)...")
tasks = [
    ("iptv-org JSON",    "https://iptv-org.github.io/api/channels.json", "1_iptv-org_full.csv", True),
    ("English M3U",      "https://iptv-org.github.io/iptv/languages/eng.m3u", "2_english_m3u.csv", False),
    ("Free-TV",          "https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8", "3_free_tv.csv", False),
    ("Canada M3U",       "https://iptv-org.github.io/iptv/countries/ca.m3u", "4_canada_kitchener.csv", False),
]

with ThreadPoolExecutor(max_workers=4) as pool:
    futures = [pool.submit(run_task, *t) for t in tasks]
    for fut in as_completed(futures):
        log(fut.result(), "RESULT")

log("═" * 70)
log("COMPLETED SUCCESSFULLY!")
log(f"CSVs saved to → {OUTPUT_DIR}")
log(f"Log file      → {LOG_FILE}")
log("═" * 70)

input("\nPress ENTER to close...")
