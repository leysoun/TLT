// _shared/llm.ts — Provider abstraction. Anthropic (default) + OpenAI.
import Anthropic from "npm:@anthropic-ai/sdk";
import OpenAI from "npm:openai";

type Provider = "anthropic" | "openai";
const DEFAULT_PROVIDER =
  (Deno.env.get("DEFAULT_INSTRUMENT_PROVIDER") ?? "anthropic") as Provider;

export type ChatMsg = { role: "user" | "assistant"; content: string };

interface RunOpts {
  provider?: Provider;
  model?: string;
  maxTokens?: number;
}

/**
 * Streams an instrument reply. Returns an async iterable of TEXT deltas.
 * The system prompt (instruction set + KB) is assembled server-side by the
 * caller and passed in here — it never leaves the server.
 */
export async function* streamText(
  system: string,
  messages: ChatMsg[],
  opts: RunOpts = {},
): AsyncGenerator<string> {
  const provider = opts.provider ?? DEFAULT_PROVIDER;
  const maxTokens = opts.maxTokens ?? 1500;

  if (provider === "anthropic") {
    const a = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });
    const stream = await a.messages.create({
      model: opts.model ?? "claude-sonnet-4-6",
      max_tokens: maxTokens,
      system,
      messages,
      stream: true,
    });
    for await (const ev of stream) {
      if (ev.type === "content_block_delta" && ev.delta.type === "text_delta") {
        yield ev.delta.text;
      }
    }
  } else {
    const o = new OpenAI({ apiKey: Deno.env.get("OPENAI_API_KEY")! });
    const stream = await o.chat.completions.create({
      model: opts.model ?? "gpt-4.1",
      stream: true,
      max_tokens: maxTokens,
      messages: [{ role: "system", content: system }, ...messages],
    });
    for await (const chunk of stream) {
      const delta = chunk.choices?.[0]?.delta?.content;
      if (delta) yield delta;
    }
  }
}

/**
 * Non-streaming completion that returns the full text. Used for structured
 * extraction (e.g. audit-extract) where we want the whole JSON at once.
 */
export async function complete(
  system: string,
  messages: ChatMsg[],
  opts: RunOpts = {},
): Promise<string> {
  const provider = opts.provider ?? DEFAULT_PROVIDER;
  const maxTokens = opts.maxTokens ?? 500;

  if (provider === "anthropic") {
    const a = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });
    const res = await a.messages.create({
      model: opts.model ?? "claude-sonnet-4-6",
      max_tokens: maxTokens,
      system,
      messages,
    });
    return res.content
      .filter((b) => b.type === "text")
      .map((b) => (b as { text: string }).text)
      .join("");
  } else {
    const o = new OpenAI({ apiKey: Deno.env.get("OPENAI_API_KEY")! });
    const res = await o.chat.completions.create({
      model: opts.model ?? "gpt-4.1",
      max_tokens: maxTokens,
      messages: [{ role: "system", content: system }, ...messages],
    });
    return res.choices?.[0]?.message?.content ?? "";
  }
}
