/** Independent Cloudflare auth on D1: PBKDF2 hashes, server-side token sessions. */
import { hashPassword, verifyPassword, randomToken, json, sessionCookie, clearSessionCookie, parseCookies } from "./util.js";

const SESSION_DAYS = 30;

export async function currentUser(env, request) {
  const token = parseCookies(request).ca_session;
  if (!token) return null;
  const row = await env.DB.prepare(
    "SELECT tokens.expires, users.email, users.name, users.role, users.avatar FROM tokens JOIN users ON users.email = tokens.email WHERE token = ?1"
  ).bind(token).first();
  if (!row || row.expires < Date.now()) return null;
  return { email: row.email, name: row.name, role: row.role, avatar: row.avatar, token };
}

export async function register(env, request) {
  const body = await readJson(request);
  const email = String(body.email || "").trim().toLowerCase();
  const name = String(body.name || "").trim().slice(0, 24);
  const password = String(body.password || "");
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || name.length < 2 || password.length < 8) {
    return json({ error: "Valid email, name (2+ chars) and password (8+ chars) required." }, 400);
  }
  const exists = await env.DB.prepare("SELECT email FROM users WHERE email = ?1").bind(email).first();
  if (exists) return json({ error: "That email is already registered here." }, 409);
  const pw = await hashPassword(password);
  const created = Math.floor(Date.now() / 1000);
  await env.DB.prepare("INSERT INTO users (email, name, pw, role, avatar, created) VALUES (?1, ?2, ?3, 'user', '', ?4)")
    .bind(email, name, pw, created).run();
  await env.DB.prepare("INSERT INTO notifications (id, email, text, read, t) VALUES (?1, ?2, ?3, 0, ?4)")
    .bind(crypto.randomUUID(), email, `Welcome to CamAnime, ${name}!`, created).run();
  return loginOk(env, email, name);
}

export async function login(env, request) {
  const body = await readJson(request);
  const email = String(body.email || "").trim().toLowerCase();
  const password = String(body.password || "");
  const user = await env.DB.prepare("SELECT email, name, pw FROM users WHERE email = ?1").bind(email).first();
  if (!user || !(await verifyPassword(password, user.pw))) {
    return json({ error: "Wrong email or password." }, 401);
  }
  return loginOk(env, user.email, user.name);
}

async function loginOk(env, email, name) {
  const token = randomToken();
  const now = Date.now();
  await env.DB.prepare("INSERT INTO tokens (token, email, created, expires) VALUES (?1, ?2, ?3, ?4)")
    .bind(token, email, now, now + SESSION_DAYS * 86400000).run();
  return json({ ok: true, email, name }, 200, { "set-cookie": sessionCookie(token) });
}

export async function logout(env, request) {
  const token = parseCookies(request).ca_session;
  if (token) await env.DB.prepare("DELETE FROM tokens WHERE token = ?1").bind(token).run();
  return json({ ok: true }, 200, { "set-cookie": clearSessionCookie() });
}

export async function me(env, request) {
  const user = await currentUser(env, request);
  if (!user) return json({ user: null });
  return json({ user: { email: user.email, name: user.name, role: user.role, avatar: user.avatar } });
}

/** Admin gate used by admin routes/pages. */
export async function requireAdmin(env, request) {
  const user = await currentUser(env, request);
  if (!user || user.role !== "admin") return { user: null, denied: true };
  return { user, denied: false };
}

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    return {};
  }
}
