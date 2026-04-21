const express = require('express');
const session = require('express-session');
const bcrypt = require('bcryptjs');
const cors = require('cors');
const bodyParser = require('body-parser');
const http = require('http');
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');

// ─────────────────────────────────────────────
// РУЧНОЙ ПАРСЕР .ENV
// ─────────────────────────────────────────────
const envPath = path.join(__dirname, '../.env');
if (fs.existsSync(envPath)) {
  try {
    const envFile = fs.readFileSync(envPath, 'utf8');
    envFile.split('\n').forEach(line => {
      const match = line.match(/^\s*([\w.-]+)\s*=\s*(.*)?\s*$/);
      if (match) {
        process.env[match[1]] = match[2] ? match[2].trim() : '';
      }
    });
  } catch(e) { console.error("Ошибка чтения .env файла", e); }
}

const app = express();
const server = http.createServer(app);

const PORT = process.env.PORT || 3000;
const DATA_FILE = path.join(__dirname, '../data/config.json');
const USERS_FILE = path.join(__dirname, '../data/users.json');

const dataDir = path.join(__dirname, '../data');
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });

process.on('uncaughtException', (err) => console.error('Критическая ошибка:', err));
process.on('unhandledRejection', (err) => console.error('Необработанный промис:', err));

function createDefaultConfig() {
  const defaultConfig = {
    installed: false, domain: '', email: '', serverIp: '', accessMode: '1', panelDomain: '', panelEmail: '', adminPassword: '', proxyUsers: []
  };
  try { fs.writeFileSync(DATA_FILE, JSON.stringify(defaultConfig, null, 2)); } catch(e){}
  return defaultConfig;
}

function loadConfig() {
  if (!fs.existsSync(DATA_FILE)) return createDefaultConfig();
  try {
    const cfg = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
    if (!cfg.proxyUsers) cfg.proxyUsers = [];
    cfg.proxyUsers = cfg.proxyUsers.filter(u => u && typeof u === 'object' && u.username);
    return cfg;
  } catch (err) {
    return createDefaultConfig();
  }
}

function saveConfig(config) {
  try { fs.writeFileSync(DATA_FILE, JSON.stringify(config, null, 2)); } 
  catch (e) { console.error("Ошибка сохранения конфига:", e); }
}

function createDefaultUsers() {
  const initialUser = process.env.ADMIN_USER || 'admin';
  const initialPass = process.env.ADMIN_PASS || 'admin';
  const defaultUsers = {
    [initialUser]: {
      password: bcrypt.hashSync(initialPass, 10),
      role: 'admin'
    }
  };
  try { fs.writeFileSync(USERS_FILE, JSON.stringify(defaultUsers, null, 2)); } catch(e){}
  return defaultUsers;
}

function loadUsers() {
  if (!fs.existsSync(USERS_FILE)) return createDefaultUsers();
  try {
    return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
  } catch (err) {
    return createDefaultUsers();
  }
}

function saveUsers(users) {
  try { fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2)); }
  catch (e) { console.error("Ошибка сохранения юзеров:", e); }
}

app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(session({
  secret: 'naiveproxy-veles-secret-2026',
  resave: false,
  saveUninitialized: false,
  cookie: { secure: false, maxAge: 24 * 60 * 60 * 1000 }
}));
app.use(express.static(path.join(__dirname, '../public')));

function requireAuth(req, res, next) {
  if (req.session && req.session.authenticated) return next();
  res.status(401).json({ error: 'Unauthorized' });
}

// ─────────────────────────────────────────────
//  ROUTES
// ─────────────────────────────────────────────
app.post('/api/login', (req, res) => {
  try {
    const { username, password } = req.body;
    const users = loadUsers();
    const user = users[username];
    if (!user) return res.json({ success: false, message: 'Неверный логин или пароль' });
    if (!bcrypt.compareSync(password, user.password)) {
      return res.json({ success: false, message: 'Неверный логин или пароль' });
    }
    req.session.authenticated = true;
    req.session.username = username;
    req.session.role = user.role;
    res.json({ success: true });
  } catch (e) {
    res.status(500).json({ success: false, message: 'Ошибка сервера' });
  }
});

app.post('/api/logout', (req, res) => {
  req.session.destroy();
  res.json({ success: true });
});

app.get('/api/me', requireAuth, (req, res) => {
  res.json({ username: req.session.username, role: req.session.role });
});

app.get('/api/config', requireAuth, (req, res) => {
  const config = loadConfig();
  res.json({ ...config });
});

app.post('/api/config/change-password', requireAuth, (req, res) => {
  try {
    const { currentPassword, newPassword } = req.body;
    if (!currentPassword || !newPassword) return res.json({ success: false, message: 'Заполните все поля' });
    if (newPassword.length < 6) return res.json({ success: false, message: 'Минимум 6 символов' });
    
    const users = loadUsers();
    const user = users[req.session.username];
    if (!user) return res.json({ success: false, message: 'Пользователь не найден' });
    if (!bcrypt.compareSync(currentPassword, user.password)) {
      return res.json({ success: false, message: 'Текущий пароль неверен' });
    }
    
    users[req.session.username].password = bcrypt.hashSync(newPassword, 10);
    saveUsers(users);
    res.json({ success: true, message: 'Пароль успешно изменён' });
  } catch (e) {
    res.status(500).json({ success: false, message: 'Ошибка сервера' });
  }
});

app.get('/api/proxy-users', requireAuth, (req, res) => {
  const config = loadConfig();
  res.json({ users: config.proxyUsers || [] });
});

app.post('/api/proxy-users/add', requireAuth, (req, res) => {
  try {
    const { username, password, profileName } = req.body;
    if (!username || !password) return res.json({ success: false, message: 'Логин и пароль обязательны' });
    
    const config = loadConfig();
    if (config.proxyUsers.find(u => u.username === username)) {
      return res.json({ success: false, message: 'Пользователь уже существует' });
    }
    
    let safeProfile = profileName ? profileName.replace(/ /g, '_') : `Naive_${username}`;
    config.proxyUsers.push({ username, password, profileName: safeProfile, createdAt: new Date().toISOString() });
    
    saveConfig(config);
    
    if (config.installed) {
      updateCaddyfile(config, () => {
        res.json({ success: true, link: `naive+https://${username}:${password}@${config.domain}:443#${encodeURIComponent(safeProfile)}` });
      });
    } else {
      res.json({ success: true, link: username + ':' + password });
    }
  } catch (e) {
    res.status(500).json({ success: false, message: 'Ошибка сервера' });
  }
});

app.delete('/api/proxy-users/:username', requireAuth, (req, res) => {
  try {
    const { username } = req.params;
    const config = loadConfig();
    const before = config.proxyUsers.length;
    config.proxyUsers = config.proxyUsers.filter(u => u.username !== username);
    
    if (config.proxyUsers.length === before) {
      return res.json({ success: false, message: 'Пользователь не найден' });
    }
    
    saveConfig(config);
    
    if (config.installed) {
      updateCaddyfile(config, () => {
        res.json({ success: true });
      });
    } else {
      res.json({ success: true });
    }
  } catch (e) {
    res.status(500).json({ success: false, message: 'Ошибка сервера' });
  }
});

app.get('/api/status', requireAuth, (req, res) => {
  try {
    const config = loadConfig();
    if (!config.installed) return res.json({ installed: false, status: 'not_installed' });
    
    exec('systemctl is-active caddy', (error, stdout) => {
      const running = stdout.trim() === 'active';
      res.json({
        installed: true,
        status: running ? 'running' : 'stopped',
        domain: config.domain,
        serverIp: config.serverIp,
        email: config.email,
        usersCount: (config.proxyUsers || []).length
      });
    });
  } catch (e) {
    res.status(500).json({ success: false, message: 'Ошибка сервера' });
  }
});

app.post('/api/service/:action', requireAuth, (req, res) => {
  try {
    const { action } = req.params;
    if (!['start', 'stop', 'restart'].includes(action)) return res.status(400).json({ error: 'Invalid action' });
    
    exec(`systemctl ${action} caddy`, (error, stdout, stderr) => {
      if (error) res.json({ success: false, message: `Ошибка выполнения: ${action}` });
      else res.json({ success: true, message: `Команда ${action} успешно выполнена` });
    });
  } catch (e) {
    res.status(500).json({ success: false, message: 'Ошибка сервера' });
  }
});

// ─────────────────────────────────────────────
//  ИСПРАВЛЕННЫЙ УМНЫЙ ГЕНЕРАТОР CADDYFILE
// ─────────────────────────────────────────────
function updateCaddyfile(config, callback) {
  let basicAuthLines = '';
  if (config.proxyUsers && config.proxyUsers.length > 0) {
    basicAuthLines = config.proxyUsers
      .filter(u => u && u.username && u.password)
      .map(u => `    basic_auth ${u.username} ${u.password}`)
      .join('\n');
  }

  // 1. Умный выбор сертификатов для ядра NaiveProxy
  let tlsLine = `tls ${config.email}`;
  const certPath = `/etc/letsencrypt/live/${config.domain}/fullchain.pem`;
  const keyPath = `/etc/letsencrypt/live/${config.domain}/privkey.pem`;
  
  if (fs.existsSync(certPath) && fs.existsSync(keyPath)) {
    tlsLine = `tls ${certPath} ${keyPath}`;
  } else if (!config.email) {
    tlsLine = `tls internal`; // Защита от падения, если email пустой
  }

  let caddyfileContent = `{
  order forward_proxy before file_server
}

:443, ${config.domain} {
  ${tlsLine}

  forward_proxy {
${basicAuthLines}
    hide_ip
    hide_via
    probe_resistance
  }

  file_server {
    root /var/www/html
  }
}
`;

  // 2. ВОССТАНОВЛЕНИЕ БЛОКА ПАНЕЛИ (Если включен доступ через Caddy)
  if (config.accessMode === "2" && config.panelDomain) {
    let pTlsLine = `tls ${config.panelEmail}`;
    const pCertPath = `/etc/letsencrypt/live/${config.panelDomain}/fullchain.pem`;
    const pKeyPath = `/etc/letsencrypt/live/${config.panelDomain}/privkey.pem`;

    if (fs.existsSync(pCertPath) && fs.existsSync(pKeyPath)) {
      pTlsLine = `tls ${pCertPath} ${pKeyPath}`;
    } else if (!config.panelEmail) {
      pTlsLine = `tls internal`;
    }

    caddyfileContent += `\n${config.panelDomain} {\n  ${pTlsLine}\n  reverse_proxy 127.0.0.1:${process.env.PORT || 3000}\n}\n`;
  }

  try {
    fs.writeFileSync('/etc/caddy/Caddyfile', caddyfileContent, 'utf8');
  } catch (e) {
    console.error("Ошибка записи Caddyfile:", e);
  }

  exec('systemctl reload-or-restart caddy', (error) => {
    if (callback) callback();
  });
}

// Serve index for all non-api routes (SPA)
app.get('*', (req, res) => {
  if (!req.path.startsWith('/api')) {
    res.sendFile(path.join(__dirname, '../public/index.html'));
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`\n╔══════════════════════════════════════╗`);
  console.log(`║   Panel NaiveProxy by Veles          ║`);
  console.log(`║   Running on http://0.0.0.0:${PORT}     ║`);
  console.log(`╚══════════════════════════════════════╝\n`);
});