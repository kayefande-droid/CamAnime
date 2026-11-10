/**
 * Firebase Cloud Messaging (HTTP v1) sender.
 *
 * Free tier, no Firebase Admin SDK dependency: the service-account JSON is read
 * from the `FCM_SERVICE_ACCOUNT` secret, a JWT is signed with WebCrypto, and the
 * access token is exchanged with Google. Nothing about the key is ever logged,
 * returned to a client, or written to D1.
 *
 * When the secret is absent every call answers `{ configured: false }` instead
 * of throwing, so notifications degrade to "not configured" while the rest of
 * the app keeps working.
 */
const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const TOKEN_URL = "https://oauth2.googleapis.com/token";

let cachedAuth = null; // { email, token, exp }

export function fcmConfigured(env) {
  return Boolean(env && env.FCM_SERVICE_ACCOUNT && env.FCM_PROJECT_ID);
}

/** Parse the secret defensively; a malformed value must never throw at import. */
export function serviceAccount(env) {
  const raw = env && env.FCM_SERVICE_ACCOUNT;
  if (!raw) return null;
  try {
    const sa = JSON.parse(typeof raw === "string" ? raw : String(raw));
    if (!sa || !sa.client_email || !sa.private_key) return null;
    sa.private_key = String(sa.private_key).replace(/\\n/g, "\n");
    return sa;
  } catch {
    return null;
  }
}

function b64url(input) {
  const bytes =
    typeof input === "string" ? new TextEncoder().encode(input) : new Uint8Array(input);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem) {
  const body = String(pem)
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const der = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) der[i] = binary.charCodeAt(i);
  return der;
}

/** OAuth2 access token for the FCM API, cached in the isolate until it expires. */
async function accessToken(sa) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedAuth && cachedAuth.email === sa.client_email && cachedAuth.exp > now + 60) {
    return cachedAuth.token;
  }

  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(
    JSON.stringify({
      iss: sa.client_email,
      scope: SCOPE,
      aud: TOKEN_URL,
      iat: now,
      exp: now + 3600,
    }),
  );

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  const assertion = `${header}.${claims}.${b64url(signature)}`;

  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`FCM auth failed (${res.status}): ${detail.slice(0, 200)}`);
  }
  const body = await res.json();
  const token = String(body.access_token || "");
  if (!token) throw new Error("FCM auth returned no access_token");
  const exp = now + (Number(body.expires_in) || 3600);
  cachedAuth = { email: sa.client_email, token, exp };
  return token;
}

/** Map an FCM error body to a machine-readable reason. */
function errorReason(status, payload) {
  const details = payload?.error?.details || [];
  for (const d of details) {
    if (d?.errorCode) return String(d.errorCode);
  }
  const message = String(payload?.error?.message || "");
  if (/UNREGISTERED|Requested entity was not found/i.test(message)) return "UNREGISTERED";
  if (/INVALID_ARGUMENT/i.test(message)) return "INVALID_ARGUMENT";
  if (status === 401 || status === 403) return "UNAUTHORIZED";
  return `HTTP_${status}`;
}

/**
 * Send one message to one registration token.
 * Returns { ok } or { ok:false, reason, dead } where `dead` means the token
 * should be pruned from D1 (uninstalled app / rotated token).
 */
export async function sendToToken(env, token, message) {
  const sa = serviceAccount(env);
  if (!sa) return { ok: false, reason: "NOT_CONFIGURED", dead: false };

  let auth;
  try {
    auth = await accessToken(sa);
  } catch (err) {
    return { ok: false, reason: "AUTH_FAILED", dead: false, detail: String(err.message).slice(0, 160) };
  }

  const endpoint = `https://fcm.googleapis.com/v1/projects/${env.FCM_PROJECT_ID}/messages:send`;
  let res;
  try {
    res = await fetch(endpoint, {
      method: "POST",
      headers: {
        authorization: `Bearer ${auth}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ message: { ...message, token } }),
    });
  } catch (err) {
    return { ok: false, reason: "NETWORK", dead: false, detail: String(err.message).slice(0, 160) };
  }

  if (res.ok) return { ok: true };

  const payload = await res.json().catch(() => null);
  const reason = errorReason(res.status, payload);
  return {
    ok: false,
    reason,
    dead: reason === "UNREGISTERED" || reason === "INVALID_ARGUMENT",
  };
}

/** Build the FCM `message` object shared by every target type. */
export function buildMessage(n) {
  const message = {
    notification: {
      title: String(n.title || "CamAnime").slice(0, 120),
      body: String(n.body || "").slice(0, 500),
    },
    data: {
      category: String(n.category || "announcement"),
      id: String(n.id || ""),
      action: String(n.action || ""),
      deep_link: String(n.deep_link || ""),
    },
    android: {
      priority: "high",
      notification: {
        // Must match Notifications.UPDATES_CHANNEL_ID in the Android app.
        channel_id: "camanime_updates",
        color: "#f5a524",
        sound: "default",
        click_action: "FLUTTER_NOTIFICATION_CLICK",
      },
    },
  };
  if (n.image && /^https:\/\//i.test(n.image)) {
    message.notification.image = n.image;
    message.android.notification.image = n.image;
  }
  return message;
}

/**
 * Fan out to a list of tokens with bounded concurrency.
 * FCM HTTP v1 sends one token per request, so this keeps the worker's
 * subrequest budget in mind and reports dead tokens for pruning.
 */
export async function sendToTokens(env, tokens, message, { concurrency = 8, limit = 500 } = {}) {
  const list = [...new Set((tokens || []).filter(Boolean))].slice(0, limit);
  const result = { configured: fcmConfigured(env), attempted: list.length, sent: 0, failed: 0, dead: [], errors: [] };

  if (!result.configured) {
    result.reason = "FCM_SERVICE_ACCOUNT / FCM_PROJECT_ID not set";
    return result;
  }
  if (!list.length) return result;

  let cursor = 0;
  const worker = async () => {
    for (;;) {
      const index = cursor;
      cursor += 1;
      if (index >= list.length) return;
      const token = list[index];
      const outcome = await sendToToken(env, token, message);
      if (outcome.ok) {
        result.sent += 1;
      } else {
        result.failed += 1;
        if (outcome.dead) result.dead.push(token);
        if (result.errors.length < 5 && outcome.reason) {
          result.errors.push({ reason: outcome.reason, detail: outcome.detail || "" });
        }
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, list.length) }, worker));
  return result;
}
