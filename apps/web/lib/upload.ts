import { createHash } from "node:crypto";
import { ALLOWED_UPLOAD_TYPES, MAX_UPLOAD_BYTES, putObject, vaultConfig, vaultKey } from "./s3";

export const DOC_TYPES = ["APP", "OAC", "RSP", "PUB", "OPP", "ORC", "REN", "DOU", "ASG", "LIC", "CNA", "POA", "LGR", "OTH"] as const;
export type DocType = (typeof DOC_TYPES)[number];
/** The mark's own image: a fifteenth code (Founder ruling 18 Nov 2026), set by the image upload, not chosen from the document list. */
export const MARK_IMAGE_TYPE = "IMG";

export interface StoredUpload { object_key: string; doc_type: string; file_name: string; content_type: string; size: number; sha256: string; uploaded_at: string }

/** Validates, names per item 43 and stores one uploaded file in the vault bucket. */
export async function storeUpload(file: File, docType: string, registryCode: string, registrationNo: string | null, applicationNo: string | null, taken: Set<string>): Promise<StoredUpload | { error: string }> {
  if (docType !== MARK_IMAGE_TYPE && !(DOC_TYPES as readonly string[]).includes(docType)) return { error: "docType" };
  const ext = ALLOWED_UPLOAD_TYPES[file.type];
  if (!ext) return { error: "fileType" };
  if (file.size === 0 || file.size > MAX_UPLOAD_BYTES) return { error: "fileSize" };
  const body = Buffer.from(await file.arrayBuffer());
  const sha256 = createHash("sha256").update(body).digest("hex");
  let name = vaultKey(registrationNo, applicationNo, new Date(), docType, ext);
  let key = `${registryCode}/${name}`;
  for (let n = 2; taken.has(key); n++) {
    name = name.replace(/\.([a-z0-9]+)$/, `_${n}.$1`);
    key = `${registryCode}/${name}`;
  }
  await putObject(vaultConfig(), key, body, file.type);
  return { object_key: key, doc_type: docType, file_name: file.name.slice(0, 200), content_type: file.type, size: body.length, sha256, uploaded_at: new Date().toISOString() };
}
