import { OAuth2Client, TokenPayload } from "google-auth-library";

const GOOGLE_ISSUER = "https://accounts.google.com";

/**
 * Verify a Google ID token and return the decoded payload.
 *
 * @param idToken  The `id_token` string from the Google Sign-In SDK
 * @param audiences  Allowed OAuth Client IDs (from GCP Console).
 *                   Pass an empty array to skip audience checking (dev only).
 */
export async function verifyGoogleIdToken(
  idToken: string,
  audiences: string[]
): Promise<TokenPayload> {
  const client = new OAuth2Client();

  const ticket = await client.verifyIdToken({
    idToken,
    audience: audiences.length > 0 ? audiences : undefined,
  });

  const payload = ticket.getPayload();
  if (!payload) {
    throw new Error("Google ID token payload is empty");
  }

  // Ensure the token was issued by Google
  if (payload.iss !== GOOGLE_ISSUER && payload.iss !== "accounts.google.com") {
    throw new Error(`Unexpected issuer: ${payload.iss}`);
  }

  // Ensure email is verified
  if (!payload.email_verified) {
    throw new Error("Google email is not verified");
  }

  return payload;
}
