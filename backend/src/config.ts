import "dotenv/config";

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function optional(name: string): string | undefined {
  const value = process.env[name]?.trim();
  return value ? value : undefined;
}

function optionalList(name: string): string[] {
  const value = process.env[name]?.trim();
  if (!value) {
    return [];
  }
  return value
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}

const port = Number(process.env.PORT ?? "8080");
if (!Number.isFinite(port) || port <= 0) {
  throw new Error("PORT must be a positive integer");
}

export const config = {
  nodeEnv: process.env.NODE_ENV ?? "development",
  port,
  databaseUrl: required("DATABASE_URL"),
  jwtSecret: required("JWT_SECRET"),
  corsOrigin: process.env.CORS_ORIGIN ?? "*",
  apple: {
    audienceList: optionalList("APPLE_AUDIENCE"),
    issuer: process.env.APPLE_ISSUER ?? "https://appleid.apple.com"
  },
  stripe: {
    secretKey: optional("STRIPE_SECRET_KEY"),
    webhookSecret: optional("STRIPE_WEBHOOK_SECRET"),
    defaultPriceId: optional("STRIPE_DEFAULT_PRICE_ID"),
    successUrl: optional("STRIPE_SUCCESS_URL"),
    cancelUrl: optional("STRIPE_CANCEL_URL")
  },
  storage: {
    endpoint: optional("S3_ENDPOINT"),
    region: process.env.S3_REGION ?? "auto",
    bucket: optional("S3_BUCKET"),
    accessKeyId: optional("S3_ACCESS_KEY_ID"),
    secretAccessKey: optional("S3_SECRET_ACCESS_KEY"),
    publicBaseUrl: optional("S3_PUBLIC_BASE_URL")
  }
};

export function hasObjectStorage(): boolean {
  const s = config.storage;
  return Boolean(s.bucket && s.accessKeyId && s.secretAccessKey);
}

export function hasStripe(): boolean {
  return Boolean(config.stripe.secretKey);
}
