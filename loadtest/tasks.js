import { check, sleep } from "k6";
import http from "k6/http";
import exec from "k6/execution";
import { Gauge, Rate, Trend } from "k6/metrics";

const baseUrl = (__ENV.BASE_URL || "").replace(/\/+$/, "");
const users = Number(__ENV.VUS || 40);
const cacheMode = __ENV.CACHE_MODE || "off";
const smoke = __ENV.SMOKE === "1";
const scenarioStart = new Gauge("workload_start_utc_ms");
const listCacheHit = new Rate("list_cache_hit");
const listLoadTime = new Trend("list_duration", true);
const jsonHeaders = { "Content-Type": "application/json" };

if (!/^https?:\/\/[^/?#]+$/.test(baseUrl)) {
  throw new Error("Set BASE_URL to the origin of your Tasks API (scheme + host + optional port)");
}
if (!Number.isInteger(users) || users < 1 || users > 120) {
  throw new Error("VUS must be an integer from 1 to 120");
}
if (!["off", "on"].includes(cacheMode)) {
  throw new Error("CACHE_MODE must be off or on");
}

export const options = {
  setupTimeout: "90s",
  discardResponseBodies: true,
  summaryTrendStats: ["p(50)", "p(95)", "p(99)"],
  scenarios: {
    tasks: smoke
      ? { executor: "shared-iterations", vus: 1, iterations: 2, maxDuration: "30s" }
      : {
          executor: "ramping-vus",
          startVUs: 0,
          gracefulRampDown: "10s",
          stages: [
            { duration: "3m", target: users },
            { duration: "5m", target: users },
            { duration: "2m", target: 0 },
          ],
        },
  },
  thresholds: {
    "http_req_failed{scope:workload}": ["rate<0.01"],
    "checks{scope:workload}": ["rate>0.99"],
    "http_reqs{scope:workload}": ["count>0"],
    "http_req_duration{scope:workload}": ["p(95)<2000"],
  },
};

function requireStatus(response, expected, label) {
  if (response.status !== expected) {
    throw new Error(`${label}: expected ${expected}, received ${response.status}`);
  }
}

export function setup() {
  const accounts = [];
  const seed = Date.now();
  for (let i = 0; i < (smoke ? 1 : 8); i += 1) {
    const username = `lab2_${seed}_${i}`;
    const password = `${Math.random().toString(36)}_${Math.random().toString(36)}_12!`;
    const register = http.post(
      `${baseUrl}/auth/register`,
      JSON.stringify({ username, password }),
      { headers: jsonHeaders },
    );
    requireStatus(register, 201, "Register test user");

    const login = http.post(`${baseUrl}/auth/login`, { username, password }, { responseType: "text" });
    requireStatus(login, 200, "Log in test user");
    const headers = { ...jsonHeaders, Authorization: `Bearer ${login.json("access_token")}` };
    const fixture = http.post(
      `${baseUrl}/tasks`,
      JSON.stringify({ title: "Lab 2 reference task" }),
      { headers, responseType: "text" },
    );
    requireStatus(fixture, 201, "Create reference task");
    const referenceId = fixture.json("id");
    const complete = http.patch(`${baseUrl}/tasks/${referenceId}`, '{"done":true}', { headers });
    requireStatus(complete, 200, "Complete reference task");

    const probe = http.get(`${baseUrl}/tasks?done=true`, { headers });
    requireStatus(probe, 200, "Probe task list");
    const mode = probe.headers["X-Tasks-Cache"];
    if ((cacheMode === "off" && mode !== "BYPASS") ||
        (cacheMode === "on" && !["HIT", "MISS"].includes(mode))) {
      throw new Error(`Unexpected cache mode ${mode || "(missing)"}; expected CACHE_MODE=${cacheMode}`);
    }
    accounts.push({ headers, referenceId });
  }
  return accounts;
}

export default function (accounts) {
  scenarioStart.add(exec.scenario.startTime);
  const { headers, referenceId } = accounts[(__VU - 1) % accounts.length];
  const scope = { scope: "workload" };
  const params = (name) => ({ headers, tags: { ...scope, name } });

  const created = http.post(
    `${baseUrl}/tasks`,
    JSON.stringify({ title: `Lab 2 VU ${__VU}, iteration ${__ITER}` }),
    { ...params("POST /tasks"), responseType: "text" },
  );
  check(created, { "task created": (r) => r.status === 201 }, scope);
  const newId = created.status === 201 ? created.json("id") : referenceId;

  for (let i = 0; i < 6; i += 1) {
    const list = http.get(`${baseUrl}/tasks?done=true`, params("GET /tasks?done=true"));
    const state = list.headers["X-Tasks-Cache"];
    check(list, {
      "list returned": (r) => r.status === 200,
      "expected cache mode": () => cacheMode === "off" ? state === "BYPASS" : ["HIT", "MISS"].includes(state),
    }, scope);
    if (list.status === 200) {
      listLoadTime.add(list.timings.duration);
      if (cacheMode === "on") {
        listCacheHit.add(state === "HIT");
      }
    }
  }

  for (const id of [newId, referenceId]) {
    const task = http.get(`${baseUrl}/tasks/${id}`, params("GET /tasks/:id"));
    check(task, { "task detail returned": (r) => r.status === 200 }, scope);
  }
  const owner = http.get(`${baseUrl}/auth/me`, params("GET /auth/me"));
  check(owner, { "owner returned": (r) => r.status === 200 }, scope);
  sleep(0.2);
}

export function handleSummary(data) {
  function metric(name, statistic) {
    return data.metrics[name]?.values[statistic] ?? null;
  }

  const latency = "http_req_duration{scope:workload}";
  const start = metric("workload_start_utc_ms", "value");
  const end = Date.now();
  const duration = start === null ? null : (end - start) / 1000;
  const requests = metric("http_reqs{scope:workload}", "count");
  const summary = {
    cache_mode: cacheMode,
    vusers: smoke ? 1 : users,
    smoke,
    scenario_started_utc: start === null ? null : new Date(start).toISOString(),
    scenario_finished_utc: new Date(end).toISOString(),
    test_duration_seconds: duration,
    requests,
    error_rate: metric("http_req_failed{scope:workload}", "rate"),
    latency_p50_ms: metric(latency, "p(50)"),
    latency_p95_ms: metric(latency, "p(95)"),
    latency_p99_ms: metric(latency, "p(99)"),
    list_latency_p95_ms: metric("list_duration", "p(95)"),
    requests_per_second: duration > 0 && requests !== null ? requests / duration : null,
    list_hit_rate: metric("list_cache_hit", "rate"),
    list_hits: metric("list_cache_hit", "passes"),
    list_misses: metric("list_cache_hit", "fails"),
    checks_pass_rate: metric("checks{scope:workload}", "rate"),
  };
  const result = JSON.stringify(summary, null, 2) + "\n";
  return { stdout: result, [`loadtest/${smoke ? "smoke-" : ""}results-${cacheMode}.json`]: result };
}
