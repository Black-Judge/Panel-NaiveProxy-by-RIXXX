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
// РУЧНОЙ ПАРСЕР .ENV (Для независимости от PM2)
// ─────────────────────────────────────────────
const envPath = path.join(__dirname, '../.env');
if (fs.existsSync(envPath)) {
  const envFile = fs.readFileSync(envPath, 'utf8');
  envFile.split('\n').forEach(line => {
    const match = line.match(/^\s*([\w.-]+)\s*=\s*(.*)?\s*$/);
    if (match) {
      process.env[match[1]] = match[2] ? match[2].trim() : '';
    }
  });
}

const app = express();
const server = http.createServer(app);

const PORT = process.env.PORT || 3000;
const DATA_FILE = path.join(__dirname, '../data/config.json');
const USERS_FILE = path.join(__dirname, '../data/users.json');

// Ensure data directory exists
const dataDir = path.join(__dirname, '../data');
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });

// Initialize config
function loadConfig() {
  if (!fs.existsSync(DATA_FILE)) {
    const defaultConfig = {
      installed: false,
      domain: '',
      email: '',
      serverIp: '',
      adminPassword: '',
      proxyUsers: []
    };
    fs.writeFileSync(DATA_FILE, JSON.stringify(defaultConfig, null, 2));
    return defaultConfig;
  }
  return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
}

function saveConfig(config) {
  fs.writeFileSync(DATA_FILE, JSON.stringify(config, null, 2));
}

function loadUsers() {
  if (!fs.existsSync(USERS_FILE)) {
    const initialUser = process.env.ADMIN_USER || 'admin';
    const initialPass = process.env.ADMIN_PASS || 'admin';

    const defaultUsers = {
      [initialUser]: {
        password: bcrypt.hashSync(initialPass, 10),
        role: 'admin'
      }
    };
    fs.writeFileSync(USERS_FILE, JSON.stringify(defaultUsers, null, 2));
    return defaultUsers;
  }
  return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
}

function saveUsers(users) {
  fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2));
}

// Middleware
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

// Auth middleware
function requireAuth(req, res, next) {
  if (req.session && req.session.authenticated) {
    return next();
  }
  res.status(401).json({ error: 'Unauthorized' });
}

// ─────────────────────────────────────────────
//  AUTH ROUTES
// ─────────────────────────────────────────────
app.post('/api/login', (req, res) => {
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
});

app.post('/api/logout', (req, res) => {
  req.session.destroy();
  res.json({ success: true });
});

app.get('/api/me', requireAuth, (req, res) => {
  res.json({ username: req.session.username, role: req.session.role });
});

// ─────────────────────────────────────────────
//  CONFIG ROUTES
// ─────────────────────────────────────────────
app.get('/api/config', requireAuth, (req, res) => {
  const config = loadConfig();
  const safe = { ...config };
  res.json(safe);
});

app.post('/api/config/change-password', requireAuth, (req, res) => {
  const { currentPassword, newPassword } = req.body;
  if (!currentPassword || !newPassword) {
    return res.json({ success: false, message: 'Заполните все поля' });
  }
  if (newPassword.length < 6) {
    return res.json({ success: false, message: 'Новый пароль минимум 6 символов' });
  }
  const users = loadUsers();
  const user = users[req.session.username];
  if (!user) {
    return res.json({ success: false, message: 'Пользователь не найден' });
  }
  if (!bcrypt.compareSync(currentPassword, user.password)) {
    return res.json({ success: false, message: 'Текущий пароль неверен' });
  }
  users[req.session.username].password = bcrypt.hashSync(newPassword, 10);
  saveUsers(users);
  res.json({ success: true, message: 'Пароль успешно изменён' });
});

// ─────────────────────────────────────────────
//  PROXY USERS ROUTES
// ─────────────────────────────────────────────
app.get('/api/proxy-users', requireAuth, (req, res) => {
  const config = loadConfig();
  res.json({ users: config.proxyUsers || [] });
});

app.post('/api/proxy-users/add', requireAuth, (req, res) => {
  // ПРИНИМАЕМ ИМЯ ПРОФИЛЯ
  const { username, password, profileName } = req.body;
  
  if (!username || !password) {
    return res.json({ success: false, message: 'Логин и пароль обязательны' });
  }
  const config = loadConfig();
  if (!config.proxyUsers) config.proxyUsers = [];
  
  if (config.proxyUsers.find(u => u.username === username)) {
    return res.json({ success: false, message: 'Пользователь уже существует' });
  }
  
  // Если профиль пустой - ставим дефолт. Иначе заменяем пробелы на безопасные
  let safeProfile = profileName ? profileName.replace(/ /g, '_') : `Naive_${username}`;

  // СОХРАНЯЕМ ИМЯ ПРОФИЛЯ В БАЗУ
  config.proxyUsers.push({ 
    username, 
    password, 
    profileName: safeProfile,
    createdAt: new Date().toISOString() 
  });
  saveConfig(config);
  
  if (config.installed) {
    updateCaddyfile(config, res, () => {
      res.json({ success: true, link: `naive+https://${username}:${password}@${config.domain}:443#${encodeURIComponent(safeProfile)}` });
    });
  } else {
    res.json({ success: true, link: username + ':' + password });
  }
});

app.delete('/api/proxy-users/:username', requireAuth, (req, res) => {
  const { username } = req.params;
  const config = loadConfig();
  const before = (config.proxyUsers || []).length;
  config.proxyUsers = (config.proxyUsers || []).filter(u => u.username !== username);
  if (config.proxyUsers.length === before) {
    return res.json({ success: false, message: 'Пользователь не найден' });
  }
  saveConfig(config);
  
  if (config.installed) {
    updateCaddyfile(config, res, () => {
      res.json({ success: true });
    });
  } else {
    res.json({ success: true });
  }
});

// ─────────────────────────────────────────────
//  SERVER STATUS
// ─────────────────────────────────────────────
app.get('/api/status', requireAuth, (req, res) => {
  const config = loadConfig();
  if (!config.installed) {
    return res.json({ installed: false, status: 'not_installed' });
  }
  
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
});

app.post('/api/service/:action', requireAuth, (req, res) => {
  const { action } = req.params;
  
  if (!['start', 'stop', 'restart'].includes(action)) {
    return res.status(400).json({ error: 'Invalid action' });
  }
  
  exec(`systemctl ${action} caddy`, (error, stdout, stderr) => {
    if (error) {
      console.error(`[Systemctl Error]: ${stderr || error.message}`);
      res.json({ success: false, message: `Ошибка выполнения: ${action}` });
    } else {
      res.json({ success: true, message: `Команда ${action} успешно выполнена` });
    }
  });
});

// ─────────────────────────────────────────────
//  CADDY UPDATE HELPER
// ─────────────────────────────────────────────
function updateCaddyfile(config, res, callback) {
  let basicAuthLines = '';
  if (config.proxyUsers && config.proxyUsers.length > 0) {
    basicAuthLines = config.proxyUsers
      .map(u => `    basic_auth ${u.username} ${u.password}`)
      .join('\n');
  }

  const caddyfileContent = `{
  order forward_proxy before file_server
}

:443, ${config.domain} {
  tls ${config.email}

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

  try {
    fs.writeFileSync('/etc/caddy/Caddyfile', caddyfileContent, 'utf8');
  } catch (e) {
    console.error("Ошибка записи Caddyfile:", e);
  }

  exec('systemctl reload-or-restart caddy', (error) => {
    if (error) console.error("Ошибка применения конфига Caddy:", error);
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