import http from 'node:http';
import { readFile } from 'node:fs/promises';
const files = new Map([['/', ['index.html', 'text/html; charset=utf-8']], ['/app.js', ['app.js', 'text/javascript; charset=utf-8']], ['/style.css', ['style.css', 'text/css; charset=utf-8']]]);
files.set('/timeline', ['timeline/index.html', 'text/html; charset=utf-8']);
files.set('/timeline/app.js', ['timeline/app.js', 'text/javascript; charset=utf-8']);
files.set('/approvals', ['approvals/index.html', 'text/html; charset=utf-8']);
files.set('/approvals/app.js', ['approvals/app.js', 'text/javascript; charset=utf-8']);
files.set('/import', ['import/index.html', 'text/html; charset=utf-8']);
files.set('/import/app.js', ['import/app.js', 'text/javascript; charset=utf-8']);
files.set('/questions', ['questions/index.html', 'text/html; charset=utf-8']);
files.set('/questions/app.js', ['questions/app.js', 'text/javascript; charset=utf-8']);
files.set('/questions/protocol.js', ['questions/protocol.js', 'text/javascript; charset=utf-8']);
const server = http.createServer(async (request, response) => {
  const entry = files.get(request.url);
  const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' http://127.0.0.1:* http://localhost:*; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'" };
  if (request.method !== 'GET' || !entry) { response.writeHead(404, headers); response.end(); return; }
  try { const bytes = await readFile(new URL(`dist/${entry[0]}`, import.meta.url)); response.writeHead(200, { ...headers, 'Content-Type': entry[1] }); response.end(bytes); }
  catch { response.writeHead(503, headers); response.end('Build the static UI first.'); }
});
const port = Number(process.env.SQUIDRA_WEB_PORT ?? '3000');
if (!Number.isInteger(port) || port < 0 || port > 65535) throw Error('Invalid UI port');
server.listen(port, '127.0.0.1', () => { const address = server.address(); console.log('SQUIDRA web listening 127.0.0.1:' + address.port); });
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close());
