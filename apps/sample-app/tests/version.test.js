const fs = require('fs');
const os = require('os');
const path = require('path');
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

  it('returns welcome_message: null when WELCOME_MESSAGE_FILE is not set', async () => {
    delete process.env.WELCOME_MESSAGE_FILE;
    const res = await request(app).get('/version');
    expect(res.body.welcome_message).toBe(null);
  });

  it('returns welcome_message: null when WELCOME_MESSAGE_FILE points at a non-existent file', async () => {
    process.env.WELCOME_MESSAGE_FILE = '/nonexistent/welcome-message';
    const res = await request(app).get('/version');
    expect(res.body.welcome_message).toBe(null);
    delete process.env.WELCOME_MESSAGE_FILE;
  });

  it('returns the file contents (trimmed) when the file exists', async () => {
    // Use mkdtempSync (kernel-randomised suffix) instead of a Date.now()-derived
    // path. Predictable temp filenames are a classic race-condition vector
    // (CodeQL js/insecure-temporary-file). mkdtemp creates the directory with
    // 0700 perms before returning the name, eliminating the TOCTOU window.
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sample-app-test-'));
    const tmp = path.join(tmpDir, 'welcome-message');
    fs.writeFileSync(tmp, 'hello-from-key-vault-via-workload-identity\n');
    process.env.WELCOME_MESSAGE_FILE = tmp;
    try {
      const res = await request(app).get('/version');
      expect(res.body.welcome_message).toBe('hello-from-key-vault-via-workload-identity');
    } finally {
      delete process.env.WELCOME_MESSAGE_FILE;
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
