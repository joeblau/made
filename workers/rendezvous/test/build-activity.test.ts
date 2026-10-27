import { env } from "cloudflare:workers";
import { reset, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { BuildActivityRoom, providerToken, pushPayload, validState, type BuildState } from "../src/build-activity";

const runKey = "blau/made/123/2";
const registration = { runKey, token: "ab".repeat(32), environment: "sandbox" as const };
const running = (): BuildState => ({ status: "in_progress", startedAt: Date.now() / 1000 - 60, checkedAt: Date.now() / 1000 });

async function signingEnvironment() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const bytes = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey) as ArrayBuffer);
  return {
    publicKey: pair.publicKey,
    environment: { ...env, APNS_KEY_ID: "TESTKEY", APNS_TEAM_ID: "TESTTEAM", APNS_PRIVATE_KEY: btoa(String.fromCharCode(...bytes)) },
  };
}

function request(operation: string, body: unknown, capability = "cd".repeat(32)) {
  return new Request(`https://rendezvous.test/live-activities/${operation}`, {
    method: "POST", headers: { authorization: `Bearer ${capability}`, "content-type": "application/json", "CF-Connecting-IP": "203.0.113.12" },
    body: JSON.stringify(body),
  });
}

interface StoredMonitor {
  token: string; expiresAt: number; latest?: BuildState; pending?: BuildState;
  failures: number; nextAttempt: number; ended: boolean;
}
function read(state: DurableObjectState): StoredMonitor {
  const row = state.storage.sql.exec<{ value: string }>("SELECT value FROM monitor WHERE key = 'monitor'").one();
  return JSON.parse(row.value) as StoredMonitor;
}
function write(state: DurableObjectState, monitor: StoredMonitor) {
  state.storage.sql.exec("UPDATE monitor SET value = ? WHERE key = 'monitor'", JSON.stringify(monitor));
}
function room() { return env.BUILD_ACTIVITIES.getByName(crypto.randomUUID()); }

afterEach(async () => { vi.restoreAllMocks(); await reset(); });

describe("build activity API", () => {
  it("requires a capability and refuses malformed or oversized input", async () => {
    const { environment } = await signingEnvironment();
    expect((await worker.fetch(request("register", registration, "bad"), environment)).status).toBe(401);
    expect((await worker.fetch(request("register", { ...registration, token: "bad" }), environment)).status).toBe(400);
    expect((await worker.fetch(request("register", { ...registration, extra: "x".repeat(5000) }), environment)).status).toBe(400);
    expect((await worker.fetch(request("register", { ...registration, runKey: "blau/made/123/../../other" }), environment)).status).toBe(400);
  });

  it("registers, binds one attempt, accepts an update and revokes without exposing credentials", async () => {
    const { environment } = await signingEnvironment();
    const registered = await worker.fetch(request("register", registration), environment);
    expect(registered.status).toBe(204);
    expect(await registered.text()).toBe("");
    expect((await worker.fetch(request("update", { runKey: "blau/made/123/1", state: running() }), environment)).status).toBe(409);
    expect((await worker.fetch(request("update", { runKey, state: running() }), environment)).status).toBe(202);
    expect((await worker.fetch(request("end", { runKey }), environment)).status).toBe(204);
  });

  it("rejects stale, future, inconsistent and unrecognized content state", () => {
    const now = Date.now() / 1000;
    expect(validState(running(), now)).toBe(true);
    expect(validState({ ...running(), checkedAt: now - 301 }, now)).toBe(false);
    expect(validState({ ...running(), checkedAt: now + 31 }, now)).toBe(false);
    expect(validState({ ...running(), status: "fake" }, now)).toBe(false);
    expect(validState({ ...running(), conclusion: "success" }, now)).toBe(false);
    expect(validState({ ...running(), status: "completed", finishedAt: now - 120 }, now)).toBe(false);
    expect(validState({ ...running(), arbitrary: "data" }, now)).toBe(false);
  });
});

describe("durable build delivery", () => {
  it("coalesces updates and prevents replay or a terminal result regressing", async () => {
    const stub = room();
    await stub.register(registration);
    const first = running();
    await stub.update(runKey, first);
    const complete = { ...first, status: "completed", conclusion: "failure", checkedAt: first.checkedAt + 1, finishedAt: first.checkedAt };
    expect(await stub.update(runKey, complete)).toBe(202);
    expect(await stub.update(runKey, first)).toBe(204);
    expect(await stub.update(runKey, { ...first, checkedAt: first.checkedAt + 2 })).toBe(204);
    expect(await stub.update(runKey, { ...complete, conclusion: "success", checkedAt: first.checkedAt + 3 })).toBe(204);
    await runInDurableObject(stub, (_, state) => { expect(read(state).pending).toEqual(complete); });
  });

  it("rotates tokens without extending the eight-hour lifetime", async () => {
    const stub = room();
    await stub.register(registration);
    const before = await runInDurableObject(stub, (_, state) => read(state).expiresAt);
    expect(await stub.register({ ...registration, token: "ef".repeat(32) })).toBe(204);
    await runInDurableObject(stub, (_, state) => {
      expect(read(state).token).toBe("ef".repeat(32));
      expect(read(state).expiresAt).toBe(before);
    });
    expect(await stub.register({ ...registration, runKey: "blau/made/123/3" })).toBe(409);
  });

  it("retries APNs failures from durable state and sends the latest result to the rotated token", async () => {
    const { environment } = await signingEnvironment();
    const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response(null, { status: 503 })).mockResolvedValueOnce(new Response(null, { status: 200 }));
    const stub = room();
    await stub.register(registration);
    await stub.update(runKey, running());
    await runInDurableObject(stub, async (_, state) => {
      await new BuildActivityRoom(state, environment).alarm();
      const saved = read(state);
      expect(saved.failures).toBe(1);
      expect(saved.nextAttempt).toBeGreaterThan(Date.now());
      expect(saved.pending?.status).toBe("in_progress");
    });
    await stub.register({ ...registration, token: "ef".repeat(32) });
    const complete = { ...running(), status: "completed", conclusion: "success", finishedAt: Date.now() / 1000 };
    await stub.update(runKey, complete);
    await runInDurableObject(stub, async (_, state) => {
      write(state, { ...read(state), nextAttempt: 0 });
      await new BuildActivityRoom(state, environment).alarm();
      const saved = read(state);
      expect(saved.ended).toBe(true);
      expect(saved.pending).toBeUndefined();
      expect(saved.token).toBe("");
    });
    expect(fetch).toHaveBeenCalledTimes(2);
    const [url, init] = fetch.mock.calls[1];
    expect(url).toBe(`https://api.sandbox.push.apple.com/3/device/${"ef".repeat(32)}`);
    expect(new Headers(init?.headers).get("apns-topic")).toBe("app.blau.copilot.push-type.liveactivity");
    expect(new Headers(init?.headers).get("apns-priority")).toBe("10");
    expect(JSON.parse(String(init?.body)).aps).toMatchObject({ event: "end", "content-state": complete });
    expect(await stub.update(runKey, running())).toBe(410);
  });

  it("drops an invalid APNs token and never retries it", async () => {
    const { environment } = await signingEnvironment();
    const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(null, { status: 410 }));
    const stub = room();
    await stub.register(registration);
    await stub.update(runKey, running());
    await runInDurableObject(stub, async (_, state) => {
      const instance = new BuildActivityRoom(state, environment);
      await instance.alarm();
      await instance.alarm();
      expect(read(state).ended).toBe(true);
      expect(read(state).token).toBe("");
    });
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("deletes expired records and cached provider tokens without sending a push", async () => {
    const fetch = vi.spyOn(globalThis, "fetch");
    const stub = room();
    await stub.register(registration);
    await runInDurableObject(stub, async (instance, state) => {
      write(state, { ...read(state), expiresAt: Date.now() - 1 });
      expect(await instance.update(runKey, running())).toBe(410);
      await instance.alarm();
      expect(state.storage.sql.exec("SELECT * FROM monitor").toArray()).toHaveLength(0);
      expect(await state.storage.getAlarm()).toBeNull();
    });
    expect(fetch).not.toHaveBeenCalled();
  });
});

describe("APNs wire format", () => {
  it("uses epoch seconds and different stale/dismissal dates for active and finished builds", () => {
    const state = running();
    expect(pushPayload(state, 100).aps).toMatchObject({ timestamp: 100, event: "update", "stale-date": Math.floor(state.checkedAt + 120), "content-state": state });
    const complete = { ...state, status: "completed", conclusion: "success" };
    expect(pushPayload(complete, 100).aps).toMatchObject({ timestamp: 100, event: "end", "dismissal-date": 1000 });
    expect(JSON.stringify(pushPayload(complete, 100)).length).toBeLessThan(4096);
  });

  it("signs provider tokens with a verifiable ES256 signature", async () => {
    const { environment, publicKey } = await signingEnvironment();
    const token = await providerToken(environment, 1234);
    const [header, payload, signature] = token.split(".");
    const decode = (value: string) => Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/")), c => c.charCodeAt(0));
    expect(JSON.parse(new TextDecoder().decode(decode(header)))).toEqual({ alg: "ES256", kid: "TESTKEY" });
    expect(JSON.parse(new TextDecoder().decode(decode(payload)))).toEqual({ iss: "TESTTEAM", iat: 1234 });
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, decode(signature), new TextEncoder().encode(`${header}.${payload}`))).toBe(true);
  });
});
