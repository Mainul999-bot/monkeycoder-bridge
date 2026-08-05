'use strict';

const http = require('http');
const path = require('path');
const fs = require('fs');
const { URL } = require('url');
const { SIGNATURE_HEADER, extractSystemPrompt, computeSignature, rewriteModel } = require('./lib/ohmyagent');

const DEFAULT_PORT = 8787;
const DEFAULT_UPSTREAM = 'https://monkeycode-ai.net';

const ALLOWED_PATHS = new Map([
  ['/v1/chat/completions', '/v1/chat/completions'],
  ['/v1/responses', '/v1/responses'],
  ['/v1/messages', '/v1/messages'],
]);

function loadConfig(configPath) {
  const file = configPath || process.env.MONKEYCODE_BRIDGE_CONFIG || path.join(__dirname, 'config.json');
  if (!fs.existsSync(file)) {
    throw new Error(`Config file not found: ${file}. Copy config.example.json to config.json and fill it in.`);
  }
  const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
  const port = Number(cfg.port ?? DEFAULT_PORT);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error(`Invalid port in config: ${cfg.port}`);
  }
  const host = cfg.host || '127.0.0.1';
  let upstream = cfg.upstreamBaseUrl || DEFAULT_UPSTREAM;
  upstream = upstream.replace(/\/+$/, '');
  if (!/^https?:\/\//.test(upstream)) {
    throw new Error(`Invalid upstreamBaseUrl in config: ${cfg.upstreamBaseUrl}`);
  }
  if (!cfg.apiKey || typeof cfg.apiKey !== 'string') {
    throw new Error('Missing "apiKey" (your OhMyAgent API key) in config.');
  }
  if (!cfg.signingSecret || typeof cfg.signingSecret !== 'string') {
    throw new Error('Missing "signingSecret" in config.');
  }
  const modelName = typeof cfg.modelName === 'string' && cfg.modelName.trim() !== '' ? cfg.modelName.trim() : null;

  let models = [];
  if (Array.isArray(cfg.models)) {
    models = cfg.models
      .filter((m) => m && typeof m.id === 'string' && m.id.trim() !== '')
      .map((m) => ({ id: m.id.trim(), name: typeof m.name === 'string' && m.name.trim() !== '' ? m.name.trim() : m.id.trim() }));
  } else if (modelName) {
    models = [{ id: modelName, name: modelName }];
  }

  return { port, host, upstream, apiKey: cfg.apiKey, signingSecret: cfg.signingSecret, modelName, models };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const LOG_FILE = path.join(__dirname, 'bridge.log');

function log(level, msg, extra) {
  const line = extra && Object.keys(extra).length ? `${msg} ${JSON.stringify(extra)}` : msg;
  const ts = new Date().toISOString();
  const out = `[bridge] ${ts} ${level.toUpperCase()} ${line}`;
  if (level === 'error') {
    console.error(out);
  } else {
    console.log(out);
  }
  try {
    fs.appendFileSync(LOG_FILE, `${ts} ${level.toUpperCase()} ${line}\n`);
  } catch (_) {}
}

function createServer(config) {
  const cfg = config || {};
  const port = cfg.port || DEFAULT_PORT;
  const host = cfg.host || '127.0.0.1';
  const upstream = (cfg.upstreamBaseUrl || DEFAULT_UPSTREAM).replace(/\/+$/, '');
  const apiKey = cfg.apiKey;
  const signingSecret = cfg.signingSecret;
  const modelName = cfg.modelName;

  return http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    log('info', 'request', { method: req.method, pathname: url.pathname, search: url.search });

    if (req.method === 'GET' && url.pathname === '/healthz') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, upstream, modelName }));
      return;
    }

    if (req.method === 'GET' && url.pathname === '/v1/models') {
      const data = cfg.models && cfg.models.length
        ? cfg.models.map((m) => ({
            id: m.id,
            object: 'model',
            created: 0,
            owned_by: 'monkeycode',
          }))
        : [];
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ object: 'list', data }));
      return;
    }

    const upstreamPath = ALLOWED_PATHS.get(url.pathname);
    if (!upstreamPath) {
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('Not Found');
      return;
    }
    if (req.method !== 'POST') {
      res.writeHead(405, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('Method Not Allowed');
      return;
    }

    let rawBody;
    try {
      rawBody = await readBody(req);
    } catch (err) {
      log('error', 'read request body failed', { error: String(err && err.message || err) });
      res.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('Bad Request');
      return;
    }

    let bodyObj;
    try {
      bodyObj = rawBody.length ? JSON.parse(rawBody.toString('utf8')) : {};
    } catch (err) {
      log('error', 'invalid JSON body');
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { message: 'request body is not valid JSON' } }));
      return;
    }

    let prompt;
    try {
      prompt = extractSystemPrompt(bodyObj);
    } catch (err) {
      log('error', 'could not extract system prompt', { error: String(err && err.message || err) });
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { message: `cannot build OhMyAgent signature: ${err.message}` } }));
      return;
    }

    const signature = computeSignature(signingSecret, prompt);
    const body = modelName ? rewriteModel(bodyObj, modelName) : bodyObj;
    const outgoingBody = JSON.stringify(body);

    const reqHeaders = {
      'content-type': req.headers['content-type'] || 'application/json',
      'accept': req.headers['accept'] || 'application/json, text/event-stream',
      'x-api-key': apiKey,
      [SIGNATURE_HEADER]: signature,
    };
    const forwardedHeaders = ['authorization'];
    for (const h of forwardedHeaders) {
      if (req.headers[h]) reqHeaders[h] = req.headers[h];
    }

    const outUrl = `${upstream}${upstreamPath}${url.search || ''}`;
    const controller = new AbortController();
    req.on('close', () => controller.abort());

    let upstreamRes;
    try {
      upstreamRes = await fetch(outUrl, {
        method: 'POST',
        headers: reqHeaders,
        body: outgoingBody,
        signal: controller.signal,
        duplex: 'half',
      });
    } catch (err) {
      log('error', 'upstream request failed', { url: outUrl, error: String(err && err.message || err) });
      res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('连接上游模型失败，请检查模型配置，或重试');
      return;
    }

    res.writeHead(upstreamRes.status, {
      'content-type': upstreamRes.headers.get('content-type') || 'application/json',
    });

    if (upstreamRes.body) {
      const { Readable } = require('stream');
      const stream = Readable.fromWeb(upstreamRes.body);
      stream.on('error', () => res.destroy());
      stream.pipe(res);
    } else {
      res.end();
    }
  });
}

function main() {
  let cfg;
  try {
    cfg = loadConfig();
  } catch (err) {
    console.error(`[bridge] FATAL ${err.message}`);
    process.exit(1);
  }
  const server = createServer(cfg);
  server.listen(cfg.port, cfg.host, () => {
    log('info', `MonkeyCoder Bridge listening on http://${cfg.host}:${cfg.port}`);
    log('info', `Forwarding to upstream ${cfg.upstream}`);
    if (cfg.modelName) {
      log('info', `Forcing model "${cfg.modelName}" on every request`);
    } else {
      log('info', 'modelName not set: passing through client model names (multi-model mode)');
    }
  });
}

if (require.main === module) {
  main();
}

module.exports = { createServer, loadConfig };
