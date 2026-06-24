// _shared/cors.ts — CORS headers for browser calls to edge functions.
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*", // tighten to your app origin in production
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
