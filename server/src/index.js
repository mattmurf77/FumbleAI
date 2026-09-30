import { createServer } from 'node:http';
import { createApp } from './app.js';

const port = Number(process.env.PORT) || 10000; // Render sets PORT.
const app = createApp();
const server = createServer(app);

server.requestTimeout = 45_000;
server.listen(port, '0.0.0.0', () => {
  const keyNote = process.env.HOME_API_KEY ? 'X-Home-Key required on /v1/*' : 'no HOME_API_KEY set (open)';
  const adminNote = process.env.HOME_ADMIN_KEY ? 'admin feedback pages on' : 'no HOME_ADMIN_KEY (admin pages off)';
  console.log(`home-server listening on :${port} (${keyNote}; ${adminNote})`);
  // Creates the feedback table if it's missing (CREATE TABLE IF NOT EXISTS).
  app.initFeedback().then((line) => console.log(line));
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
