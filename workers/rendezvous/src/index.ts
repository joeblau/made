import { DurableObject } from "cloudflare:workers";
import { AlarmSchedule } from "./alarm";
import { SignalingRoom } from "./signaling";

export { SignalingRoom };

interface Env {
  ROOMS: DurableObjectNamespace<RendezvousRoom>;
  SIGNALS: DurableObjectNamespace<SignalingRoom>;
  SIGNAL_RATE_LIMIT: RateLimit;
  CONNECTION_RATE_LIMIT: RateLimit;
  ABUSE_METRICS?: AnalyticsEngineDataset;
  ENVIRONMENT: "production" | "development" | "test";
}

interface SocketAttachment {
  byteCount: number;
  connectedAt: number;
  lastActivityAt: number;
  messageCount: number;
  windowStartedAt: number;
}

interface ActiveSocket {
  socket: WebSocket;
  attachment: SocketAttachment;
}

interface SignalRequest {
  token: string;
  publicKey: string;
  port?: number;
}

const MAX_BODY_BYTES = 4 * 1024;
const MAX_MESSAGE_BYTES = 256 * 1024;
const MAX_BUFFERED_BYTES = 1024 * 1024;
const MESSAGE_WINDOW_MS = 10_000;
const MAX_MESSAGES_PER_WINDOW = 60;
const MAX_BYTES_PER_WINDOW = 1024 * 1024;
const SOCKET_IDLE_MS = 2 * 60 * 1000;
const SOCKET_LIFETIME_MS = 30 * 60 * 1000;
const IDENTIFIER_RE = /^[A-Za-z0-9_-]+$/;
const BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json",
    },
  });
}

function record(env: Env, event: string): void {
  env.ABUSE_METRICS?.writeDataPoint({ blobs: [event], doubles: [1] });
}

function validIdentifier(value: unknown): value is string {
  if (
    typeof value !== "string" ||
    value.length < 32 ||
    value.length > 128 ||
    !IDENTIFIER_RE.test(value)
  ) {
    return false;
  }
  // Reject obviously human-chosen/repeated values. Clients must generate at
  // least 192 random bits and encode them as base64url.
  return new Set(value).size >= 8;
}

function validPublicKey(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 64 || !BASE64_RE.test(value)) {
    return false;
  }
  try {
    return Uint8Array.from(atob(value), (character) =>
      character.charCodeAt(0),
    ).byteLength === 32;
  } catch {
    return false;
  }
}

function validPort(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isInteger(value) &&
    value >= 1 &&
    value <= 65_535
  );
}

async function readSignalBody(
  request: Request,
): Promise<SignalRequest | Response> {
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (!Number.isFinite(declaredLength) || declaredLength > MAX_BODY_BYTES) {
    return json({ error: "body too large" }, 413);
  }
  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
    return json({ error: "content type must be application/json" }, 415);
  }

  let raw: string;
  try {
    raw = await request.text();
  } catch {
    return json({ error: "invalid request" }, 400);
  }
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
    return json({ error: "body too large" }, 413);
  }

  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return json({ error: "expected JSON object" }, 400);
  }
  return body as SignalRequest;
}

function trustedSource(request: Request, env: Env): string | null {
  const edgeAddress = request.headers.get("CF-Connecting-IP")?.trim();
  if (edgeAddress) return edgeAddress;

  if (env.ENVIRONMENT !== "development" && env.ENVIRONMENT !== "test") {
    return null;
  }
  const hostname = new URL(request.url).hostname;
  return ["localhost", "127.0.0.1", "::1"].includes(hostname)
    ? "local-development"
    : null;
}

async function digest(value: string): Promise<string> {
  const hash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(hash), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

async function allow(
  binding: RateLimit,
  values: readonly string[],
): Promise<boolean> {
  const key = await digest(values.join("\0"));
  return (await binding.limit({ key })).success;
}

function signalingStub(env: Env, token: string) {
  return env.SIGNALS.get(env.SIGNALS.idFromName(token));
}

async function handleRegister(request: Request, env: Env): Promise<Response> {
  const source = trustedSource(request, env);
  if (!source) {
    record(env, "untrusted-source");
    return json({ error: "request source unavailable" }, 403);
  }
  const body = await readSignalBody(request);
  if (body instanceof Response) return body;
  if (!validIdentifier(body.token)) {
    return json({ error: "invalid token" }, 400);
  }
  if (!validPublicKey(body.publicKey)) {
    return json({ error: "invalid publicKey" }, 400);
  }
  if (!validPort(body.port)) {
    return json({ error: "invalid port" }, 400);
  }
  if (!(await allow(env.SIGNAL_RATE_LIMIT, ["register", source]))) {
    record(env, "signal-rate-limit");
    return json({ error: "rate limit exceeded" }, 429);
  }

  const result = await signalingStub(env, body.token).register({
    publicKey: body.publicKey,
    ip: source,
    port: body.port,
  });
  if (result.status === "full") {
    record(env, "signal-room-full");
    return json({ error: "token pair is full" }, 409);
  }
  if (result.peer === null) return new Response(null, { status: 204 });
  return json({
    publicKey: result.peer.publicKey,
    ip: result.peer.ip,
    port: result.peer.port,
  });
}

async function handleGetPeer(request: Request, env: Env): Promise<Response> {
  const source = trustedSource(request, env);
  if (!source) {
    record(env, "untrusted-source");
    return json({ error: "request source unavailable" }, 403);
  }
  const body = await readSignalBody(request);
  if (body instanceof Response) return body;
  if (!validIdentifier(body.token)) {
    return json({ error: "invalid token" }, 400);
  }
  if (!validPublicKey(body.publicKey)) {
    return json({ error: "invalid publicKey" }, 400);
  }
  if (!(await allow(env.SIGNAL_RATE_LIMIT, ["lookup", source]))) {
    record(env, "signal-rate-limit");
    return json({ error: "rate limit exceeded" }, 429);
  }

  const peer = await signalingStub(env, body.token).getPeer(body.publicKey);
  if (peer === null) return new Response(null, { status: 204 });
  return json({ publicKey: peer.publicKey, ip: peer.ip, port: peer.port });
}

/** A bounded, hibernatable two-party WebSocket relay. */
export class RendezvousRoom extends DurableObject<Env> {
  private readonly expiry = new AlarmSchedule(this.ctx.storage);

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }

    const now = Date.now();
    const active = this.activeSockets(now);
    if (active.length >= 2) {
      record(this.env, "websocket-room-full");
      return new Response("Room is full", { status: 409 });
    }

    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server);
    const attachment: SocketAttachment = {
      byteCount: 0,
      connectedAt: now,
      lastActivityAt: now,
      messageCount: 0,
      windowStartedAt: now,
    };
    server.serializeAttachment(attachment);
    await this.scheduleExpiry([...active, { socket: server, attachment }]);

    if (active.length === 1) {
      this.broadcastControl({ type: "peer-joined" });
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(
    sender: WebSocket,
    message: ArrayBuffer | string,
  ): Promise<void> {
    const now = Date.now();
    const attachment = this.attachment(sender, now);
    if (this.expired(attachment, now)) {
      record(this.env, "websocket-expired");
      sender.close(1008, "connection expired");
      return;
    }

    const size =
      typeof message === "string"
        ? new TextEncoder().encode(message).byteLength
        : message.byteLength;
    if (size > MAX_MESSAGE_BYTES) {
      record(this.env, "websocket-message-too-large");
      sender.close(1009, "message too large");
      return;
    }

    if (now - attachment.windowStartedAt >= MESSAGE_WINDOW_MS) {
      attachment.windowStartedAt = now;
      attachment.messageCount = 0;
      attachment.byteCount = 0;
    }
    attachment.messageCount += 1;
    attachment.byteCount += size;
    attachment.lastActivityAt = now;
    sender.serializeAttachment(attachment);
    if (attachment.messageCount > MAX_MESSAGES_PER_WINDOW) {
      record(this.env, "websocket-message-rate");
      sender.close(1008, "message rate exceeded");
      return;
    }
    if (attachment.byteCount > MAX_BYTES_PER_WINDOW) {
      record(this.env, "websocket-throughput-limit");
      sender.close(1013, "relay capacity exceeded");
      return;
    }

    const active = this.activeSockets(now, { socket: sender, attachment });
    for (const { socket: peer } of active) {
      if (peer === sender) continue;
      const bufferedAmount =
        (peer as WebSocket & { bufferedAmount?: number }).bufferedAmount ?? 0;
      if (bufferedAmount + size > MAX_BUFFERED_BYTES) {
        record(this.env, "websocket-backpressure");
        peer.close(1013, "receiver overloaded");
        sender.close(1013, "receiver overloaded");
        return;
      }
      try {
        peer.send(message);
      } catch {
        peer.close(1011, "relay unavailable");
      }
    }
    // Activity only moves the sender's idle deadline later, so this normally
    // keeps the earlier alarm already in storage without writing.
    await this.scheduleExpiry(active);
  }

  async webSocketClose(sender: WebSocket): Promise<void> {
    this.notifyPeerLeft(sender);
    await this.scheduleExpiry(this.activeSockets(Date.now()));
  }

  async webSocketError(sender: WebSocket): Promise<void> {
    record(this.env, "websocket-error");
    this.notifyPeerLeft(sender);
    await this.scheduleExpiry(this.activeSockets(Date.now()));
  }

  async alarm(): Promise<void> {
    // Closes expired sockets and rearms for the earliest remaining deadline;
    // an early wake-up from a retained alarm simply rearms here.
    await this.expiry.replace(this.nextDeadline(this.activeSockets(Date.now())));
  }

  private attachment(socket: WebSocket, now: number): SocketAttachment {
    return {
      byteCount: 0,
      connectedAt: now,
      lastActivityAt: now,
      messageCount: 0,
      windowStartedAt: now,
      ...(socket.deserializeAttachment() as Partial<SocketAttachment> | null),
    };
  }

  private deadline(attachment: SocketAttachment): number {
    return Math.min(
      attachment.lastActivityAt + SOCKET_IDLE_MS,
      attachment.connectedAt + SOCKET_LIFETIME_MS,
    );
  }

  private expired(attachment: SocketAttachment, now: number): boolean {
    return now >= this.deadline(attachment);
  }

  /**
   * Accepted sockets still within their idle and lifetime limits; expired ones
   * are closed. `known` reuses an attachment the caller already updated so
   * the message path deserializes each attachment once.
   */
  private activeSockets(now: number, known?: ActiveSocket): ActiveSocket[] {
    const active: ActiveSocket[] = [];
    for (const socket of this.ctx.getWebSockets()) {
      const attachment =
        socket === known?.socket ? known.attachment : this.attachment(socket, now);
      if (!this.expired(attachment, now)) {
        active.push({ socket, attachment });
        continue;
      }
      record(this.env, "websocket-expired");
      socket.close(1008, "connection expired");
    }
    return active;
  }

  private nextDeadline(active: readonly ActiveSocket[]): number | null {
    const deadlines = active.map(({ attachment }) => this.deadline(attachment));
    return deadlines.length === 0 ? null : Math.min(...deadlines);
  }

  private async scheduleExpiry(active: readonly ActiveSocket[]): Promise<void> {
    await this.expiry.require(this.nextDeadline(active));
  }

  private notifyPeerLeft(sender: WebSocket): void {
    const text = JSON.stringify({ type: "peer-left" });
    for (const socket of this.ctx.getWebSockets()) {
      if (socket === sender) continue;
      try {
        socket.send(text);
      } catch {
        // The next event/alarm prunes a peer that vanished mid-send.
      }
    }
  }

  private broadcastControl(message: Record<string, unknown>): void {
    const text = JSON.stringify(message);
    for (const socket of this.ctx.getWebSockets()) {
      try {
        socket.send(text);
      } catch {
        // The next event/alarm prunes a peer that vanished mid-send.
      }
    }
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/healthz") {
      return new Response("ok\n", {
        headers: { "content-type": "text/plain" },
      });
    }

    if (url.pathname === "/register") {
      if (request.method !== "POST") {
        return json({ error: "method not allowed" }, 405);
      }
      return handleRegister(request, env);
    }
    if (url.pathname === "/get-peer") {
      if (request.method !== "POST") {
        return json({ error: "method not allowed" }, 405);
      }
      return handleGetPeer(request, env);
    }

    const segments = url.pathname.split("/").filter(Boolean);
    const code = segments.length === 2 && segments[0] === "room"
      ? segments[1]
      : undefined;
    if (!validIdentifier(code)) {
      return new Response("Invalid room code\n", { status: 400 });
    }

    const source = trustedSource(request, env);
    if (!source) {
      record(env, "untrusted-source");
      return new Response("Request source unavailable\n", { status: 403 });
    }
    if (!(await allow(env.CONNECTION_RATE_LIMIT, [source]))) {
      record(env, "websocket-connection-rate");
      return new Response("Rate limit exceeded\n", { status: 429 });
    }

    return env.ROOMS.get(env.ROOMS.idFromName(code)).fetch(request);
  },
} satisfies ExportedHandler<Env>;
