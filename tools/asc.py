#!/usr/bin/env python3
"""Minimal App Store Connect API client (stdlib + openssl, no pip installs).

Credentials: ASC_KEY_ID and ASC_ISSUER_ID from the environment or
~/.appstoreconnect/chromanoise.env, and the private key at
~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (never in the repo).

    tools/asc.py app                  # app record id for the bundle ID
    tools/asc.py builds               # recent builds and their processing state
    tools/asc.py wait-build 42        # wait until build 42 is processed
    tools/asc.py listing              # store listing as entered in App Store Connect
"""
import base64
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


def get(path: str, **params) -> dict:
    url = f"{API}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    # Retry network hiccups (timeouts, resets); API errors fail at once.
    for attempt in range(4):
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            sys.exit(f"App Store Connect API {error.code}: {error.read().decode()[:500]}")
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
            if attempt == 3:
                sys.exit(f"App Store Connect unreachable: {error}")
            time.sleep(5 * 2 ** attempt)


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
