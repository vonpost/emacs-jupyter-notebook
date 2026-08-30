# Fake Helper Fixture

`ejn_fake_helper.py` is a standalone Python-standard-library executable for
ERT process and transport tests. It never imports the production helper,
Jupyter, Emacs, SSH, or network code. Protocol bytes are written only to
stdout; diagnostics from argument parsing go to stderr. `--requests PATH`
records at most 1000 decoded requests and at most 8192 total bytes, with
flushed append behavior. The scenario process reacts to each complete frame
while stdin remains open; callers may keep the pipe open for subsequent
requests.

Run the bounded deterministic self-test:

```sh
timeout 30 python3 tests/fixtures/ejn_fake_helper.py --self-test
```

It runs every scenario twice under bounded child deadlines. The self-test
checks correlated responses, fragmentation, raw fault bytes, exact oversize
prefixes and partial-frame slices, flood count/sequence/ID, late-response
timing and follow-up response, exit-after-op policy, and silent request
recording/liveness:

`normal`, `silent`, `garbage`, `fragmented`, `oversize`, `mid-frame-stop`,
`flood`, `late-response`, and `exit-after-op`.

`normal` and `fragmented` respond immediately to each complete request and
remain usable until stdin closes. `silent` consumes the first request and
remains alive without output. `garbage` emits invalid bytes and exits;
`oversize` emits a prefix exactly one byte above the complete 262144-byte
to-Emacs ceiling without allocating a payload; and `mid-frame-stop` exits
after a partial valid response. `late-response` waits for the bounded
`--delay-ms` (default 100 ms), then responds and remains usable. `flood`
emits `--count` bounded legal events (default 100) followed by a correlated
response. `exit-after-op` defaults to `hello` and exits without a response;
`--respond` opts into a response. All subprocesses have a two-second child
timeout and the outer `timeout` prevents a wedged self-test from waiting
forever.
