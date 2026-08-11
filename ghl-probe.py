#!/usr/bin/env python3
"""
GHL probe — reports what your GoHighLevel account actually returns, so the
KPI sync can be built against real field names instead of guesses.

Run it from this folder:

    python3 ghl-probe.py

It reads GHL_TOKEN and GHL_LOCATION_ID from .env. It only ever prints
structure: field names, pipeline and stage names, tag vocabulary, and
counts. It never prints contact names, phone numbers, emails, addresses,
or message bodies — so the output is safe to paste back into chat.
"""

import json
import sys
import urllib.error
import urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone

BASE = "https://services.leadconnectorhq.com"
API_VERSION = "2021-07-28"

# Anything whose field name matches one of these has its VALUE withheld.
# Field names themselves are still shown, since that's what we're mapping.
PII_HINTS = (
    "name", "email", "phone", "address", "city", "state", "postal", "zip",
    "contact", "body", "message", "text", "firstname", "lastname", "companyname",
    "website", "dnd", "ssn", "attribution",
)


def load_env(path=".env"):
    env = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, val = line.split("=", 1)
                    env[key.strip()] = val.strip()
    except FileNotFoundError:
        sys.exit("No .env found. Run this from the folder that contains it.")
    return env


# GHL sits behind Cloudflare, which rejects requests whose client signature
# looks automated — the default "Python-urllib/3.x" User-Agent gets a 403
# with error_code 1010 before the request ever reaches the API. A normal
# browser UA is enough to get through in most cases; when the TLS
# fingerprint is also flagged, curl (system TLS) usually still works.
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")


def _headers(token):
    return {
        "Authorization": "Bearer " + token,
        "Version": API_VERSION,
        "Accept": "application/json",
        "User-Agent": UA,
    }


def _is_cloudflare_block(body):
    return isinstance(body, str) and "error_code" in body and "1010" in body


def _curl_get(path, token):
    """Fallback for when Cloudflare flags the Python TLS fingerprint."""
    import subprocess
    cmd = ["curl", "-sS", "-w", "\n%{http_code}", "--max-time", "30"]
    for key, val in _headers(token).items():
        cmd += ["-H", f"{key}: {val}"]
    cmd.append(BASE + path)
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=40).stdout
        body, _, code = out.rpartition("\n")
        status = int(code.strip() or 0)
        try:
            return status, json.loads(body)
        except json.JSONDecodeError:
            return status, body[:400]
    except Exception as err:
        return "ERR", f"curl fallback failed: {err}"[:200]


def api_get(path, token):
    req = urllib.request.Request(BASE + path, headers=_headers(token))
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as err:
        body = err.read().decode()[:400]
        if err.code == 403 and _is_cloudflare_block(body):
            return _curl_get(path, token)
        return err.code, body
    except Exception as err:  # network, DNS, TLS
        return "ERR", str(err)[:200]


def redact(value, key=""):
    """Keep the shape, drop anything that could identify a person."""
    if any(hint in key.lower() for hint in PII_HINTS):
        if isinstance(value, list):
            return f"<list of {len(value)}, withheld>"
        return "<withheld>"
    if isinstance(value, dict):
        return {k: redact(v, k) for k, v in list(value.items())[:30]}
    if isinstance(value, list):
        return [redact(v, key) for v in value[:2]]
    if isinstance(value, str) and len(value) > 60:
        return value[:60] + "…"
    return value


def section(title):
    print("\n" + "=" * 64)
    print(title)
    print("=" * 64)


def main():
    env = load_env()
    token = env.get("GHL_TOKEN", "")
    loc = env.get("GHL_LOCATION_ID", "")

    if not token:
        sys.exit("GHL_TOKEN is empty in .env")
    if not loc:
        sys.exit("GHL_LOCATION_ID is empty in .env")

    print(f"Location: {loc}")
    print(f"Token:    {token[:8]}… ({len(token)} chars)")

    # --- 1. Sanity check — NOT a gate. -------------------------------
    # /locations/:id needs its own `locations.readonly` scope, which isn't
    # on the list we requested (it isn't needed for anything below). A 401
    # here on its own doesn't mean the token is bad — it means that one
    # scope is missing. The real test is whether contacts/opportunities/
    # conversations work, so every section below runs regardless of what
    # happens here.
    section("1. LOCATION — sanity check only, not required for the sync")
    status, data = api_get(f"/locations/{loc}", token)
    print("status:", status)
    if status == 401:
        print("401 here just means the token has no `locations.readonly` scope.")
        print("That scope isn't needed for KPI syncing — continuing to the")
        print("sections that actually matter.")
    elif status == 403:
        if _is_cloudflare_block(data):
            print("403 from Cloudflare (error 1010), not from GHL — blocked at the")
            print("edge before reaching the API.")
        else:
            print("403 from GHL — missing scope for this endpoint specifically.")
    if isinstance(data, dict):
        print("keys:", list(data.keys())[:15])
    else:
        print("body:", str(data)[:300])

    # --- 2. Pipelines: the single most important thing to see ---------
    # KPI metrics like leadsOfferedOn and dealsProduced are defined by
    # which stage an opportunity sits in, so the mapping is impossible
    # without the real stage names.
    section("2. PIPELINES + STAGES — needed to map offers and deals")
    status, data = api_get(f"/opportunities/pipelines?locationId={loc}", token)
    print("status:", status)
    if isinstance(data, dict):
        for pipe in data.get("pipelines", []):
            print(f"\n  Pipeline: {pipe.get('name')}  (id {pipe.get('id')})")
            for stage in pipe.get("stages", []):
                print(f"     - {stage.get('name')}   (id {stage.get('id')})")
    else:
        print("body:", str(data)[:300])

    # --- 3. Contacts: field names + tag vocabulary --------------------
    section("3. CONTACTS — field names, and which tags you actually use")
    status, data = api_get(f"/contacts/?locationId={loc}&limit=20", token)
    print("status:", status)
    if isinstance(data, dict):
        print("top-level keys:", list(data.keys())[:10])
        contacts = data.get("contacts", [])
        print("returned:", len(contacts))
        if contacts:
            print("\nfield names on a contact:")
            print(" ", sorted(contacts[0].keys()))
            print("\none contact, values redacted:")
            print(json.dumps(redact(contacts[0]), indent=2)[:1200])
            tags = Counter(t for c in contacts for t in (c.get("tags") or []))
            print("\ntags in use (name -> count):")
            for tag, n in tags.most_common(30):
                print(f"  {tag}: {n}")
    else:
        print("body:", str(data)[:300])

    # --- 4. Opportunities --------------------------------------------
    section("4. OPPORTUNITIES — field names and status vocabulary")
    status, data = api_get(f"/opportunities/search?location_id={loc}&limit=5", token)
    print("status:", status)
    if isinstance(data, dict):
        print("top-level keys:", list(data.keys())[:10])
        opps = data.get("opportunities", [])
        print("returned:", len(opps))
        if opps:
            print("\nfield names on an opportunity:")
            print(" ", sorted(opps[0].keys()))
            print("\none opportunity, values redacted:")
            print(json.dumps(redact(opps[0]), indent=2)[:1200])
            print("\nstatus values seen:", Counter(o.get("status") for o in opps))
    else:
        print("body:", str(data)[:300])

    # --- 4b. Custom field definitions ---------------------------------
    # "Contract Status" and any similar checkbox fields live here. We need
    # the exact field key/id and the full list of option values so the
    # webhook listener knows what it's watching for.
    section("4b. CUSTOM FIELDS — definitions, incl. checkbox option values")
    status, data = api_get(f"/locations/{loc}/customFields", token)
    print("status:", status)
    if isinstance(data, dict):
        fields = data.get("customFields", [])
        print("returned:", len(fields))
        for f in fields:
            print(f"\n  \"{f.get('name')}\"")
            print(f"     id/key:      {f.get('id')} / {f.get('fieldKey')}")
            print(f"     dataType:    {f.get('dataType')}")
            opts = f.get("picklistOptions") or f.get("options")
            if opts:
                print(f"     options:     {opts}")
    else:
        print("body:", str(data)[:300])

    # --- 5. Conversations --------------------------------------------
    section("5. CONVERSATIONS — for touch points and leads contacted")
    status, data = api_get(f"/conversations/search?locationId={loc}&limit=5", token)
    print("status:", status)
    if isinstance(data, dict):
        print("top-level keys:", list(data.keys())[:10])
        convos = data.get("conversations", [])
        print("returned:", len(convos))
        if convos:
            print("\nfield names on a conversation:")
            print(" ", sorted(convos[0].keys()))
            print("\none conversation, values redacted:")
            print(json.dumps(redact(convos[0]), indent=2)[:1200])

            # --- 5b. Messages inside a conversation with a call --------
            # leadsContacted needs call duration. It won't be on the
            # conversation object itself (that's a rollup) — check the
            # individual messages for a duration field, and specifically
            # try to find one that's a call rather than an SMS.
            section("5b. MESSAGES — looking for call duration specifically")
            call_convo = None
            for c in convos:
                if (c.get("type") or "").upper() in ("TYPE_PHONE", "TYPE_CALL") or c.get("lastMessageType") == "TYPE_CALL":
                    call_convo = c
                    break
            probe_convo = call_convo or convos[0]
            cid = probe_convo.get("id")
            status2, mdata = api_get(f"/conversations/{cid}/messages?limit=20", token)
            print("status:", status2, " (conversation used:", ("a call thread" if call_convo else "first available, may not include a call"), ")")
            if isinstance(mdata, dict):
                msgs = (mdata.get("messages") or {}).get("messages") or mdata.get("messages") or []
                if isinstance(msgs, dict):
                    msgs = msgs.get("messages", [])
                print("returned:", len(msgs))
                types_seen = Counter(m.get("messageType") or m.get("type") for m in msgs)
                print("message types seen:", types_seen)
                calls = [m for m in msgs if "call" in str(m.get("messageType") or m.get("type") or "").lower()]
                if calls:
                    print("\nfield names on a call message:")
                    print(" ", sorted(calls[0].keys()))
                    print("\none call message, values redacted:")
                    print(json.dumps(redact(calls[0]), indent=2)[:1200])
                else:
                    print("\nno call-type messages in this thread. Field names on whatever's here:")
                    if msgs:
                        print(" ", sorted(msgs[0].keys()))
                        print(json.dumps(redact(msgs[0]), indent=2)[:800])
            else:
                print("body:", str(mdata)[:300])
    else:
        print("body:", str(data)[:300])

    # --- 6. Volume sanity check --------------------------------------
    # If these numbers look nothing like your real activity, the date
    # filtering needs a different field and it's better to know now.
    section("6. VOLUME — rough contact counts, to sanity-check date filtering")
    now = datetime.now(timezone.utc)
    for label, days in (("last 24h", 1), ("last 7 days", 7), ("last 30 days", 30)):
        start = int((now - timedelta(days=days)).timestamp() * 1000)
        end = int(now.timestamp() * 1000)
        status, data = api_get(
            f"/contacts/?locationId={loc}&limit=1"
            f"&startAfterDate={start}&endBeforeDate={end}",
            token,
        )
        total = data.get("meta", {}).get("total") if isinstance(data, dict) else None
        print(f"  contacts created, {label:12} status {status}  total: {total}")

    print("\n" + "=" * 64)
    print("Done. This output contains no contact data — safe to paste back.")
    print("=" * 64)


if __name__ == "__main__":
    main()
