import { check, sleep } from "k6";
import http from "k6/http";
import { setup as setupTasks } from "./tasks.js";

export const setup = setupTasks;
const baseUrl = __ENV.BASE_URL.replace(/\/+$/, "");
const users = Number(__ENV.VUS || 40);

export const options = {
  setupTimeout: "90s",
  discardResponseBodies: true,
  summaryTrendStats: ["p(50)", "p(95)", "p(99)"],
  scenarios: {
    queue: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [{ duration: "3m", target: users }, { duration: "5m", target: users }, { duration: "2m", target: 0 }],
    },
  },
  thresholds: {
    "http_req_duration{scope:queue}": ["p(95)<500"],
    "http_req_failed{scope:queue}": ["rate<0.01"],
    "checks{scope:queue}": ["rate>0.99"],
  },
};

export default function (accounts) {
  const { headers, referenceId } = accounts[(__VU - 1) % accounts.length];
  const tags = { scope: "queue" };
  const job = http.post(
    `${baseUrl}/task-jobs`,
    JSON.stringify({ title: `Lab 2 async VU ${__VU}, iteration ${__ITER}` }),
    { headers, tags },
  );
  check(job, { "job accepted": (response) => response.status === 202 && Boolean(response.headers.Location) }, tags);
  for (let i = 0; i < 6; i += 1) {
    http.get(`${baseUrl}/tasks?done=true`, { headers, tags: { name: "GET /tasks?done=true" } });
  }
  for (let i = 0; i < 2; i += 1) {
    http.get(`${baseUrl}/tasks/${referenceId}`, { headers, tags: { name: "GET /tasks/:id" } });
  }
  http.get(`${baseUrl}/auth/me`, { headers });
  sleep(0.2);
}
