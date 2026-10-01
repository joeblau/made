import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  reset,
  runDurableObjectAlarm,
  runInDurableObject,
} from "cloudflare:test";
import { AlarmSchedule, type AlarmStorage } from "../src/alarm";
import worker, { RendezvousRoom } from "../src/index";
import { SignalingRoom } from "../src/signaling";

// Mirrors the limits in src/index.ts and src/signaling.ts.
const SOCKET_IDLE_MS = 2 * 60 * 1000;
const SOCKET_LIFETIME_MS = 30 * 60 * 1000;
const PEER_TTL_MS = 5 * 60 * 1000;

afterEach(async () => {
  await reset();
});

class CountingStorage implements AlarmStorage {
  alarm: number | null;
  gets = 0;
  sets: number[] = [];
  deletes = 0;

  constructor(initial: number | null = null) {
    this.alarm = initial;
  }

  async getAlarm(): Promise<number | null> {
    this.gets += 1;
    return this.alarm;
  }

  async setAlarm(time: number | Date): Promise<void> {
    const value = typeof time === "number" ? time : time.getTime();
    this.sets.push(value);
    this.alarm = value;
  }

  async deleteAlarm(): Promise<void> {
    this.deletes += 1;
    this.alarm = null;
  }
}

describe("AlarmSchedule", () => {
  it("writes once for a burst of later deadlines", async () => {
    const storage = new CountingStorage();
    const schedule = new AlarmSchedule(storage);
    for (let index = 0; index < 1_000; index += 1) {
      await schedule.require(10_000 + index);
    }
    expect(storage.gets).toBe(1);
    expect(storage.sets).toEqual([10_000]);
    expect(storage.deletes).toBe(0);
  });

  it("moves a later alarm earlier immediately", async () => {
    const storage = new CountingStorage(50_000);
    const schedule = new AlarmSchedule(storage);
    await schedule.require(20_000);
    expect(storage.sets).toEqual([20_000]);
    await schedule.require(5_000);
    expect(storage.sets).toEqual([20_000, 5_000]);
    expect(storage.gets).toBe(1);
  });

  it("reads storage again on a reconstructed instance", async () => {
    const storage = new CountingStorage();
    await new AlarmSchedule(storage).require(30_000);

    const reconstructed = new AlarmSchedule(storage);
    await reconstructed.require(40_000);
    await reconstructed.require(40_001);
    expect(storage.gets).toBe(2);
    expect(storage.sets).toEqual([30_000]);
  });

  it("replaces the running alarm unconditionally and caches the result", async () => {
    const storage = new CountingStorage();
    const schedule = new AlarmSchedule(storage);
    await schedule.require(10_000);
    // From alarm(): a later deadline must still be written, since the alarm
    // that is running is about to be consumed.
    await schedule.replace(12_000);
    await schedule.require(12_500);
    expect(storage.sets).toEqual([10_000, 12_000]);
    await schedule.replace(null);
    expect(storage.deletes).toBe(1);
    expect(storage.gets).toBe(1);
  });

  it("clears only an alarm that exists", async () => {
    const storage = new CountingStorage(10_000);
    const schedule = new AlarmSchedule(storage);
    await schedule.require(null);
    await schedule.require(null);
    expect(storage.deletes).toBe(1);
    expect(storage.alarm).toBeNull();
  });
});

function token(): string {
  return `ABCDEFGH${crypto.randomUUID().replaceAll("-", "")}`;
}

function publicKey(seed: number): string {
  return btoa(
    String.fromCharCode(...Array.from({ length: 32 }, (_, index) => seed + index)),
  );
}

interface Attachment {
  byteCount: number;
  connectedAt: number;
  lastActivityAt: number;
  messageCount: number;
  windowStartedAt: number;
}

function deadline(attachment: Attachment): number {
  return Math.min(
    attachment.lastActivityAt + SOCKET_IDLE_MS,
    attachment.connectedAt + SOCKET_LIFETIME_MS,
  );
}

async function openRoom(peers: number) {
  const code = token();
  const clients: WebSocket[] = [];
  for (let index = 0; index < peers; index += 1) {
    const response = await worker.fetch(
      new Request(`https://rendezvous.example.test/room/${code}`, {
        headers: {
          "CF-Connecting-IP": `203.0.113.${index + 1}`,
          Upgrade: "websocket",
        },
      }),
      env,
    );
    expect(response.status).toBe(101);
    const client = response.webSocket;
    if (!client) throw new Error("missing client socket");
    client.accept();
    clients.push(client);
  }
  return { clients, stub: env.ROOMS.get(env.ROOMS.idFromName(code)) };
}

function closeEvent(socket: WebSocket): Promise<CloseEvent> {
  return new Promise((resolve) => socket.addEventListener("close", resolve));
}

function countAlarmOperations(storage: DurableObjectStorage) {
  const spies = {
    get: vi.spyOn(storage, "getAlarm"),
    set: vi.spyOn(storage, "setAlarm"),
    delete: vi.spyOn(storage, "deleteAlarm"),
  };
  return {
    counts: () => ({
      get: spies.get.mock.calls.length,
      set: spies.set.mock.calls.length,
      delete: spies.delete.mock.calls.length,
    }),
    restore: () => Object.values(spies).forEach((spy) => spy.mockRestore()),
  };
}

function editAttachments(
  state: DurableObjectState,
  edit: (attachment: Attachment) => void,
): void {
  for (const socket of state.getWebSockets()) {
    const attachment = socket.deserializeAttachment() as Attachment;
    edit(attachment);
    socket.serializeAttachment(attachment);
  }
}

describe("relay expiry alarm", () => {
  it("keeps the existing alarm through a sustained message burst", async () => {
    const { stub } = await openRoom(2);
    await runInDurableObject(stub, async (instance, state) => {
      const before = await state.storage.getAlarm();
      expect(before).not.toBeNull();
      const operations = countAlarmOperations(state.storage);
      const [sender] = state.getWebSockets();
      for (let index = 0; index < 50; index += 1) {
        await instance.webSocketMessage(sender, `message ${index}`);
      }
      // Baseline before this change: 50 setAlarm calls for 50 messages.
      expect(operations.counts()).toEqual({ get: 0, set: 0, delete: 0 });
      operations.restore();
      expect(await state.storage.getAlarm()).toBe(before);
    });
  });

  it("reads the stored alarm once after reconstruction", async () => {
    const { stub } = await openRoom(2);
    await runInDurableObject(stub, async (_instance, state) => {
      const reconstructed = new RendezvousRoom(state, env);
      const operations = countAlarmOperations(state.storage);
      const [sender] = state.getWebSockets();
      for (let index = 0; index < 10; index += 1) {
        await reconstructed.webSocketMessage(sender, "message");
      }
      expect(operations.counts()).toEqual({ get: 1, set: 0, delete: 0 });
      operations.restore();
    });
  });

  it("never delays a deadline earlier than the stored alarm", async () => {
    const { stub } = await openRoom(2);
    await runInDurableObject(stub, async (_instance, state) => {
      await state.storage.setAlarm(Date.now() + 60 * 60 * 1000);
      const reconstructed = new RendezvousRoom(state, env);
      const [sender] = state.getWebSockets();
      await reconstructed.webSocketMessage(sender, "message");

      const required = Math.min(
        ...state
          .getWebSockets()
          .map((socket) => deadline(socket.deserializeAttachment() as Attachment)),
      );
      expect(await state.storage.getAlarm()).toBe(required);
    });
  });

  it("rearms an early retained alarm for the earliest live deadline", async () => {
    const { stub } = await openRoom(2);
    const early = Date.now() + 1_000;
    await runInDurableObject(stub, async (_instance, state) => {
      editAttachments(state, (attachment) => {
        attachment.lastActivityAt = Date.now() + 30_000;
      });
      await state.storage.setAlarm(early);
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    await runInDurableObject(stub, async (_instance, state) => {
      expect(state.getWebSockets()).toHaveLength(2);
      const required = Math.min(
        ...state
          .getWebSockets()
          .map((socket) => deadline(socket.deserializeAttachment() as Attachment)),
      );
      const alarm = await state.storage.getAlarm();
      expect(alarm).toBe(required);
      expect(alarm).toBeGreaterThan(early);
    });
  });

  it("enforces the idle limit from the alarm of a reconstructed object", async () => {
    const { clients, stub } = await openRoom(2);
    const closes = clients.map(closeEvent);
    await runInDurableObject(stub, async (_instance, state) => {
      editAttachments(state, (attachment) => {
        attachment.lastActivityAt = Date.now() - SOCKET_IDLE_MS;
      });
      await new RendezvousRoom(state, env).alarm();
      expect(await state.storage.getAlarm()).toBeNull();
    });
    for (const close of closes) {
      await expect(close).resolves.toMatchObject({ code: 1008 });
    }
  });

  it("enforces the absolute lifetime on a late message", async () => {
    const { clients, stub } = await openRoom(2);
    const firstClose = Promise.race(clients.map(closeEvent));
    const relayed: unknown[] = [];
    for (const client of clients) {
      client.addEventListener("message", (event) => {
        relayed.push(event.data);
      });
    }
    await runInDurableObject(stub, async (instance, state) => {
      const [sender] = state.getWebSockets();
      const attachment = sender.deserializeAttachment() as Attachment;
      attachment.connectedAt = Date.now() - SOCKET_LIFETIME_MS;
      attachment.lastActivityAt = Date.now();
      sender.serializeAttachment(attachment);
      await instance.webSocketMessage(sender, "late");
    });
    await expect(firstClose).resolves.toMatchObject({ code: 1008 });
    expect(relayed).not.toContain("late");
  });

  it("rejects a message that arrives after the idle limit", async () => {
    const { clients, stub } = await openRoom(1);
    const closed = closeEvent(clients[0]);
    await runInDurableObject(stub, async (instance, state) => {
      const [sender] = state.getWebSockets();
      const attachment = sender.deserializeAttachment() as Attachment;
      attachment.lastActivityAt = Date.now() - SOCKET_IDLE_MS;
      sender.serializeAttachment(attachment);
      await instance.webSocketMessage(sender, "late");
    });
    await expect(closed).resolves.toMatchObject({ code: 1008 });
  });

  it("keeps the remaining peer's alarm and clears it when the room empties", async () => {
    const { clients, stub } = await openRoom(2);
    clients[0].close();
    await vi.waitFor(async () => {
      await runInDurableObject(stub, async (_instance, state) => {
        expect(state.getWebSockets()).toHaveLength(1);
      });
    });
    await runInDurableObject(stub, async (_instance, state) => {
      const [remaining] = state.getWebSockets();
      expect(await state.storage.getAlarm()).toBeLessThanOrEqual(
        deadline(remaining.deserializeAttachment() as Attachment),
      );
    });

    clients[1].close();
    await vi.waitFor(async () => {
      await runInDurableObject(stub, async (_instance, state) => {
        expect(state.getWebSockets()).toHaveLength(0);
        expect(await state.storage.getAlarm()).toBeNull();
      });
    });
  });
});

describe("signaling cleanup alarm", () => {
  it("keeps the earlier cleanup alarm when a peer refreshes", async () => {
    const stub = env.SIGNALS.get(env.SIGNALS.idFromName(token()));
    const key = publicKey(1);
    await stub.register({ publicKey: key, ip: "203.0.113.1", port: 45_001 });

    await runInDurableObject(stub, async (instance, state) => {
      const peers = await state.storage.get<Record<string, { updatedAt: number }>>(
        "peers",
      );
      const first = await state.storage.getAlarm();
      expect(first).toBe((peers?.[key]?.updatedAt ?? 0) + PEER_TTL_MS + 1);

      const operations = countAlarmOperations(state.storage);
      for (let index = 0; index < 20; index += 1) {
        await (instance as SignalingRoom).register({
          publicKey: key,
          ip: "203.0.113.1",
          port: 45_001,
        });
      }
      // Baseline before this change: 20 setAlarm calls for 20 refreshes.
      expect(operations.counts()).toEqual({ get: 0, set: 0, delete: 0 });
      operations.restore();
      expect(await state.storage.getAlarm()).toBe(first);
    });
  });

  it("rearms from the latest peer expiry and drops an abandoned token", async () => {
    const stub = env.SIGNALS.get(env.SIGNALS.idFromName(token()));
    await stub.register({ publicKey: publicKey(1), ip: "203.0.113.1", port: 46_001 });
    await stub.register({ publicKey: publicKey(2), ip: "203.0.113.2", port: 46_002 });

    const now = Date.now();
    await runInDurableObject(stub, async (_instance, state) => {
      const peers = await state.storage.get<Record<string, { updatedAt: number }>>(
        "peers",
      );
      const [older, newer] = Object.values(peers ?? {});
      older.updatedAt = now - PEER_TTL_MS - 1;
      newer.updatedAt = now - 1_000;
      await state.storage.put("peers", peers ?? {});
    });

    expect(await runDurableObjectAlarm(stub)).toBe(true);
    await runInDurableObject(stub, async (_instance, state) => {
      const peers = await state.storage.get<Record<string, unknown>>("peers");
      expect(Object.keys(peers ?? {})).toHaveLength(1);
      expect(await state.storage.getAlarm()).toBe(now - 1_000 + PEER_TTL_MS + 1);

      const reconstructed = new SignalingRoom(state, env);
      const stored = peers as Record<string, { updatedAt: number }>;
      for (const peer of Object.values(stored)) peer.updatedAt = now - PEER_TTL_MS - 1;
      await state.storage.put("peers", stored);
      await reconstructed.alarm();
      expect(await state.storage.get("peers")).toBeUndefined();
      expect(await state.storage.getAlarm()).toBeNull();
    });
  });
});
