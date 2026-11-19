// Production-like request mix against api-factory: every request of requests.valid.json (factory loadgen, sampled
// from the real data, validated by validate.py), picked at random, at a constant arrival rate.
//   k6 run -e BASE=http://<host>:30081 -e TOKEN_FILE=$PWD/../.secrets/laptop/api-factory-prod.token \
//          -e RATE=50 -e DURATION=2m [-e EXCLUDE=api1,api2] loadtest/mix.js
// One script for every mode: smoke (low RATE, short), step load (step.sh: RATE per step), soak (RATE ≈ 50-60% of the
// saturation point, DURATION 1h). Requests are tagged with the API: per-API latency in the summary.
import http from "k6/http";
import { check } from "k6";
import { SharedArray } from "k6/data";

const exclude = (__ENV.EXCLUDE || "").split(",").filter(Boolean);
const reqs = new SharedArray("requests", () =>
  JSON.parse(open(__ENV.REQUESTS || "./requests.valid.json")).filter((r) => !exclude.includes(r.api)));

export const options = {
  scenarios: {
    mix: {
      executor: "constant-arrival-rate",
      rate: Number(__ENV.RATE || 20),
      timeUnit: "1s",
      duration: __ENV.DURATION || "2m",
      preAllocatedVUs: Number(__ENV.VUS || 100),
      maxVUs: Number(__ENV.MAX_VUS || 400),
    },
  },
  summaryTrendStats: ["avg", "med", "p(90)", "p(95)", "p(99)", "max"],
  thresholds: { http_req_failed: ["rate<0.01"], http_req_duration: ["p(95)<1000"] },
};

// TOKEN_FILE (preferred: the token never appears in the process list) or TOKEN
const token = __ENV.TOKEN_FILE ? open(__ENV.TOKEN_FILE).trim() : __ENV.TOKEN;
const headers = { "Content-Type": "application/json", Authorization: `Bearer ${token}` };

export default function () {
  const r = reqs[Math.floor(Math.random() * reqs.length)];
  const res = http.post(__ENV.BASE + r.path, JSON.stringify(r.body), { headers, tags: { api: r.api }, timeout: "10s" });
  check(res, { "200": (x) => x.status === 200 });
}
