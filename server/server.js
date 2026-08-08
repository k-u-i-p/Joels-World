import http from 'http';
import path from 'path';
import { fileURLToPath } from 'url';
import { SessionManager } from './managers/SessionManager.js';
import { setupWebSocket } from './websocket.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const port = process.env.PORT || 80;

// There is no HTTP surface left: the clients are native apps that ship their own assets, so
// every asset URL, the `/api/config` emote list and the EJS game page all went with the web
// client. What remains exists only so `ws` has a server to attach to and so Cloud Run's
// health check gets an answer.
const server = http.createServer((req, res) => {
  if (req.method === 'GET' && (req.url === '/' || req.url === '/healthz')) {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Joel\'s World: WebSocket only.\n');
    return;
  }
  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not found\n');
});

// Sessions still carry play state between connections — the client presents its token on the
// socket handshake and `setupWebSocket` resolves it. What went is the HTTP-side cookie
// middleware, which no native client ever sent a cookie to and which minted an empty session
// file for every asset request that reached it.
const sessionManager = new SessionManager(path.resolve(__dirname, './sessions'));

setupWebSocket(server, sessionManager);

server.listen(port, '0.0.0.0', () => {
  console.log(`Joel's World WebSocket server listening on 0.0.0.0:${port}`);
});
