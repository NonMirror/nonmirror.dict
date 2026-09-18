# Dictionary

An [Omarchy](https://omarchy.org/) shell plugin (Quickshell / QML) that turns
the current selection into an English → Chinese dictionary entry, using
[`sdcv`](https://github.com/Dushistov/sdcv) with the
[ECDICT](https://github.com/skywind3000/ECDICT) StarDict package.

Select a word anywhere, hit `Ctrl+Shift+S`, and read the definition in an
overlay. Search interactively, copy a clean entry, or save the word to an
Anki-importable vocabulary — no terminal popup involved.

![The Dictionary overlay showing the lookup for "anthropic"](preview.png)

## Features

- **Look up the selection** — reads the primary selection or clipboard,
  whichever you touched last, and normalizes it to a single lookup term.
- **Interactive search** — `Ctrl+Shift+D` opens an empty field; type and the
  definition updates as you go (debounced).
- **Loosening lookup** — a query escalates automatically: exact match → exact
  match lowercased → fuzzy suggestions, so `Ephemeral` and `ephemera` both
  land somewhere useful.
- **Copy** — `Enter` copies `word`, phonetic and definition as plain text.
- **Save to vocabulary** — `Ctrl+S` appends `word<TAB>definition` to a TSV,
  ready to import into Anki (newlines are stored as `<br>`).
- **Recently-touched source** — when `dict-watch` timestamps are available,
  the plugin prefers whichever source was touched last.

## Requirements

This plugin is third-party code that runs unsandboxed inside the Omarchy shell
process. It shells out to the following tools, all of which must be on `PATH`:

| Dependency | Purpose | Source |
| --- | --- | --- |
| `sdcv` | StarDict console client that performs the lookups | `extra/sdcv` |
| `stardict-ecdict` | The English → Chinese ECDICT dictionary data | AUR |
| `wl-clipboard` | `wl-copy` / `wl-paste` for selection and copy | `extra/wl-clipboard` |
| `bash`, coreutils | `selection.sh`, vocabulary writes | base |
| `python` (Python 3) | Bounded clipboard and dictionary subprocess helper; standard library only | `core/python` |
| `omarchy-notification-send` | Save/no-result notifications | Omarchy |

Install the packages listed above from their repositories using your usual
tooling. `sdcv` finds the dictionary automatically under
`/usr/share/stardict/dic/`. Confirm it works before installing the plugin:

```sh
sdcv -n -j -e ephemeral
```

## Installation

### Via the Omarchy plugin CLI (recommended)

```sh
omarchy plugin add https://github.com/NonMirror/nonmirror.dict --enable
```

This clones the repository, validates the manifest, installs it to
`~/.config/omarchy/plugins/nonmirror.dict/`, and enables it.

### Manual installation

If you install plugins by hand, download this repository and place its
contents in `~/.config/omarchy/plugins/nonmirror.dict/`.

Then enable it in `~/.config/omarchy/shell.json` by adding it to `plugins`:

```json
"plugins": [
  { "id": "nonmirror.dict" }
]
```

The shell hot-reloads `shell.json` on save; force discovery with
`omarchy-shell shell rescanPlugins` if needed.

### Keybindings

Bind the hotkeys in `~/.config/hypr/bindings.lua`:

```lua
o.bind("CTRL + SHIFT + S", "Dictionary: look up selection",
  "omarchy-shell shell toggle nonmirror.dict '{\"mode\":\"lookup\"}'")
o.bind("CTRL + SHIFT + D", "Dictionary: search",
  "omarchy-shell shell toggle nonmirror.dict '{\"mode\":\"search\"}'")
o.bind("CTRL + SHIFT + ALT + S", "Dictionary: save word to vocabulary",
  "omarchy-shell shell summon nonmirror.dict '{\"mode\":\"save\"}'")
```

Then reload:

```sh
hyprctl reload
```

> **Note:** binding `Ctrl+Shift+S` / `Ctrl+Shift+D` at the compositor level
> shadows those chords in applications while focused. Move them to other
> bindings if that matters to you.

## Uninstallation

### Via the Omarchy plugin CLI (recommended)

```sh
omarchy plugin remove nonmirror.dict
```

### Manual removal

```sh
omarchy plugin disable nonmirror.dict
rm -rf ~/.config/omarchy/plugins/nonmirror.dict
omarchy-shell shell rescanPlugins
```

Remove the `nonmirror.dict` block from `~/.config/omarchy/shell.json` and the
three bindings above from `~/.config/hypr/bindings.lua`.

The plugin never creates its own state outside the vocabulary file, so nothing
else is left behind. To delete the saved words as well:

```sh
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-dict/vocab.tsv"
```

## Usage

| Key | Action |
| --- | --- |
| `Ctrl+Shift+S` | Look up the current selection / clipboard |
| `Ctrl+Shift+D` | Open an empty search field |
| `Ctrl+Shift+Alt+S` | Look up the selection and save it to the vocabulary |
| type | Edit the search field (updates after a short debounce) |
| `↑` / `↓`, `Alt+J` / `Alt+K` | Move through the matches |
| `Enter` | Copy the current entry (or re-run the query if it produced nothing) |
| `Ctrl+S` | Save the current entry to the vocabulary |
| `Ctrl+V` | Paste the clipboard into the search field |
| `Backspace`, `Ctrl+Backspace`, `Ctrl+U` | Edit the field |
| `Ctrl+Del` | Clear the field |
| click a match | Select it |
| `Esc` / click outside | Close the overlay |

Copying and saving write a short status to the heading and post an
`omarchy-notification-send` notification (overwritten on repeat, so saves do
not pile up).

### Modes

The plugin can also be driven directly, which is what the keybindings do:

```sh
# Look up the selection / clipboard
omarchy-shell shell toggle nonmirror.dict '{"mode":"lookup"}'

# Open an empty search field
omarchy-shell shell toggle nonmirror.dict '{"mode":"search"}'

# Look up the selection and save the entry
omarchy-shell shell summon nonmirror.dict '{"mode":"save"}'

# Look up an explicit term
omarchy-shell shell toggle nonmirror.dict '{"mode":"lookup","term":"ephemeral"}'
```

## Vocabulary / Anki

Saved words go to a tab-separated file:

```
${XDG_DATA_HOME:-~/.local/share}/omarchy-dict/vocab.tsv
```

Each line is `term<TAB>definition`, with `<br>` standing in for line breaks
and HTML entities escaped, matching `~/.local/bin/dict-save` and the
`omarchy-dict` helper so existing imports keep working.

In Anki: **File → Import**, pick `vocab.tsv`, set the field separator to
**Tab** and enable **Allow HTML in fields**. The definition's `<br>` tags then
render as line breaks instead of literal text.

## How it works

- `Dict.qml` owns the overlay, the key handling and the `sdcv` calls. Queries
  run one at a time; a term typed while one is in flight is queued and run
  when the current one finishes, so a stale result can never win.
- `sdcv -n -j` returns JSON, which the QML parses after the bounded helper
  has accepted the complete response. The exact-match
  stage adds `-e`, and fuzzy suggestions are reordered so the term you asked
  for is selected rather than buried at the end.
- `bounded_io.py` reads selection, explicit paste, and dictionary output
  under byte limits and deadlines. `selection.sh` is a compatibility wrapper
  for its selection mode; clipboard data is never stored in shell variables.
- Source preference uses the modification times of `primary.time` and
  `clipboard.time` under `${XDG_CACHE_HOME:-~/.cache}/omarchy-dict/` when
  both exist, otherwise primary selection is preferred. Empty/unavailable
  text falls back to the other source. The plugin reads these timestamps
  but never writes them or executes the optional `omarchy-dict/lib.sh`.

### Resource limits

| Data / operation | Limit |
| --- | --- |
| Each selection or clipboard read | 4 KiB of stdout, 8 KiB of stderr, 1 second |
| Entire selection operation, including fallback | 2 seconds |
| Each dictionary stage | 256 KiB of stdout, 8 KiB of stderr, 5 seconds |
| Search field / lookup term | 1,024 UTF-8 bytes |

Limits apply before normalization, JSON parsing, or rendering. An oversized
response is rejected entirely; it is never silently truncated. A failed or
timed-out dictionary stage stops that lookup instead of escalating to fuzzy
search. Every producer runs in a separate process group: cleanup sends
`SIGTERM`, then `SIGKILL` after a 100 ms grace period, and reaps the producer
and adopted descendants. The grace period is the only scheduled extension
past an operation's deadline. Closing the overlay also cancels active reads.

See [the security fix explanation](SECURITY-FIX.md) for the original failure
mode, implementation details, and reproducible regression tests.

## Development

Validate before committing:

```sh
omarchy plugin validate ~/.config/omarchy/plugins/nonmirror.dict
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
qmllint -I "$OMARCHY_PATH/shell" \
  ~/.config/omarchy/plugins/nonmirror.dict/Dict.qml
```

Saved changes under `~/.config/omarchy/plugins/` reload automatically; use
`omarchy-shell shell rescanPlugins` to force discovery.

The regression tests use fake producer processes, so they do not read or
change your clipboard. With Quickshell installed, they also exercise the
production QML controller and process handlers using an offscreen harness.
`qmllint` may report unresolved `qs.*` imports because these are provided
by the running Omarchy shell; it is not a substitute for runtime tests.

## Notes and limits

- The dictionary is **English → Chinese**; other languages work only if you
  install additional StarDict dictionaries that `sdcv` picks up.
- The overlay grabs the keyboard exclusively while open
  (`WlrKeyboardFocus.Exclusive`), so compositor shortcuts other than the ones
  above are not available until it closes.
- Selection capture trims to the first line and strips surrounding
  punctuation; selections containing more than four words use the longest
  word. This normalization is applied only after the entire read passes
  the byte limit.
- The vocabulary file is append-only from the plugin's side; de-duplicate or
  edit it by hand if needed.

## License

MIT — see [LICENSE](LICENSE).
