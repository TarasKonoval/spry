import { getAccessToken, handleUnauthorized } from "@/lib/auth"
import { toIsoDate } from "@/lib/datetime"
import type { ParsedAgenda } from "@/lib/types"

/**
 * The agenda parser's function URL (infra/ai.yml). It only suggests: saving
 * always goes through the meetings API. Empty hides Paste an agenda.
 */
export const PARSER_URL = process.env.NEXT_PUBLIC_PARSER_URL ?? ""
export const isParserConfigured = Boolean(PARSER_URL)

/** The parser refuses longer text with 413; checked here first to save the trip. */
export const MAX_PASTE_CHARS = 10_000

export type ParseResult = {
  agenda: ParsedAgenda
  model: string
  prompt_version: string
}

export type ParserErrorKind =
  "too_long" | "no_agenda" | "busy" | "unavailable" | "network" | "unauthorized"

// One distinct message per kind. The dialog adds "You can still type the agenda below."
const messages: Record<ParserErrorKind, string> = {
  too_long: `The text is too long. Paste at most ${MAX_PASTE_CHARS.toLocaleString("en")} characters.`,
  no_agenda: "Could not find an agenda in this text.",
  busy: "The parser is busy right now. Try again in a few seconds.",
  network: "Could not reach the parser. Check your connection.",
  unauthorized: "Your session has expired. Sign in again.",
  unavailable: "The parser isn't available right now.",
}

export class ParserError extends Error {
  readonly kind: ParserErrorKind

  constructor(kind: ParserErrorKind) {
    super(messages[kind])
    this.name = "ParserError"
    this.kind = kind
  }
}

function errorKind(status: number): ParserErrorKind {
  switch (status) {
    case 401:
      return "unauthorized"
    case 413:
      return "too_long"
    case 422:
      return "no_agenda"
    case 429:
      return "busy"
    // 502: Bedrock refused the call (e.g. no model access); 503: Bedrock or
    // sign-in unreachable. Neither is the text's fault, unlike 422.
    default:
      return "unavailable"
  }
}

/**
 * Sends pasted text to the parser. Takes 2–8 s; pass an AbortSignal so the
 * user can cancel. A cancelled request rejects with the fetch AbortError.
 */
export async function parseAgenda(text: string, signal?: AbortSignal): Promise<ParseResult> {
  if (text.length > MAX_PASTE_CHARS) throw new ParserError("too_long")

  const token = getAccessToken()
  let response: Response
  try {
    response = await fetch(`${PARSER_URL}/`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      // "Monday" means the user's Monday: the function itself runs in UTC.
      body: JSON.stringify({
        text,
        today: toIsoDate(new Date()),
        tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
      }),
      signal,
      cache: "no-store",
    })
  } catch (error) {
    if (signal?.aborted) throw error
    throw new ParserError("network")
  }

  if (!response.ok) {
    if (response.status === 401) handleUnauthorized()
    throw new ParserError(errorKind(response.status))
  }
  return (await response.json()) as ParseResult
}
