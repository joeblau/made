import { DurableObject } from "cloudflare:workers";

// These fields deliberately match BuildActivityState's Swift Codable keys.
export interface BuildState {
  status: string;
  conclusion?: string | null;
  startedAt?: number | null;
  finishedAt?: number | null;
  checkedAt: number;
}

interface Registration {
  token: string;
  environment: "sandbox" | "production";
  runKey: string;
}

interface Monitor extends Registration {
  expiresAt: number;
  revision: number;
  latest?: BuildState;
  pending?: BuildState;
  ended: boolean;
  failures: number;
  nextAttempt: number;
  lastTimestamp: number;
}

type PushEnv = Pick<Cloudflare.Env, "APNS_KEY_ID" | "APNS_TEAM_ID" | "APNS_PRIVATE_KEY">;
type RouteEnv = PushEnv & Pick<Cloudflare.Env, "BUILD_ACTIVITIES" | "BUILD_ACTIVITY_RATE_LIMIT">;
const MAX_AGE = 8 * 60 * 60 * 1000;
const MAX_BODY = 4096;
const RUN_KEY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/[1-9][0-9]*\/[1-9][0-9]*$/;
const STATUS = new Set(["queued", "requested", "pending", "waiting", "in_progress", "completed"]);
const CONCLUSION = new Set(["success", "failure", "neutral", "cancelled", "skipped", "timed_out", "action_required", "startup_failure", "stale"]);

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function validState(value: unknown, now = Date.now() / 1000): value is BuildState {
  if (!object(value) || typeof value.status !== "string" || !STATUS.has(value.status)) return false;
  if (typeof value.checkedAt !== "number" || !Number.isFinite(value.checkedAt) || value.checkedAt > now + 30 || value.checkedAt < now - 300) return false;
  if (value.conclusion != null && (typeof value.conclusion !== "string" || !CONCLUSION.has(value.conclusion))) return false;
  for (const key of ["startedAt", "finishedAt"]) {
    const date = value[key];
    if (date != null && (typeof date !== "number" || !Number.isFinite(date) || date < 0 || date > now + 30)) return false;
  }
  if (typeof value.startedAt === "number" && typeof value.finishedAt === "number" && value.finishedAt < value.startedAt) return false;
  if (value.status !== "completed" && (value.finishedAt != null || value.conclusion != null)) return false;
  return Object.keys(value).every(key => ["status", "conclusion", "startedAt", "finishedAt", "checkedAt"].includes(key));
}

function validRegistration(value: unknown): value is Registration {
  return object(value) && typeof value.token === "string" && /^[0-9a-f]{64,1024}$/.test(value.token)
    && value.token.length % 2 === 0 && ["sandbox", "production"].includes(String(value.environment))
    && typeof value.runKey === "string" && value.runKey.length < 300 && RUN_KEY.test(value.runKey);
}

function response(status: number): Response {
  return new Response(null, { status, headers: { "cache-control": "no-store" } });
}

async function digest(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes), byte => byte.toString(16).padStart(2, "0")).join("");
}

async function body(request: Request): Promise<unknown> {
  if (!request.headers.get("content-type")?.startsWith("application/json")) throw new Error("content type");
  const reader = request.body?.getReader();
  if (!reader) throw new Error("body missing");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > MAX_BODY) { await reader.cancel(); throw new Error("body too large"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return JSON.parse(new TextDecoder().decode(bytes));
}

export async function handleBuildActivity(request: Request, env: RouteEnv): Promise<Response> {
  if (request.method !== "POST") return response(405);
  const operation = new URL(request.url).pathname.split("/").pop();
  if (!["register", "update", "end"].includes(operation ?? "")) return response(404);
  // The random 256-bit capability is generated on the phone, sent to its paired Mac
  // through authenticated sync, and never appears in URLs, responses, or logs.
  const capability = request.headers.get("authorization")?.match(/^Bearer ([0-9a-f]{64})$/)?.[1];
  if (!capability) return response(401);
  const source = request.headers.get("CF-Connecting-IP");
  if (!source) return response(403);
  const key = await digest(capability);
  for (const limitKey of [await digest(`build-ip:${source}`), key]) {
    if (!(await env.BUILD_ACTIVITY_RATE_LIMIT.limit({ key: limitKey })).success) return response(429);
  }
  if (!env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_PRIVATE_KEY) return response(503);
  let input: unknown;
  try { input = await body(request); } catch { return response(400); }
  const stub = env.BUILD_ACTIVITIES.getByName(key);
  if (operation === "register") {
    if (!validRegistration(input)) return response(400);
    return response(await stub.register(input));
  }
  if (!object(input) || typeof input.runKey !== "string" || !RUN_KEY.test(input.runKey)) return response(400);
  if (operation === "end") return response(await stub.end(input.runKey));
  if (!validState(input.state)) return response(400);
  return response(await stub.update(input.runKey, input.state));
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export async function providerToken(env: PushEnv, issuedAt: number): Promise<string> {
  const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const message = `${encode({ alg: "ES256", kid: env.APNS_KEY_ID })}.${encode({ iss: env.APNS_TEAM_ID, iat: issuedAt })}`;
  const pem = env.APNS_PRIVATE_KEY.replaceAll("\\n", "\n").replace(/-----[^-]+-----|\s/g, "");
  const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(atob(pem), c => c.charCodeAt(0)), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(message));
  return `${message}.${base64url(new Uint8Array(signature))}`;
}

export function pushPayload(state: BuildState, timestamp: number) {
  const completed = state.status === "completed";
  return { aps: {
    timestamp, event: completed ? "end" : "update", "content-state": state,
    ...(completed ? { "dismissal-date": timestamp + 15 * 60 } : { "stale-date": Math.floor(state.checkedAt + 120) }),
  } };
}

export class BuildActivityRoom extends DurableObject<Cloudflare.Env> {
  constructor(ctx: DurableObjectState, env: Cloudflare.Env) {
    super(ctx, env);
    this.ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS monitor (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
  }

  private read<T>(key: string): T | undefined {
    const row = this.ctx.storage.sql.exec<{ value: string }>("SELECT value FROM monitor WHERE key = ?", key).toArray()[0];
    return row ? JSON.parse(row.value) as T : undefined;
  }
  private write(key: string, value: unknown): void {
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO monitor VALUES (?, ?)", key, JSON.stringify(value));
  }

  async register(input: Registration): Promise<number> {
    const current = this.read<Monitor>("monitor");
    if (current && (current.ended || current.expiresAt <= Date.now())) return 410;
    if (current && current.runKey !== input.runKey) return 409;
    const monitor: Monitor = current ? { ...current, token: input.token, environment: input.environment, revision: current.revision + 1 }
      : { ...input, expiresAt: Date.now() + MAX_AGE, revision: 1, ended: false, failures: 0, nextAttempt: 0, lastTimestamp: 0 };
    this.write("monitor", monitor);
    await this.schedule(monitor);
    return 204;
  }

  async update(runKey: string, state: BuildState): Promise<number> {
    const monitor = this.read<Monitor>("monitor");
    if (!monitor) return 404;
    if (monitor.ended || monitor.expiresAt <= Date.now()) return 410;
    if (monitor.runKey !== runKey) return 409;
    if (monitor.latest && (state.checkedAt <= monitor.latest.checkedAt || monitor.latest.status === "completed")) return 204;
    monitor.latest = state;
    monitor.pending = state;
    monitor.revision += 1;
    this.write("monitor", monitor);
    await this.schedule(monitor);
    return 202;
  }

  async end(runKey: string): Promise<number> {
    const monitor = this.read<Monitor>("monitor");
    if (!monitor) return 204;
    if (monitor.runKey !== runKey) return 409;
    if (monitor.ended || monitor.latest?.status === "completed") return 204;
    if (!monitor.latest) {
      monitor.ended = true;
      monitor.token = "";
    } else {
      monitor.pending = { ...monitor.latest, status: "completed", conclusion: "cancelled", finishedAt: Date.now() / 1000, checkedAt: Date.now() / 1000 };
      monitor.latest = monitor.pending;
    }
    monitor.revision += 1;
    this.write("monitor", monitor);
    await this.schedule(monitor);
    return 204;
  }

  async alarm(): Promise<void> {
    const monitor = this.read<Monitor>("monitor");
    if (!monitor || monitor.expiresAt <= Date.now()) {
      this.ctx.storage.sql.exec("DELETE FROM monitor");
      await this.ctx.storage.deleteAlarm();
      return;
    }
    if (!monitor.pending || monitor.nextAttempt > Date.now()) { await this.schedule(monitor); return; }
    const timestamp = Math.max(Math.floor(Date.now() / 1000), monitor.lastTimestamp + 1);
    let status = 503;
    try {
      let auth = this.read<{ token: string; issuedAt: number; keyID: string }>("auth");
      if (!auth || timestamp - auth.issuedAt > 50 * 60 || auth.keyID !== this.env.APNS_KEY_ID) {
        auth = { token: await providerToken(this.env, timestamp), issuedAt: timestamp, keyID: this.env.APNS_KEY_ID };
        this.write("auth", auth);
      }
      const host = monitor.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
      const result = await fetch(`https://${host}/3/device/${monitor.token}`, {
        method: "POST", signal: AbortSignal.timeout(15_000),
        headers: {
          authorization: `bearer ${auth.token}`, "apns-topic": "app.blau.copilot.push-type.liveactivity",
          "apns-push-type": "liveactivity", "apns-priority": monitor.pending.status === "completed" ? "10" : "5",
          "apns-expiration": String(monitor.pending.status === "completed" ? Math.floor(monitor.expiresAt / 1000) : timestamp + 120),
          "content-type": "application/json",
        },
        body: JSON.stringify(pushPayload(monitor.pending, timestamp)),
      });
      status = result.status;
      await result.body?.cancel();
    } catch { /* Retry without logging device tokens or provider credentials. */ }
    const current = this.read<Monitor>("monitor");
    if (!current || current.revision !== monitor.revision) { if (current) await this.schedule(current); return; }
    if (status !== 200) {
      console.warn(JSON.stringify({ event: "build_push_failed", status, retry: status !== 400 && status !== 410 }));
    }
    if (status === 200 || status === 400 || status === 410) {
      current.ended = status !== 200 || current.pending?.status === "completed";
      current.pending = undefined;
      current.failures = 0;
      current.nextAttempt = 0;
      current.lastTimestamp = timestamp;
      if (current.ended) current.token = "";
    } else {
      current.failures += 1;
      current.nextAttempt = Date.now() + Math.min(300_000, 5000 * 2 ** Math.min(current.failures, 6));
    }
    this.write("monitor", current);
    await this.schedule(current);
  }

  private async schedule(monitor: Monitor): Promise<void> {
    const next = monitor.pending ? Math.max(Date.now() + 1000, monitor.nextAttempt) : monitor.expiresAt;
    await this.ctx.storage.setAlarm(Math.min(next, monitor.expiresAt));
  }
}
