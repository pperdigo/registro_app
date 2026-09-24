// Testes do frontend estático: carrega index.html, config.js e app.js num DOM
// simulado e confere as chamadas à API e a troca de telas.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const FRONT = path.join(__dirname, '..', '..', 'frontend');
const read = (f) => fs.readFileSync(path.join(FRONT, f), 'utf8');

function load({ config, responses = {}, token } = {}) {
  const html = read('index.html').replace(/<script src="[^"]+"><\/script>/g, '');
  const dom = new JSDOM(html, { runScripts: 'outside-only', url: 'http://site.example/' });
  const { window } = dom;
  const calls = [];
  window.fetch = async (url, opts = {}) => {
    calls.push({ url, opts });
    const key = `${opts.method || 'GET'} ${new URL(url, window.location.href).pathname}`;
    const [status, body] = responses[key] || [404, { error: 'não encontrado' }];
    return { ok: status < 400, status, json: async () => body };
  };
  if (token) window.localStorage.setItem('token', token);
  window.eval(config ?? read('config.js'));
  window.eval(read('app.js'));
  return { window, calls, $: (s) => window.document.querySelector(s) };
}

const tick = () => new Promise((r) => setTimeout(r, 0));
const user = { id: 1, name: 'Ana', email: 'ana@teste.dev', created_at: '2026-01-02T00:00:00Z' };

test('config.js local usa caminho relativo (proxy do nginx)', async () => {
  const { window, calls, $ } = load({ responses: { 'POST /api/login': [200, { token: 't1', user }] } });
  $('#login-form [name=email]').value = user.email;
  $('#login-form [name=password]').value = 'segredo1';
  $('#login-form').dispatchEvent(new window.Event('submit', { cancelable: true }));
  await tick();
  assert.equal(calls[0].url, '/api/login');
  assert.deepEqual(JSON.parse(calls[0].opts.body), { email: user.email, password: 'segredo1' });
  assert.equal(window.localStorage.getItem('token'), 't1');
  assert.equal($('#profile-name').textContent, 'Ana');
  assert.ok($('#auth-view').classList.contains('hidden'));
});

test('config.js do deploy aponta para a API e mostra a versão', async () => {
  const config = "window.APP_CONFIG = { apiBaseUrl: 'http://203.0.113.9:3000/', version: 'abc123' };";
  const { window, calls, $ } = load({ config, responses: { 'POST /api/register': [201, { token: 't2', user }] } });
  assert.equal($('#app-version').textContent, 'abc123');
  $('#register-form [name=name]').value = 'Ana';
  $('#register-form [name=email]').value = user.email;
  $('#register-form [name=password]').value = 'segredo1';
  $('#register-form').dispatchEvent(new window.Event('submit', { cancelable: true }));
  await tick();
  assert.equal(calls[0].url, 'http://203.0.113.9:3000/api/register');
  assert.equal($('#profile-email').textContent, user.email);
});

test('erro da API aparece na tela e mantém o login', async () => {
  const { window, $ } = load({ responses: { 'POST /api/login': [401, { error: 'Credenciais inválidas' }] } });
  $('#login-form').dispatchEvent(new window.Event('submit', { cancelable: true }));
  await tick();
  assert.equal($('#message').textContent, 'Credenciais inválidas');
  assert.ok(!$('#auth-view').classList.contains('hidden'));
});

test('restaura a sessão com token salvo e envia Authorization', async () => {
  const { calls, $ } = load({ token: 'salvo', responses: { 'GET /api/me': [200, { user }] } });
  await tick();
  assert.equal(calls[0].opts.headers.Authorization, 'Bearer salvo');
  assert.equal($('#profile-name').textContent, 'Ana');
});
