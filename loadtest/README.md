# Load tests (api-factory)

Run from the workstation over Tailscale (k6 off the measured machine). Target: the laptop cluster's prod
(`http://<laptop>:30081`, ≈5 GB / 33M rows of production-like dirty data, `factory seed-volume`).

| File | What |
|---|---|
| `requests.json` | `factory loadgen` (api-factory): per API, requests whose parameters are sampled from the real data |
| `validate.py` | sends each request once, per-API report → `requests.valid.json` (the load mix: only 200s) |
| `mix.js` | k6, constant arrival rate, random request of the mix, tagged per API. `BASE`, `RATE`, `DURATION`, `EXCLUDE`, `TOKEN_FILE` (or `TOKEN`); optional `REQUESTS`, `VUS`, `MAX_VUS` |
| `step.sh` | step load (2 min per rate, `STEP_DURATION`; optional 4th argument: APIs to exclude) until p95 > 1 s, errors > 2 % or dropped iterations: the saturation point; results in `results/step-<time>/` |
| `reports/` | one report per test (template: conditions, stop conditions, results, findings, improvements, not verified) |

```sh
python3 -I loadtest/validate.py http://100.90.245.89:30081 .secrets/laptop/api-factory-prod.token
loadtest/step.sh http://100.90.245.89:30081 .secrets/laptop/api-factory-prod.token "10 20 40 60 80 120"
cd loadtest && k6 run -e BASE=http://100.90.245.89:30081 -e TOKEN_FILE=$PWD/../.secrets/laptop/api-factory-prod.token \
  -e RATE=35 -e DURATION=60m --summary-export results/soak.json mix.js        # soak: ~50 % of saturation
```

Rate targets: there is no real traffic, so not "peak × 3": find the saturation point, soak at ~50 %.
