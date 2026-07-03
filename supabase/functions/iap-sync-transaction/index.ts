import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response("Missing authorization", { status: 401 });
  }

  const userClient = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) {
    return new Response("Unauthorized", { status: 401 });
  }

  const body = await req.json();
  const signedTransactionInfo = body.signedTransactionInfo as string | undefined;
  if (!signedTransactionInfo) {
    return new Response("Missing signedTransactionInfo", { status: 400 });
  }

  // Production should verify the App Store JWS and extract transaction fields.
  // This scaffold mirrors the local StoreKit entitlement so the app/backend contract exists.
  const adminClient = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  );

  const { error } = await adminClient.from("iap_entitlements").upsert({
    user_id: userData.user.id,
    product_id: "club.roam.supporter.monthly",
    last_signed_transaction: signedTransactionInfo,
  }, { onConflict: "user_id,product_id" });

  if (error) {
    return new Response(error.message, { status: 500 });
  }

  return Response.json({ ok: true });
});
