import Stripe from "stripe";
import { config } from "./config.js";

let stripeClient: Stripe | null = null;

export function getStripeClient(): Stripe | null {
  if (!config.stripe.secretKey) {
    return null;
  }
  if (!stripeClient) {
    stripeClient = new Stripe(config.stripe.secretKey, {
      apiVersion: "2026-01-28.clover"
    });
  }
  return stripeClient;
}

export function requireStripeClient(): Stripe {
  const client = getStripeClient();
  if (!client) {
    throw new Error("Stripe is not configured. Set STRIPE_SECRET_KEY.");
  }
  return client;
}

export function isActiveSubscriptionStatus(status: string | null | undefined): boolean {
  if (!status) {
    return false;
  }
  return status === "active" || status === "trialing" || status === "past_due";
}

export function deriveTierFromSubscriptionStatus(status: string | null | undefined): "free" | "pro" {
  return isActiveSubscriptionStatus(status) ? "pro" : "free";
}
