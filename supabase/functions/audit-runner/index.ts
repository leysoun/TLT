// audit-runner/index.ts — The Self-Permission Audit instrument (streaming).
//
// Flow:
//  1. authenticate caller (their JWT) -> client_id
//  2. get-or-create the 'audit' thread for this client
//  3. persist the incoming user message (service role)
//  4. load history, build system = audit prompt + KB (server-side only)
//  5. stream the model reply to the browser AND accumulate it
//  6. on completion, persist the assistant message
//
// The client may only SELECT messages (RLS). All writes happen here via the
// service role. Prompts/KB never leave the server.

import { corsHeaders } from "../_shared/cors.ts";
import { adminClient, requireUser } from "../_shared/supabase.ts";
import { buildAuditSystem } from "../_shared/kb.ts";
import { streamText, type ChatMsg } from "../_shared/llm.ts";

const SEED_USER_TURN = "I'm ready to begin the audit.";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const clientId = await requireUser(req);
    const body = await req.json().catch(() => ({}));
    const userMessage: string = (body.message ?? "").toString();

    const db = adminClient();

    // 1. get-or-create the audit thread
    let { data: thread } = await db
      .from("threads")
      .select("id")
      .eq("client_id", clientId)
      .eq("program", "audit")
      .maybeSingle();

    if (!thread) {
      const { data: created, error } = await db
        .from("threads")
        .insert({ client_id: clientId, program: "audit" })
        .select("id")
        .single();
      if (error) throw error;
      thread = created;
    }
    const threadId = thread.id;

    // 2. load history (oldest first)
    const { data: history } = await db
      .from("messages")
      .select("role, content")
      .eq("thread_id", threadId)
      .order("created_at", { ascending: true });

    const priorMsgs: ChatMsg[] = (history ?? []).map((m) => ({
      role: m.role as "user" | "assistant",
      content: m.content,
    }));

    // 3. determine the user turn to send
    //    - first ever turn: seed so the instrument opens correctly
    //    - otherwise: the client's message (required)
    const isFirstTurn = priorMsgs.length === 0;
    const turn = isFirstTurn ? SEED_USER_TURN : userMessage;
    if (!turn) {
      return new Response(JSON.stringify({ error: "message required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // persist the user turn (skip persisting the synthetic seed)
    if (!isFirstTurn) {
      await db.from("messages").insert({
        thread_id: threadId,
        role: "user",
        content: userMessage,
      });
    }

    const messages: ChatMsg[] = [...priorMsgs, { role: "user", content: turn }];
    const system = buildAuditSystem();

    // 4. stream to browser + accumulate, then persist the assistant message
    let full = "";
    const encoder = new TextEncoder();
    const stream = new ReadableStream({
      async start(controller) {
        try {
          for await (const delta of streamText(system, messages)) {
            full += delta;
            controller.enqueue(encoder.encode(delta));
          }
          await db.from("messages").insert({
            thread_id: threadId,
            role: "assistant",
            content: full,
          });
          controller.close();
        } catch (e) {
          controller.error(e);
        }
      },
    });

    return new Response(stream, {
      headers: {
        ...corsHeaders,
        "Content-Type": "text/plain; charset=utf-8",
        "Cache-Control": "no-cache",
        "X-Thread-Id": threadId,
      },
    });
  } catch (e) {
    if (e instanceof Response) return e; // 401 from requireUser
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
