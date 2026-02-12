import { Pool } from "pg";
import { config } from "./config.js";

export const pool = new Pool({
  connectionString: config.databaseUrl,
  ssl: config.databaseUrl.includes("sslmode=require")
    ? { rejectUnauthorized: false }
    : undefined
});

export async function initDb(): Promise<void> {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      email TEXT UNIQUE,
      phone_number TEXT,
      display_name TEXT,
      password_hash TEXT,
      apple_sub TEXT UNIQUE,
      stripe_customer_id TEXT UNIQUE,
      subscription_tier TEXT NOT NULL DEFAULT 'free',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS recordings (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      source_id TEXT,
      text TEXT NOT NULL,
      provider TEXT,
      locale TEXT,
      duration_ms INTEGER,
      audio_object_key TEXT,
      audio_content_type TEXT,
      audio_size_bytes INTEGER,
      audio_url TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE UNIQUE INDEX IF NOT EXISTS recordings_user_source_id_unique
      ON recordings(user_id, source_id);

    CREATE INDEX IF NOT EXISTS recordings_user_created_idx
      ON recordings(user_id, created_at DESC);

    CREATE TABLE IF NOT EXISTS dictionary_terms (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      term TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'manual',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE UNIQUE INDEX IF NOT EXISTS dictionary_terms_user_term_unique
      ON dictionary_terms(user_id, term);

    CREATE TABLE IF NOT EXISTS subscriptions (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      provider TEXT NOT NULL DEFAULT 'stripe',
      customer_id TEXT NOT NULL,
      price_id TEXT,
      product_id TEXT,
      status TEXT NOT NULL,
      tier TEXT NOT NULL DEFAULT 'free',
      cancel_at_period_end BOOLEAN NOT NULL DEFAULT FALSE,
      current_period_end TIMESTAMPTZ,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_user_provider_unique
      ON subscriptions(user_id, provider);

    CREATE INDEX IF NOT EXISTS subscriptions_customer_id_idx
      ON subscriptions(customer_id);
  `);
}

export async function healthCheck(): Promise<void> {
  await pool.query("SELECT 1");
}
