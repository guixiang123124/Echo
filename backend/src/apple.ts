import { createHash } from "node:crypto";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { config } from "./config.js";

const APPLE_JWKS = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

export type AppleIdentity = {
  sub: string;
  email: string | null;
  emailVerified: boolean;
  isPrivateEmail: boolean;
  audience: string | null;
};

function normalizeEmailVerified(value: unknown): boolean {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "string") {
    return value.toLowerCase() === "true";
  }
  return false;
}

function normalizePrivateEmail(value: unknown): boolean {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "string") {
    return value.toLowerCase() === "true";
  }
  return false;
}

function verifyNonce(payloadNonce: unknown, expectedNonce: string): boolean {
  if (typeof payloadNonce !== "string" || !payloadNonce) {
    return false;
  }

  if (payloadNonce === expectedNonce) {
    return true;
  }

  const digest = createHash("sha256").update(expectedNonce).digest("hex");
  return payloadNonce === digest;
}

export async function verifyAppleIdentityToken(
  identityToken: string,
  nonce: string | undefined
): Promise<AppleIdentity> {
  if (config.apple.audienceList.length === 0) {
    throw new Error("Server Apple audience is not configured. Set APPLE_AUDIENCE.");
  }

  const { payload } = await jwtVerify(identityToken, APPLE_JWKS, {
    issuer: config.apple.issuer,
    audience: config.apple.audienceList
  });

  const sub = typeof payload.sub === "string" ? payload.sub : null;
  if (!sub) {
    throw new Error("Apple token missing `sub`.");
  }

  if (nonce) {
    const valid = verifyNonce(payload.nonce, nonce);
    if (!valid) {
      throw new Error("Apple token nonce mismatch.");
    }
  }

  return {
    sub,
    email: typeof payload.email === "string" ? payload.email.toLowerCase() : null,
    emailVerified: normalizeEmailVerified(payload.email_verified),
    isPrivateEmail: normalizePrivateEmail(payload.is_private_email),
    audience: typeof payload.aud === "string" ? payload.aud : null
  };
}
