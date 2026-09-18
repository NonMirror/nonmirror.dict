# Clipboard and dictionary resource-exhaustion fix

This addresses the maintainer's [report on submission #7008](https://github.com/omacom/omarchy-plugin-marketplace/issues/7008#issuecomment-5701193287).
The affected submitted commit was `4d742ea5ee269d316acc3000dafcc9140c22ad04`.
The correction is included in version 1.0.1.

## How the vulnerability worked

A Wayland clipboard or primary-selection owner supplies the bytes that
`wl-paste` reads. Those bytes are untrusted input. A local application can
offer a very large selection, stream data quickly, or leave the stream open.
The user triggers the affected path by opening a selection lookup or pasting
into the dictionary overlay; owning the clipboard alone does not automatically
start a lookup.

Previously, `selection.sh` collected the complete `wl-paste` output using a
shell command substitution. `timeout 1` limited elapsed time, but a fast
producer could still deliver hundreds of megabytes within that second.
Trimming to the first line happened only after the complete payload was
already in memory. The optional shared `lib.sh` contained the same unbounded
command substitutions, so wrapping just that library's final output would
not protect its internal shell variables.

`Dict.qml` also used unrestricted `StdioCollector` objects for selection
capture, explicit paste, and both stdout and stderr from `sdcv`. Those
collectors accumulated complete streams inside the long-lived Omarchy shell.
Parsing JSON and building the results model could then allocate additional
copies and objects. A large dictionary response or stderr flood therefore
had the same resource-exhaustion path even without a malicious clipboard.
There was no deadline for paste or dictionary processes, and a process or
descendant holding a pipe open could leave the lookup stuck indefinitely.

The impact was excessive memory consumption, possible shell unresponsiveness
or termination, and stalled/background processes. This finding is a denial
of service through uncontrolled resource consumption, not evidence of remote
code execution or data theft.

## What changed

All three reads now pass through `bounded_io.py`, a short-lived Python 3
standard-library helper. QML never directly collects `wl-paste` or `sdcv`
output. `selection.sh` only executes the same helper. The plugin no longer
sources the optional shell library; it preserves source preference by reading
the watcher timestamps' modification times directly.

| Resource | Maximum |
| --- | --- |
| Selection or explicit paste stdout | 4,096 bytes per read |
| Dictionary stdout | 262,144 bytes per stage |
| Producer stderr | 8,192 bytes per process; counted and discarded |
| Search term, including accumulated pastes | 1,024 UTF-8 bytes |
| Clipboard producer | 1 second |
| Selection operation including fallback | 2 seconds |
| Dictionary stage | 5 seconds |
| Termination grace | 100 milliseconds |

The helper reads fixed-size chunks with a maximum of the remaining allowance
plus one sentinel byte. That extra byte detects overflow even when a stream
would otherwise look valid at the boundary. It never performs an unbounded
read, never accumulates stderr, and never silently accepts a truncated prefix.
Size checks happen before decoding, selection normalization, or JSON parsing.
Invalid UTF-8 and embedded NUL bytes are rejected too.

Successful stdout is released only after both streams have closed, the
producer has exited successfully, and its process group has been cleaned up.
Overflow, timeout, or producer failure discards the collected response.
QML checks both exit code and exit status before accessing the collector,
parsing JSON, updating the search field, rendering results, or saving an entry.
If forwarding to QML itself stalls, the forwarding deadline also expires;
any partially forwarded data still has a failed exit status and is rejected.

Deadlines use a monotonic clock and are checked even when no bytes arrive,
when a producer closes its pipes but keeps running, and when descendants keep
the pipes open after their parent exits. Each producer starts in a new
session/process group. On every exit path, including successful completion,
the helper closes its read ends, sends `SIGTERM` to that group, waits 100 ms,
sends `SIGKILL`, and waits for children to be reaped. Linux subreaper mode lets
the helper adopt and reap orphaned grandchildren in the same group as well.
Closing or reopening the overlay signals the helper to perform this cleanup;
the QML controller waits for it before reusing the process objects.

Dictionary stages still run sequentially: exact, lowercased exact when
needed, and fuzzy. Each stage has its own five-second deadline; a failed
stage aborts that lookup. A pending edited term can then run independently.
Terms are passed as separate arguments after `--`, preventing option-shaped
search text from becoming an `sdcv` option.

## Verification

Run from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
omarchy plugin validate .
bash -n selection.sh
git diff --check
```

The tests use temporary fake `wl-paste` and `sdcv` programs; they never touch
the real clipboard. Integration cases cover exact limits and one-byte
overflow, valid stdout plus overflowing stderr, continuous output, invalid
encoding, failed producers, partial output followed by a stall, and a consumer
that stops reading. Process-tree tests include a leader, child, and grandchild
that ignore `SIGTERM`; they verify that all recorded PIDs disappear from
`/proc`, including zombie entries, before the helper exits.

When Quickshell is installed, additional offscreen tests run the production
controller and `Process` blocks with inert presentation stubs. These check
selection-to-query flow, rejected responses never reaching the JSON parser,
paste rejection, UTF-8 search-field limits, queued queries, and cancellation
when the overlay is reopened. They do not claim to visually test the overlay.

The marketplace's validation and automated security baseline must report the
same full commit SHA as the pushed repository HEAD. Their updated comments
and workflow link are published on [submission #7008](https://github.com/omacom/omarchy-plugin-marketplace/issues/7008).
These static marketplace checks complement the regression tests; they do not
establish that every possible security issue has been audited.

## Scope

The bound protects this plugin's collection, parsing, and rendering path.
The helper still trusts the installed Python, `wl-paste`, and `sdcv` executables.
Process groups are not a sandbox for an intentionally malicious executable
that creates a new session to escape its group, and output caps do not bound
all internal memory allocations inside a dictionary parser. Normal Linux
signal delivery and scheduling are required; a task stuck in uninterruptible
kernel I/O cannot be made to exit on a strict userspace schedule.
