import type { Request, Response, NextFunction } from "express";
import jwt from "jsonwebtoken";
import { config } from "./config.js";

type TokenPayload = {
  userId: string;
  email?: string | null;
};

export type AuthUser = {
  id: string;
  email: string | null;
};

export function issueAccessToken(user: AuthUser): string {
  const payload: TokenPayload = {
    userId: user.id,
    email: user.email
  };
  return jwt.sign(payload, config.jwtSecret, { expiresIn: "30d" });
}

export function verifyAccessToken(token: string): TokenPayload {
  const decoded = jwt.verify(token, config.jwtSecret);
  if (typeof decoded !== "object" || !decoded || !("userId" in decoded)) {
    throw new Error("Invalid token payload");
  }
  return decoded as TokenPayload;
}

export function authMiddleware(req: Request, res: Response, next: NextFunction): void {
  const authHeader = req.header("authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    res.status(401).json({ error: "missing_bearer_token" });
    return;
  }

  const token = authHeader.slice("Bearer ".length).trim();
  try {
    const payload = verifyAccessToken(token);
    req.authUser = {
      id: payload.userId,
      email: payload.email ?? null
    };
    next();
  } catch {
    res.status(401).json({ error: "invalid_token" });
  }
}

declare global {
  namespace Express {
    interface Request {
      authUser?: AuthUser;
    }
  }
}
