import { Buffer } from 'node:buffer'
import {
  Environment,
  SignedDataVerifier
} from '@apple/app-store-server-library'

export const APP_BUNDLE_ID = 'app.getmoss.moss'
export const SUPPORTER_PRODUCT_ID = 'app.moss.supporter.monthly'

const APPLE_ROOT_CERTIFICATES_BASE64 = [
  // Apple Root CA - G3
  `MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==`,
  // Apple Root CA - G2
  `MIIFkjCCA3qgAwIBAgIIAeDltYNno+AwDQYJKoZIhvcNAQEMBQAwZzEbMBkGA1UE
AwwSQXBwbGUgUm9vdCBDQSAtIEcyMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0
aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMw
HhcNMTQwNDMwMTgxMDA5WhcNMzkwNDMwMTgxMDA5WjBnMRswGQYDVQQDDBJBcHBs
ZSBSb290IENBIC0gRzIxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0
aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzCCAiIwDQYJ
KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgREkhI2imKScUcx+xuM23+TfvgHN6s
XuI2pyT5f1BrTM65MFQn5bPW7SXmMLYFN14UIhHF6Kob0vuy0gmVOKTvKkmMXT5x
ZgM4+xb1hYjkWpIMBDLyyED7Ul+f9sDx47pFoFDVEovy3d6RhiPw9bZyLgHaC/Yu
OQhfGaFjQQscp5TBhsRTL3b2CtcM0YM/GlMZ81fVJ3/8E7j4ko380yhDPLVoACVd
J2LT3VXdRCCQgzWTxb+4Gftr49wIQuavbfqeQMpOhYV4SbHXw8EwOTKrfl+q04tv
ny0aIWhwZ7Oj8ZhBbZF8+NfbqOdfIRqMM78xdLe40fTgIvS/cjTf94FNcX1RoeKz
8NMoFnNvzcytN31O661A4T+B/fc9Cj6i8b0xlilZ3MIZgIxbdMYs0xBTJh0UT8TU
gWY8h2czJxQI6bR3hDRSj4n4aJgXv8O7qhOTH11UL6jHfPsNFL4VPSQ08prcdUFm
IrQB1guvkJ4M6mL4m1k8COKWNORj3rw31OsMiANDC1CvoDTdUE0V+1ok2Az6DGOe
HwOx4e7hqkP0ZmUoNwIx7wHHHtHMn23KVDpA287PT0aLSmWaasZobNfMmRtHsHLD
d4/E92GcdB/O/WuhwpyUgquUoue9G7q5cDmVF8Up8zlYNPXEpMZ7YLlmQ1A/bmH8
DvmGqmAMQ0uVAgMBAAGjQjBAMB0GA1UdDgQWBBTEmRNsGAPCe8CjoA1/coB6HHcm
jTAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQwF
AAOCAgEAUabz4vS4PZO/Lc4Pu1vhVRROTtHlznldgX/+tvCHM/jvlOV+3Gp5pxy+
8JS3ptEwnMgNCnWefZKVfhidfsJxaXwU6s+DDuQUQp50DhDNqxq6EWGBeNjxtUVA
eKuowM77fWM3aPbn+6/Gw0vsHzYmE1SGlHKy6gLti23kDKaQwFd1z4xCfVzmMX3z
ybKSaUYOiPjjLUKyOKimGY3xn83uamW8GrAlvacp/fQ+onVJv57byfenHmOZ4VxG
/5IFjPoeIPmGlFYl5bRXOJ3riGQUIUkhOb9iZqmxospvPyFgxYnURTbImHy99v6Z
SYA7LNKmp4gDBDEZt7Y6YUX6yfIjyGNzv1aJMbDZfGKnexWoiIqrOEDCzBL/FePw
N983csvMmOa/orz6JopxVtfnJBtIRD6e/J/JzBrsQzwBvDR4yGn1xuZW7AYJNpDr
FEobXsmII9oDMJELuDY++ee1KG++P+w8j2Ud5cAeh6Squpj9kuNsJnfdBrRkBof0
Tta6SqoWqPQFZ2aWuuJVecMsXUmPgEkrihLHdoBR37q9ZV0+N0djMenl9MU/S60E
inpxLK8JQzcPqOMyT/RFtm2XNuyE9QoB6he7hY1Ck3DDUOUUi78/w0EP3SIEIwiK
um1xRKtzCTrJ+VKACd+66eYWyi4uTLLT3OUEVLLUNIAytbwPF+E=`,
  // Apple Root CA
  `MIIEuzCCA6OgAwIBAgIBAjANBgkqhkiG9w0BAQUFADBiMQswCQYDVQQGEwJVUzET
MBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlv
biBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwHhcNMDYwNDI1MjE0
MDM2WhcNMzUwMjA5MjE0MDM2WjBiMQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBw
bGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkx
FjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAw
ggEKAoIBAQDkkakJH5HbHkdQ6wXtXnmELes2oldMVeyLGYne+Uts9QerIjAC6Bg+
+FAJ039BqJj50cpmnCRrEdCju+QbKsMflZ56DKRHi1vUFjczy8QPTc4UadHJGXL1
XQ7Vf1+b8iUDulWPTV0N8WQ1IxVLFVkds5T39pyez1C6wVhQZ48ItCD3y6wsIG9w
tj8BMIy3Q88PnT3zK0koGsj+zrW5DtleHNbLPbU6rfQPDgCSC7EhFi501TwN22IW
q6NxkkdTVcGvL0Gz+PvjcM3mo0xFfh9Ma1CWQYnEdGILEINBhzOKgbEwWOxaBDKM
aLOPHd5lc/9nXmW8Sdh2nzMUZaF3lMktAgMBAAGjggF6MIIBdjAOBgNVHQ8BAf8E
BAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUK9BpR5R2Cf70a40uQKb3
R01/CF4wHwYDVR0jBBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wggERBgNVHSAE
ggEIMIIBBDCCAQAGCSqGSIb3Y2QFATCB8jAqBggrBgEFBQcCARYeaHR0cHM6Ly93
d3cuYXBwbGUuY29tL2FwcGxlY2EvMIHDBggrBgEFBQcCAjCBthqBs1JlbGlhbmNl
IG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBhcnR5IGFzc3VtZXMgYWNjZXB0
YW5jZSBvZiB0aGUgdGhlbiBhcHBsaWNhYmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBj
b25kaXRpb25zIG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFuZCBjZXJ0aWZp
Y2F0aW9uIHByYWN0aWNlIHN0YXRlbWVudHMuMA0GCSqGSIb3DQEBBQUAA4IBAQBc
NplMLXi37Yyb3PN3m/J20ncwT8EfhYOFG5k9RzfyqZtAjizUsZAS2L70c5vu0mQP
y3lPNNiiPvl4/2vIB+x9OYOLUyDTOMSxv5pPCmv/K/xZpwUJfBdAVhEedNO3iyM7
R6PVbyTi69G3cN8PReEnyvFteO3ntRcXqNx+IjXKJdXZD9Zr1KIkIxH3oayPc4Fg
xhtbCS+SsvhESPBgOJ4V9T0mZyCKM2r3DYLP3uujL/lTaltkwGMzd/c6ByxW69oP
IQ7aunMZT7XZNn/Bh1XZp5m5MkL72NVxnn6hUrcbvZNCJBIqxw8dtk2cXmPIS4AX
UKqK1drk/NAJBzewdXUh`
]

export type VerifiedEntitlementStatus = 'active' | 'expired' | 'revoked'
export type VerificationSource = 'device' | 'notification'

export interface VerifiedSubscriptionTransaction {
  userID: string
  productID: string
  bundleID: string
  originalTransactionID: string
  transactionID: string
  status: VerifiedEntitlementStatus
  expiresAt: string
  revokedAt: string | null
  environment: 'Production' | 'Sandbox'
  signedAt: string
}

export class ApplePayloadValidationError extends Error {}
export class AppleVerificationConfigurationError extends Error {}

type DecodedTransaction = {
  appAccountToken?: string
  bundleId?: string
  environment?: string
  expiresDate?: number | string
  originalTransactionId?: string
  productId?: string
  revocationDate?: number | string
  signedDate?: number | string
  transactionId?: string
}

type DecodedNotification = {
  notificationType?: string
  data?: {
    bundleId?: string
    environment?: string
    signedTransactionInfo?: string
  }
}

const verifiers = new Map<string, SignedDataVerifier>()

function rootCertificates(): Buffer[] {
  return APPLE_ROOT_CERTIFICATES_BASE64.map((certificate) =>
    Buffer.from(certificate.replace(/\s/g, ''), 'base64')
  )
}

function claimedEnvironment(jws: string): Environment {
  const parts = jws.split('.')
  if (parts.length !== 3) {
    throw new ApplePayloadValidationError('Malformed Apple JWS')
  }

  let payload: Record<string, unknown>
  try {
    const normalized = parts[1].replace(/-/g, '+').replace(/_/g, '/')
    payload = JSON.parse(Buffer.from(normalized, 'base64').toString('utf8'))
  } catch {
    throw new ApplePayloadValidationError('Malformed Apple JWS payload')
  }

  const data = payload.data as Record<string, unknown> | undefined
  const summary = payload.summary as Record<string, unknown> | undefined
  const environment =
    payload.environment ?? data?.environment ?? summary?.environment
  if (
    environment !== Environment.PRODUCTION &&
    environment !== Environment.SANDBOX
  ) {
    throw new ApplePayloadValidationError('Unsupported Apple environment')
  }
  return environment
}

function verifier(environment: Environment): SignedDataVerifier {
  const cached = verifiers.get(environment)
  if (cached) return cached

  let appAppleID: number | undefined
  if (environment === Environment.PRODUCTION) {
    const rawAppAppleID = process.env.APPLE_APP_ID
    appAppleID = rawAppAppleID ? Number(rawAppAppleID) : undefined
    if (!Number.isSafeInteger(appAppleID) || (appAppleID ?? 0) <= 0) {
      throw new AppleVerificationConfigurationError(
        'APPLE_APP_ID must be configured for production verification'
      )
    }
  }

  const value = new SignedDataVerifier(
    rootCertificates(),
    true,
    environment,
    APP_BUNDLE_ID,
    appAppleID
  )
  verifiers.set(environment, value)
  return value
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new ApplePayloadValidationError(`Missing Apple transaction ${field}`)
  }
  return value
}

function uuid(value: unknown, field: string): string {
  const stringValue = requiredString(value, field).toLowerCase()
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
      stringValue
    )
  ) {
    throw new ApplePayloadValidationError(`Invalid Apple transaction ${field}`)
  }
  return stringValue
}

function dateFromMillis(value: unknown, field: string): string {
  const millis = typeof value === 'string' ? Number(value) : value
  if (typeof millis !== 'number' || !Number.isFinite(millis) || millis <= 0) {
    throw new ApplePayloadValidationError(`Invalid Apple transaction ${field}`)
  }
  return new Date(millis).toISOString()
}

function optionalDateFromMillis(value: unknown, field: string): string | null {
  return value == null ? null : dateFromMillis(value, field)
}

export function validateSubscriptionTransaction(
  transaction: DecodedTransaction,
  expectedUserID?: string,
  notificationType?: string
): VerifiedSubscriptionTransaction {
  const productID = requiredString(transaction.productId, 'productId')
  const bundleID = requiredString(transaction.bundleId, 'bundleId')
  const environment = requiredString(transaction.environment, 'environment')
  const userID = uuid(transaction.appAccountToken, 'appAccountToken')

  if (productID !== SUPPORTER_PRODUCT_ID) {
    throw new ApplePayloadValidationError('Unexpected Apple product ID')
  }
  if (bundleID !== APP_BUNDLE_ID) {
    throw new ApplePayloadValidationError('Unexpected Apple bundle ID')
  }
  if (
    environment !== Environment.PRODUCTION &&
    environment !== Environment.SANDBOX
  ) {
    throw new ApplePayloadValidationError('Unexpected Apple environment')
  }
  if (
    expectedUserID &&
    userID !== uuid(expectedUserID, 'authenticated user ID')
  ) {
    throw new ApplePayloadValidationError('Apple transaction account mismatch')
  }

  const expiresAt = dateFromMillis(transaction.expiresDate, 'expiresDate')
  const revokedAt = optionalDateFromMillis(
    transaction.revocationDate,
    'revocationDate'
  )
  let status: VerifiedEntitlementStatus =
    new Date(expiresAt) > new Date() ? 'active' : 'expired'
  if (
    revokedAt ||
    notificationType === 'REFUND' ||
    notificationType === 'REVOKE'
  ) {
    status = 'revoked'
  } else if (notificationType === 'EXPIRED') {
    status = 'expired'
  }

  return {
    userID,
    productID,
    bundleID,
    originalTransactionID: requiredString(
      transaction.originalTransactionId,
      'originalTransactionId'
    ),
    transactionID: requiredString(transaction.transactionId, 'transactionId'),
    status,
    expiresAt,
    revokedAt,
    environment,
    signedAt: dateFromMillis(transaction.signedDate, 'signedDate')
  }
}

export async function verifySubscriptionTransaction(
  signedTransactionInfo: string,
  expectedUserID?: string,
  notificationType?: string
): Promise<VerifiedSubscriptionTransaction> {
  const environment = claimedEnvironment(signedTransactionInfo)
  const transaction = (await verifier(environment).verifyAndDecodeTransaction(
    signedTransactionInfo
  )) as DecodedTransaction
  return validateSubscriptionTransaction(
    transaction,
    expectedUserID,
    notificationType
  )
}

export async function verifySubscriptionNotification(
  signedPayload: string
): Promise<{
  notification: DecodedNotification
  transaction: VerifiedSubscriptionTransaction
}> {
  const environment = claimedEnvironment(signedPayload)
  const notification = (await verifier(environment).verifyAndDecodeNotification(
    signedPayload
  )) as DecodedNotification
  const signedTransactionInfo = notification.data?.signedTransactionInfo
  if (!signedTransactionInfo) {
    throw new ApplePayloadValidationError(
      'Notification has no signed transaction'
    )
  }

  const transaction = await verifySubscriptionTransaction(
    signedTransactionInfo,
    undefined,
    notification.notificationType
  )
  if (
    transaction.environment !== environment ||
    notification.data?.bundleId !== APP_BUNDLE_ID
  ) {
    throw new ApplePayloadValidationError(
      'Notification transaction metadata mismatch'
    )
  }
  return { notification, transaction }
}
