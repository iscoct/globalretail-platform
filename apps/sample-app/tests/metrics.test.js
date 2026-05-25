const request = require('supertest');
const app = require('../src/index');

describe('GET /metrics', () => {
  it('returns 200 with Prometheus text/plain format', async () => {
    // Warm up the counters by hitting /health a couple of times before
    // scraping. Without this, `health_checks_total` is 0 and prom-client
    // may not emit the line at all (depends on counter semantics — better
    // to test the realistic case where it has data).
    await request(app).get('/health');
    await request(app).get('/health');

    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/text\/plain/);
  });

  it('exposes default process-level metrics (CPU, heap, event loop)', async () => {
    const res = await request(app).get('/metrics');
    expect(res.text).toMatch(/process_cpu_seconds_total/);
    expect(res.text).toMatch(/nodejs_heap_size_total_bytes/);
    expect(res.text).toMatch(/nodejs_eventloop_lag_seconds/);
  });

  it('exposes the custom health-check counter labelled with the app name', async () => {
    await request(app).get('/health');
    const res = await request(app).get('/metrics');
    expect(res.text).toMatch(/health_checks_total\{app="globalretail-sample-app"\}\s+\d+/);
  });

  it('exposes the http_request_duration histogram after a few requests', async () => {
    await request(app).get('/health');
    await request(app).get('/version');
    const res = await request(app).get('/metrics');
    expect(res.text).toMatch(/http_request_duration_seconds_bucket/);
    expect(res.text).toMatch(/http_request_duration_seconds_count/);
  });
});
