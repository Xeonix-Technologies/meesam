/**
 * What Meesam checks and how it names a publication file, shared by the worker (fetched issues) and the web
 * service (issues added by hand under the temporary ruling of 19 Nov 2026): the same shape check and the same
 * place in the bucket, whichever way the file arrived.
 */
const MAGIC: Record<string, number[]> = {
  rar: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07],
  zip: [0x50, 0x4b, 0x03, 0x04],
  pdf: [0x25, 0x50, 0x44, 0x46],
};

/**
 * The shape check on a downloaded file (Section 4): it is the kind of file the catalogue expects, of a plausible
 * size, and its date is not in the future. Returns the reason it fails, or null when it passes. (The mark-count
 * range of Section 4 is checked after extraction, when the marks are known.)
 */
export function shapeProblem(head: Uint8Array, bytes: number, publishedOn: string | null, spec: { container?: string; min_bytes?: number }, today = new Date()): string | null {
  const kind = (spec.container ?? "pdf").toLowerCase();
  const magic = MAGIC[kind];
  if (!magic) return `the catalogue names an unknown file kind: ${kind}`;
  if (!magic.every((b, i) => head[i] === b)) return `the file is not a ${kind.toUpperCase()} file (the site may have answered with a page)`;
  const min = spec.min_bytes ?? 20 * 1024;
  if (bytes < min) return `the file is too small to be an issue: ${bytes} bytes`;
  if (publishedOn && new Date(`${publishedOn}T00:00:00Z`).getTime() > today.getTime() + 36 * 3600 * 1000) return `the issue date ${publishedOn} is in the future`;
  return null;
}

export const contentTypeOf = (container: string): string =>
  ({ rar: "application/vnd.rar", zip: "application/zip", pdf: "application/pdf" })[container.toLowerCase()] ?? "application/octet-stream";

/** Where an issue is kept in the publications bucket: registry / stream / number and the start of its checksum. */
export function issueKey(registry: string, stream: string, issueNo: string, sha256Hex: string, container: string): string {
  const safe = issueNo.replace(/[^A-Za-z0-9]+/g, "-").replace(/^-|-$/g, "") || "issue";
  return `${registry}/${stream}/${safe}_${sha256Hex.slice(0, 12)}.${container.toLowerCase().replace(/[^a-z0-9]/g, "")}`;
}
