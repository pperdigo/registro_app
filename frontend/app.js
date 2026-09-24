const TOKEN_KEY = 'token';
const APP_CONFIG = window.APP_CONFIG || {};
const API_BASE = (APP_CONFIG.apiBaseUrl || '').replace(/\/$/, '');

const $ = (sel) => document.querySelector(sel);
const loginForm = $('#login-form');
const registerForm = $('#register-form');
const message = $('#message');
if (APP_CONFIG.version) $('#app-version').textContent = APP_CONFIG.version;

function showMessage(text, type = 'error') {
  message.textContent = text;
  message.className = `message ${type}`;
}

async function api(path, options = {}) {
  const token = localStorage.getItem(TOKEN_KEY);
  const res = await fetch(`${API_BASE}/api${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || 'Erro na requisição');
  return data;
}

function formData(form) {
  return Object.fromEntries(new FormData(form));
}

function switchTab(tab) {
  document.querySelectorAll('.tab').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
  loginForm.classList.toggle('hidden', tab !== 'login');
  registerForm.classList.toggle('hidden', tab !== 'register');
  showMessage('');
}

function showProfile(user) {
  $('#profile-name').textContent = user.name;
  $('#profile-email').textContent = user.email;
  $('#profile-created').textContent = new Date(user.created_at).toLocaleDateString('pt-BR');
  $('#auth-view').classList.add('hidden');
  $('#profile-view').classList.remove('hidden');
}

function showAuth() {
  $('#auth-view').classList.remove('hidden');
  $('#profile-view').classList.add('hidden');
}

document.querySelectorAll('.tab').forEach((b) => b.addEventListener('click', () => switchTab(b.dataset.tab)));

loginForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  try {
    const { token, user } = await api('/login', {
      method: 'POST',
      body: JSON.stringify(formData(loginForm)),
    });
    localStorage.setItem(TOKEN_KEY, token);
    loginForm.reset();
    showProfile(user);
  } catch (err) {
    showMessage(err.message);
  }
});

registerForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  try {
    const { token, user } = await api('/register', {
      method: 'POST',
      body: JSON.stringify(formData(registerForm)),
    });
    localStorage.setItem(TOKEN_KEY, token);
    registerForm.reset();
    showProfile(user);
  } catch (err) {
    showMessage(err.message);
  }
});

$('#logout').addEventListener('click', () => {
  localStorage.removeItem(TOKEN_KEY);
  switchTab('login');
  showAuth();
});

// Restaura a sessão se já houver um token válido
(async () => {
  if (!localStorage.getItem(TOKEN_KEY)) return;
  try {
    const { user } = await api('/me');
    showProfile(user);
  } catch {
    localStorage.removeItem(TOKEN_KEY);
  }
})();
