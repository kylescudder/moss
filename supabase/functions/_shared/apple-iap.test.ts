import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.14";
import {
  Environment,
  type JWSTransactionDecodedPayload,
} from "npm:@apple/app-store-server-library@3.1.0";
import {
  assertTransactionClaims,
  BUNDLE_ID,
  entitlementWriteResponse,
  IAPVerificationError,
  PRODUCT_ID,
  verifiedEntitlementRPCArguments,
  verifiedEntitlementWriteResult,
} from "./apple-iap.ts";

function transaction(
  overrides: Partial<JWSTransactionDecodedPayload> = {},
): JWSTransactionDecodedPayload {
  return {
    bundleId: BUNDLE_ID,
    environment: Environment.SANDBOX,
    productId: PRODUCT_ID,
    appAccountToken: "11111111-1111-1111-1111-111111111111",
    originalTransactionId: "original-1",
    transactionId: "transaction-1",
    signedDate: 1_722_470_400_000,
    expiresDate: 1_725_148_800_000,
    ...overrides,
  } as JWSTransactionDecodedPayload;
}

Deno.test("verified transaction claims require the configured app and product", () => {
  assertThrows(
    () =>
      assertTransactionClaims(
        transaction({ bundleId: "com.example.spoof" }),
        Environment.SANDBOX,
      ),
    IAPVerificationError,
    "bundle ID mismatch",
  );
  assertThrows(
    () =>
      assertTransactionClaims(
        transaction({ productId: "com.example.other" }),
        Environment.SANDBOX,
      ),
    IAPVerificationError,
    "product ID mismatch",
  );
  assertThrows(
    () =>
      assertTransactionClaims(
        transaction({ environment: Environment.PRODUCTION }),
        Environment.SANDBOX,
      ),
    IAPVerificationError,
    "environment mismatch",
  );
});

Deno.test("verified transactions require identifiers and a signing timestamp", () => {
  assertThrows(
    () =>
      assertTransactionClaims(
        transaction({ originalTransactionId: undefined }),
        Environment.SANDBOX,
      ),
    IAPVerificationError,
    "identifiers are required",
  );
  assertThrows(
    () =>
      assertTransactionClaims(
        transaction({ signedDate: undefined }),
        Environment.SANDBOX,
      ),
    IAPVerificationError,
    "signing date is required",
  );
});

Deno.test("verified entitlement RPC arguments carry the server contract", () => {
  const args = verifiedEntitlementRPCArguments(
    transaction(),
    Environment.SANDBOX,
    "active",
    "signed-transaction",
    "app_store_transaction_jws",
    "11111111-1111-1111-1111-111111111111",
  );

  assertEquals(args.target_bundle_id, BUNDLE_ID);
  assertEquals(args.target_product_id, PRODUCT_ID);
  assertEquals(args.target_original_transaction_id, "original-1");
  assertEquals(args.target_transaction_id, "transaction-1");
  assertEquals(args.target_signed_at, "2024-08-01T00:00:00.000Z");
  assertEquals(args.target_verification_source, "app_store_transaction_jws");
});

Deno.test("stale writer results expose authoritative state", () => {
  const result = verifiedEntitlementWriteResult([{
    stored: false,
    authoritative_status: "revoked",
    authoritative_signed_at: "2026-08-02T12:00:00.000Z",
    authoritative_expires_at: "2026-09-02T12:00:00.000Z",
    authoritative_revoked_at: "2026-08-02T12:00:00.000Z",
    authoritative_transaction_id: "newer-revoked-transaction",
  }]);

  assertEquals(entitlementWriteResponse(result), {
    confirmed: true,
    stored: false,
    result: "ignored_stale_event",
    status: "revoked",
    signedAt: "2026-08-02T12:00:00.000Z",
    transactionId: "newer-revoked-transaction",
  });
});

Deno.test("missing authoritative writer state is rejected", () => {
  const error = assertThrows(
    () => verifiedEntitlementWriteResult([]),
    IAPVerificationError,
    "no authoritative state",
  );
  assertEquals(error.status, 500);
});

Deno.test("authenticated sync requires a matching app account token", () => {
  const userID = "11111111-1111-1111-1111-111111111111";
  assertTransactionClaims(transaction(), Environment.SANDBOX, userID);

  const missing = assertThrows(
    () =>
      assertTransactionClaims(
        transaction({ appAccountToken: undefined }),
        Environment.SANDBOX,
        userID,
      ),
    IAPVerificationError,
  );
  assertEquals(missing.status, 403);

  const mismatch = assertThrows(
    () =>
      assertTransactionClaims(
        transaction({
          appAccountToken: "22222222-2222-2222-2222-222222222222",
        }),
        Environment.SANDBOX,
        userID,
      ),
    IAPVerificationError,
  );
  assertEquals(mismatch.status, 403);
});
