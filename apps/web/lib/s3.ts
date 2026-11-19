/**
 * The vault's bucket client. The S3 code itself is shared with the worker and lives in @meesam/db
 * (object-store); this file adds what only the vault needs: the file name rule and the upload limits.
 */
export { vaultConfig, putObject, getObject, deleteObject, copyObject, presignGet, type VaultConfig } from "@meesam/db";

/** Vault key per item 43: regno_serial_DDMMYY_TYPE.ext — an empty part stays empty. */
export function vaultKey(registrationNo: string | null | undefined, applicationNo: string | null | undefined, date: Date, docType: string, ext: string): string {
  const clean = (s: string | null | undefined) => (s ?? "").replace(/[^A-Za-z0-9-]/g, "");
  const dd = String(date.getUTCDate()).padStart(2, "0");
  const mm = String(date.getUTCMonth() + 1).padStart(2, "0");
  const yy = String(date.getUTCFullYear()).slice(-2);
  return `${clean(registrationNo)}_${clean(applicationNo)}_${dd}${mm}${yy}_${docType.toUpperCase()}.${ext.toLowerCase().replace(/[^a-z0-9]/g, "")}`;
}

export const ALLOWED_UPLOAD_TYPES: Record<string, string> = {
  "application/pdf": "pdf",
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/webp": "webp",
  "image/tiff": "tif",
};
export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;
