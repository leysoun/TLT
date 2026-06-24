// audit-extract/index.ts — After the Audit concludes, extract the structured
// diagnosis and write it to client_records. Returns JSON only.
//
// Called by the frontend when the Audit reaches its result (or triggered by the
// runner). Does a structured, non-streaming completion over the transcript,
// validates against the canonical archetype/key map, then updates the record.

import { corsHeaders } from "../_shared/cors.ts";
import { adminClient, requireUser } from "../_shared/supabase.ts";
import { complete, type ChatMsg } from "../_shared/llm.ts";
import { ARCHETYPE_KEYS, ARCHETYPES } from "../_shared/kb.ts";

const EXTRACT_SYSTEM = `You read a completed Self-Permission Audit transcript and output the diagnosis as STRICT JSON, nothing else.

Return exactly:
{"archetype":"<one of: ${ARCHETYPES.join(", ")}>","prisoner_pattern":"<the personalised 3-5 word pattern name the audit named>"}

Rules:
- archetype MUST be exactly one of the listed values (snake_case).
- prisoner_pattern is the short, personalised name the audit gave THIS person.
- Output JSON only. No prose, no markdown, no backticks.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const clientId = await requireUser(req);
    const db = adminClient();

    // load the audit transcript
    const { data: thread } = await db
      .from("threads")
      .select("id")
      .eq("client_id", clientId)
      .eq("program", "audit")
      .maybeSingle();
    if (!thread) {
      return json({ error: "no audit thread" }, 404);
    }

    const { data: msgs } = await db
      .from("messages")
      .select("role, content")
      .eq("thread_id", thread.id)
      .order("created_at", { ascending: true });

    const transcript = (msgs ?? [])
      .map((m) => `${m.role.toUpperCase()}: ${m.content}`)
      .join("\n\n");

    const messages: ChatMsg[] = [
      { role: "user", content: `TRANSCRIPT:\n\n${transcript}` },
    ];

    const raw = await complete(EXTRACT_SYSTEM, messages, { maxTokens: 200 });

    let parsed: { archetype?: string; prisoner_pattern?: string };
    try {
      parsed = JSON.parse(raw.replace(/```json|```/g, "").trim());
    } catch {
      return json({ error: "extract_parse_failed", raw }, 422);
    }

    const archetype = (parsed.archetype ?? "").trim();
    if (!ARCHETYPES.includes(archetype)) {
      return json({ error: "invalid_archetype", got: archetype }, 422);
    }

    // canonical key — never trust the model's phrasing for this
    const key = ARCHETYPE_KEYS[archetype];
    const prisoner_pattern = (parsed.prisoner_pattern ?? "").trim() || null;

    const { error } = await db
      .from("client_records")
      .update({
        archetype,
        key,
        prisoner_pattern,
        current_program: "architect", // unlock the next stage
        current_phase: "day_1",
      })
      .eq("client_id", clientId);
    if (error) throw error;

    return json({ archetype, key, prisoner_pattern });
  } catch (e) {
    if (e instanceof Response) return e;
    return json({ error: String(e) }, 500);
  }
});

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
