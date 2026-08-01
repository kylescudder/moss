import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.14";
import {
  Environment,
  type JWSTransactionDecodedPayload,
} from "npm:@apple/app-store-server-library@3.1.0";
import {
  assertTransactionClaims,
  BUNDLE_ID,
  IAPVerificationError,
  PRODUCT_ID,
} from "./apple-iap.ts";

function transaction(
  overrides: Partial<JWSTransactionDecodedPayload> = {},
): JWSTransactionDecodedPayload {
  return {
    bundleId: BUNDLE_ID,
    environment: Environment.SANDBOX,
    productId: PRODUCT_ID,
    appAccountToken: "11111111-1111-1111-1111-111111111111",
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
