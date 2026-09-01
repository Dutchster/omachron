#!/usr/bin/env python3
"""Resolve what the active window is really showing.

The compositor reports a window's appId, but for screen time three kinds
of window deserve a better answer:

  * Terminals ("foot") — walk /proc to the pty's foreground process group
    and report the app running inside (e.g. "opencode", "btop").
  * Steam games ("steam_app_730") — resolve the AppID to the game title
    from local appmanifests.
  * Browsers ("firefox", "brave-browser", …) — resolve the focused tab to
    a per-site key ("site:github.com") from the browser's own session
    store: Firefox-family recovery.jsonlz4, Chromium-family SNSS
    Session_* files. Both already exist for crash recovery, so the
    browser does no extra work — no extension, no debug port, no
    accessibility tree. Private/incognito windows never reach the session
    store, so private browsing stays untracked by design.

Results are canonicalized: a browser launched from a terminal (or one of
its subprocesses) reports the browser's tracking app name, never the
binary or an internal worker (zen-bin / Web Content / forkserver / …), so
screen time aggregates per browser.

Usage: resolve_app.py <terminal-pid>
Prints a single tracking name and nothing on failure (the service falls
back to the raw appId).
"""

import configparser
import glob
import json
import os
import re
import struct
import subprocess
import sys
from urllib.parse import urlsplit


# comm names of internal browser worker processes. These must never show up
# as tracked apps on their own.
BROWSER_SUBPROCESS_COMMS = {
    "Web Content",
    "forkserver",
    "socket",
    "rdd",
    "utility",
    "tab",
    "GPU Process",
    "Content Process",
    "Utility Process",
    "Isolated Web App",
    "WebExtensions",
    "spellcheck",
    "renderer",
    "Renderer",
    "zygote",
    "gpu-process",
    "GPU",
    "Crashpad Handler",
    "Chrome_ChildThread",
}

# Browser binary basenames -> canonical tracking app name.
# Single source of truth: lib/browser_aliases.json (shared with Model.js).
_ALIASES_JSON = os.path.join(
    os.path.dirname(__file__), os.pardir, "lib", "browser_aliases.json"
)
try:
    with open(_ALIASES_JSON) as _f:
        BROWSER_BINARY_TO_APP = json.load(_f)
except (OSError, json.JSONDecodeError):
    BROWSER_BINARY_TO_APP = {}

# Tracking key for a resolved website; lib/Model.js renders these keys
# (SITE_KEY_RE) with the site's registrable label and favicon.
SITE_KEY_PREFIX = "site:"

# Web apps that deserve their own identity: hosts kept as their own
# tracking bucket instead of folding into the registrable domain, so
# mail.google.com is gmail rather than more google. Single source of
# truth: lib/site_apps.json (shared with Model.js, which renders the
# display names).
_SITE_APPS_JSON = os.path.join(
    os.path.dirname(__file__), os.pardir, "lib", "site_apps.json"
)
try:
    with open(_SITE_APPS_JSON) as _f:
        SITE_APPS = json.load(_f)
except (OSError, json.JSONDecodeError):
    SITE_APPS = {}

# Canonical browser name -> session-store profile base, per engine family.
# tor-browser and mullvad-browser are deliberately absent: resolving their
# tabs would defeat the point of using them.
GECKO_PROFILE_BASES = {
    "firefox": "~/.mozilla/firefox",
    "zen": "~/.zen",
    "librewolf": "~/.librewolf",
    "waterfox": "~/.waterfox",
}
BLINK_PROFILE_BASES = {
    "chromium": "~/.config/chromium",
    "brave": "~/.config/BraveSoftware/Brave-Browser",
    "google-chrome": "~/.config/google-chrome",
    "vivaldi": "~/.config/vivaldi",
    "microsoft-edge": "~/.config/microsoft-edge",
}

# Window titles are "<tab title><suffix>"; stripping the suffix leaves the
# tab title used to pick the focused window's tab among several windows.
_TITLE_SUFFIXES = (
    " — Mozilla Firefox Private Browsing",
    " — Mozilla Firefox",
    " - Mozilla Firefox",
    " — LibreWolf",
    " - LibreWolf",
    " — Zen Browser",
    " - Zen Browser",
    " - Chromium",
    " - Brave",
    " - Google Chrome",
    " - Vivaldi",
    " - Microsoft Edge",
)

# Common two-label public suffixes, enough to reduce a hostname to its
# registrable domain (news.ycombinator.com -> ycombinator.com, bbc.co.uk ->
# bbc.co.uk stays bbc + co.uk). Not the full PSL; unknown two-label
# suffixes just keep one extra label, which is harmless for grouping.
_MULTI_PART_SUFFIXES = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk",
    "com.au", "net.au", "org.au", "edu.au", "gov.au",
    "co.nz", "org.nz", "net.nz",
    "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
    "com.br", "net.br", "org.br",
    "com.mx", "com.ar", "com.co", "com.pe", "com.ve",
    "co.in", "net.in", "org.in", "ac.in",
    "co.kr", "or.kr", "com.cn", "net.cn", "org.cn",
    "com.tw", "com.hk", "com.sg", "com.my", "co.th", "co.id",
    "co.za", "org.za", "com.tr", "com.eg", "co.il", "org.il",
    "com.ua", "com.pl", "com.ru",
}


def proc_stat(pid):
    """Parse /proc/[pid]/stat. Returns a dict or None on failure."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as fh:
            data = fh.read().decode()
    except (OSError, ValueError):
        return None
    try:
        lparen = data.index("(")
        rparen = data.rindex(")")
    except ValueError:
        return None
    comm = data[lparen + 1 : rparen]
    fields = data[rparen + 1 :].split()
    if len(fields) < 8:
        return None
    return {
        "comm": comm,
        "ppid": int(fields[1]),
        "pgrp": int(fields[2]),
        "session": int(fields[3]),
        "ttynr": int(fields[4]),
        "tpgid": int(fields[5]),
    }


def proc_name(pid):
    """Display name of a process: basename of argv[0], falling back to comm."""
    stat = proc_stat(pid)
    if stat is None:
        return None
    name = stat["comm"]
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            args = fh.read().decode(errors="replace").split("\0")
        if args and args[0]:
            name = os.path.basename(args[0])
    except OSError:
        pass
    return name


def _children(pid):
    """Direct child pids of a process, via /proc task children files."""
    try:
        tasks = os.listdir(f"/proc/{pid}/task")
    except OSError:
        return []
    out = []
    for tid in tasks:
        try:
            with open(f"/proc/{pid}/task/{tid}/children") as fh:
                out.extend(int(p) for p in fh.read().split())
        except (OSError, ValueError):
            continue
    return out


# Levels below the terminal to search for the pty-owning session.
# Terminals spawn their shell directly (depth 1); wrappers are rare.
_MAX_TTY_SEARCH_DEPTH = 4

# steamapps directories that hold appmanifest_<appid>.acf files. The first
# two are the same library via symlink on most installs; both are listed
# because neither is guaranteed to exist.
_STEAM_ROOTS = [
    os.path.expanduser("~/.steam/steam/steamapps"),
    os.path.expanduser("~/.local/share/Steam/steamapps"),
    os.path.expanduser("~/.steam/root/steamapps"),
    os.path.expanduser(
        "~/.var/app/com.valvesoftware.Steam/.steam/steam/steamapps"
    ),
]

_STEAM_CLASS_RE = re.compile(r"^steam_app_(\d+)$", re.IGNORECASE)


def _steam_class_appid(class_name):
    """AppID from a Steam window class ("steam_app_730" -> "730").

    Steam games report their AppID as the compositor window class. Returns
    None for anything else, including non-string input.
    """
    if not isinstance(class_name, str):
        return None
    m = _STEAM_CLASS_RE.match(class_name)
    return m.group(1) if m else None


def _acf_name(path):
    """Game title from an appmanifest .acf file, or None.

    ACF is Valve's KeyValues format; manifests carry the title as a flat
    "name" entry ("name"\t\t"Stardew Valley"), so a targeted regex beats
    shipping a full parser.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            data = fh.read()
    except OSError:
        return None
    m = re.search(r'"name"\s*"([^"]*)"', data)
    return m.group(1) if m else None


def steam_title_for_class(class_name):
    """Resolve a steam_app_* window class to its game title, or None."""
    appid = _steam_class_appid(class_name)
    if appid is None:
        return None
    for root_dir in _STEAM_ROOTS:
        title = _acf_name(os.path.join(root_dir, f"appmanifest_{appid}.acf"))
        if title:
            return title
    return None


def _find_tty_session(terminal_pid):
    """Bounded DFS below the terminal for a descendant owning a pty.

    Terminals like foot spawn their shell with forkpty, so the pty is
    the child's controlling terminal, not the terminal's own.  Returns
    that descendant's proc_stat (its ``tpgid`` is the foreground group),
    or None when no descendant owns a tty.
    """
    frontier = [(pid, 1) for pid in _children(terminal_pid)]
    seen = set()
    while frontier:
        pid, depth = frontier.pop(0)
        if pid in seen or depth > _MAX_TTY_SEARCH_DEPTH:
            continue
        seen.add(pid)
        stat = proc_stat(pid)
        if stat is None:
            continue
        if stat["ttynr"] and stat["tpgid"] > 0:
            return stat
        for child in _children(pid):
            frontier.append((child, depth + 1))
    return None


def _resolve_terminal_foreground(terminal_pid):
    """Resolve the foreground process in a terminal window.

    Reads the terminal's own /proc/[pid]/stat ``tpgid`` field when the
    terminal holds the pty as its controlling terminal.  Otherwise (e.g.
    foot reports ttynr=0 / tpgid=-1) searches its descendants for the
    pty-owning session and uses that session's ``tpgid``.  If the
    foreground process is a browser subprocess (Web Content, forkserver,
    …), walks its ancestor chain to find the browser binary.  Returns
    the canonical app name, or None.
    """
    stat = proc_stat(terminal_pid)
    if stat is None:
        return None

    tpgid = stat["tpgid"]
    if tpgid <= 0 or tpgid == terminal_pid:
        tty_stat = _find_tty_session(terminal_pid)
        tpgid = tty_stat["tpgid"] if tty_stat else 0
    if tpgid <= 0:
        return None

    name = proc_name(tpgid)
    if not name:
        return None

    # Walk up from a browser worker (Web Content, forkserver, …) to the
    # browser binary so time attributes to the browser, not an internal
    # process.  Only reads /proc for ancestors, not all processes.
    pid = tpgid
    while name in BROWSER_SUBPROCESS_COMMS:
        parent_stat = proc_stat(pid)
        ppid = parent_stat["ppid"] if parent_stat else 0
        if ppid <= 1:
            break
        pid = ppid
        name = proc_name(pid)
        if not name:
            break

    return BROWSER_BINARY_TO_APP.get(name, name) if name else None


# ---- Browser site resolution ---------------------------------------------
#
# Reads the focused tab out of the browser's crash-recovery session store.
# Firefox family keeps titles fresh but selection markers up to 15s stale
# (browser.sessionstore.interval), so the compositor title picks the tab.
# Chromium family writes selection markers within ~3s but persists empty
# titles, so its own active-window/selected-tab markers decide. Everything
# degrades to "print nothing" (the service then buckets the plain browser).


def lz4_block_decompress(src, max_out):
    """Raw LZ4 block decoder (pure python; mozLz4 carries one block)."""
    dst = bytearray()
    i, n = 0, len(src)
    while i < n:
        token = src[i]
        i += 1
        lit_len = token >> 4
        if lit_len == 15:
            while True:
                b = src[i]
                i += 1
                lit_len += b
                if b != 255:
                    break
        if lit_len:
            dst += src[i:i + lit_len]
            i += lit_len
        if i >= n:
            break  # last sequence carries literals only
        offset = src[i] | (src[i + 1] << 8)
        i += 2
        match_len = (token & 0x0F) + 4
        if match_len == 19:
            while True:
                b = src[i]
                i += 1
                match_len += b
                if b != 255:
                    break
        start = len(dst) - offset
        if offset == 0 or start < 0:
            raise ValueError("corrupt LZ4 stream")
        if offset >= match_len:
            dst += dst[start:start + match_len]
        else:
            # Overlapping (RLE-style) match: double a bytes chunk instead
            # of appending byte-by-byte; += on a bytearray sourcing itself
            # raises BufferError.
            chunk = bytes(dst[start:])
            while len(chunk) < match_len:
                chunk = chunk + chunk
            dst += chunk[:match_len]
        if len(dst) > max_out:
            raise ValueError("LZ4 output exceeds declared size")
    return bytes(dst)


# Ceilings for a Firefox-family session store, mirroring _SNSS_MAX_BYTES on
# the Chromium side: a store past the compressed cap is not worth replaying
# on a poll tick, and a header that declares a decompressed size far beyond
# what that could expand to is a corrupt or hostile file, not a session.
# Without the caps this path would read, decompress (the header size field
# is an arbitrary u32) and json-parse an unbounded file every 5 seconds
# while a browser holds focus.
_MOZLZ4_MAX_BYTES = 20 * 1024 * 1024
_MOZLZ4_MAX_OUT = 8 * _MOZLZ4_MAX_BYTES


def read_mozlz4(path):
    if os.path.getsize(path) > _MOZLZ4_MAX_BYTES:
        raise ValueError("mozLz4 file exceeds size ceiling")
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(b"mozLz40\0"):
        raise ValueError("not a mozLz4 file")
    (out_size,) = struct.unpack_from("<I", data, 8)
    if out_size > _MOZLZ4_MAX_OUT:
        raise ValueError("mozLz4 declared size exceeds ceiling")
    return lz4_block_decompress(data[12:], out_size)


def firefox_default_profile(base_dir):
    """Profile dir from profiles.ini: [Install*] Default=, else Default=1.

    The [Install…] section is what a normally launched Firefox uses; the
    per-profile Default=1 flag and first-profile fallbacks cover older
    layouts.
    """
    cp = configparser.ConfigParser()
    if not cp.read(os.path.join(base_dir, "profiles.ini")):
        return None

    def resolve(section):
        path = cp.get(section, "Path", fallback=None)
        if not path:
            return None
        rel = cp.get(section, "IsRelative", fallback="1") == "1"
        return os.path.join(base_dir, path) if rel else path

    for section in cp.sections():
        if section.startswith("Install"):
            path = cp.get(section, "Default", fallback=None)
            if path:
                return os.path.join(base_dir, path)
    for section in cp.sections():
        if (section.startswith("Profile")
                and cp.get(section, "Default", fallback=None) == "1"):
            return resolve(section)
    for section in cp.sections():
        if section.startswith("Profile"):
            return resolve(section)
    return None


def firefox_open_tabs(profile_dir):
    """Open tabs from recovery.jsonlz4 (sessionstore.jsonlz4 right after
    launch, before the first recovery write). Each tab: url, title,
    selected_in_window, window_selected, last_accessed."""
    candidates = (
        os.path.join(profile_dir, "sessionstore-backups", "recovery.jsonlz4"),
        os.path.join(profile_dir, "sessionstore.jsonlz4"),
    )
    session = None
    for path in candidates:
        try:
            session = json.loads(read_mozlz4(path))
            break
        except (OSError, ValueError):
            continue
    if session is None:
        return []
    out = []
    sel_win = session.get("selectedWindow", 1)
    for wi, win in enumerate(session.get("windows", []), start=1):
        sel_tab = win.get("selected", 1)
        for ti, tab in enumerate(win.get("tabs", []), start=1):
            entries = tab.get("entries") or []
            idx = tab.get("index", len(entries))
            if not entries or not (1 <= idx <= len(entries)):
                continue
            entry = entries[idx - 1]
            out.append({
                "url": entry.get("url", ""),
                "title": entry.get("title", ""),
                "selected_in_window": ti == sel_tab,
                "window_selected": wi == sel_win,
                "last_accessed": tab.get("lastAccessed", 0),
            })
    return out


class _Pickle:
    """Chromium base::Pickle reader: u32 payload size, 4-byte aligned
    fields, strings length-prefixed (string16 = UTF-16LE)."""

    def __init__(self, buf):
        (self.size,) = struct.unpack_from("<I", buf, 0)
        self.buf = buf
        self.off = 4

    def _align(self):
        self.off = (self.off + 3) & ~3

    def read_int(self):
        (v,) = struct.unpack_from("<i", self.buf, self.off)
        self.off += 4
        return v

    def read_string(self):
        n = self.read_int()
        if n < 0 or self.off + n > len(self.buf):
            raise ValueError("bad pickle string")
        s = self.buf[self.off:self.off + n].decode("utf-8", "replace")
        self.off += n
        self._align()
        return s

    def read_string16(self):
        n = self.read_int()
        nb = n * 2
        if n < 0 or self.off + nb > len(self.buf):
            raise ValueError("bad pickle string16")
        s = self.buf[self.off:self.off + nb].decode("utf-16-le", "replace")
        self.off += nb
        self._align()
        return s


# components/sessions/core/session_service_commands.cc ids (stable for
# years). UpdateTabNavigation payloads are Pickles; the small commands are
# raw packed structs with NO pickle header — verified against real
# Session_* files. Unknown ids are skipped, so format drift degrades to
# the plain browser bucket instead of breaking.
_SNSS_SET_TAB_WINDOW = 0
_SNSS_SET_TAB_INDEX_IN_WINDOW = 2
_SNSS_UPDATE_TAB_NAVIGATION = 6
_SNSS_SET_SELECTED_NAVIGATION_INDEX = 7
_SNSS_SET_SELECTED_TAB_IN_INDEX = 8
_SNSS_TAB_CLOSED = 16
_SNSS_WINDOW_CLOSED = 17
_SNSS_SET_ACTIVE_WINDOW = 20

# A Session_* file larger than this is not worth replaying on a poll tick.
_SNSS_MAX_BYTES = 20 * 1024 * 1024


def _iter_snss_commands(path):
    if os.path.getsize(path) > _SNSS_MAX_BYTES:
        return
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:4] != b"SNSS":
        return
    off = 8  # magic + i32 version
    n = len(data)
    while off + 3 <= n:
        (size,) = struct.unpack_from("<H", data, off)
        off += 2
        if size == 0 or off + size > n:
            break  # truncated tail mid-write; keep what replayed so far
        yield data[off], data[off + 1:off + size]
        off += size


def chromium_last_used_profile(base_dir):
    """Profile dir from Local State's profile.last_used (default Default)."""
    name = "Default"
    try:
        with open(os.path.join(base_dir, "Local State")) as fh:
            name = json.load(fh).get("profile", {}).get("last_used", name)
    except (OSError, ValueError):
        pass
    return os.path.join(base_dir, name)


def chromium_open_tabs(profile_dir):
    """Replay the newest Sessions/Session_* command log into open tabs."""
    files = glob.glob(os.path.join(profile_dir, "Sessions", "Session_*"))
    if not files:
        return []
    path = max(files, key=os.path.getmtime)
    tab_window = {}
    tab_index = {}
    tab_navs = {}
    tab_sel_nav = {}
    win_sel_tab = {}
    active_window = None
    closed_tabs = set()
    closed_windows = set()

    try:
        commands = list(_iter_snss_commands(path))
    except OSError:
        return []
    for cmd, payload in commands:
        try:
            if cmd == _SNSS_SET_TAB_WINDOW:
                w, t = struct.unpack_from("<ii", payload, 0)
                tab_window[t] = w
                closed_tabs.discard(t)
            elif cmd == _SNSS_SET_TAB_INDEX_IN_WINDOW:
                t, i = struct.unpack_from("<ii", payload, 0)
                tab_index[t] = i
            elif cmd == _SNSS_UPDATE_TAB_NAVIGATION:
                p = _Pickle(payload)
                t = p.read_int()
                nav_index = p.read_int()
                url = p.read_string()
                title = p.read_string16()
                tab_navs.setdefault(t, {})[nav_index] = (url, title)
            elif cmd == _SNSS_SET_SELECTED_NAVIGATION_INDEX:
                t, i = struct.unpack_from("<ii", payload, 0)
                tab_sel_nav[t] = i
            elif cmd == _SNSS_SET_SELECTED_TAB_IN_INDEX:
                w, i = struct.unpack_from("<ii", payload, 0)
                win_sel_tab[w] = i
            elif cmd == _SNSS_SET_ACTIVE_WINDOW:
                (active_window,) = struct.unpack_from("<i", payload, 0)
            elif cmd == _SNSS_TAB_CLOSED:
                (t,) = struct.unpack_from("<i", payload, 0)
                closed_tabs.add(t)
            elif cmd == _SNSS_WINDOW_CLOSED:
                (w,) = struct.unpack_from("<i", payload, 0)
                closed_windows.add(w)
        except (struct.error, ValueError, IndexError):
            continue

    out = []
    for t, navs in tab_navs.items():
        if t in closed_tabs or not navs:
            continue
        w = tab_window.get(t)
        if w in closed_windows:
            continue
        nav = tab_sel_nav.get(t)
        if nav not in navs:
            nav = max(navs)
        url, title = navs[nav]
        # Selection data can be absent (fresh profile, format drift);
        # missing must read as not-selected, never None == None.
        sel_idx = win_sel_tab.get(w)
        idx = tab_index.get(t)
        out.append({
            "url": url,
            "title": title,
            "selected_in_window": (sel_idx is not None and idx is not None
                                   and sel_idx == idx),
            "window_selected": (active_window is not None
                                and w == active_window),
            "last_accessed": 0,
        })
    return out


def strip_title_suffix(window_title):
    for suffix in _TITLE_SUFFIXES:
        if window_title.endswith(suffix):
            return window_title[:-len(suffix)]
    return window_title


def pick_active_tab(tabs, window_title=None):
    """Best guess at the focused tab.

    1. A compositor-title match against a selected-in-window tab wins: it
       identifies the focused window even when the session's own
       active-window marker is stale (Firefox: up to 15s).
    2. Else the session's active window's selected tab.
    3. Else any selected tab, most recently accessed first.
    """
    if not tabs:
        return None
    selected = [t for t in tabs if t["selected_in_window"]]
    if window_title:
        want = strip_title_suffix(window_title)
        matches = [t for t in selected if t["title"] == want]
        if not matches:
            matches = [t for t in tabs if t["title"] == want]
        if len(matches) == 1:
            return matches[0]
        if matches:
            for t in matches:
                if t["window_selected"]:
                    return t
            return matches[0]
    for t in selected:
        if t["window_selected"]:
            return t
    if selected:
        return max(selected, key=lambda t: t["last_accessed"])
    return None


def site_key_for_url(url):
    """Tracking key for a URL: "site:" + registrable domain, or None for
    URLs without a meaningful host (about:, file:, …). Known web apps
    (lib/site_apps.json) keep their own subdomain as the key instead —
    mail.google.com stays gmail's bucket, not google's."""
    try:
        host = urlsplit(url).hostname or ""
    except ValueError:
        return None
    host = host.strip(".").lower()
    if not host:
        return None
    labels = host.split(".")
    # Longest mapped suffix wins, so u.mail.google.com still lands on
    # mail.google.com's bucket.
    for i in range(len(labels)):
        candidate = ".".join(labels[i:])
        if candidate in SITE_APPS:
            return SITE_KEY_PREFIX + candidate
    if len(labels) < 2 or all(p.isdigit() for p in labels) or ":" in host:
        return SITE_KEY_PREFIX + host  # localhost, IPv4, IPv6
    tail2 = ".".join(labels[-2:])
    keep = 3 if tail2 in _MULTI_PART_SUFFIXES and len(labels) >= 3 else 2
    return SITE_KEY_PREFIX + ".".join(labels[-keep:])


def resolve_browser_site(canonical_app, window_title):
    """Site key for the focused tab of a browser window, or None."""
    if canonical_app in GECKO_PROFILE_BASES:
        base = os.path.expanduser(GECKO_PROFILE_BASES[canonical_app])
        profile = firefox_default_profile(base)
        tabs = firefox_open_tabs(profile) if profile else []
    elif canonical_app in BLINK_PROFILE_BASES:
        base = os.path.expanduser(BLINK_PROFILE_BASES[canonical_app])
        tabs = chromium_open_tabs(chromium_last_used_profile(base))
    else:
        return None
    active = pick_active_tab(tabs, window_title)
    if not active:
        return None
    return site_key_for_url(active["url"])


def main():
    window_class = ""
    window_title = ""
    if len(sys.argv) == 2:
        try:
            terminal_pid = int(sys.argv[1])
        except ValueError:
            sys.exit(0)
    else:
        try:
            out = subprocess.run(
                ["hyprctl", "activewindow", "-j"],
                capture_output=True,
                text=True,
                timeout=2,
            ).stdout
            info = json.loads(out)
            terminal_pid = int(info.get("pid") or 0)
            window_class = info.get("class") or ""
            window_title = info.get("title") or ""
        except (ValueError, json.JSONDecodeError, subprocess.SubprocessError):
            terminal_pid = 0

    # Steam games: the class carries the AppID, so /proc walking is both
    # unnecessary and wrong (it would report the game binary). Resolve the
    # title from local manifests; if the manifest is missing, exit without
    # output so tracking keeps the stable steam_app_* key instead of
    # flip-flopping to a binary name.
    if _steam_class_appid(window_class) is not None:
        title = steam_title_for_class(window_class)
        if title:
            print(title)
        sys.exit(0)

    # Browsers: resolve the focused tab to a site key from the session
    # store. Any failure exits without output so tracking falls back to
    # the plain browser bucket; unexpected errors go to stderr, which the
    # service logs (a silently broken resolver would degrade invisibly).
    canonical = BROWSER_BINARY_TO_APP.get(window_class.lower())
    if canonical in GECKO_PROFILE_BASES or canonical in BLINK_PROFILE_BASES:
        try:
            site = resolve_browser_site(canonical, window_title)
        except Exception as err:  # noqa: BLE001 — degrade, never crash
            print(f"site resolution failed: {err!r}", file=sys.stderr)
            site = None
        if site:
            print(site)
        sys.exit(0)

    if not terminal_pid:
        sys.exit(0)

    name = _resolve_terminal_foreground(terminal_pid)
    if name:
        print(name)


if __name__ == "__main__":
    main()
