#!/usr/bin/env python3
"""Minimal App Store Connect API client (stdlib + openssl, no pip installs).

Credentials: ASC_KEY_ID and ASC_ISSUER_ID from the environment or
~/.appstoreconnect/chromanoise.env, and the private key at
~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (never in the repo).

    tools/asc.py app                  # app record id for the bundle ID
    tools/asc.py builds               # recent builds and their processing state
    tools/asc.py wait-build 42        # wait until build 42 is processed
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
