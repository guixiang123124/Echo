#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import Stripe from "stripe";

function requiredEnv(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required env: ${name}`);
  }
  return value;
}

function optionalEnv(name, fallback = "") {
  const value = process.env[name]?.trim();
  return value && value.length > 0 ? value : fallback;
}

function toBool(value) {
  return ["1", "true", "yes", "on"].includes(String(value).toLowerCase());
}

function runRailway(args) {
  return execFileSync("npx", ["-y", "@railway/cli", ...args], {
    encoding: "utf8",
    stdio: ["pipe", "pipe", "pipe"]
  });
}

async function ensureEchoProduct(stripe) {
  const products = await stripe.products.list({ active: true, limit: 100 });
  const existing = products.data.find(
    (p) => p.metadata?.app === "echo" && p.metadata?.kind === "subscription"
  );
  if (existing) return existing;

  return stripe.products.create({
    name: "Echo Pro",
    description: "Echo AI voice input subscription",
    metadata: {
      app: "echo",
      kind: "subscription"
    }
  });
}

function findRecurringPrice(prices, interval, amount, currency) {
  return prices.find(
    (p) =>
      p.active === true &&
      p.currency.toLowerCase() === currency.toLowerCase() &&
      p.recurring?.interval === interval &&
      p.unit_amount === amount
  );
}

async function ensurePrice(stripe, productId, { interval, amount, currency }) {
  const list = await stripe.prices.list({
    product: productId,
    active: true,
    limit: 100
  });
  const existing = findRecurringPrice(list.data, interval, amount, currency);
  if (existing) return existing;

  return stripe.prices.create({
    product: productId,
    currency,
    unit_amount: amount,
    recurring: { interval },
    metadata: {
      app: "echo",
      tier: "pro",
      interval
    }
  });
}

async function ensureWebhook(stripe, webhookUrl) {
  const existing = await stripe.webhookEndpoints.list({ limit: 100 });
  const target = existing.data.find((w) => w.url === webhookUrl);
  if (target) {
    return {
      endpoint: target,
      secret: null,
      reused: true
    };
  }

  const created = await stripe.webhookEndpoints.create({
    url: webhookUrl,
    enabled_events: [
      "checkout.session.completed",
      "customer.subscription.created",
      "customer.subscription.updated",
      "customer.subscription.deleted"
    ],
    description: "Echo billing webhook",
    metadata: {
      app: "echo"
    }
  });

  return {
    endpoint: created,
    secret: created.secret ?? null,
    reused: false
  };
}

async function recreateWebhook(stripe, endpointId, webhookUrl) {
  await stripe.webhookEndpoints.del(endpointId);
  const created = await stripe.webhookEndpoints.create({
    url: webhookUrl,
    enabled_events: [
      "checkout.session.completed",
      "customer.subscription.created",
      "customer.subscription.updated",
      "customer.subscription.deleted"
    ],
    description: "Echo billing webhook",
    metadata: {
      app: "echo"
    }
  });
  return {
    endpoint: created,
    secret: created.secret ?? null,
    reused: false
  };
}

async function main() {
  const secretKey = requiredEnv("STRIPE_SECRET_KEY");
  const apiBaseUrl = requiredEnv("ECHO_API_BASE_URL").replace(/\/+$/, "");
  const railwaySync = toBool(optionalEnv("RAILWAY_SYNC", "false"));
  const railwayService = optionalEnv("RAILWAY_SERVICE_NAME", "echo-api");
  const railwayEnvironment = optionalEnv("RAILWAY_ENVIRONMENT", "production");
  const recreateWebhookIfExists = toBool(optionalEnv("ECHO_RECREATE_WEBHOOK_IF_EXISTS", "false"));

  const monthlyUsd = Number(optionalEnv("ECHO_MONTHLY_USD_CENTS", "999"));
  const yearlyUsd = Number(optionalEnv("ECHO_YEARLY_USD_CENTS", "9999"));
  const currency = optionalEnv("ECHO_CURRENCY", "usd");

  if (!Number.isInteger(monthlyUsd) || monthlyUsd <= 0) {
    throw new Error("ECHO_MONTHLY_USD_CENTS must be a positive integer");
  }
  if (!Number.isInteger(yearlyUsd) || yearlyUsd <= 0) {
    throw new Error("ECHO_YEARLY_USD_CENTS must be a positive integer");
  }

  const stripe = new Stripe(secretKey, {
    apiVersion: "2026-01-28.clover"
  });

  const product = await ensureEchoProduct(stripe);
  const monthly = await ensurePrice(stripe, product.id, {
    interval: "month",
    amount: monthlyUsd,
    currency
  });
  const yearly = await ensurePrice(stripe, product.id, {
    interval: "year",
    amount: yearlyUsd,
    currency
  });

  const webhookUrl = `${apiBaseUrl}/v1/billing/stripe/webhook`;
  let webhook = await ensureWebhook(stripe, webhookUrl);
  if (recreateWebhookIfExists && webhook.reused) {
    webhook = await recreateWebhook(stripe, webhook.endpoint.id, webhookUrl);
  }

  if (railwaySync) {
    const varsToSet = [
      `STRIPE_SECRET_KEY=${secretKey}`,
      `STRIPE_DEFAULT_PRICE_ID=${monthly.id}`
    ];
    if (webhook.secret) {
      varsToSet.push(`STRIPE_WEBHOOK_SECRET=${webhook.secret}`);
    }

    for (const variable of varsToSet) {
      runRailway([
        "variable",
        "set",
        "--service",
        railwayService,
        "--environment",
        railwayEnvironment,
        "--skip-deploys",
        variable
      ]);
    }
    try {
      runRailway([
        "restart",
        "--service",
        railwayService,
        "--yes"
      ]);
    } catch (_error) {
      runRailway([
        "redeploy",
        "--service",
        railwayService,
        "--yes"
      ]);
    }
  }

  console.log("");
  console.log("Stripe bootstrap complete");
  console.log("------------------------");
  console.log(`Product ID: ${product.id}`);
  console.log(`Monthly Price ID: ${monthly.id}`);
  console.log(`Yearly Price ID: ${yearly.id}`);
  console.log(`Webhook Endpoint ID: ${webhook.endpoint.id}`);
  if (webhook.secret) {
    const masked = `${webhook.secret.slice(0, 8)}...${webhook.secret.slice(-6)}`;
    console.log(`Webhook Secret: ${masked}`);
  } else {
    console.log("Webhook Secret: <not returned because endpoint already existed>");
    console.log("Tip: Rotate secret in Stripe Dashboard if needed.");
  }
  console.log("");
  console.log("Suggested Railway vars:");
  console.log(`STRIPE_DEFAULT_PRICE_ID=${monthly.id}`);
  console.log(`STRIPE_SECRET_KEY=${secretKey.startsWith("sk_live_") ? "<your-live-key>" : "<your-test-key>"}`);
  if (webhook.secret) {
    console.log("STRIPE_WEBHOOK_SECRET=<created and already synced when RAILWAY_SYNC=true>");
  } else {
    console.log("STRIPE_WEBHOOK_SECRET=<rotate and copy from Stripe>");
  }
  if (railwaySync) {
    console.log("");
    console.log(
      `Railway sync: applied vars to service "${railwayService}" in environment "${railwayEnvironment}" and triggered restart/redeploy.`
    );
  }
  console.log("");
}

main().catch((error) => {
  console.error(error?.message ?? error);
  process.exit(1);
});
