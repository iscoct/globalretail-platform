const request = require('supertest');
const app = require('../src/index');

describe('GET /version', () => {
  it('returns 200 with app metadata', async () => {
    const res = await request(app).get('/version');
    expect(res.status).toBe(200);
    expect(res.body.name).toBe('globalretail-sample-app');
    expect(typeof res.body.version).toBe('string');
    expect(typeof res.body.commit).toBe('string');
  });

  it('reflects APP_VERSION env var when set', async () => {
    process.env.APP_VERSION = '1.2.3';
    const res = await request(app).get('/version');
    expect(res.body.version).toBe('1.2.3');
    delete process.env.APP_VERSION;
  });
});