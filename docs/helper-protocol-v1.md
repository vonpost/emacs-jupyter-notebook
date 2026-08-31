# EJN Helper Transport Protocol v1

This document freezes the local Emacs/helper transport contract. It is a
length-prefixed stream protocol; it is not the Jupyter wire protocol. The
normative examples and boundary cases are in
`tests/fixtures/helper-protocol-v1.json`, checked by
`tests/validate-helper-protocol-v1.py`.

## Wire format

Each frame is exactly:

```
uint32_be(payload byte length) + payload
```

There is no delimiter or trailing newline. The payload is one UTF-8 encoded
JSON object. The fixture's golden encoder uses `ensure_ascii=false`, sorted
keys, and compact separators `,` and `:` for reproducible bytes. Production
encoders need not sort keys recursively; receivers accept any valid UTF-8
JSON object and ignore unknown top-level fields. JSON strings use normal JSON escapes;
newline and NUL are therefore represented as `\\n` and `\\u0000` in the
payload. The four-byte prefix is included in frame-size accounting and is
never included in the declared payload length.

Both readers must accept a prefix or payload split at any byte boundary and
multiple complete frames in one read. A reader must retain incomplete bytes;
it must reject malformed UTF-8, malformed JSON, a non-object payload, and a
length exceeding its configured ceiling.

## Constants

| Name | Value |
| --- | ---: |
| `EJN_PROTOCOL_VERSION` | 1 |
| `EJN_MAX_TO_EMACS_FRAME` | 262144 bytes |
| `EJN_MAX_TO_HELPER_FRAME` | 1048576 bytes |
| `EJN_MAX_RESPONSE_FRAME` | 65536 bytes |
| `EJN_MAX_CODE_BYTES` | 524288 bytes |
| `EJN_MAX_INFLIGHT_REQUESTS` | 8 |
| `EJN_INITIAL_EVENT_CREDIT` | 262144 bytes |
| `EJN_MAX_EVENT_QUEUE` | 1048576 bytes |
| `EJN_MAX_PRIORITY_QUEUE` | 524288 bytes |
| `EJN_MAX_RAW_ACCUMULATOR` | 1048576 bytes |
| `EJN_STREAM_CHUNK_BYTES` | 32768 bytes |
| `EJN_MAX_ARTIFACT_BYTES` | 67108864 bytes |
| `EJN_PARTIAL_FRAME_TIMEOUT` | 5 seconds |
| `EJN_HELPER_PING_INTERVAL` | 5 seconds |
| `EJN_HELPER_PING_TIMEOUT` | 2 seconds |

All `EJN_MAX_*_FRAME` values and `EJN_MAX_RESPONSE_FRAME` are complete wire
frame ceilings, including the four-byte prefix. The declared length is still
payload bytes. Defcustoms may lower a ceiling, never raise it in v1.

## Envelopes

Every request has an EJN-generated string `id` and has exactly one bounded
response. Requests use `kind=request`, a numeric `v` of 1, an allowed `op`,
and an object `params` (empty when no parameters are needed). Responses use
`kind=response`, the request `id`, and either `ok=true` with a `result`
object or `ok=false` with an `error` object. Unknown top-level fields are
ignored.

Events are asynchronous helper-to-Emacs notifications. Every event has a
numeric helper-local monotonic `seq`, an allowed `event`, and an object
`data`. Events associated with execution output carry `request_id`.
The transport queue, not event producers, assigns `seq` immediately before
wire delivery.  Values therefore increase strictly in observed wire order,
including when a priority event bypasses ordinary output blocked on credit.

Allowed operations are: `hello`, `ping`, `grant_event_credit`, `connect`,
`kernel_info`, `execute`, `complete`, `inspect`, `is_complete`,
`input_reply`, `interrupt`, `restart`, `shutdown`, and `close`.

Allowed events are: `stream`, `display_data`, `execute_result`,
`clear_output`, `status`, `execute_reply`, `input_request`,
`transport_error`, and `output_truncated`.

The canonical error codes are: `invalid-request`, `invalid-event`,
`unsupported`, `timeout`, `protocol-error`, `frame-too-large`,
`credit-exhausted`, `transport-error`, and `busy`. Error messages are short
and safe; tracebacks and arbitrary exception representations remain in logs.

Unknown `kind`, `op`, or `event` values produce a structured `unsupported`
error. Missing or wrongly typed required fields produce `invalid-request` or
`invalid-event`.

## Handshake and credit

Emacs sends `hello` immediately after process creation. Before a valid hello
response, it grants no event credit and sends no `connect`. A successful
response selects version 1 and reports a helper build version and fixed
capabilities. Version mismatch, silence, early exit, bytes before a valid
frame, or text on stdout fails startup.

After the handshake Emacs grants `EJN_INITIAL_EVENT_CREDIT`. Ordinary events
consume credit equal to their complete framed byte length. Credit is
replenished by exactly that amount only after dispatch outside the process
filter. Priority events (`status`, `execute_reply`, `input_request`,
`transport_error`, and `output_truncated`) do not consume ordinary credit;
they share the bounded priority queue and the response-frame ceiling.

The helper coalesces adjacent same-request/same-stream events up to
`EJN_STREAM_CHUNK_BYTES`. If ordinary event storage overflows, further
ordinary stream/result text for that request is discarded and exactly one
`output_truncated` event is guaranteed. State transitions, terminal replies,
input requests, transport errors, and the truncation marker are never dropped.

## Operations and execution

`connect` uses an already-local rewritten connection file and reports
`attached`; liveness is then checked with bounded `kernel_info`. `ping` is
local helper liveness and does not touch Jupyter. `execute` accepts at most
`EJN_MAX_CODE_BYTES` UTF-8 source bytes and is never split. `close` is
local-only. `restart` and `shutdown` are sent only after the corresponding
explicit user command.

The execution ledger is monotonic:

```
queued -> dispatched -> busy -> terminal-ok
                             -> terminal-error
                             -> terminal-cancelled
queued ----------------------> terminal-cancelled
dispatched/busy --------------> outcome-unknown
```

Only one user execution is dispatched at a time. An execution is terminal
only after its correlated `execute_reply` and IOPub `status=idle` have both
arrived, in either order. Late or duplicate events are logged and ignored;
an ambiguous transport failure is never replayed automatically.

### Field contract

Requests require `v`, `kind`, string `id`, string `op`, and object `params`.
`hello.params.versions` is an integer list; `grant_event_credit.bytes` is a
non-negative integer. `connect` requires absolute `connection_file` and
`artifact_dir` strings. `execute` requires UTF-8 `code` at most
`EJN_MAX_CODE_BYTES`; `complete` and `inspect` require `code` and integer
`cursor_pos`; `is_complete` requires `code`; `input_reply` requires the owning
execution's string `request_id`, its exact 32-character lowercase-hex
`input_id`, and a UTF-8 `value` of at most 65536 bytes. The no-parameter
operations use `{}`.

Responses require string `id` and boolean `ok`; success has an object
`result`, failure has a short safe `error` with string `code` and `message`.
Events require integer monotonic `seq`, string `event`, and object `data`;
execution events also require `request_id`. An `input_request` has exactly
`input_id`, `prompt`, and `password`: `input_id` is a fresh 32-character
lowercase-hex token, `prompt` is at most 4096 UTF-8 bytes, and `password` is a
boolean. One input reply may claim each token; stale, duplicate, and
wrong-execution replies are rejected without reaching Jupyter. Stream data has
`name` and `text`; MIME events have bounded `data` and `metadata`; status and
terminal events carry their corresponding state/status fields. Invalid required
fields map to `invalid-request` or `invalid-event`.

For MIME events, `data` remains the Jupyter MIME bundle shape: a selected
artifact MIME has a nested reference value `{path,bytes,sha256}` in place of
the original base64 value, while `text/plain` remains a bounded string.
`metadata` is copied through a JSON-safe normalizer: at most 32 values across
two nested container levels and 8192 UTF-8 string bytes; unsupported or
excess values are omitted and `_ejn_metadata_truncated:true` is added. An
`execute_result` may carry a bounded non-negative integer `execution_count`.
An oversized transient `display_id` is omitted and represented as
`transient.display_id_omitted:true`; it is never shortened, so distinct IDs
cannot become one update key.

User and silent-setup executions share one serialized execution gate, while
silent setup creates no panel entry. At most 8 requests await responses. On
transport ambiguity, dispatched/busy becomes `outcome-unknown`; code is
never replayed automatically. Late replies and duplicate events are logged
and ignored.

### Scheduling and artifacts

Adjacent same-request/same-stream text is coalesced up to
`EJN_STREAM_CHUNK_BYTES`. Ordinary events consume credit equal to their full
wire frame. Priority events are `status`, `execute_reply`, `input_request`,
`transport_error`, and `output_truncated`; they use the reserved priority
queue. Event and priority queues are bounded by their constants. Ordinary
event queue pressure drops bounded ordinary stream/result output for the
affected request, with exactly one `output_truncated` marker guaranteed. Only
priority queue exhaustion is fatal; priority and terminal events are never
dropped. The process filter drains at most 16
frames or 262144 payload bytes per invocation, then schedules a zero-delay
continuation. Its raw accumulator is bounded to 1 MiB. A partial frame has a
5-second deadline and maps to `protocol-error`. Helper pings are answered by
the local asyncio control loop without touching Jupyter.

Emacs creates a per-helper artifact directory mode `0700`, owned by the
current user, and passes its absolute path in `connect`. The helper validates
ownership and confinement and writes only below it. Files use random
same-directory temporary names, mode `0600`, fsync/close, and atomic rename;
published events contain only MIME, byte count, SHA-256, and absolute path.
Before base64 decode, conservative size above `EJN_MAX_ARTIFACT_BYTES` is
rejected, then actual size is checked. Base64 never crosses the transport,
logs, panel, or stdout. Emacs rejects paths outside its directory; Emacs
owns retention/deletion and helper exit does not delete published files.

## Fixture use

The fixture contains named complete vectors plus deterministic `recipe`
vectors. A recipe describes a repeated JSON string field and its target
payload length; the validator materializes it and verifies the expected
length and prefix without storing a large payload in git. Invalid inputs are
represented as `raw_hex` or recipes and expected structured errors, never as
live malformed JSON in the fixture itself.
