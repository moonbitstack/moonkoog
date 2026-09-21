// Server-Sent Events framing (WHATWG HTML `EventSource` wire format) — the transport A2A streams
// its `message/stream` responses over. This is the pure codec: a byte-exact parser turning an SSE
// body into its events (`event:` / `data:` / `id:` fields, `:` comments ignored, multiple `data:`
// lines joined by newline, a blank line dispatching the event), independent of any live connection.

///|
/// One dispatched SSE event: its type (default `message`), its data payload, and the last seen id.
pub(all) struct SseEvent {
  event : String
  data : String
  id : String?
} derive(Eq, Debug)

///|
/// Parse an SSE stream body into its dispatched events (WHATWG `EventSource` interpretation).
pub fn parse_sse(text : String) -> Array[SseEvent] {
  let events : Array[SseEvent] = []
  let mut event_type = ""
  let data = StringBuilder()
  let mut has_data = false
  let mut last_id : String? = None
  for line in sse_lines(text) {
    if line == "" {
      if has_data {
        let raw = data.to_string()
        events.push({
          event: if event_type == "" {
            "message"
          } else {
            event_type
          },
          data: drop_last_char(raw),
          id: last_id,
        })
      }
      event_type = ""
      data.reset()
      has_data = false
    } else if line.has_prefix(":") {
      continue
    } else {
      let (field, value) = split_field(line)
      match field {
        "event" => event_type = value
        "data" => {
          data.write_string(value)
          data.write_string("\n")
          has_data = true
        }
        "id" => if !contains_nul(value) { last_id = Some(value) }
        _ => ()
      }
    }
  }
  events
}

///|
/// Split an SSE line into (field name, value): the text before the first colon, and the text after
/// it with one optional leading space removed (a colon-less line is a field with an empty value).
fn split_field(line : String) -> (String, String) {
  let chars = chars_of(line)
  let mut colon = -1
  for i in 0..<chars.length() {
    if chars[i] == ':' {
      colon = i
      break
    }
  }
  if colon < 0 {
    return (line, "")
  }
  let mut value_start = colon + 1
  if value_start < chars.length() && chars[value_start] == ' ' {
    value_start = value_start + 1
  }
  (
    chars_to_string(chars, 0, colon),
    chars_to_string(chars, value_start, chars.length()),
  )
}

///|
/// Split `text` on CR, LF, or CRLF line breaks (SSE accepts all three).
fn sse_lines(text : String) -> Array[String] {
  let lines : Array[String] = []
  let sb = StringBuilder()
  let chars = chars_of(text)
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '\r' {
      lines.push(sb.to_string())
      sb.reset()
      if i + 1 < chars.length() && chars[i + 1] == '\n' {
        i = i + 1
      }
    } else if c == '\n' {
      lines.push(sb.to_string())
      sb.reset()
    } else {
      sb.write_string(c.to_string())
    }
    i = i + 1
  }
  lines.push(sb.to_string())
  lines
}

///|
fn chars_of(s : String) -> Array[Char] {
  let a : Array[Char] = []
  for c in s {
    a.push(c)
  }
  a
}

///|
fn chars_to_string(a : Array[Char], start : Int, end : Int) -> String {
  let sb = StringBuilder()
  for i in start..<end {
    sb.write_string(a[i].to_string())
  }
  sb.to_string()
}

///|
/// `s` with its final character removed (used to drop the trailing newline the data buffer carries).
fn drop_last_char(s : String) -> String {
  let a = chars_of(s)
  if a.length() == 0 {
    ""
  } else {
    chars_to_string(a, 0, a.length() - 1)
  }
}

///|
fn contains_nul(s : String) -> Bool {
  for c in s {
    if c == '\u{0000}' {
      return true
    }
  }
  false
}

///|
pub extend SseEvent with Debug::{to_repr}

///|
pub extend SseEvent with Eq::{not_equal, equal}
