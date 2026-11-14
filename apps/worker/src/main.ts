import http from "node:http";

/**
 * Meesam worker — job-table runner (Data Architecture 14.11).
 * Step 2 scope: boot, expose /health, poll loop scaffold. Job handlers arrive in Step 3
 * (timers and notifications 3.6, pricing 3.7, watch fetchers/extraction/alerts 3.8, prospects 3.9).
 */
const port = Number(process.env.PORT ?? 8080);
const pollMs = Number(process.env.WORKER_POLL_MS ?? 5000);
let ticks = 0;
let stopping = false;

async function tick(): Promise<void> {
  // SELECT ... FOR UPDATE SKIP LOCKED against the jobs table lands with the schema (Step 3.1).
  ticks += 1;
}

async function loop(): Promise<void> {
  while (!stopping) {
    try {
      await tick();
    } catch (err) {
      console.error(JSON.stringify({ level: "error", at: "worker.tick", message: (err as Error).message }));
    }
    await new Promise((r) => setTimeout(r, pollMs));
  }
}

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: "ok", service: "worker", ticks, environment: process.env.RAILWAY_ENVIRONMENT_NAME ?? "local" }));
    return;
  }
  res.writeHead(404).end();
});

server.listen(port, () => console.log(JSON.stringify({ level: "info", at: "worker.start", port, pollMs })));
void loop();

for (const sig of ["SIGTERM", "SIGINT"] as const) {
  process.on(sig, () => {
    stopping = true;
    server.close(() => process.exit(0));
  });
}
