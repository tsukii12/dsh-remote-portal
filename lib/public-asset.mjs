import { createHash } from "node:crypto";

export const MOBILE_ASSETS = new Set(["mobile.css", "mobile.js"]);

export function assetRevision(body) {
  return createHash("sha256").update(body).digest("base64url");
}

export function assetCacheControl(req, body) {
  const search = new URL(req.url || "/", "http://localhost").searchParams;
  if (search.get("v") === assetRevision(body)) return "public, max-age=31536000, immutable";
  return "no-cache";
}
