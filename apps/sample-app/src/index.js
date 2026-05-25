const express = require('express');
const promClient = require('prom-client');

const app = express();
const startedAt = Date.now();

// --- Prometheus instrumentation ----------------------------------------------
// A per-app Registry keeps OUR metrics scoped — important once more apps share
// a cluster, so prom-client's defaults from app A don't bleed into app B.
const register = new promClient.Registry();
register.setDefaultLabels({ app: 'globalretail-sample-app' });

// The default collectors expose process-level signals for free: CPU time, RSS,
// heap usage, event-loop lag, GC pauses, open FDs, etc. — about 15 metrics
// that already tell a real production-grade story without any per-route code.
promClient.collectDefaultMetrics({ register });

// RED-style histogram for HTTP requests. Buckets tuned for a fast in-cluster
// service; if your p99 lands in the last bucket (5s), widen them.
const httpRequestDuration = new promClient.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds.',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

// App-specific counter, mostly to demonstrate custom metrics + give Grafana
// something app-specific to graph.
const healthChecksTotal = new promClient.Counter({
  name: 'health_checks_total',
  help: 'Number of /health responses returned.',
  registers: [register],
});

// Middleware: time every request. `req.route?.path` collapses ?query=... into
// the route template, keeping label cardinality bounded — critical for
// Prometheus (each unique label set is a new time series).
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    end({
      method: req.method,
      route: req.route?.path || req.path,
      status: String(res.statusCode),
    });
  });
  next();
});

// --- Routes ------------------------------------------------------------------
app.get('/health', (_req, res) => {
  healthChecksTotal.inc();
  res.json({
    status: 'ok',
    uptimeSeconds: Math.round((Date.now() - startedAt) / 1000),
  });
});

app.get('/version', (_req, res) => {
  res.json({
    name: 'globalretail-sample-app',
    version: process.env.APP_VERSION || 'dev',
    commit: process.env.APP_COMMIT || 'unknown',
  });
});

app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

module.exports = app;

/* istanbul ignore next -- entry-point block, not exercised in unit tests */
if (require.main === module) {
  const port = Number(process.env.PORT) || 3000;
  app.listen(port, () => {
    console.log(`globalretail-sample-app listening on :${port}`);
  });
}
