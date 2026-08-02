// Supabase Edge Function: iap-app-store-notifications
//
// Verifies App Store Server Notifications V2 and the nested transaction JWS
// with Apple's server library before updating public.iap_entitlements.
// Required/optional secrets match iap-sync-transaction.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  assertTransactionClaims,
  dateFromMillis,
  IAPVerificationError,
  verifiedEntitlementRPCArguments,
  verifyNotification,
} from "../_shared/apple-iap.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);

interface NotificationRequest {
  signedPayload: string;
}

function statusFor(
  notificationType: string | undefined,
  expiresAt: string | null,
  revokedAt: string | null,
): "active" | "expired" | "revoked" | "unknown" {
  if (
    revokedAt ||
    notificationType === "REFUND" ||
    notificationType === "REVOKE"
  ) {
    return "revoked";
  }
  if (notificationType === "EXPIRED") return "expired";
  if (expiresAt && new Date(expiresAt).getTime() <= Date.now()) {
    return "expired";
  }
  if (notificationType == null) return "unknown";
  return "active";
}

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const body = (await req.json()) as NotificationRequest;
    if (!body.signedPayload) {
      throw new IAPVerificationError("Missing signed notification.");
    }

    const verifiedNotification = await verifyNotification(body.signedPayload);
    const notification = verifiedNotification.payload;
    const signedTransactionInfo = notification.data?.signedTransactionInfo;
    if (!signedTransactionInfo) {
      return Response.json({ confirmed: true, result: "no transaction" });
    }

    const transaction = await verifiedNotification.verifier
      .verifyAndDecodeTransaction(signedTransactionInfo);
    assertTransactionClaims(transaction, verifiedNotification.environment);

    const expiresAt = dateFromMillis(transaction.expiresDate);
    const revokedAt = dateFromMillis(transaction.revocationDate);
    const status = statusFor(
      notification.notificationType,
      expiresAt,
      revokedAt,
    );

    const { error } = await supabase.rpc(
      "record_verified_iap_entitlement",
      verifiedEntitlementRPCArguments(
        transaction,
        verifiedNotification.environment,
        status,
        signedTransactionInfo,
        "app_store_server_notification_v2",
        transaction.appAccountToken?.toLowerCase() ?? null,
      ),
    );
    if (error) throw error;

    return Response.json({ confirmed: true, status });
  } catch (error) {
    console.error(error);
    const status = error instanceof IAPVerificationError ? error.status : 500;
    const message = error instanceof Error ? error.message : "Unknown error";
    return Response.json({ confirmed: false, error: message }, { status });
  }
});
