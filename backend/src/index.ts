import { randomUUID } from "node:crypto";
import bcrypt from "bcryptjs";
import cors from "cors";
import express from "express";
import Stripe from "stripe";
import { z } from "zod";
import { authMiddleware, issueAccessToken } from "./auth.js";
import { verifyAppleIdentityToken } from "./apple.js";
import { verifyGoogleIdToken } from "./google.js";
import { config, hasStripe } from "./config.js";
import { healthCheck, initDb, pool } from "./db.js";
import { maybeUploadAudio } from "./storage.js";
import { deriveTierFromSubscriptionStatus, requireStripeClient } from "./stripe.js";

const app = express();

app.post("/v1/billing/stripe/webhook", express.raw({ type: "application/json" }), async (req, res) => {
  if (!hasStripe() || !config.stripe.webhookSecret) {
    res.status(503).json({ error: "stripe_not_configured" });
    return;
  }

  const stripe = requireStripeClient();
  const signature = req.header("stripe-signature");
  if (!signature) {
    res.status(400).json({ error: "missing_stripe_signature" });
    return;
  }

  try {
    const payload = Buffer.isBuffer(req.body) ? req.body : Buffer.from(req.body ?? "", "utf8");
    const event = stripe.webhooks.constructEvent(payload, signature, config.stripe.webhookSecret);
    await handleStripeWebhookEvent(event);
    res.status(200).json({ ok: true });
  } catch (error) {
    res.status(400).json({
      error: "invalid_webhook",
      message: error instanceof Error ? error.message : "Unable to verify Stripe webhook payload."
    });
  }
});

app.use(express.json({ limit: "25mb" }));
app.use(
  cors({
    origin: config.corsOrigin === "*" ? true : config.corsOrigin.split(",").map((s) => s.trim()),
    credentials: true
  })
);

function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

type UserRow = {
  id: string;
  email: string | null;
  phone_number: string | null;
  display_name: string | null;
};

function userResponseRow(row: UserRow, provider?: string) {
  return {
    uid: row.id,
    email: row.email ?? null,
    phoneNumber: row.phone_number ?? null,
    displayName: row.display_name ?? null,
    provider: provider ?? "email"
  };
}

app.get("/healthz", async (_req, res) => {
  try {
    await healthCheck();
    res.json({ ok: true });
  } catch (error) {
    res.status(500).json({ ok: false, error: (error as Error).message });
  }
});

const registerSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8).max(128),
  displayName: z.string().min(1).max(100).optional()
});

app.post("/v1/auth/register", async (req, res) => {
  const parsed = registerSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "invalid_payload", details: parsed.error.flatten() });
    return;
  }

  const email = normalizeEmail(parsed.data.email);
  const existing = await pool.query("SELECT id FROM users WHERE email = $1 LIMIT 1", [email]);
  if (existing.rowCount) {
    res.status(409).json({ error: "email_already_exists" });
    return;
  }

  const userId = randomUUID();
  const passwordHash = await bcrypt.hash(parsed.data.password, 12);
  const insert = await pool.query<UserRow>(
    `INSERT INTO users (id, email, password_hash, display_name)
     VALUES ($1, $2, $3, $4)
     RETURNING id, email, phone_number, display_name`,
    [userId, email, passwordHash, parsed.data.displayName ?? null]
  );

  const user = insert.rows[0];
  const accessToken = issueAccessToken({ id: user.id, email: user.email });
  res.status(201).json({ accessToken, token: accessToken, user: userResponseRow(user, "email") });
});

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(1)
});

app.post("/v1/auth/login", async (req, res) => {
  const parsed = loginSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "invalid_payload", details: parsed.error.flatten() });
    return;
  }

  const email = normalizeEmail(parsed.data.email);
  const result = await pool.query<
    UserRow & {
      password_hash: string | null;
    }
  >(
    "SELECT id, email, phone_number, display_name, password_hash FROM users WHERE email = $1 LIMIT 1",
    [email]
  );
  const user = result.rows[0];
  if (!user || !user.password_hash) {
    res.status(401).json({ error: "invalid_credentials" });
    return;
  }

  const valid = await bcrypt.compare(parsed.data.password, user.password_hash);
  if (!valid) {
    res.status(401).json({ error: "invalid_credentials" });
    return;
  }

  const accessToken = issueAccessToken({ id: user.id, email: user.email });
  res.json({ accessToken, token: accessToken, user: userResponseRow(user, "email") });
});

const appleSignInSchema = z.object({
  identityToken: z.string().min(1).optional(),
  idToken: z.string().min(1).optional(),
  nonce: z.string().min(1).optional(),
  displayName: z.string().min(1).max(100).optional(),
  fullName: z.string().min(1).max(120).optional()
});

app.post("/v1/auth/apple", async (req, res) => {
  const parsed = appleSignInSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "invalid_payload", details: parsed.error.flatten() });
    return;
  }

  const identityToken = parsed.data.identityToken ?? parsed.data.idToken;
  if (!identityToken) {
    res.status(400).json({ error: "missing_identity_token" });
    return;
  }

  try {
    const verified = await verifyAppleIdentityToken(identityToken, parsed.data.nonce);
    const email = verified.email ? normalizeEmail(verified.email) : null;
    const displayName = parsed.data.fullName ?? parsed.data.displayName ?? null;

    const existingByApple = await pool.query<UserRow>(
      "SELECT id, email, phone_number, display_name FROM users WHERE apple_sub = $1 LIMIT 1",
      [verified.sub]
    );

    let user = existingByApple.rows[0];
    if (!user && email) {
      const existingByEmail = await pool.query<UserRow & { apple_sub: string | null }>(
        "SELECT id, email, phone_number, display_name, apple_sub FROM users WHERE email = $1 LIMIT 1",
        [email]
      );
      const existingEmailUser = existingByEmail.rows[0];
      if (existingEmailUser) {
        const linked = await pool.query<UserRow>(
          `UPDATE users
           SET apple_sub = $2, updated_at = NOW()
           WHERE id = $1
           RETURNING id, email, phone_number, display_name`,
          [existingEmailUser.id, verified.sub]
        );
        user = linked.rows[0];
      }
    }

    if (!user) {
      const userId = randomUUID();
      const inserted = await pool.query<UserRow>(
        `INSERT INTO users (id, email, apple_sub, display_name)
         VALUES ($1, $2, $3, $4)
         RETURNING id, email, phone_number, display_name`,
        [userId, email, verified.sub, displayName]
      );
      user = inserted.rows[0];
    } else if (!user.email && email) {
      const updated = await pool.query<UserRow>(
        `UPDATE users
         SET email = $2, updated_at = NOW()
         WHERE id = $1
         RETURNING id, email, phone_number, display_name`,
        [user.id, email]
      );
      user = updated.rows[0];
    }

    const accessToken = issueAccessToken({ id: user.id, email: user.email });
    res.json({ accessToken, token: accessToken, user: userResponseRow(user, "apple") });
  } catch (error) {
    res.status(401).json({
      error: "invalid_apple_token",
      message: error instanceof Error ? error.message : "Apple token verification failed."
    });
  }
});

const googleSignInSchema = z.object({
  idToken: z.string().min(1)
});

app.post("/v1/auth/google", async (req, res) => {
  const parsed = googleSignInSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "invalid_payload", details: parsed.error.flatten() });
    return;
  }

  try {
    const verified = await verifyGoogleIdToken(parsed.data.idToken, config.google.audienceList);
    const email = verified.email ? normalizeEmail(verified.email) : null;
    const googleSub = verified.sub;
    const displayName = verified.name ?? null;

    if (!googleSub) {
      res.status(401).json({ error: "invalid_google_token", message: "Missing Google subject (sub)." });
      return;
    }

    const existingByGoogle = await pool.query<UserRow>(
      "SELECT id, email, phone_number, display_name FROM users WHERE google_sub = $1 LIMIT 1",
      [googleSub]
    );

    let user = existingByGoogle.rows[0];

    if (!user && email) {
      const existingByEmail = await pool.query<UserRow & { google_sub: string | null }>(
        "SELECT id, email, phone_number, display_name, google_sub FROM users WHERE email = $1 LIMIT 1",
        [email]
      );
      const existingEmailUser = existingByEmail.rows[0];
      if (existingEmailUser) {
        const linked = await pool.query<UserRow>(
          `UPDATE users
           SET google_sub = $2, updated_at = NOW()
           WHERE id = $1
           RETURNING id, email, phone_number, display_name`,
          [existingEmailUser.id, googleSub]
        );
        user = linked.rows[0];
      }
    }

    if (!user) {
      const userId = randomUUID();
      const inserted = await pool.query<UserRow>(
        `INSERT INTO users (id, email, google_sub, display_name)
         VALUES ($1, $2, $3, $4)
         RETURNING id, email, phone_number, display_name`,
        [userId, email, googleSub, displayName]
      );
      user = inserted.rows[0];
    } else if (!user.email && email) {
      const updated = await pool.query<UserRow>(
        `UPDATE users
         SET email = $2, updated_at = NOW()
         WHERE id = $1
         RETURNING id, email, phone_number, display_name`,
        [user.id, email]
      );
      user = updated.rows[0];
    }

    const accessToken = issueAccessToken({ id: user.id, email: user.email });
    res.json({ accessToken, token: accessToken, user: userResponseRow(user, "google") });
  } catch (error) {
    res.status(401).json({
      error: "invalid_google_token",
      message: error instanceof Error ? error.message : "Google token verification failed."
    });
  }
});

app.get("/v1/auth/me", authMiddleware, async (req, res) => {
  const userId = req.authUser?.id;
  if (!userId) {
    res.status(401).json({ error: "not_authenticated" });
    return;
  }

  const result = await pool.query<UserRow>(
    "SELECT id, email, phone_number, display_name FROM users WHERE id = $1 LIMIT 1",
    [userId]
  );
  const user = result.rows[0];
  if (!user) {
    res.status(404).json({ error: "user_not_found" });
    return;
  }
  res.json({ user: userResponseRow(user) });
});

const billingCheckoutSchema = z.object({
  priceId: z.string().min(1).optional()
});

app.get("/v1/billing/status", authMiddleware, async (req, res) => {
  const userId = req.authUser?.id;
  if (!userId) {
    res.status(401).json({ error: "not_authenticated" });
    return;
  }

  const userResult = await pool.query<{ subscription_tier: string }>(
    "SELECT subscription_tier FROM users WHERE id = $1 LIMIT 1",
    [userId]
  );
  const user = userResult.rows[0];
  if (!user) {
    res.status(404).json({ error: "user_not_found" });
    return;
  }

  const subscriptionResult = await pool.query<{
    id: string;
    status: string;
    tier: string;
    price_id: string | null;
    current_period_end: Date | null;
    cancel_at_period_end: boolean;
    updated_at: Date;
  }>(
    `SELECT id, status, tier, price_id, current_period_end, cancel_at_period_end, updated_at
     FROM subscriptions
     WHERE user_id = $1 AND provider = 'stripe'
     ORDER BY updated_at DESC
     LIMIT 1`,
    [userId]
  );
  const subscription = subscriptionResult.rows[0];

  res.json({
    tier: subscription?.tier ?? user.subscription_tier ?? "free",
    hasActiveSubscription: Boolean(subscription && deriveTierFromSubscriptionStatus(subscription.status) === "pro"),
    subscription: subscription
      ? {
          id: subscription.id,
          status: subscription.status,
          tier: subscription.tier,
          priceId: subscription.price_id,
          currentPeriodEnd: subscription.current_period_end?.toISOString() ?? null,
          cancelAtPeriodEnd: subscription.cancel_at_period_end
        }
      : null
  });
});

app.post("/v1/billing/create-checkout-session", authMiddleware, async (req, res) => {
  if (!hasStripe()) {
    res.status(503).json({ error: "stripe_not_configured" });
    return;
  }

  const userId = req.authUser?.id;
  if (!userId) {
    res.status(401).json({ error: "not_authenticated" });
    return;
  }

  const parsed = billingCheckoutSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "invalid_payload", details: parsed.error.flatten() });
    return;
  }

  const priceId = parsed.data.priceId ?? config.stripe.defaultPriceId;
  if (!priceId) {
    res.status(400).json({ error: "missing_price_id", message: "Set STRIPE_DEFAULT_PRICE_ID or provide priceId." });
    return;
  }
  if (!config.stripe.successUrl || !config.stripe.cancelUrl) {
    res.status(400).json({
      error: "missing_checkout_urls",
      message: "Set STRIPE_SUCCESS_URL and STRIPE_CANCEL_URL."
    });
    return;
  }

  const userResult = await pool.query<{
    id: string;
    email: string | null;
    display_name: string | null;
    stripe_customer_id: string | null;
  }>(
    "SELECT id, email, display_name, stripe_customer_id FROM users WHERE id = $1 LIMIT 1",
    [userId]
  );
  const user = userResult.rows[0];
  if (!user) {
    res.status(404).json({ error: "user_not_found" });
    return;
  }

  const stripe = requireStripeClient();
  let customerId = user.stripe_customer_id;
  if (!customerId) {
    const customer = await stripe.customers.create({
      email: user.email ?? undefined,
      name: user.display_name ?? undefined,
      metadata: { userId: user.id }
    });
    customerId = customer.id;
    await pool.query("UPDATE users SET stripe_customer_id = $2, updated_at = NOW() WHERE id = $1", [
      user.id,
      customerId
    ]);
  }

  const session = await stripe.checkout.sessions.create({
    mode: "subscription",
    customer: customerId,
    line_items: [{ price: priceId, quantity: 1 }],
    success_url: config.stripe.successUrl,
    cancel_url: config.stripe.cancelUrl,
    client_reference_id: user.id,
    metadata: { userId: user.id },
    allow_promotion_codes: true
  });

  res.status(201).json({
    id: session.id,
    url: session.url
  });
});

app.post("/v1/billing/create-portal-session", authMiddleware, async (req, res) => {
  if (!hasStripe()) {
    res.status(503).json({ error: "stripe_not_configured" });
    return;
  }
  if (!config.stripe.successUrl) {
    res.status(400).json({ error: "missing_return_url", message: "Set STRIPE_SUCCESS_URL." });
    return;
  }

  const userId = req.authUser?.id;
  if (!userId) {
    res.status(401).json({ error: "not_authenticated" });
    return;
  }

  const userResult = await pool.query<{ stripe_customer_id: string | null }>(
    "SELECT stripe_customer_id FROM users WHERE id = $1 LIMIT 1",
    [userId]
  );
  const stripeCustomerId = userResult.rows[0]?.stripe_customer_id;
  if (!stripeCustomerId) {
    res.status(400).json({ error: "no_customer", message: "No Stripe customer bound to this account yet." });
    return;
  }

  const stripe = requireStripeClient();
  const session = await stripe.billingPortal.sessions.create({
    customer: stripeCustomerId,
    return_url: config.stripe.successUrl
  });
  res.status(201).json({ url: session.url });
});

const flatSyncRecordingSchema = z.object({
  id: z.string().min(1).optional(),
  text: z.string().min(1),
  createdAt: z.string().optional(),
  durationMs: z.number().int().nonnegative().optional(),
  provider: z.string().max(120).optional(),
  locale: z.string().max(32).optional(),
  audioBase64: z.string().optional(),
  audioContentType: z.string().max(120).optional()
});

const nestedSyncRecordingSchema = z.object({
  recording: z.object({
    id: z.string().min(1),
    createdAt: z.string(),
    duration: z.number().nonnegative(),
    asrProviderId: z.string().max(120).optional(),
    transcriptRaw: z.string().optional().nullable(),
    transcriptFinal: z.string().optional().nullable(),
    status: z.string().optional()
  }),
  audioBase64: z.string().optional(),
  audioContentType: z.string().max(120).optional()
});

type NormalizedSyncPayload = {
  sourceId: string;
  text: string;
  createdAt: Date;
  durationMs: number | null;
  provider: string | null;
  locale: string | null;
  audioBase64: string | null;
  audioContentType: string | null;
};

function normalizeSyncPayload(payload: unknown): NormalizedSyncPayload | null {
  const flat = flatSyncRecordingSchema.safeParse(payload);
  if (flat.success) {
    const createdAt = flat.data.createdAt ? new Date(flat.data.createdAt) : new Date();
    return {
      sourceId: flat.data.id ?? randomUUID(),
      text: flat.data.text,
      createdAt: Number.isNaN(createdAt.getTime()) ? new Date() : createdAt,
      durationMs: flat.data.durationMs ?? null,
      provider: flat.data.provider ?? null,
      locale: flat.data.locale ?? null,
      audioBase64: flat.data.audioBase64 ?? null,
      audioContentType: flat.data.audioContentType ?? null
    };
  }

  const nested = nestedSyncRecordingSchema.safeParse(payload);
  if (!nested.success) {
    return null;
  }
  const recording = nested.data.recording;
  const text = (recording.transcriptFinal ?? recording.transcriptRaw ?? "").trim();
  if (!text) {
    return null;
  }
  const createdAt = new Date(recording.createdAt);
  return {
    sourceId: recording.id,
    text,
    createdAt: Number.isNaN(createdAt.getTime()) ? new Date() : createdAt,
    durationMs: Math.round(recording.duration * 1000),
    provider: recording.asrProviderId ?? null,
    locale: null,
    audioBase64: nested.data.audioBase64 ?? null,
    audioContentType: nested.data.audioContentType ?? null
  };
}

app.post("/v1/sync/recordings", authMiddleware, async (req, res) => {
  const userId = req.authUser?.id;
  if (!userId) {
    res.status(401).json({ error: "not_authenticated" });
    return;
  }

  const payload = normalizeSyncPayload(req.body);
  if (!payload) {
    res.status(400).json({ error: "invalid_payload", message: "Invalid recording sync payload." });
    return;
  }

  let uploadResult: Awaited<ReturnType<typeof maybeUploadAudio>> = null;

  if (payload.audioBase64) {
    try {
      uploadResult = await maybeUploadAudio({
        userId,
        sourceId: payload.sourceId,
        base64: payload.audioBase64,
        contentType: payload.audioContentType
      });
    } catch (error) {
      res.status(400).json({ error: "audio_upload_failed", message: (error as Error).message });
      return;
    }
  }

  const dbResult = await pool.query(
    `INSERT INTO recordings (
       id, user_id, source_id, text, provider, locale, duration_ms, created_at,
       audio_object_key, audio_content_type, audio_size_bytes, audio_url
     )
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
     ON CONFLICT (user_id, source_id) DO UPDATE
       SET text = EXCLUDED.text,
           provider = EXCLUDED.provider,
           locale = EXCLUDED.locale,
           duration_ms = EXCLUDED.duration_ms,
           created_at = EXCLUDED.created_at,
           audio_object_key = COALESCE(EXCLUDED.audio_object_key, recordings.audio_object_key),
           audio_content_type = COALESCE(EXCLUDED.audio_content_type, recordings.audio_content_type),
           audio_size_bytes = COALESCE(EXCLUDED.audio_size_bytes, recordings.audio_size_bytes),
           audio_url = COALESCE(EXCLUDED.audio_url, recordings.audio_url),
           updated_at = NOW()
     RETURNING id, source_id, text, provider, locale, duration_ms, created_at, updated_at, audio_url`,
    [
      randomUUID(),
      userId,
      payload.sourceId,
      payload.text,
      payload.provider,
      payload.locale,
      payload.durationMs,
      payload.createdAt.toISOString(),
      uploadResult?.objectKey ?? null,
      payload.audioContentType ?? null,
      uploadResult?.bytes ?? null,
      uploadResult?.audioUrl ?? null
    ]
  );

  res.status(201).json({
    ok: true,
    recording: dbResult.rows[0],
    uploadedAudio: Boolean(uploadResult)
  });
});

app.get("/v1/sync/recordings", authMiddleware, async (req, res) => {
  const userId = req.authUser?.id;
  if (!userId) {
    res.status(401).json({ error: "not_authenticated" });
    return;
  }

  const limit = Math.max(1, Math.min(200, Number(req.query.limit ?? 50) || 50));
  const result = await pool.query(
    `SELECT COALESCE(source_id, id) AS id, text, provider, locale, duration_ms, created_at, updated_at, audio_url
     FROM recordings
     WHERE user_id = $1
     ORDER BY created_at DESC
     LIMIT $2`,
    [userId, limit]
  );
  res.json({ recordings: result.rows });
});

const dictionaryCreateSchema = z.object({
  term: z.string().trim().min(1).max(120),
  kind: z.enum(["manual", "auto"]).optional()
});

app.get("/v1/sync/dictionary", authMiddleware, async (req, res) => {
  const userId = req.authUser?.id;
  if (!userId) {
    res.status(401).json({ error: "not_authenticated" });
    return;
  }
  const rows = await pool.query(
    `SELECT id, term, kind, created_at
     FROM dictionary_terms
     WHERE user_id = $1
     ORDER BY created_at DESC`,
    [userId]
  );
  res.json({ terms: rows.rows });
});

app.post("/v1/sync/dictionary", authMiddleware, async (req, res) => {
  const userId = req.authUser?.id;
  if (!userId) {
    res.status(401).json({ error: "not_authenticated" });
    return;
  }
  const parsed = dictionaryCreateSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "invalid_payload", details: parsed.error.flatten() });
    return;
  }

  const id = randomUUID();
  const result = await pool.query(
    `INSERT INTO dictionary_terms (id, user_id, term, kind)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (user_id, term) DO UPDATE
       SET kind = EXCLUDED.kind, updated_at = NOW()
     RETURNING id, term, kind, created_at`,
    [id, userId, parsed.data.term, parsed.data.kind ?? "manual"]
  );
  res.status(201).json({ term: result.rows[0] });
});

app.delete("/v1/sync/dictionary/:id", authMiddleware, async (req, res) => {
  const userId = req.authUser?.id;
  if (!userId) {
    res.status(401).json({ error: "not_authenticated" });
    return;
  }
  await pool.query("DELETE FROM dictionary_terms WHERE id = $1 AND user_id = $2", [
    req.params.id,
    userId
  ]);
  res.status(204).send();
});

app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  console.error(error);
  res.status(500).json({ error: "internal_error", message: "Unexpected server error." });
});

async function handleStripeWebhookEvent(event: Stripe.Event): Promise<void> {
  if (event.type === "checkout.session.completed") {
    const session = event.data.object as Stripe.Checkout.Session;
    const customerId = typeof session.customer === "string" ? session.customer : null;
    const userId = session.metadata?.userId ?? session.client_reference_id ?? null;
    if (customerId && userId) {
      await pool.query(
        "UPDATE users SET stripe_customer_id = $2, updated_at = NOW() WHERE id = $1",
        [userId, customerId]
      );
    }
    return;
  }

  if (
    event.type === "customer.subscription.created" ||
    event.type === "customer.subscription.updated" ||
    event.type === "customer.subscription.deleted"
  ) {
    const subscription = event.data.object as Stripe.Subscription;
    const customerId = typeof subscription.customer === "string" ? subscription.customer : null;
    if (!customerId) {
      return;
    }

    const userResult = await pool.query<{ id: string }>(
      "SELECT id FROM users WHERE stripe_customer_id = $1 LIMIT 1",
      [customerId]
    );
    const userId = userResult.rows[0]?.id;
    if (!userId) {
      return;
    }

    const firstItem = subscription.items.data[0];
    const priceId = firstItem?.price?.id ?? null;
    const productId =
      firstItem?.price?.product && typeof firstItem.price.product === "string"
        ? firstItem.price.product
        : null;
    const tier = deriveTierFromSubscriptionStatus(subscription.status);
    const rawPeriodEnd = (subscription as unknown as { current_period_end?: number }).current_period_end;
    const periodEnd = typeof rawPeriodEnd === "number" ? new Date(rawPeriodEnd * 1000).toISOString() : null;

    await pool.query(
      `INSERT INTO subscriptions (
         id, user_id, provider, customer_id, price_id, product_id, status,
         tier, cancel_at_period_end, current_period_end
       )
       VALUES ($1,$2,'stripe',$3,$4,$5,$6,$7,$8,$9)
       ON CONFLICT (id) DO UPDATE
         SET user_id = EXCLUDED.user_id,
             customer_id = EXCLUDED.customer_id,
             price_id = EXCLUDED.price_id,
             product_id = EXCLUDED.product_id,
             status = EXCLUDED.status,
             tier = EXCLUDED.tier,
             cancel_at_period_end = EXCLUDED.cancel_at_period_end,
             current_period_end = EXCLUDED.current_period_end,
             updated_at = NOW()`,
      [
        subscription.id,
        userId,
        customerId,
        priceId,
        productId,
        subscription.status,
        tier,
        subscription.cancel_at_period_end,
        periodEnd
      ]
    );

    await pool.query("UPDATE users SET subscription_tier = $2, updated_at = NOW() WHERE id = $1", [
      userId,
      tier
    ]);
  }
}

async function main() {
  await initDb();
  app.listen(config.port, () => {
    console.log(`[echo-api] listening on :${config.port}`);
  });
}

main().catch((error) => {
  console.error("[echo-api] failed to boot", error);
  process.exit(1);
});
