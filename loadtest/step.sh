#!/usr/bin/env bash
# Step load: constant arrival rate per step (STEP_DURATION each), increasing until the service saturates:
# p95 > 1 s, errors > 2 % or k6 cannot start the requested rate (dropped iterations). The last good step ≈ capacity.
#   loadtest/step.sh <base-url> <token-file> "20 40 80 ..." [exclude]
set -euo pipefail
base=$1 tokfile=$(cd "$(dirname "$2")" && pwd)/$(basename "$2") rates=$3 exclude=${4:-}   # absolute: we cd below
cd "$(dirname "$0")"
out=results/step-$(date +%Y%m%d-%H%M); mkdir -p "$out"
printf '%6s %8s %8s %8s %8s %8s %7s\n' rate actual p50ms p95ms p99ms errors dropped | tee "$out/summary.txt"
for r in $rates; do
  k6 run -q -e BASE="$base" -e TOKEN_FILE="$tokfile" -e RATE="$r" -e DURATION="${STEP_DURATION:-2m}" -e EXCLUDE="$exclude" \
    --summary-export "$out/rate-$r.json" mix.js >/dev/null 2>&1 || true
  python3 -I - "$out/rate-$r.json" "$r" <<'PY' | tee -a "$out/summary.txt"
import json, sys
m = json.load(open(sys.argv[1]))["metrics"]
d = m["http_req_duration"]; f = m["http_req_failed"]
dropped = m.get("dropped_iterations", {}).get("count", 0)
print(f'{sys.argv[2]:>6} {m["http_reqs"]["rate"]:8.1f} {d["med"]:8.1f} {d["p(95)"]:8.1f} {d["p(99)"]:8.1f} {f["value"]*100:7.2f}% {dropped:7.0f}')
PY
  last=$(tail -1 "$out/summary.txt")
  read -r _ _ _ p95 _ err dropped <<<"$last"
  if awk -v p="$p95" -v e="${err%\%}" -v d="$dropped" 'BEGIN{exit !(p>1000 || e>2 || d>0)}'; then echo "saturated at $r rps"; break; fi
done
echo "results: $out"
