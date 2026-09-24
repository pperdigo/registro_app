// Testes HTTP da API. Os que tocam o banco exigem DATABASE_URL com as
// migrations aplicadas (no CI, um PostgreSQL descartável); sem ela, são pulados.
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

process.env.CORS_ORIGIN = 'http://site.example';
const app = require('../src/app');
const pool = require('../src/db');

let server;
let base;

before(async () => {
  server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  server.close();
  await pool.end();
});

const post = (path, body) =>
  fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

test('health responde ok', async () => {
  const res = await fetch(`${base}/api/health`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true });
});

test('CORS libera só a origem configurada', async () => {
  const ok = await fetch(`${base}/api/health`, { method: 'OPTIONS', headers: { Origin: 'http://site.example' } });
  assert.equal(ok.status, 204);
  assert.equal(ok.headers.get('access-control-allow-origin'), 'http://site.example');

  const other = await fetch(`${base}/api/health`, { headers: { Origin: 'http://evil.example' } });
  assert.equal(other.headers.get('access-control-allow-origin'), null);
});

test('register valida campos antes de tocar o banco', async () => {
  assert.equal((await post('/api/register', { email: 'a@b.co' })).status, 400);
  assert.equal((await post('/api/register', { name: 'A', email: 'invalido', password: '123456' })).status, 400);
  assert.equal((await post('/api/register', { name: 'A', email: 'a@b.co', password: '123' })).status, 400);
});

test('me exige token válido', async () => {
  assert.equal((await fetch(`${base}/api/me`)).status, 401);
  const res = await fetch(`${base}/api/me`, { headers: { Authorization: 'Bearer xyz' } });
  assert.equal(res.status, 401);
});

test('fluxo completo persiste no banco', { skip: !process.env.DATABASE_URL }, async () => {
  const email = `user${Date.now()}@teste.dev`;
  const reg = await post('/api/register', { name: 'Teste', email, password: 'segredo1' });
  assert.equal(reg.status, 201);
  const { token, user } = await reg.json();
  assert.equal(user.email, email);

  assert.equal((await post('/api/register', { name: 'Outro', email, password: 'segredo1' })).status, 409);
  assert.equal((await post('/api/login', { email, password: 'errada' })).status, 401);

  const login = await post('/api/login', { email: email.toUpperCase(), password: 'segredo1' });
  assert.equal(login.status, 200);
  assert.equal((await login.json()).user.password_hash, undefined);

  const me = await fetch(`${base}/api/me`, { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(me.status, 200);
  assert.equal((await me.json()).user.email, email);

  const { rows } = await pool.query('SELECT password_hash FROM users WHERE email = $1', [email]);
  assert.notEqual(rows[0].password_hash, 'segredo1');
});
