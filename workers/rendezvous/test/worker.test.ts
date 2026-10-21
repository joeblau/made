import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it } from "vitest";
import { reset, runInDurableObject } from "cloudflare:test";
import worker from "../src/index";

const endpoint = "https://rendezvous.example.test";

function token(): string {
  return `ABCDEFGH${crypto.randomUUID().replaceAll("-", "")}`;
}

function publicKey(seed: number): string {
  return btoa(
    String.fromCharCode(...Array.from({ length: 32 }, (_, index) => seed + index)),
  );
}

function request(
  path: string,
  body?: unknown,
  init: RequestInit = {},
): Request {
  const headers = new Headers(init.headers);
  if (!headers.has("CF-Connecting-IP")) {
    headers.set("CF-Connecting-IP", "203.0.113.10");
  }
  if (body !== undefined && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }
  return new Request(`${endpoint}${path}`, {
    ...init,
    method: body === undefined ? "GET" : "POST",
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function fetch(request: Request): Promise<Response> {
  return worker.fetch(request, env);
}

afterEach(async () => {
  await reset();
});

describe("signaling", () => {
  it("introduces two peers immediately and rejects a third", async () => {
    const pairingToken = token();
    const first = { token: pairingToken, publicKey: publicKey(1), port: 40_001 };
    const second = { token: pairingToken, publicKey: publicKey(2), port: 40_002 };
    const third = { token: pairingToken, publicKey: publicKey(3), port: 40_003 };

    const firstResponse = await fetch(request("/register", first));
    expect(firstResponse.status).toBe(204);

    const secondResponse = await fetch(
      request("/register", second, {
        headers: { "CF-Connecting-IP": "203.0.113.11" },
      }),
    );
    expect(secondResponse.status).toBe(200);
    await expect(secondResponse.json()).resolves.toMatchObject({
      publicKey: first.publicKey,
      ip: "203.0.113.10",
      port: first.port,
    });

    const refreshResponse = await fetch(request("/register", first));
    expect(refreshResponse.status).toBe(200);
    await expect(refreshResponse.json()).resolves.toMatchObject({
      publicKey: second.publicKey,
      ip: "203.0.113.11",
      port: second.port,
    });

    expect((await fetch(request("/register", third))).status).toBe(409);
  });

  it("looks up peers with a POST body and keeps secrets out of the URL", async () => {
    const pairingToken = token();
    const firstKey = publicKey(10);
    const secondKey = publicKey(20);
    await fetch(
      request("/register", {
        token: pairingToken,
        publicKey: firstKey,
        port: 41_001,
      }),
    );
    await fetch(
      request("/register", {
        token: pairingToken,
        publicKey: secondKey,
        port: 41_002,
      }),
    );

    const lookupRequest = request("/get-peer", {
      token: pairingToken,
      publicKey: firstKey,
    });
    expect(lookupRequest.url).not.toContain(pairingToken);
    expect(lookupRequest.url).not.toContain(firstKey);
    const response = await fetch(lookupRequest);
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      publicKey: secondKey,
      port: 41_002,
    });

    const legacy = await fetch(
      request(`/get-peer?token=${pairingToken}&publicKey=${firstKey}`),
    );
    expect(legacy.status).toBe(405);
  });

  it("rejects malformed and oversized signaling requests", async () => {
    const valid = { token: token(), publicKey: publicKey(1), port: 42_001 };
    expect((await fetch(request("/register", { ...valid, token: "repeated".repeat(5) }))).status).toBe(400);
    expect((await fetch(request("/register", { ...valid, publicKey: "not-a-key" }))).status).toBe(400);
    expect((await fetch(request("/register", { ...valid, port: 0 }))).status).toBe(400);

    const oversized = new Request(`${endpoint}/register`, {
      method: "POST",
      headers: {
        "CF-Connecting-IP": "203.0.113.10",
        "content-length": "5000",
      },
      body: "{}",
    });
    expect((await fetch(oversized)).status).toBe(413);
  });

  it("rejects an oversized streamed body without buffering it", async () => {
    // No content-length header: the declared-length fast path cannot reject,
    // so the bounded reader must stop pulling once the cap is crossed.
    let pulled = 0;
    let cancelled = false;
    const chunk = new Uint8Array(1024).fill(0x20);
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulled += chunk.byteLength;
        controller.enqueue(chunk);
      },
      cancel() {
        cancelled = true;
      },
    });
    const response = await fetch(
      new Request(`${endpoint}/register`, {
        method: "POST",
        headers: {
          "CF-Connecting-IP": "203.0.113.10",
          "content-type": "application/json",
        },
        body,
      }),
    );
    expect(response.status).toBe(413);
    expect(cancelled).toBe(true);
    // Allow a little readahead, but nothing near an unbounded buffer.
    expect(pulled).toBeLessThanOrEqual(16 * 1024);
  });

  it("requires the trusted Cloudflare source header in production", async () => {
    const response = await fetch(
      new Request(`${endpoint}/register`, {
        method: "POST",
        body: JSON.stringify({
          token: token(),
          publicKey: publicKey(1),
          port: 43_001,
        }),
      }),
    );
    expect(response.status).toBe(403);
  });

  it("evicts expired registrations before returning a peer", async () => {
    const pairingToken = token();
    const stub = env.SIGNALS.get(env.SIGNALS.idFromName(pairingToken));
    const firstKey = publicKey(1);
    const secondKey = publicKey(2);
    await stub.register({ publicKey: firstKey, ip: "203.0.113.1", port: 44_001 });
    await stub.register({ publicKey: secondKey, ip: "203.0.113.2", port: 44_002 });

    await runInDurableObject(stub, async (_instance, state) => {
      const peers = await state.storage.get<Record<string, { updatedAt: number }>>("peers");
      expect(peers).toBeDefined();
      for (const peer of Object.values(peers ?? {})) peer.updatedAt = 0;
      await state.storage.put("peers", peers ?? {});
    });

    await expect(stub.getPeer(firstKey)).resolves.toBeNull();
  });
});

describe("WebSocket relay", () => {
  function upgradeRequest(pairingToken: string): Request {
    return request(`/room/${pairingToken}`, undefined, {
      headers: {
        "CF-Connecting-IP": `203.0.113.${Math.floor(Math.random() * 200) + 1}`,
        Upgrade: "websocket",
      },
    });
  }

  it("bounds each room to two peers", async () => {
    const pairingToken = token();
    const first = await fetch(upgradeRequest(pairingToken));
    const second = await fetch(upgradeRequest(pairingToken));
    expect(first.status).toBe(101);
    expect(second.status).toBe(101);
    first.webSocket?.accept();
    second.webSocket?.accept();

    expect((await fetch(upgradeRequest(pairingToken))).status).toBe(409);
    first.webSocket?.close();
    second.webSocket?.close();
  });

  it("rejects low-entropy room identifiers", async () => {
    expect((await fetch(upgradeRequest("a".repeat(40)))).status).toBe(400);
    expect((await fetch(upgradeRequest("too-short"))).status).toBe(400);
  });

  it("closes a sender that exceeds the message-size limit", async () => {
    const pairingToken = token();
    const response = await fetch(upgradeRequest(pairingToken));
    const socket = response.webSocket;
    expect(response.status).toBe(101);
    expect(socket).toBeDefined();
    socket?.accept();

    const closed = new Promise<CloseEvent>((resolve) =>
      socket?.addEventListener("close", resolve),
    );
    socket?.send(new Uint8Array(256 * 1024 + 1));
    await expect(closed).resolves.toMatchObject({ code: 1009 });
  });

  it("closes a sender that floods a room", async () => {
    const response = await fetch(upgradeRequest(token()));
    const socket = response.webSocket;
    expect(socket).toBeDefined();
    socket?.accept();
    const closed = new Promise<CloseEvent>((resolve) =>
      socket?.addEventListener("close", resolve),
    );
    for (let index = 0; index < 61; index += 1) socket?.send("message");
    await expect(closed).resolves.toMatchObject({ code: 1008 });
  });

  it("relays messages without writing alarm storage", async () => {
    const pairingToken = token();
    const first = await fetch(upgradeRequest(pairingToken));
    const second = await fetch(upgradeRequest(pairingToken));
    expect(first.status).toBe(101);
    expect(second.status).toBe(101);
    first.webSocket?.accept();
    second.webSocket?.accept();

    const stub = env.ROOMS.get(env.ROOMS.idFromName(pairingToken));
    let alarmWrites = 0;
    await runInDurableObject(stub, async (_instance, state) => {
      const original = state.storage.setAlarm.bind(state.storage);
      state.storage.setAlarm = ((scheduledTime, options) => {
        alarmWrites += 1;
        return original(scheduledTime, options);
      }) as typeof state.storage.setAlarm;
    });

    const relayed = new Promise<unknown>((resolve) => {
      second.webSocket?.addEventListener("message", (event) => {
        if (event.data === "hello") resolve(event.data);
      });
    });
    first.webSocket?.send("hello");
    await expect(relayed).resolves.toBe("hello");
    expect(alarmWrites).toBe(0);

    first.webSocket?.close();
    second.webSocket?.close();
  });

  it("bounds relay throughput even below the message-count limit", async () => {
    const response = await fetch(upgradeRequest(token()));
    const socket = response.webSocket;
    socket?.accept();
    const closed = new Promise<CloseEvent>((resolve) =>
      socket?.addEventListener("close", resolve),
    );
    const chunk = new Uint8Array(256 * 1024);
    for (let index = 0; index < 5; index += 1) socket?.send(chunk);
    await expect(closed).resolves.toMatchObject({ code: 1013 });
  });
});
