import { createServer } from 'node:http';
import { createApp } from './app.js';

const port = Number(process.env.PORT) || 10000; // Render sets PORT.
const server = createServer(createApp());

server.requestTimeout = 45_000;
server.listen(port, '0.0.0.0', () => {
  const keyNote = process.env.HOME_API_KEY ? 'X-Home-Key required on /v1/*' : 'no HOME_API_KEY set (open)';
  console.log(`home-server listening on :${port} (${keyNote})`);
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
