const express = require('express');

const app = express();
const startedAt = Date.now();

app.get('/health', (_req, res) => {
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

module.exports = app;

/* istanbul ignore next -- entry-point block, not exercised in unit tests */
if (require.main === module) {
  const port = Number(process.env.PORT) || 3000;
  app.listen(port, () => {
    console.log(`globalretail-sample-app listening on :${port}`);
  });
}