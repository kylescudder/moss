// Supabase Edge Function: iap-sync-transaction
//
// Verifies the StoreKit 2 JWS with Apple's server library before mirroring it.
// Required secrets:
//   SUPABASE_SERVICE_ROLE_KEY
//   SUPABASE_URL
//   APPLE_APP_ID
// Optional configuration:
//   APPLE_IAP_ENVIRONMENTS (defaults to Production,Sandbox)

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  assertTransactionClaims,
  dateFromMillis,
  entitlementWriteResponse,
  IAPVerificationError,
  verifiedEntitlementRPCArguments,
  verifiedEntitlementWriteResult,
  verifyTransaction,
} from "../_shared/apple-iap.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);

interface SyncRequest {
  signedTransactionInfo: string;
  source?: string;
}

function statusFor(
  expiresAt: string | null,
  revokedAt: string | null,
): "active" | "expired" | "revoked" {
  if (revokedAt) return "revoked";
  if (expiresAt && new Date(expiresAt).getTime() <= Date.now()) {
    return "expired";
  }
  return "active";
}

async function authenticatedUserID(req: Request): Promise<string> {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "");
  if (!token) throw new IAPVerificationError("Missing bearer token.", 401);

  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) {
    throw new IAPVerificationError("Invalid user token.", 401);
  }
  return data.user.id;
}

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const userID = await authenticatedUserID(req);
    const body = (await req.json()) as SyncRequest;
    if (!body.signedTransactionInfo) {
      throw new IAPVerificationError("Missing signed transaction.");
    }

    const verified = await verifyTransaction(body.signedTransactionInfo);
    const transaction = verified.payload;
    assertTransactionClaims(transaction, verified.environment, userID);

    const expiresAt = dateFromMillis(transaction.expiresDate);
    const revokedAt = dateFromMillis(transaction.revocationDate);
    const status = statusFor(expiresAt, revokedAt);

    const { data, error } = await supabase.rpc(
      "record_verified_iap_entitlement",
      verifiedEntitlementRPCArguments(
        transaction,
        verified.environment,
        status,
        body.signedTransactionInfo,
        "app_store_transaction_jws",
        userID,
      ),
    );
    if (error) throw error;

    const writeResult = verifiedEntitlementWriteResult(data);
    const response = entitlementWriteResponse(writeResult);
    if (!writeResult.stored && writeResult.authoritative_status !== "active") {
      return Response.json(
        { ...response, confirmed: false },
        { status: 409 },
      );
    }
    return Response.json(response);
  } catch (error) {
    console.error(error);
    const status = error instanceof IAPVerificationError ? error.status : 500;
    const message = error instanceof Error ? error.message : "Unknown error";
    return Response.json({ confirmed: false, error: message }, { status });
  }
});
