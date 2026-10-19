#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: 2026 Neoteric OS
# SPDX-License-Identifier: Apache-2.0
#

cd "$(dirname "$0")" || exit 1

python3 - <<'EOF'
import urllib.request
import re
import json
import random
import sys
import os

def get_html(url, headers=None):
    req_headers = {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64)'}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, headers=req_headers)
    try:
        return urllib.request.urlopen(req, timeout=15).read().decode('utf-8')
    except Exception as e:
        print(f"Error fetching {url}: {e}", file=sys.stderr)
        return None

def get_device_initial_sdk_int(device):
    if not device:
        return 32
    sdk_map = {
        "oriole": 32, "raven": 32, "bluejay": 32,
        "panther": 33, "cheetah": 33, "lynx": 33, "felix": 33, "tangorpro": 33,
        "shiba": 34, "husky": 34, "akita": 34, "tokay": 34, "caiman": 34, "komodo": 34, "comet": 34,
        "tegu": 35, "stallion": 35,
        "frankel": 36, "blazer": 36, "mustang": 36, "rango": 36,
        "cubs": 37, "grizzly": 37, "kodiak": 37, "yogi": 37
    }
    return sdk_map.get(device, 37)

def get_release_version(build_id):
    if not build_id:
        return "16"
    if any(build_id.startswith(p) for p in ("AP1", "AP2", "UP1", "UD1", "UQ1")):
        return "14"
    if any(build_id.startswith(p) for p in ("AP3", "AP4", "BP1", "BP2", "VP1")):
        return "15"
    if any(build_id.startswith(p) for p in ("CP1", "CP2", "CP3", "WP1", "WP2")):
        return "16"
    if any(build_id.startswith(p) for p in ("DP1", "DP2", "DP3", "ZP1")):
        return "17"
    return "16"

out_file = "gms_certified_props.json"
existing_meta = {}
if os.path.exists(out_file):
    try:
        with open(out_file, "r") as f:
            existing_meta = json.load(f)
    except Exception:
        pass

print("Fetching latest Android versions...")
versions_html = get_html("https://developer.android.com/about/versions")
if not versions_html:
    print("Failed to fetch Android versions page.", file=sys.stderr)
    sys.exit(1)

versions = re.findall(r'href=[\"\'](?:https://developer\.android\.com)?/about/versions/([0-9]{2})(?:/[^\"]*)?[\"\']', versions_html)
int_versions = [int(v) for v in versions if v.isdigit()]
max_ver = max(int_versions) if int_versions else 17
latest_build_url = f"https://developer.android.com/about/versions/{max_ver}"

print(f"Fetching latest factory image info for Android {max_ver}...")
latest_html = get_html(latest_build_url)
if not latest_html:
    print(f"Failed to fetch {latest_build_url}", file=sys.stderr)
    sys.exit(1)

m_fi = re.search(r'href=[\"\']([^\"\']*download(?!-ota)[^\"\']*)[\"\']', latest_html)
m_ota = re.search(r'href=[\"\']([^\"\']*download-ota[^\"\']*)[\"\']', latest_html)
fi_path = m_fi.group(1) if m_fi else None
ota_path = m_ota.group(1) if m_ota else None

target_path = fi_path or ota_path
if not target_path:
    print("Could not find factory image or OTA download link.", file=sys.stderr)
    sys.exit(1)

full_fi_url = target_path if target_path.startswith("http") else "https://developer.android.com" + ("" if target_path.startswith("/") else "/") + target_path
factory_html = get_html(full_fi_url)
if not factory_html:
    print("Could not load download page HTML.", file=sys.stderr)
    sys.exit(1)

devices = {}
# Exclude end-of-life devices (Pixel 6 / 6 Pro: oriole, raven) that only have outdated Android 16 builds,
# and exclude devices with launch SDK > 35 (Pixel 10 / 11) to avoid strict RKP requirements.
excluded_devices = {"oriole", "raven"}

for m in re.finditer(r'<tr\s+id="([^"]+)"[^>]*>\s*<td>([^<]+)</td>', factory_html, re.I):
    device_id = m.group(1).strip()
    device_name = m.group(2).strip()
    sdk = get_device_initial_sdk_int(device_id)
    if device_id not in excluded_devices and sdk <= 35:
        devices[device_name] = device_id + "_beta"

if not devices:
    print("No compatible beta devices found (<= API 35). Falling back to all found devices.", file=sys.stderr)
    for m in re.finditer(r'<tr\s+id="([^"]+)"[^>]*>\s*<td>([^<]+)</td>', factory_html, re.I):
        devices[m.group(2).strip()] = m.group(1).strip() + "_beta"

device_name = random.choice(list(devices.keys()))
product = devices[device_name]
device = product.replace("_beta", "")
initial_sdk = get_device_initial_sdk_int(device)

print(f"Selected random device: {device_name} ({device}, initial SDK: {initial_sdk})")

print("Getting flash station key...")
flash_html = get_html("https://flash.android.com/") or ""
flash_key_match = re.search(r'data-client-config\s*=\s*"(?:[^,]*?,){2}\s*&quot;([^&]+)&quot;', flash_html, re.I)
if flash_key_match:
    flash_key = flash_key_match.group(1).replace("&quot;", '"').replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
else:
    alt_match = re.search(r'AIza[0-9A-Za-z_-]{35}', flash_html)
    if alt_match:
        flash_key = alt_match.group(0)
    else:
        print("Failed to get flash station key.", file=sys.stderr)
        sys.exit(1)

print("Fetching build information from FlashStation...")
station_req = urllib.request.Request(
    f"https://content-flashstation-pa.googleapis.com/v1/builds?product={product}&key={flash_key}",
    headers={'Referer': 'https://flash.android.com/'}
)
try:
    station_json = urllib.request.urlopen(station_req, timeout=15).read().decode('utf-8')
except Exception as e:
    print(f"Failed to fetch station JSON: {e}", file=sys.stderr)
    sys.exit(1)

build_id = None
build_inc = None
for rc, bi in zip(re.finditer(r'"releaseCandidateName"\s*:\s*"([^"]+)"', station_json),
                  re.finditer(r'"buildId"\s*:\s*"([^"]+)"', station_json)):
    build_id = rc.group(1)
    build_inc = bi.group(1)

if not build_id or not build_inc:
    print("Failed to parse buildId or releaseCandidateName.", file=sys.stderr)
    sys.exit(1)

canary_id = None
canary_matches = re.findall(r'\{[^}]*\"canary\"\s*:\s*true[^}]*\}', station_json, re.I | re.DOTALL)
if canary_matches:
    cid_m = re.search(r'\"id\"\s*:\s*\"canary-([^\"]+)\"', canary_matches[-1])
    if cid_m:
        canary_id = cid_m.group(1)

security_patch = None
if canary_id and len(canary_id) >= 4:
    canary_dash = canary_id[:4] + "-" + canary_id[4:]
    sec_html = get_html("https://source.android.com/docs/security/bulletin/pixel")
    if sec_html:
        sp_m = re.search(rf'<td>{re.escape(canary_dash)}</td>\s*<td>([^<]+)</td>', sec_html, re.I)
        if sp_m:
            security_patch = sp_m.group(1).strip()
    if not security_patch:
        security_patch = f"{canary_dash}-05"

if not security_patch:
    security_patch = existing_meta.get("SECURITY_PATCH", "2026-10-05")

release_version = get_release_version(build_id)
fingerprint = f"google/{product}/{device}:CANARY/{build_id}/{build_inc}:user/release-keys"

pif_data = {
    "MANUFACTURER": "Google",
    "MODEL": device_name,
    "FINGERPRINT": fingerprint,
    "BRAND": "google",
    "PRODUCT": product,
    "DEVICE": device,
    "RELEASE": release_version,
    "VERSION.RELEASE": release_version,
    "ID": build_id,
    "INCREMENTAL": build_inc,
    "VERSION.INCREMENTAL": build_inc,
    "TYPE": "user",
    "TAGS": "release-keys",
    "SECURITY_PATCH": security_patch,
    "VERSION.SECURITY_PATCH": security_patch,
    "ro.build.version.security_patch": security_patch,
    "DEVICE_INITIAL_SDK_INT": str(initial_sdk),
    "VERSION.DEVICE_INITIAL_SDK_INT": str(initial_sdk),
    "ro.product.first_api_level": str(initial_sdk),
    "ro.board.first_api_level": "32",
    "ro.build.fingerprint": fingerprint,
    "ro.build.id": build_id,
    "ro.product.device": device,
    "ro.product.name": product
}

with open(out_file, "w") as f:
    json.dump(pif_data, f, indent=4)

xml_file = "CertifiedPropsOverlay/res/values/config.xml"
os.makedirs(os.path.dirname(xml_file), exist_ok=True)
items_xml = "\n".join([f"        <item>{k}:{v}</item>" for k, v in pif_data.items()])
xml_content = f"""<?xml version="1.0" encoding="utf-8"?>
<!--
     Copyright (C) 2023 Paranoid Android
     SPDX-License-Identifier: Apache-2.0
-->
<resources>
    <!-- Build properties from a GMS certified device -->
    <string-array name="config_certifiedBuildProperties" translatable="false">
{items_xml}
    </string-array>
</resources>
"""

with open(xml_file, "w") as f:
    f.write(xml_content)

print(f"\nSuccessfully generated random PIF and updated files:")
print(f"- {os.path.abspath(out_file)}")
print(f"- {os.path.abspath(xml_file)}")
print("\nGenerated certified properties:")
print(json.dumps(pif_data, indent=4))
EOF

