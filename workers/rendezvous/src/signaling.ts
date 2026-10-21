import { DurableObject } from "cloudflare:workers";
import { AlarmSchedule } from "./alarm";

/**
 * Signaling / rendezvous Durable Object for UDP hole punching (issue #51,
 * Phase 1). One instance per shared pairing `token`. It records at most two
 * distinct peers (a pair) so two devices that present the same token can learn
 * each other's public UDP endpoint and then punch a hole directly.
 *
 * The server is intentionally dumb about crypto: it only stores each peer's
 * long-term public key (opaque base64), the observed source IP, and the UDP
 * port the peer reported. It NEVER sees plaintext, session keys, or the
 * pairing secret used to derive the handshake — only the routing metadata
 * needed to introduce the two endpoints.
 */

/** A registered peer in a token's pair. */
export interface Peer {
  /** Long-term Curve25519 public key, base64. Identifies the peer. */
  publicKey: string;
  /** Public IP observed by the edge (CF-Connecting-IP), not self-reported. */
  ip: string;
  /** UDP port the peer reported it is listening on. */
  port: number;
  /** Last registration time (ms epoch), used for TTL eviction. */
  updatedAt: number;
}

/** Persisted shape: the (<=2) peers keyed by their public key. */
type PeerMap = Record<string, Peer>;

/**
 * How long a registration stays valid. Stale peers are evicted on the next
 * touch so a long-dead device can't keep occupying a pair slot. UDP hole
 * punches are short-lived, so a few minutes is plenty.
 */
const PEER_TTL_MS = 5 * 60 * 1000;

/** Hard cap on distinct public keys per token: a pair, never a crowd. */
const MAX_PEERS_PER_TOKEN = 2;

const STORAGE_KEY = "peers";

export type RegistrationResult =
  | { status: "registered"; peer: Peer | null }
  | { status: "full" };

/**
 * The first instant at which `load` evicts every stored peer, or null when
 * nothing is stored. Eviction requires strictly more than `PEER_TTL_MS`.
 */
function cleanupDeadline(peers: PeerMap): number | null {
  const updates = Object.values(peers).map((peer) => peer.updatedAt);
  return updates.length === 0 ? null : Math.max(...updates) + PEER_TTL_MS + 1;
}

export class SignalingRoom extends DurableObject<unknown> {
  private readonly cleanup = new AlarmSchedule(this.ctx.storage);

  /**
   * Register (or refresh) a peer under this token. On success, returns the
   * OTHER peer if it is already present. A third distinct key is rejected.
   */
  async register(input: {
    publicKey: string;
    ip: string;
    port: number;
  }): Promise<RegistrationResult> {
    const now = Date.now();
    const peers = await this.load(now);

    // Re-registration of a known key always refreshes in place (IP/port may
    // change as the device's NAT mapping moves) and never counts against the
    // cap.
    const existing = peers[input.publicKey];
    if (!existing && Object.keys(peers).length >= MAX_PEERS_PER_TOKEN) {
      return { status: "full" };
    }

    const peer: Peer = {
      publicKey: input.publicKey,
      ip: input.ip,
      port: input.port,
      updatedAt: now,
    };
    peers[input.publicKey] = peer;
    await this.save(peers);
    // Bound the lifetime of this DO's storage with an alarm so abandoned
    // tokens self-clean instead of lingering forever. A refresh only moves the
    // deadline later, so an already-scheduled earlier alarm is kept and
    // rearms itself when it fires.
    await this.cleanup.require(cleanupDeadline(peers));
    const other = Object.entries(peers).find(
      ([publicKey]) => publicKey !== input.publicKey,
    )?.[1];
    return { status: "registered", peer: other ?? null };
  }

  /**
   * Return the OTHER peer in this token's pair (the one whose public key is not
   * `publicKey`), or `null` if no such peer has registered yet.
   */
  async getPeer(publicKey: string): Promise<Peer | null> {
    const now = Date.now();
    const peers = await this.load(now);
    for (const [key, peer] of Object.entries(peers)) {
      if (key !== publicKey) return peer;
    }
    return null;
  }

  /** Storage TTL alarm: drop everything once the pair has gone stale. */
  async alarm(): Promise<void> {
    const peers = await this.load(Date.now());
    if (Object.keys(peers).length === 0) await this.ctx.storage.deleteAll();
    // Re-arm for the moment the last fresh peer expires, or clear the alarm.
    await this.cleanup.replace(cleanupDeadline(peers));
  }

  /** Load peers, evicting any that have aged past the TTL. */
  private async load(now: number): Promise<PeerMap> {
    const stored =
      (await this.ctx.storage.get<PeerMap>(STORAGE_KEY)) ?? {};
    let changed = false;
    for (const [key, peer] of Object.entries(stored)) {
      if (now - peer.updatedAt > PEER_TTL_MS) {
        delete stored[key];
        changed = true;
      }
    }
    if (changed) await this.save(stored);
    return stored;
  }

  private async save(peers: PeerMap): Promise<void> {
    await this.ctx.storage.put(STORAGE_KEY, peers);
  }
}
