import http from "node:http";
import https from "node:https";
import type { Socket } from "node:net";
import tls from "node:tls";

/**
 * Relays (Founder, 27 Nov 2026). Some registries answer only networks inside their own country or region, and the
 * worker runs elsewhere. A relay is a small server of Meesam's own inside that country, with a fixed address,
 * running an ordinary forward proxy; a source that names one (`fetch_spec.via`, set by the watch operations lead)
 * is fetched through it. The request is still Meesam's own, with Meesam's name on it: the relay only carries it.
 *
 * Where a relay is and how to sign in to it is configuration of the worker, never data and never code:
 * FETCH_RELAY_<NAME> = https://user:password@host:port (http:// only for a relay on a private network).
 * A source that names a relay this worker does not have is not fetched directly instead: it fails, and says so.
 */
export interface Relay { name: string; url: URL }

export function relayFor(name: string | undefined | null): Relay | null {
  const n = String(name ?? "").trim().toUpperCase();
  if (!n) return null;
  if (!/^[A-Z0-9_]{2,20}$/.test(n)) throw new Error(`"${n}" is not a relay name`);
  const raw = (process.env[`FETCH_RELAY_${n}`] ?? "").trim();
  if (!raw) throw new Error(`relay ${n} is not set up on this worker (FETCH_RELAY_${n})`);
  let url: URL;
  try { url = new URL(raw); } catch { throw new Error(`the address of relay ${n} is not a valid address`); }
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new Error(`the address of relay ${n} must start with https:// or http://`);
  return { name: n, url };
}

const auth = (r: Relay): Record<string, string> =>
  r.url.username ? { "proxy-authorization": `Basic ${Buffer.from(`${decodeURIComponent(r.url.username)}:${decodeURIComponent(r.url.password)}`).toString("base64")}` } : {};

/** A connection to host:port carried by the relay (HTTP CONNECT). The error says which side failed. */
export function tunnel(r: Relay, host: string, port: number, connectMs: number): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const lib = r.url.protocol === "http:" ? http : https;
    const req = lib.request({
      host: r.url.hostname, port: Number(r.url.port) || (r.url.protocol === "http:" ? 80 : 443), method: "CONNECT", path: `${host}:${port}`,
      headers: { host: `${host}:${port}`, ...auth(r) }, family: 4, agent: false,
    });
    const timer = setTimeout(() => req.destroy(new Error(`relay ${r.name} did not connect to ${host} within ${Math.round(connectMs / 1000)} s`)), connectMs);
    req.once("connect", (res, socket) => {
      clearTimeout(timer);
      if (res.statusCode === 200) return resolve(socket);
      socket.destroy();
      reject(new Error(res.statusCode === 407 ? `relay ${r.name} refused Meesam's sign-in (407)` : `relay ${r.name} could not reach ${host} (${res.statusCode})`));
    });
    req.once("error", (e) => { clearTimeout(timer); reject(new Error(`relay ${r.name}: ${e.message}`)); });
    req.end();
  });
}

/** What node:http(s) needs to send one request through the relay: a ready connection for https, the proxy itself for http. */
export async function throughRelay(r: Relay, u: URL, connectMs: number): Promise<{ createConnection?: () => Socket; agent: false; host?: string; port?: number; path?: string; headers?: Record<string, string> }> {
  if (u.protocol === "http:") {
    if (r.url.protocol !== "http:") throw new Error(`relay ${r.name} carries https addresses only`);
    return { agent: false, host: r.url.hostname, port: Number(r.url.port) || 80, path: u.toString(), headers: auth(r) };
  }
  const raw = await tunnel(r, u.hostname, Number(u.port) || 443, connectMs);
  const secure = tls.connect({ socket: raw, servername: u.hostname });
  return { agent: false, createConnection: () => secure };
}
