import http, { type IncomingMessage } from "node:http";
import https from "node:https";
import { throughRelay, type Relay } from "./relay.js";

/** The fetcher says who it is on every request, directly or through a relay. */
export const AGENT = "MeesamWatch/1.0 (+https://meesam.ae; publication fetcher)";

/**
 * One GET over node:http(s), following redirects. Used instead of the built-in fetch because its connection
 * timeout is fixed at 10 seconds and it may try IPv6 first: registry sites far from the worker's region need
 * longer, and several answer on IPv4 only. `family` 4 is tried first; the error names what actually happened
 * (timed out while connecting, refused, reset, a status code), so the incident page says something useful.
 */
export async function get(url: string, opts: { accept?: string; connectMs: number; idleMs: number; via?: Relay | null }, hops = 0): Promise<IncomingMessage> {
  const u = new URL(url);
  // a source fetched through a relay (see relay.ts): the same request, carried from inside the registry's country
  const carried = opts.via ? await throughRelay(opts.via, u, opts.connectMs) : null;
  const where = opts.via ? `${u.host} (through relay ${opts.via.name})` : u.host;
  return new Promise((resolve, reject) => {
    const lib = u.protocol === "http:" ? http : https;
    const headers = { "user-agent": AGENT, accept: opts.accept ?? "*/*", ...(carried?.headers ?? {}) };
    const options = carried
      ? { protocol: u.protocol, host: carried.host ?? u.hostname, port: carried.port ?? (u.port || undefined), path: carried.path ?? `${u.pathname}${u.search}`, servername: u.hostname, agent: false as const, createConnection: carried.createConnection, headers: carried.path ? { ...headers, host: u.host } : headers }
      : { protocol: u.protocol, host: u.hostname, port: u.port || undefined, path: `${u.pathname}${u.search}`, family: 4, headers };
    const req = lib.get(options, (res) => {
      const code = res.statusCode ?? 0;
      if (code >= 300 && code < 400 && res.headers.location) {
        res.resume();
        if (hops >= 5) return reject(new Error("too many redirects"));
        return resolve(get(new URL(res.headers.location, u).toString(), opts, hops + 1));
      }
      if (code < 200 || code >= 300) { res.resume(); return reject(new Error(`${where} answered ${code}`)); }
      res.setTimeout(opts.idleMs, () => res.destroy(new Error(`${where} stopped sending after ${Math.round(opts.idleMs / 1000)} s`)));
      resolve(res);
    });
    // connected but silent (no answer to the request) is a failure too, not something to wait on for ever
    req.setTimeout(opts.idleMs, () => req.destroy(new Error(`${where} accepted the connection but sent nothing for ${Math.round(opts.idleMs / 1000)} s`)));
    const connecting = setTimeout(() => req.destroy(new Error(opts.via
      ? `no connection to ${u.host} within ${Math.round(opts.connectMs / 1000)} s through relay ${opts.via.name} (the site did not answer the relay either)`
      : `no connection to ${u.host} within ${Math.round(opts.connectMs / 1000)} s (the site did not answer from this server's network)`)), opts.connectMs);
    req.on("socket", (sock) => {
      // through a relay the connection is already made (and, for https, may already be secured) when the request gets it
      const s = sock as typeof sock & { connecting?: boolean; encrypted?: boolean; authorized?: boolean; secureConnecting?: boolean };
      if (carried && (u.protocol === "http:" ? !s.connecting : s.encrypted && !s.secureConnecting)) return clearTimeout(connecting);
      sock.once(u.protocol === "http:" ? "connect" : "secureConnect", () => clearTimeout(connecting));
    });
    req.on("error", (e: NodeJS.ErrnoException) => { clearTimeout(connecting); reject(e.code && !e.message.includes(e.code) ? new Error(`${e.message} (${e.code})`) : e); });
  });
}
