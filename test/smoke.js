'use strict';

const assert = require('assert');
const http = require('http');
const {
  extractSystemPrompt,
  computeSignature,
  rewriteModel,
  verifySignature,
  OhMyAgentError,
} = require('../lib/ohmyagent');
const { createServer } = require('../server');

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`  ok  ${name}`);
  } catch (err) {
    failures += 1;
    console.log(`FAIL  ${name}: ${err.message}`);
  }
}

console.log('extractSystemPrompt');
check('top-level system string', () => {
  assert.strictEqual(extractSystemPrompt({ system: 'sys-a' }), 'sys-a');
});
check('top-level system array -> first block only', () => {
  assert.strictEqual(extractSystemPrompt({ system: [{ text: 's1' }, { text: 's2' }] }), 's1');
});
check('instructions string', () => {
  assert.strictEqual(extractSystemPrompt({ instructions: 'inst' }), 'inst');
});
check('instructions array -> joined with \\n', () => {
  assert.strictEqual(extractSystemPrompt({ instructions: [{ text: 'a' }, { text: 'b' }] }), 'a\nb');
});
check('messages role=system string content', () => {
  const body = { messages: [{ role: 'user', content: 'u' }, { role: 'system', content: 'sys-msg' }] };
  assert.strictEqual(extractSystemPrompt(body), 'sys-msg');
});
check('messages role=system array content -> joined', () => {
  const body = { messages: [{ role: 'system', content: [{ text: 'x' }, { text: 'y' }] }] };
  assert.strictEqual(extractSystemPrompt(body), 'x\ny');
});
check('input role=developer', () => {
  const body = { input: [{ role: 'developer', content: 'dev-msg' }] };
  assert.strictEqual(extractSystemPrompt(body), 'dev-msg');
});
check('input role=system', () => {
  const body = { input: [{ role: 'system', content: 'in-sys' }] };
  assert.strictEqual(extractSystemPrompt(body), 'in-sys');
});
check('system beats messages', () => {
  const body = { system: 'top', messages: [{ role: 'system', content: 'nested' }] };
  assert.strictEqual(extractSystemPrompt(body), 'top');
});
check('throws when no system prompt', () => {
  assert.throws(() => extractSystemPrompt({ messages: [{ role: 'user', content: 'hi' }] }), OhMyAgentError);
});

console.log('signature');
check('HMAC-SHA256 known vector', () => {
  const sig = computeSignature('key', 'The quick brown fox jumps over the lazy dog');
  assert.strictEqual(sig, 'v1=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8');
});
check('verifySignature accepts correct sig', () => {
  const prompt = 'hello';
  const sig = computeSignature('secret', prompt);
  assert.strictEqual(verifySignature('secret', sig, prompt), true);
});
check('verifySignature rejects wrong secret', () => {
  const sig = computeSignature('wrong', 'hello');
  assert.throws(() => verifySignature('secret', sig, 'hello'), /signature mismatch/);
});
check('verifySignature rejects malformed prefix', () => {
  assert.throws(() => verifySignature('s', 'sha256=abc', 'p'), /unsupported signature/);
});

console.log('rewriteModel');
check('rewrite sets model field', () => {
  const body = { model: 'any-name', messages: [] };
  assert.deepStrictEqual(rewriteModel(body, 'real-model-name'), { model: 'real-model-name', messages: [] });
});

console.log('server boot');
function request(port, pathname) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: pathname, method: 'GET' }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    req.end();
  });
}

check('healthz responds', async () => {
  const server = createServer({ port: 0, host: '127.0.0.1', apiKey: 'k', signingSecret: 's', modelName: 'm' });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const addr = server.address();
  const health = await request(addr.port, '/healthz');
  assert.strictEqual(health.status, 200);
  assert.ok(health.body.includes('modelName'));
  const missing = await request(addr.port, '/v1/chat/completions');
  assert.strictEqual(missing.status, 404);
  server.close();
});

console.log('models list');
check('GET /v1/models returns configured models', async () => {
  const server = createServer({
    port: 0,
    host: '127.0.0.1',
    apiKey: 'k',
    signingSecret: 's',
    models: [
      { id: 'monkeycode-basic/qwen3.5-plus', name: 'Qwen 3.5 Plus' },
      { id: 'monkeycode-basic/deepseek-v4-flash', name: 'DeepSeek v4 Flash' },
    ],
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const addr = server.address();
  const models = await request(addr.port, '/v1/models');
  assert.strictEqual(models.status, 200);
  const parsed = JSON.parse(models.body);
  assert.strictEqual(parsed.object, 'list');
  assert.strictEqual(parsed.data.length, 2);
  assert.strictEqual(parsed.data[0].id, 'monkeycode-basic/qwen3.5-plus');
  assert.strictEqual(parsed.data[0].object, 'model');
  server.close();
});

check('GET /v1/models returns empty list when none configured', async () => {
  const server = createServer({ port: 0, host: '127.0.0.1', apiKey: 'k', signingSecret: 's', modelName: null });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const addr = server.address();
  const models = await request(addr.port, '/v1/models');
  assert.strictEqual(models.status, 200);
  const parsed = JSON.parse(models.body);
  assert.strictEqual(parsed.object, 'list');
  assert.strictEqual(parsed.data.length, 0);
  server.close();
});

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
