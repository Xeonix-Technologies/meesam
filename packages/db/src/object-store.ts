import { createHash, createHmac } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import https from "node:https";
import http from "node:http";

/**
 * Minimal S3 client (SigV4, path-style) for the Railway buckets — PUT, GET, HEAD, DELETE and
 * presigned GET. No SDK: one file, no dependency, works with any S3-compatible endpoint
 * (Railway buckets are Tigris, region "auto"). Documents never touch a volume or the database.
 * Shared by the web service (vault) and the worker (fetched publications).
 */
export interface VaultConfig {
  bucket: string;
  endpoint: string; // e.g. https://t3.storageapi.dev
  accessKeyId: string;
  secretAccessKey: string;
  region: string;
}

export function vaultConfig(prefix: "VAULT" | "PUBLICATIONS" | "BACKUP" = "VAULT"): VaultConfig {
  const get = (k: string) => process.env[`${prefix}_${k}`];
  const bucket = get("BUCKET");
  const endpoint = get("ENDPOINT");
  const accessKeyId = get("ACCESS_KEY_ID");
  const secretAccessKey = get("SECRET_ACCESS_KEY");
  if (!bucket || !endpoint || !accessKeyId || !secretAccessKey) throw new Error(`${prefix}_* bucket variables are not set`);
  return { bucket, endpoint: endpoint.replace(/\/$/, "").replace(/^(?!https?:\/\/)/, "https://"), accessKeyId, secretAccessKey, region: get("REGION") ?? "auto" };
}

const sha256hex = (data: Buffer | string) => createHash("sha256").update(data).digest("hex");
const hmac = (key: Buffer | string, data: string) => createHmac("sha256", key).update(data).digest();

function amzDate(d = new Date()): { amz: string; day: string } {
  const iso = d.toISOString().replace(/[:-]|\.\d{3}/g, "");
  return { amz: iso, day: iso.slice(0, 8) };
}

function encodeKey(key: string): string {
  return key.split("/").map((s) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)).join("/");
}

function signingKey(cfg: VaultConfig, day: string): Buffer {
  return hmac(hmac(hmac(hmac(`AWS4${cfg.secretAccessKey}`, day), cfg.region), "s3"), "aws4_request");
}

interface SignedRequest { url: string; headers: Record<string, string> }

function sign(cfg: VaultConfig, method: string, key: string, body: Buffer | null, extraHeaders: Record<string, string> = {}, knownHash?: string): SignedRequest {
  const { amz, day } = amzDate();
  const url = new URL(cfg.endpoint);
  const path = `/${cfg.bucket}/${encodeKey(key)}`;
  const payloadHash = knownHash ?? (body ? sha256hex(body) : sha256hex(""));
  const headers: Record<string, string> = {
    host: url.host,
    "x-amz-date": amz,
    "x-amz-content-sha256": payloadHash,
    ...Object.fromEntries(Object.entries(extraHeaders).map(([k, v]) => [k.toLowerCase(), v])),
  };
  const signedHeaderNames = Object.keys(headers).sort();
  const canonicalHeaders = signedHeaderNames.map((h) => `${h}:${headers[h]!.trim()}\n`).join("");
  const canonical = [method, path, "", canonicalHeaders, signedHeaderNames.join(";"), payloadHash].join("\n");
  const scope = `${day}/${cfg.region}/s3/aws4_request`;
  const toSign = ["AWS4-HMAC-SHA256", amz, scope, sha256hex(canonical)].join("\n");
  const signature = createHmac("sha256", signingKey(cfg, day)).update(toSign).digest("hex");
  headers.authorization = `AWS4-HMAC-SHA256 Credential=${cfg.accessKeyId}/${scope}, SignedHeaders=${signedHeaderNames.join(";")}, Signature=${signature}`;
  delete headers.host;
  return { url: `${url.origin}${path}`, headers };
}

/**
 * Asks the storage one harmless question (list at most one object) and reports how it answered, to tell apart a
 * key that cannot reach the bucket at all from one that may read it but not write. Reads nothing and changes nothing.
 */
export async function probeBucket(cfg: VaultConfig): Promise<{ status: number; code: string }> {
  const { amz, day } = amzDate();
  const url = new URL(cfg.endpoint);
  const path = `/${cfg.bucket}`;
  const query = "list-type=2&max-keys=1";
  const payloadHash = sha256hex("");
  const headers: Record<string, string> = { host: url.host, "x-amz-content-sha256": payloadHash, "x-amz-date": amz };
  const names = Object.keys(headers).sort();
  const canonical = ["GET", path, query, names.map((h) => `${h}:${headers[h]}\n`).join(""), names.join(";"), payloadHash].join("\n");
  const scope = `${day}/${cfg.region}/s3/aws4_request`;
  const signature = createHmac("sha256", signingKey(cfg, day)).update(["AWS4-HMAC-SHA256", amz, scope, sha256hex(canonical)].join("\n")).digest("hex");
  const res = await fetch(`${url.origin}${path}?${query}`, { headers: { "x-amz-content-sha256": payloadHash, "x-amz-date": amz, authorization: `AWS4-HMAC-SHA256 Credential=${cfg.accessKeyId}/${scope}, SignedHeaders=${names.join(";")}, Signature=${signature}` } });
  const text = res.ok ? "" : await res.text();
  return { status: res.status, code: res.ok ? "ok" : (/<Code>([^<]+)<\/Code>/.exec(text)?.[1] ?? "unknown") };
}

export async function putObject(cfg: VaultConfig, key: string, body: Buffer, contentType: string): Promise<void> {
  const req = sign(cfg, "PUT", key, body, { "content-type": contentType, "content-length": String(body.length) });
  const res = await fetch(req.url, { method: "PUT", headers: req.headers, body: new Uint8Array(body) });
  if (!res.ok) throw new Error(`vault PUT ${key} failed: ${res.status} ${(await res.text()).slice(0, 200)}`);
}

export async function getObject(cfg: VaultConfig, key: string): Promise<{ body: Buffer; contentType: string | null }> {
  const req = sign(cfg, "GET", key, null);
  const res = await fetch(req.url, { headers: req.headers });
  if (!res.ok) throw new Error(`vault GET ${key} failed: ${res.status}`);
  return { body: Buffer.from(await res.arrayBuffer()), contentType: res.headers.get("content-type") };
}

/** Downloads an object straight to a file, without holding it in memory (a publication issue can be hundreds of megabytes). */
export async function getObjectFile(cfg: VaultConfig, key: string, filePath: string): Promise<number> {
  const req = sign(cfg, "GET", key, null);
  const res = await fetch(req.url, { headers: req.headers });
  if (!res.ok || !res.body) throw new Error(`bucket GET ${key} failed: ${res.status}`);
  await pipeline(Readable.fromWeb(res.body as never), createWriteStream(filePath));
  return Number(res.headers.get("content-length") ?? 0);
}

export async function deleteObject(cfg: VaultConfig, key: string): Promise<void> {
  const req = sign(cfg, "DELETE", key, null);
  const res = await fetch(req.url, { method: "DELETE", headers: req.headers });
  if (!res.ok && res.status !== 404) throw new Error(`vault DELETE ${key} failed: ${res.status}`);
}

export async function copyObject(cfg: VaultConfig, fromKey: string, toKey: string): Promise<void> {
  const req = sign(cfg, "PUT", toKey, null, { "x-amz-copy-source": `/${cfg.bucket}/${encodeKey(fromKey)}` });
  const res = await fetch(req.url, { method: "PUT", headers: req.headers });
  if (!res.ok) throw new Error(`vault COPY ${fromKey} → ${toKey} failed: ${res.status} ${(await res.text()).slice(0, 200)}`);
}

/** Presigned GET, short-lived; the browser downloads straight from the bucket after Meesam has checked access. */
export function presignGet(cfg: VaultConfig, key: string, expiresSeconds = 600, downloadName?: string): string {
  const { amz, day } = amzDate();
  const url = new URL(cfg.endpoint);
  const path = `/${cfg.bucket}/${encodeKey(key)}`;
  const scope = `${day}/${cfg.region}/s3/aws4_request`;
  const params = new URLSearchParams({
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
    "X-Amz-Credential": `${cfg.accessKeyId}/${scope}`,
    "X-Amz-Date": amz,
    "X-Amz-Expires": String(expiresSeconds),
    "X-Amz-SignedHeaders": "host",
  });
  if (downloadName) params.set("response-content-disposition", `attachment; filename*=UTF-8''${encodeURIComponent(downloadName)}`);
  params.sort();
  const canonicalQuery = [...params.entries()].map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
  const canonical = ["GET", path, canonicalQuery, `host:${url.host}\n`, "host", "UNSIGNED-PAYLOAD"].join("\n");
  const toSign = ["AWS4-HMAC-SHA256", amz, scope, sha256hex(canonical)].join("\n");
  const signature = createHmac("sha256", signingKey(cfg, day)).update(toSign).digest("hex");
  return `${url.origin}${path}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}

/**
 * Uploads a file from local scratch space without holding it in memory (a publication issue can be hundreds of
 * megabytes). The caller has already computed the file's SHA-256 while downloading it; S3 verifies it on arrival.
 */
export function putObjectFile(cfg: VaultConfig, key: string, filePath: string, size: number, sha256Hex: string, contentType: string): Promise<void> {
  const req = sign(cfg, "PUT", key, null, { "content-type": contentType, "content-length": String(size) }, sha256Hex);
  const url = new URL(req.url);
  return new Promise((resolve, reject) => {
    const out = (url.protocol === "http:" ? http : https).request(url, { method: "PUT", headers: req.headers }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (c: Buffer) => chunks.push(c));
      res.on("end", () => ((res.statusCode ?? 500) < 300 ? resolve() : reject(new Error(`bucket PUT ${key} failed: ${res.statusCode} ${Buffer.concat(chunks).toString("utf8").slice(0, 200)}`))));
    });
    out.on("error", reject);
    out.setTimeout(10 * 60 * 1000, () => out.destroy(new Error(`bucket PUT ${key} timed out`)));
    const file = createReadStream(filePath);
    file.on("error", (e) => out.destroy(e));
    file.pipe(out);
  });
}
