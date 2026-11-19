#!/usr/bin/env python3
"""Send every request of requests.json once (16 concurrent) and report per API: OK, with data, slowest, top error.
Writes requests.valid.json: only the requests that returned 200 (the load mix). Usage:
  python3 -I loadtest/validate.py <base-url> <token-file> [requests.json]"""
import collections, concurrent.futures, json, sys, time, urllib.request, urllib.error

base, tokfile = sys.argv[1], sys.argv[2]
src = sys.argv[3] if len(sys.argv) > 3 else "loadtest/requests.json"
reqs = json.load(open(src))
tok = open(tokfile).read().strip()

def call(r):
    req = urllib.request.Request(base + r["path"], data=json.dumps(r["body"]).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + tok})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            b, code = json.loads(resp.read() or b"{}"), 200
    except urllib.error.HTTPError as e:
        b, code = json.loads(e.read() or b"{}"), e.code
    except Exception as e:
        return r, -1, str(e)[:60], False, time.time() - t
    data = any(isinstance(v, list) and v for v in b.values()) or any(not isinstance(v, list) for v in b.values())
    return r, code, (b.get("message", "")[:70] if code != 200 else ""), data, time.time() - t

with concurrent.futures.ThreadPoolExecutor(16) as ex:
    res = list(ex.map(call, reqs))
by = collections.defaultdict(list)
for r, c, m, d, dt in res:
    by[r["api"]].append((c, m, d, dt))
attention = 0
for a in sorted(by):
    xs = by[a]
    ok = sum(c == 200 for c, *_ in xs)
    data = sum(c == 200 and d for c, _, d, _ in xs)
    top = collections.Counter(m for c, m, *_ in xs if c != 200).most_common(1)
    flag = "" if ok >= len(xs) * 0.8 and data >= len(xs) // 2 else "  <--"
    attention += bool(flag)
    print(f"{a:45} ok {ok:2}/{len(xs)}  data {data:2}  max {max(x[3] for x in xs) * 1000:6.0f}ms {top[0] if top else ''}{flag}")
valid = [r for r, c, *_ in res if c == 200]
json.dump(valid, open(src.replace(".json", ".valid.json"), "w"), indent=1)
print(f"APIs needing attention: {attention}; {len(valid)}/{len(reqs)} requests valid → {src.replace('.json', '.valid.json')}")
