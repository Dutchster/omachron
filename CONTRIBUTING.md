# Contributing to Omachron

Thanks for your interest in contributing! This document explains how to get
started.

## Development setup

1. Clone the repo and symlink it into `~/.config/omarchy/plugins/` as
   `dutchster.omachron`.
2. Install [Omarchy](https://github.com/basecamp/omarchy) 4.0+ with Quickshell.
3. Saved changes reload automatically. If one does not take, force it with
   `omarchy-shell shell rescanPlugins`.

## Running tests

```bash
# JavaScript (Model.js + State.js)
node --check lib/Model.js && node --check lib/State.js && node --check lib/Messages.js
node --test tests/model.test.js tests/state.test.js tests/messages.test.js

# Python (resolve_app.py, fs_guard.py)
python3 -m py_compile scripts/resolve_app.py scripts/fs_guard.py
python3 -m unittest discover -s tests

# QML lint (best-effort, requires qt6-declarative-tools)
qmllint Service.qml Panel.qml
```

All tests must pass before submitting a PR. GitHub Actions runs the same
commands on every push and pull request, so a PR that breaks them will say
so; the qmllint job is advisory.

## Project structure

```
BarWidget.qml       Bar widget (today's total, popup host)
Panel.qml           Popup panel (usage list, week trend, insights)
Service.qml         Long-running background service (timers, persistence)
lib/
  Messages.js         Every funny message, in one editable place
  Model.js            Pure JS helpers (formatting, aggregation, slacking-off rules)
  State.js            Pure JS state machine (bucket lifecycle, suspend, midnight)
  browser_aliases.json  Browser binary/process names -> canonical app name
  site_apps.json      Hosts that keep their own bucket and name
  slack_apps.json     Sites and programs that count as slacking off by default
scripts/
  resolve_app.py      Terminal, Steam and browser-site resolver
  fetch_site_icon.sh  One-shot site favicon fetch (network side)
  fs_guard.py         Descriptor-based filesystem transactions (history
                      load/save, icon listing, scratch lifecycle, publish)
tests/                Unit tests (Node.js + Python)
docs/assets/        README images
```

### Architecture

- **State.js** owns all state transitions as pure functions. Every input is
  passed explicitly, every output is a new object. Fully testable in Node.js.
- **Model.js** owns display logic: formatting, aggregation, the slacking-off
  rules. Also pure and testable.
- **Service.qml** owns side effects: timers, disk I/O, process spawning, QML
  property bindings. Delegates state transitions to State.js.
- **Panel.qml** and **BarWidget.qml** are read-only views of the service state.

## Making changes

1. **Open an issue first** for non-trivial changes so the approach can be
   discussed.
2. **Follow TDD**: write a failing test that defines the desired behavior,
   then implement the minimal code to make it pass.
3. **Keep changes focused**: one logical change per commit. Do not mix
   unrelated fixes.
4. **Run the full test suite** before pushing:
   ```
   node --test tests/model.test.js tests/state.test.js tests/messages.test.js && python3 -m unittest discover -s tests
   ```

## Code style

- **JavaScript**: `var` (QML engine compatibility), no `let`/`const` in
  source files (tests may use `const`/`let`).
- **Python**: PEP 8, no external dependencies.
- **Wording**: every joke lives in `lib/Messages.js` — verdict phrases,
  go-outside nudges, budget quips. That is the only file to touch to change
  what the plugin says. Its tests assert structure and rotation, never the
  exact wording, so the words can be edited freely without breaking a build.
  Other user-facing strings (insight labels, units) live in `lib/Model.js`,
  never inline in QML.
- **QML**: follow existing patterns in the file you're editing.
- **QML scope**: an unqualified name resolves against the *component root*
  and then the file root — intermediate objects are not in that chain. If a
  delegate gains a wrapper, properties its children read unqualified must
  move up to the new root, or they will silently resolve against the panel
  instead of erroring.

## Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short summary>
```

Types: `feat`, `fix`, `test`, `refactor`, `chore`, `docs`, `perf`, `style`.

- Summary: imperative mood, lowercase, no period, max 72 chars.
- One logical change per commit.

## Browser aliases

`lib/browser_aliases.json` is the single source of truth. `scripts/resolve_app.py`
loads it at runtime, so adding a browser there is enough for the resolver.

`lib/Model.js` cannot `require()` under QML's JS engine, so it carries an inline
copy in `BROWSER_ALIASES`. Update **both**:

- `lib/browser_aliases.json` (read by `scripts/resolve_app.py`, and by
  `lib/Model.js` under Node)
- `lib/Model.js` → `BROWSER_ALIASES` inline copy

They must contain the same keys and map to the same canonical names.

## Site app names

If you add a web app that should keep its own bucket and name
(`mail.google.com` → `gmail`), update **both**:

- `lib/site_apps.json` (read by `scripts/resolve_app.py`, and by
  `lib/Model.js` under Node)
- `lib/Model.js` → `SITE_APPS` inline copy (QML's JS engine has no
  `require`)

They must contain the same entries; a test compares them and fails on drift.
The favicon is fetched from the mapped host, so gmail gets gmail's icon
automatically.

Add the registrable domain unless the subdomain is genuinely a different
thing — a new subdomain key moves that host into its own tracking bucket and
splits existing history. If the only goal is a nicer name, map the domain the
resolver already reduces to. That is how the `" web"` suffixes work: Claude,
Discord, Slack, Spotify and Telegram all ship Linux apps whose window class
reduces to the same word as their domain, so the site is named apart from the
app without moving either one's bucket.

## Slacking-off defaults

The list of sites and programs that count as slacking off out of the box
lives in `lib/slack_apps.json`. Because QML's JS engine has no `require()`,
`lib/Model.js` carries an inline copy in `SLACK_DEFAULTS` — and that inline
copy is the one the shell actually runs. Update **both**; a test compares
them and fails on drift.

Sites are matched on any parent suffix, so `youtube.com` also covers
`music.youtube.com`. Add the registrable domain, not a subdomain, unless
the subdomain is genuinely a different thing.

## Filesystem helper contract

Every stateful disk operation runs through `scripts/fs_guard.py` — history
load/save, the icon-cache listing, and the icon fetcher's scratch
create/publish/discard lifecycle. `Service.qml` and
`scripts/fetch_site_icon.sh` invoke its subcommands with fixed command
strings, and `tests/test_fs_guard.py` pins both sides the same way the
inline JSON copies above are pinned: it asserts the exact invocation
fragments in `Service.qml` and `fetch_site_icon.sh`, and that the domain
regex in `fetch_site_icon.sh` is textually identical to
`fs_guard.DOMAIN_RE`. If you change a subcommand name, an argv shape, or
either regex, update all sides — the drift tests fail otherwise.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE).
