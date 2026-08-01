import { Buffer } from "node:buffer";
import {
  Environment,
  type JWSTransactionDecodedPayload,
  type ResponseBodyV2DecodedPayload,
  SignedDataVerifier,
} from "npm:@apple/app-store-server-library@3.1.0";

export const PRODUCT_ID = "app.moss.supporter.monthly";
export const BUNDLE_ID = Deno.env.get("APPLE_BUNDLE_ID") ?? "app.getmoss.moss";

const APPLE_APP_ID = parseAppleAppID(Deno.env.get("APPLE_APP_ID"));
const ROOT_CERTIFICATE_URLS = [
  "https://www.apple.com/appleca/AppleIncRootCertificate.cer",
  "https://www.apple.com/certificateauthority/AppleRootCA-G2.cer",
  "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer",
];

let rootCertificatesPromise: Promise<Buffer[]> | undefined;
const verifierPromises = new Map<Environment, Promise<SignedDataVerifier>>();

export class IAPVerificationError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
    this.name = "IAPVerificationError";
  }
}

export interface VerifiedPayload<T> {
  payload: T;
  environment: Environment;
  verifier: SignedDataVerifier;
}

export async function verifyTransaction(
  signedTransactionInfo: string,
): Promise<VerifiedPayload<JWSTransactionDecodedPayload>> {
  let finalError: unknown;
  for (const environment of configuredEnvironments()) {
    try {
      const verifier = await verifierFor(environment);
      const payload = await verifier.verifyAndDecodeTransaction(
        signedTransactionInfo,
      );
      assertTransactionClaims(payload, environment);
      return { payload, environment, verifier };
    } catch (error) {
      finalError = error;
    }
  }

  console.error("Apple transaction verification failed", finalError);
  throw new IAPVerificationError(
    "Invalid Apple transaction signature or claims.",
  );
}

export async function verifyNotification(
  signedPayload: string,
): Promise<VerifiedPayload<ResponseBodyV2DecodedPayload>> {
  let finalError: unknown;
  for (const environment of configuredEnvironments()) {
    try {
      const verifier = await verifierFor(environment);
      const payload = await verifier.verifyAndDecodeNotification(signedPayload);
      if (payload.data?.bundleId !== BUNDLE_ID) {
        throw new IAPVerificationError("Notification bundle ID mismatch.");
      }
      if (payload.data?.environment !== environment) {
        throw new IAPVerificationError("Notification environment mismatch.");
      }
      return { payload, environment, verifier };
    } catch (error) {
      finalError = error;
    }
  }

  console.error("Apple notification verification failed", finalError);
  throw new IAPVerificationError(
    "Invalid Apple notification signature or claims.",
  );
}

export function assertTransactionClaims(
  transaction: JWSTransactionDecodedPayload,
  expectedEnvironment: Environment,
  authenticatedUserID?: string,
) {
  if (transaction.bundleId !== BUNDLE_ID) {
    throw new IAPVerificationError("Transaction bundle ID mismatch.");
  }
  if (transaction.environment !== expectedEnvironment) {
    throw new IAPVerificationError("Transaction environment mismatch.");
  }
  if (transaction.productId !== PRODUCT_ID) {
    throw new IAPVerificationError("Transaction product ID mismatch.");
  }

  if (authenticatedUserID !== undefined) {
    if (!transaction.appAccountToken) {
      throw new IAPVerificationError(
        "The transaction is missing its app account token.",
        403,
      );
    }
    if (
      transaction.appAccountToken.toLowerCase() !==
        authenticatedUserID.toLowerCase()
    ) {
      throw new IAPVerificationError("Transaction account mismatch.", 403);
    }
  }
}

export function dateFromMillis(value?: number | string): string | null {
  if (value == null) return null;
  const numeric = typeof value === "string" ? Number(value) : value;
  if (!Number.isFinite(numeric)) return null;
  return new Date(numeric).toISOString();
}

function configuredEnvironments(): Environment[] {
  const configured = Deno.env.get("APPLE_IAP_ENVIRONMENTS") ??
    "Production,Sandbox";
  return configured.split(",").map((value) => {
    switch (value.trim().toLowerCase()) {
      case "production":
        if (APPLE_APP_ID === undefined) {
          throw new IAPVerificationError(
            "APPLE_APP_ID is required when Production verification is enabled.",
            500,
          );
        }
        return Environment.PRODUCTION;
      case "sandbox":
        return Environment.SANDBOX;
      default:
        throw new IAPVerificationError(
          `Unsupported APPLE_IAP_ENVIRONMENTS value: ${value}`,
          500,
        );
    }
  });
}

function verifierFor(environment: Environment): Promise<SignedDataVerifier> {
  let promise = verifierPromises.get(environment);
  if (!promise) {
    promise = appleRootCertificates().then((roots) =>
      new SignedDataVerifier(
        roots,
        true,
        environment,
        BUNDLE_ID,
        environment === Environment.PRODUCTION ? APPLE_APP_ID : undefined,
      )
    );
    verifierPromises.set(environment, promise);
  }
  return promise;
}

function appleRootCertificates(): Promise<Buffer[]> {
  rootCertificatesPromise ??= Promise.all(
    ROOT_CERTIFICATE_URLS.map(async (url) => {
      const response = await fetch(url);
      if (!response.ok) {
        throw new IAPVerificationError(
          `Could not load an Apple root certificate (${response.status}).`,
          503,
        );
      }
      return Buffer.from(await response.arrayBuffer());
    }),
  );
  return rootCertificatesPromise;
}

function parseAppleAppID(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new IAPVerificationError(
      "APPLE_APP_ID must be a positive integer.",
      500,
    );
  }
  return parsed;
}
