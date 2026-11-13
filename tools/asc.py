#!/usr/bin/env python3
"""Minimal App Store Connect API client (stdlib + openssl, no pip installs).

Credentials: ASC_KEY_ID and ASC_ISSUER_ID from the environment or
~/.appstoreconnect/chromanoise.env, and the private key at
~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (never in the repo).

    tools/asc.py app                  # app record id for the bundle ID
    tools/asc.py builds               # recent builds and their processing state
    tools/asc.py wait-build 42        # wait until build 42 is processed
    tools/asc.py listing              # store listing as entered in App Store Connect
    tools/asc.py keywords "a,b,c"     # set the editable version's keywords
    tools/asc.py promo "..."          # ...and its promotional text (170 max)
    tools/asc.py select-build 60      # ...and the build it submits
    tools/asc.py upload-screenshots screenshots/framed
                                      # replace the editable version's screenshots
"""
import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BUNDLE_ID = "com.talkabel.ChromaNoise"
API = "https://api.appstoreconnect.apple.com/v1"
CONFIG = os.path.expanduser("~/.appstoreconnect/chromanoise.env")


def credentials():
    values = {}
    if os.path.exists(CONFIG):
        for line in open(CONFIG):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()
    key_id = os.environ.get("ASC_KEY_ID", values.get("ASC_KEY_ID"))
    issuer = os.environ.get("ASC_ISSUER_ID", values.get("ASC_ISSUER_ID"))
    if not key_id or not issuer:
        sys.exit(f"Set ASC_KEY_ID and ASC_ISSUER_ID (env or {CONFIG})")
    key_path = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    if not os.path.exists(key_path):
        sys.exit(f"Missing {key_path}")
    return key_id, issuer, key_path


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(sig: bytes) -> bytes:
    """ECDSA DER SEQUENCE{INTEGER r, INTEGER s} -> 64-byte r||s (JWS ES256)."""
    def read_int(data, i):
        assert data[i] == 0x02
        length = data[i + 1]
        value = data[i + 2:i + 2 + length].lstrip(b"\0")
        return value.rjust(32, b"\0"), i + 2 + length
    assert sig[0] == 0x30
    i = 3 if sig[1] & 0x80 else 2
    r, i = read_int(sig, i)
    s, _ = read_int(sig, i)
    return r + s


def token() -> str:
    key_id, issuer, key_path = credentials()
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 15 * 60,
                                 "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{payload}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing_input, capture_output=True, check=True).stdout
    return f"{header}.{payload}.{b64url(der_to_raw(der))}"


def request(method: str, path: str, body: dict | None = None, **params) -> dict:
    url = f"{API}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    # Retry network hiccups (timeouts, resets); API errors fail at once.
    for attempt in range(4):
        headers = {"Authorization": f"Bearer {token()}"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            sys.exit(f"App Store Connect API {error.code}: {error.read().decode()[:500]}")
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
            if attempt == 3:
                sys.exit(f"App Store Connect unreachable: {error}")
            time.sleep(5 * 2 ** attempt)


def get(path: str, **params) -> dict:
    return request("GET", path, **params)


def app_id() -> str:
    apps = get("/apps", **{"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps:
        sys.exit(f"No App Store Connect app for {BUNDLE_ID}")
    return apps[0]["id"]


def builds(version: str | None = None) -> list:
    params = {"filter[app]": app_id(), "sort": "-uploadedDate", "limit": "10",
              "fields[builds]": "version,processingState,uploadedDate,expired"}
    if version:
        params["filter[version]"] = version
    return get("/builds", **params)["data"]


def show(title: str, attributes: dict, keys: list[str]) -> None:
    print(f"== {title}")
    for key in keys:
        value = attributes.get(key)
        if isinstance(value, str) and "\n" in value:
            print(f"  {key}:")
            for line in value.splitlines():
                print(f"    {line}")
        else:
            print(f"  {key}: {value}")


def listing() -> None:
    """Everything the store page is built from, read-only."""
    app = app_id()
    show("App", get(f"/apps/{app}")["data"]["attributes"],
         ["name", "bundleId", "sku", "primaryLocale", "contentRightsDeclaration"])
    for info in get(f"/apps/{app}/appInfos", include="primaryCategory,secondaryCategory")["data"]:
        rel = info["relationships"]
        cats = [(rel.get(k, {}).get("data") or {}).get("id") for k in ("primaryCategory", "secondaryCategory")]
        show(f"App info {info['id']}", info["attributes"] | {"categories": cats},
             ["state", "appStoreAgeRating", "categories"])
        for loc in get(f"/appInfos/{info['id']}/appInfoLocalizations")["data"]:
            show(f"App info ({loc['attributes']['locale']})", loc["attributes"],
                 ["name", "subtitle", "privacyPolicyUrl", "privacyChoicesUrl"])
        age = get(f"/appInfos/{info['id']}/ageRatingDeclaration")["data"]
        answered = {k: v for k, v in (age or {}).get("attributes", {}).items() if v not in (None, "NONE", False)}
        print(f"== Age rating answers (non-default): {answered or 'none'}")
    for version in get(f"/apps/{app}/appStoreVersions")["data"]:
        vid = version["id"]
        show(f"Version {version['attributes']['versionString']}", version["attributes"],
             ["platform", "appStoreState", "copyright", "releaseType", "usesIdfa"])
        build = get(f"/appStoreVersions/{vid}/build")["data"]
        print(f"  build: {build['attributes']['version'] if build else None}")
        for loc in get(f"/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]:
            a = loc["attributes"]
            show(f"Version text ({a['locale']})", a,
                 ["description", "keywords", "promotionalText", "supportUrl", "marketingUrl", "whatsNew"])
            for shots in get(f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]:
                count = len(get(f"/appScreenshotSets/{shots['id']}/appScreenshots")["data"])
                print(f"  screenshots {shots['attributes']['screenshotDisplayType']}: {count}")
        review = get(f"/appStoreVersions/{vid}/appStoreReviewDetail")["data"]
        if review:
            a = review["attributes"]
            show("Review details", a | {"contactEmail": "(set)" if a.get("contactEmail") else None},
                 ["contactFirstName", "contactLastName", "contactEmail", "demoAccountRequired", "notes"])
        else:
            print("== Review details: none")


def editable_version() -> dict:
    """The App Store version still being prepared."""
    versions = get(f"/apps/{app_id()}/appStoreVersions",
                   **{"filter[appStoreState]": "PREPARE_FOR_SUBMISSION,DEVELOPER_REJECTED,REJECTED"})["data"]
    if not versions:
        sys.exit("No version is open for editing")
    return versions[0]


def select_build(number: str) -> None:
    rows = builds(number)
    if not rows or rows[0]["attributes"]["processingState"] != "VALID":
        sys.exit(f"Build {number} isn't processed (tools/asc.py wait-build {number})")
    version = editable_version()
    request("PATCH", f"/appStoreVersions/{version['id']}/relationships/build",
            {"data": {"type": "builds", "id": rows[0]["id"]}})
    print(f"Version {version['attributes']['versionString']} now submits build {number}")


def editable_localization() -> dict:
    """The en-US text of the version still being prepared (the one whose
    listing can change)."""
    version = editable_version()
    for loc in get(f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]:
        if loc["attributes"]["locale"] == "en-US":
            return loc
    sys.exit("The editable version has no en-US localization")


def set_version_text(field: str, value: str, limit: int) -> None:
    """Sets one text field of the editable version's en-US listing."""
    if len(value) > limit:
        sys.exit(f"{field} is {len(value)} characters; the limit is {limit}")
    loc = editable_localization()
    print(f"was: {loc['attributes'][field]}")
    request("PATCH", f"/appStoreVersionLocalizations/{loc['id']}", {"data": {
        "type": "appStoreVersionLocalizations", "id": loc["id"],
        "attributes": {field: value}}})
    print(f"now: {value}")


# screenshots/<device>/ folder -> App Store Connect display type. The Duo's
# folded and unfolded sets share one type.
DISPLAY_TYPES = {
    "iPhone 17": "APP_IPHONE_61",
    "iPad Pro 13-inch (M5)": "APP_IPAD_PRO_3GEN_129",
    "iPhone Duo": "APP_IPHONE_DUO",
    "iPhone Duo (inner)": "APP_IPHONE_DUO",
}


def upload_screenshot(set_id: str, path: str) -> str:
    """Reserve, upload and commit one screenshot; returns its id."""
    data = open(path, "rb").read()
    reserved = request("POST", "/appScreenshots", {"data": {
        "type": "appScreenshots",
        "attributes": {"fileName": os.path.basename(path), "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})["data"]
    for op in reserved["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"], headers=headers)
        with urllib.request.urlopen(req, timeout=120):
            pass
    request("PATCH", f"/appScreenshots/{reserved['id']}", {"data": {
        "type": "appScreenshots", "id": reserved["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    return reserved["id"]


def wait_until_processed(ids: list[str]) -> None:
    """Apple checks each upload; a failed one would leave a hole in the set."""
    deadline = time.time() + 10 * 60
    pending = set(ids)
    while pending:
        for shot_id in sorted(pending):
            state = get(f"/appScreenshots/{shot_id}")["data"]["attributes"]["assetDeliveryState"]
            if state["state"] == "COMPLETE":
                pending.discard(shot_id)
            elif state["state"] == "FAILED":
                sys.exit(f"Screenshot {shot_id} failed processing: {state.get('errors')}")
        if pending:
            if time.time() > deadline:
                sys.exit(f"Timed out waiting for {len(pending)} screenshots to process")
            time.sleep(5)


def upload_screenshots(root: str) -> None:
    """Replaces each display type's screenshots with the PNGs under
    root/<device>/, in file-name order. The new set is uploaded and
    processed before the old one is removed, so a failure midway leaves the
    old screenshots in place."""
    loc = editable_localization()
    sets = {s["attributes"]["screenshotDisplayType"]: s["id"]
            for s in get(f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]}
    files: dict[str, list[str]] = {}
    for device, display_type in DISPLAY_TYPES.items():
        folder = os.path.join(root, device)
        if os.path.isdir(folder):
            files.setdefault(display_type, []).extend(
                os.path.join(folder, f) for f in sorted(os.listdir(folder)) if f.endswith(".png"))
    if not files:
        sys.exit(f"No screenshots under {root}/ ({', '.join(DISPLAY_TYPES)})")
    for display_type, paths in files.items():
        if display_type not in sets:
            sets[display_type] = request("POST", "/appScreenshotSets", {"data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": display_type},
                "relationships": {"appStoreVersionLocalization": {"data": {
                    "type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]["id"]
        set_id = sets[display_type]
        old = [s["id"] for s in get(f"/appScreenshotSets/{set_id}/appScreenshots")["data"]]
        print(f"==> {display_type}: uploading {len(paths)}, replacing {len(old)}", flush=True)
        new = []
        for path in paths:
            new.append(upload_screenshot(set_id, path))
            print(f"    {path}", flush=True)
        wait_until_processed(new)
        for shot_id in old:
            request("DELETE", f"/appScreenshots/{shot_id}")
        # Display order: the new screenshots, in file-name order.
        request("PATCH", f"/appScreenshotSets/{set_id}/relationships/appScreenshots", {
            "data": [{"type": "appScreenshots", "id": i} for i in new]})


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "builds"
    if command == "app":
        print(app_id())
    elif command == "builds":
        rows = builds()
        if not rows:
            print("No builds uploaded yet.")
        for build in rows:
            a = build["attributes"]
            print(f"build {a['version']:>5}  {a['processingState']:<11} uploaded {a['uploadedDate']}")
    elif command == "listing":
        listing()
    elif command == "keywords" and len(sys.argv) == 3:
        set_version_text("keywords", sys.argv[2], 100)
    elif command == "select-build" and len(sys.argv) == 3:
        select_build(sys.argv[2])
    elif command == "promo" and len(sys.argv) == 3:
        set_version_text("promotionalText", sys.argv[2], 170)
    elif command == "upload-screenshots" and len(sys.argv) == 3:
        upload_screenshots(sys.argv[2])
    elif command == "wait-build" and len(sys.argv) == 3:
        version, deadline = sys.argv[2], time.time() + 60 * 60
        while time.time() < deadline:
            rows = builds(version)
            state = rows[0]["attributes"]["processingState"] if rows else "NOT YET VISIBLE"
            print(f"build {version}: {state}", flush=True)
            if state == "VALID":
                return
            if state in ("FAILED", "INVALID"):
                sys.exit(1)
            time.sleep(60)
        sys.exit("Timed out waiting for processing")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
