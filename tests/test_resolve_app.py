#!/usr/bin/env python3
"""Unit tests for resolve_app.py. Runs with zero dependencies:

    python3 -m unittest discover -s tests

Process-touching tests use the current process (always alive, always in
/proc), so nothing here needs a running Hyprland session.
"""

import json
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import resolve_app as r  # noqa: E402


class CanonicalizationTests(unittest.TestCase):
    def test_browser_aliases_json_is_loaded(self):
        json_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "lib", "browser_aliases.json")
        with open(json_path) as f:
            expected = json.load(f)
        self.assertEqual(r.BROWSER_BINARY_TO_APP, expected)

    def test_browser_binaries_fold_to_canonical_names(self):
        for binary in ("zen-bin", "zen_browser", "brave-browser", "chrome"):
            self.assertIn(binary, r.BROWSER_BINARY_TO_APP)

    def test_browser_worker_comms_are_flagged(self):
        for comm in ("Web Content", "forkserver", "rdd", "zygote", "GPU Process"):
            self.assertIn(comm, r.BROWSER_SUBPROCESS_COMMS)

    def test_unknown_binary_passes_through(self):
        self.assertEqual(r.BROWSER_BINARY_TO_APP.get("foot", "foot"), "foot")


class ProcParsingTests(unittest.TestCase):
    def test_proc_stat_parses_current_process(self):
        stat = r.proc_stat(os.getpid())
        assert stat is not None
        self.assertIn("comm", stat)
        self.assertIn("ppid", stat)
        self.assertIn("tpgid", stat)
        self.assertGreater(stat["ppid"], 0)

    def test_proc_stat_tolerates_missing_pid(self):
        self.assertIsNone(r.proc_stat(2**31 - 1))

    def test_proc_name_resolves_current_process(self):
        name = r.proc_name(os.getpid())
        assert name
        self.assertNotIn("/", name)

    def test_proc_name_unknown_pid_returns_none(self):
        self.assertIsNone(r.proc_name(2**31 - 1))


class FakeProc:
    """In-memory /proc stand-in for resolver tree tests.

    Models only what resolve_app reads: proc_stat fields and direct
    children. proc_name() falls back to comm because fake pids have no
    /proc/[pid]/cmdline on disk.
    """

    def __init__(self):
        self.stats = {}
        self.kids = {}

    def add(self, pid, comm, ppid, ttynr=0, tpgid=-1):
        self.stats[pid] = {
            "comm": comm,
            "ppid": ppid,
            "pgrp": pid,
            "session": pid if ttynr else 0,
            "ttynr": ttynr,
            "tpgid": tpgid,
        }
        self.kids.setdefault(ppid, []).append(pid)

    def install(self, testcase):
        testcase._orig_proc_stat = r.proc_stat
        testcase._orig_children = getattr(r, "_children", None)
        r.proc_stat = self.stats.get
        r._children = lambda pid: list(self.kids.get(pid, []))

    @staticmethod
    def restore(testcase):
        r.proc_stat = testcase._orig_proc_stat
        if testcase._orig_children is not None:
            r._children = testcase._orig_children


class TerminalResolutionTests(unittest.TestCase):
    """Simulated process trees for _resolve_terminal_foreground."""

    def setUp(self):
        self.world = FakeProc()
        self.world.install(self)

    def tearDown(self):
        FakeProc.restore(self)

    def test_foot_style_terminal_resolves_via_child_session(self):
        # foot does not hold the pty as its controlling terminal; the
        # spawned shell's session does. Regression test for "shows foot".
        w = self.world
        w.add(100, "foot", 1)                      # ttynr=0, tpgid=-1
        w.add(110, "bash", 100, ttynr=34817, tpgid=120)
        w.add(120, "opencode", 110, ttynr=34817, tpgid=120)
        self.assertEqual(r._resolve_terminal_foreground(100), "opencode")

    def test_legacy_terminal_holding_tty_uses_own_tpgid(self):
        w = self.world
        w.add(200, "term", 1, ttynr=5, tpgid=210)
        w.add(210, "btop", 200)
        self.assertEqual(r._resolve_terminal_foreground(200), "btop")

    def test_no_tty_owning_descendant_returns_none(self):
        w = self.world
        w.add(300, "term", 1)
        w.add(310, "notify-send", 300)             # no controlling tty
        self.assertIsNone(r._resolve_terminal_foreground(300))

    def test_tty_session_found_below_direct_children(self):
        w = self.world
        w.add(400, "term", 1)
        w.add(410, "shim", 400)                    # depth 2, no tty
        w.add(420, "bash", 410, ttynr=99, tpgid=430)
        w.add(430, "htop", 420)
        self.assertEqual(r._resolve_terminal_foreground(400), "htop")

    def test_tty_session_beyond_depth_limit_returns_none(self):
        w = self.world
        w.add(500, "term", 1)
        parent = 500
        for pid in range(510, 520):                # chain deeper than limit
            w.add(pid, "wrap", parent)
            parent = pid
        w.add(520, "bash", parent, ttynr=7, tpgid=530)
        w.add(530, "top", 520)
        self.assertIsNone(r._resolve_terminal_foreground(500))

    def test_browser_worker_as_foreground_walks_to_canonical_browser(self):
        w = self.world
        w.add(600, "foot", 1)
        w.add(610, "bash", 600, ttynr=11, tpgid=620)
        w.add(620, "Web Content", 630)             # browser worker is fg
        w.add(630, "zen-bin", 610)
        self.assertEqual(r._resolve_terminal_foreground(600), "zen")

    def test_negative_tpgid_on_tty_holder_falls_back_to_search(self):
        # A tty-owning session whose own tpgid is invalid must not be
        # selected; the search continues (or fails cleanly).
        w = self.world
        w.add(700, "term", 1)
        w.add(710, "weird", 700, ttynr=12, tpgid=-1)
        self.assertIsNone(r._resolve_terminal_foreground(700))


class SteamTitleTests(unittest.TestCase):
    """Steam window classes resolve to game titles from local appmanifests."""

    def _write_manifest(self, directory, appid, name):
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, f"appmanifest_{appid}.acf")
        with open(path, "w") as f:
            f.write(
                '"AppState"\n{\n\t"appid"\t\t"%s"\n'
                '\t"name"\t\t"%s"\n}\n' % (appid, name)
            )
        return path

    def test_steam_title_for_class_extracts_appid(self):
        self.assertEqual(r._steam_class_appid("steam_app_730"), "730")
        self.assertEqual(r._steam_class_appid("Steam_App_440900"), "440900")

    def test_steam_title_for_class_rejects_non_steam(self):
        self.assertIsNone(r._steam_class_appid("foot"))
        self.assertIsNone(r._steam_class_appid("steam_app_"))
        self.assertIsNone(r._steam_class_appid(None))

    def test_acf_name_parses_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write_manifest(tmp, "730", "Counter-Strike 2")
            self.assertEqual(r._acf_name(path), "Counter-Strike 2")

    def test_acf_name_missing_file_is_none(self):
        self.assertIsNone(
            r._acf_name(os.path.join(tempfile.gettempdir(), "nope.acf")))

    def test_steam_title_searches_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._write_manifest(tmp, "570", "Dota 2")
            original = r._STEAM_ROOTS
            r._STEAM_ROOTS = [tmp]
            try:
                self.assertEqual(r.steam_title_for_class("steam_app_570"), "Dota 2")
                self.assertEqual(r.steam_title_for_class("steam_app_999"), None)
            finally:
                r._STEAM_ROOTS = original


# ---- Browser site resolution fixtures ------------------------------------


def lz4_literal_encode(data):
    """Valid LZ4 block holding only literals (no matches): enough to feed
    the decoder real container framing without a compressor dependency."""
    out = bytearray()
    n = len(data)
    if n >= 15:
        out.append(0xF0)
        rem = n - 15
        while rem >= 255:
            out.append(255)
            rem -= 255
        out.append(rem)
    else:
        out.append(n << 4)
    out += data
    return bytes(out)


def write_mozlz4(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"mozLz40\0" + struct.pack("<I", len(payload))
                + lz4_literal_encode(payload))


def write_firefox_session(profile_dir, session):
    write_mozlz4(
        os.path.join(profile_dir, "sessionstore-backups", "recovery.jsonlz4"),
        json.dumps(session).encode())


def _pad4(b):
    return b + b"\0" * (-len(b) % 4)


def snss_command(cmd_id, payload):
    return struct.pack("<H", len(payload) + 1) + bytes([cmd_id]) + payload


def snss_nav(tab_id, nav_index, url, title):
    """UpdateTabNavigation payload: a Pickle (u32 size header, aligned
    fields), unlike the small raw-struct commands."""
    body = struct.pack("<ii", tab_id, nav_index)
    u = url.encode()
    body += struct.pack("<i", len(u)) + _pad4(u)
    body += struct.pack("<i", len(title)) + _pad4(title.encode("utf-16-le"))
    return struct.pack("<I", len(body)) + body


def write_snss_session(profile_dir, commands):
    sessions = os.path.join(profile_dir, "Sessions")
    os.makedirs(sessions, exist_ok=True)
    path = os.path.join(sessions, "Session_13400000000000000")
    with open(path, "wb") as f:
        f.write(b"SNSS" + struct.pack("<i", 3) + b"".join(commands))
    return path


class Lz4Tests(unittest.TestCase):
    def test_literal_only_block(self):
        data = b'{"windows": []}'
        self.assertEqual(
            r.lz4_block_decompress(lz4_literal_encode(data), 100), data)

    def test_non_overlapping_match(self):
        # 8 literals then a match: offset 4, length 8 -> abcdefgh + efghefgh
        blk = bytes([0x84]) + b"abcdefgh" + struct.pack("<H", 4) + bytes([0])
        self.assertEqual(
            r.lz4_block_decompress(blk, 100), b"abcdefghefghefgh")

    def test_overlapping_rle_match(self):
        # 1 literal, offset 1, match 15+4+5 -> 'x' * 25
        blk = bytes([0x1F]) + b"x" + struct.pack("<H", 1) + bytes([5, 0])
        self.assertEqual(r.lz4_block_decompress(blk, 100), b"x" * 25)

    def test_corrupt_offset_raises(self):
        blk = bytes([0x14]) + b"a" + struct.pack("<H", 9) + bytes([0])
        with self.assertRaises(ValueError):
            r.lz4_block_decompress(blk, 100)

    def test_mozlz4_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "recovery.jsonlz4")
            write_mozlz4(path, b'{"ok": true}')
            self.assertEqual(r.read_mozlz4(path), b'{"ok": true}')


class FirefoxSessionTests(unittest.TestCase):
    SESSION = {
        "selectedWindow": 2,
        "windows": [
            {"selected": 1, "tabs": [
                {"index": 1, "lastAccessed": 100, "entries": [
                    {"url": "https://example.com/", "title": "Example"}]},
            ]},
            {"selected": 2, "tabs": [
                {"index": 1, "lastAccessed": 200, "entries": [
                    {"url": "https://github.com/a", "title": "Repo A"}]},
                {"index": 2, "lastAccessed": 300, "entries": [
                    {"url": "https://old.example.org/x", "title": "Old"},
                    {"url": "https://news.ycombinator.com/", "title": "HN"}]},
            ]},
        ],
    }

    def test_open_tabs_follow_entry_index_and_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_firefox_session(tmp, self.SESSION)
            tabs = r.firefox_open_tabs(tmp)
        self.assertEqual(len(tabs), 3)
        by_url = {t["url"]: t for t in tabs}
        # index=2 picks the tab's current entry, not the first
        self.assertIn("https://news.ycombinator.com/", by_url)
        hn = by_url["https://news.ycombinator.com/"]
        self.assertTrue(hn["selected_in_window"] and hn["window_selected"])
        ex = by_url["https://example.com/"]
        self.assertTrue(ex["selected_in_window"])
        self.assertFalse(ex["window_selected"])

    def test_session_markers_pick_active_without_title(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_firefox_session(tmp, self.SESSION)
            active = r.pick_active_tab(r.firefox_open_tabs(tmp))
        self.assertEqual(active["url"], "https://news.ycombinator.com/")

    def test_compositor_title_overrides_stale_markers(self):
        # Focus is on window 1 per the compositor even though the session
        # still says window 2 (up to 15s stale): the title decides.
        with tempfile.TemporaryDirectory() as tmp:
            write_firefox_session(tmp, self.SESSION)
            active = r.pick_active_tab(
                r.firefox_open_tabs(tmp), "Example — Mozilla Firefox")
        self.assertEqual(active["url"], "https://example.com/")

    def test_sessionstore_fallback_when_no_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_mozlz4(os.path.join(tmp, "sessionstore.jsonlz4"),
                         json.dumps(self.SESSION).encode())
            self.assertEqual(len(r.firefox_open_tabs(tmp)), 3)

    def test_missing_profile_yields_no_tabs(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(r.firefox_open_tabs(tmp), [])


class SnssTests(unittest.TestCase):
    def _write_two_tab_session(self, tmp, active_index):
        return write_snss_session(tmp, [
            snss_command(0, struct.pack("<ii", 1, 10)),   # tab 10 -> window 1
            snss_command(2, struct.pack("<ii", 10, 0)),   # tab 10 at strip 0
            snss_command(6, snss_nav(10, 0, "https://example.com/", "Example")),
            snss_command(7, struct.pack("<ii", 10, 0)),
            snss_command(0, struct.pack("<ii", 1, 11)),
            snss_command(2, struct.pack("<ii", 11, 1)),
            snss_command(6, snss_nav(11, 0, "https://github.com/", "GitHub")),
            snss_command(7, struct.pack("<ii", 11, 0)),
            snss_command(8, struct.pack("<ii", 1, active_index)),
            snss_command(20, struct.pack("<i", 1)),
            snss_command(255, b""),                       # marker: skipped
        ])

    def test_replay_selects_marked_tab(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._write_two_tab_session(tmp, 1)
            tabs = r.chromium_open_tabs(tmp)
            active = r.pick_active_tab(tabs)
        self.assertEqual(len(tabs), 2)
        self.assertEqual(active["url"], "https://github.com/")
        self.assertEqual(active["title"], "GitHub")

    def test_later_selection_commands_win(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write_two_tab_session(tmp, 1)
            with open(path, "ab") as f:
                f.write(snss_command(8, struct.pack("<ii", 1, 0)))
            active = r.pick_active_tab(r.chromium_open_tabs(tmp))
        self.assertEqual(active["url"], "https://example.com/")

    def test_closed_tabs_are_pruned(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write_two_tab_session(tmp, 0)
            with open(path, "ab") as f:
                f.write(snss_command(16, struct.pack("<i", 11)))
            tabs = r.chromium_open_tabs(tmp)
        self.assertEqual([t["url"] for t in tabs], ["https://example.com/"])

    def test_truncated_tail_keeps_replayed_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._write_two_tab_session(tmp, 0)
            with open(path, "ab") as f:
                f.write(struct.pack("<H", 500) + b"\x06partial")
            self.assertEqual(len(r.chromium_open_tabs(tmp)), 2)

    def test_missing_selection_reads_as_not_selected(self):
        # Headless-style logs carry navigations but no tab-strip commands;
        # None == None must never mark a tab selected.
        with tempfile.TemporaryDirectory() as tmp:
            write_snss_session(tmp, [
                snss_command(0, struct.pack("<ii", 1, 10)),
                snss_command(6, snss_nav(10, 0, "https://example.com/", "")),
            ])
            tabs = r.chromium_open_tabs(tmp)
        self.assertFalse(tabs[0]["selected_in_window"])
        self.assertFalse(tabs[0]["window_selected"])
        self.assertIsNone(r.pick_active_tab(tabs))

    def test_no_sessions_dir_yields_no_tabs(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(r.chromium_open_tabs(tmp), [])


class SiteKeyTests(unittest.TestCase):
    def test_hostname_reduces_to_registrable_domain(self):
        self.assertEqual(r.site_key_for_url("https://old.reddit.com/r/x"),
                         "site:reddit.com")
        self.assertEqual(r.site_key_for_url("https://www.github.com/a/b"),
                         "site:github.com")
        self.assertEqual(r.site_key_for_url("https://github.com/"),
                         "site:github.com")

    def test_multi_part_public_suffixes_keep_the_brand(self):
        self.assertEqual(r.site_key_for_url("https://www.bbc.co.uk/news"),
                         "site:bbc.co.uk")
        self.assertEqual(r.site_key_for_url("https://shop.example.com.au/"),
                         "site:example.com.au")

    def test_hosts_without_suffix_pass_through(self):
        self.assertEqual(r.site_key_for_url("http://localhost:3000/app"),
                         "site:localhost")
        self.assertEqual(r.site_key_for_url("http://192.168.1.5:8080/"),
                         "site:192.168.1.5")

    def test_urls_without_meaningful_host_are_none(self):
        self.assertIsNone(r.site_key_for_url("about:blank"))
        self.assertIsNone(r.site_key_for_url("file:///home/x/doc.pdf"))
        self.assertIsNone(r.site_key_for_url(""))

    def test_known_web_apps_keep_their_subdomain(self):
        self.assertEqual(r.site_key_for_url("https://mail.google.com/mail/u/0"),
                         "site:mail.google.com")
        self.assertEqual(r.site_key_for_url("https://music.youtube.com/watch?v=1"),
                         "site:music.youtube.com")

    def test_web_app_match_walks_suffixes(self):
        self.assertEqual(r.site_key_for_url("https://u.mail.google.com/x"),
                         "site:mail.google.com")

    def test_unmapped_subdomains_still_reduce(self):
        self.assertEqual(r.site_key_for_url("https://gist.github.com/x"),
                         "site:github.com")
        self.assertEqual(r.site_key_for_url("https://www.google.com/search"),
                         "site:google.com")

    def test_site_apps_json_is_loaded(self):
        json_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "lib", "site_apps.json")
        with open(json_path) as f:
            expected = json.load(f)
        self.assertTrue(expected)
        self.assertEqual(r.SITE_APPS, expected)


class TitleSuffixTests(unittest.TestCase):
    def test_known_suffixes_are_stripped(self):
        self.assertEqual(
            r.strip_title_suffix("Wicket - Brave"), "Wicket")
        self.assertEqual(
            r.strip_title_suffix("HN — Mozilla Firefox"), "HN")
        self.assertEqual(
            r.strip_title_suffix("Docs - Chromium"), "Docs")

    def test_unknown_titles_pass_through(self):
        self.assertEqual(r.strip_title_suffix("just a title"), "just a title")


class ProfileDiscoveryTests(unittest.TestCase):
    def test_install_section_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "profiles.ini"), "w") as f:
                f.write("[Install4F96D1932A9F858E]\n"
                        "Default=abc.default-release\n\n"
                        "[Profile0]\nName=old\nIsRelative=1\n"
                        "Path=abc.default\nDefault=1\n")
            self.assertEqual(r.firefox_default_profile(tmp),
                             os.path.join(tmp, "abc.default-release"))

    def test_default_flag_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "profiles.ini"), "w") as f:
                f.write("[Profile0]\nName=a\nIsRelative=1\n"
                        "Path=abc.default\nDefault=1\n")
            self.assertEqual(r.firefox_default_profile(tmp),
                             os.path.join(tmp, "abc.default"))

    def test_missing_ini_is_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(r.firefox_default_profile(tmp))

    def test_local_state_last_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "Local State"), "w") as f:
                f.write('{"profile": {"last_used": "Profile 2"}}')
            self.assertEqual(r.chromium_last_used_profile(tmp),
                             os.path.join(tmp, "Profile 2"))

    def test_local_state_missing_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(r.chromium_last_used_profile(tmp),
                             os.path.join(tmp, "Default"))


class ResolveBrowserSiteTests(unittest.TestCase):
    def test_gecko_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            profile = os.path.join(tmp, "abc.default")
            os.makedirs(profile)
            with open(os.path.join(tmp, "profiles.ini"), "w") as f:
                f.write("[Profile0]\nName=a\nIsRelative=1\n"
                        "Path=abc.default\nDefault=1\n")
            write_firefox_session(profile, {
                "selectedWindow": 1,
                "windows": [{"selected": 1, "tabs": [
                    {"index": 1, "entries": [
                        {"url": "https://news.ycombinator.com/item?id=1",
                         "title": "HN"}]}]}],
            })
            original = r.GECKO_PROFILE_BASES
            r.GECKO_PROFILE_BASES = dict(original, firefox=tmp)
            try:
                # news.ycombinator.com is a mapped web app, so the key
                # keeps the subdomain instead of reducing to the
                # registrable domain.
                self.assertEqual(r.resolve_browser_site("firefox", None),
                                 "site:news.ycombinator.com")
            finally:
                r.GECKO_PROFILE_BASES = original

    def test_blink_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            profile = os.path.join(tmp, "Default")
            os.makedirs(profile)
            write_snss_session(profile, [
                snss_command(0, struct.pack("<ii", 1, 10)),
                snss_command(2, struct.pack("<ii", 10, 0)),
                snss_command(6, snss_nav(10, 0, "https://github.com/x", "")),
                snss_command(7, struct.pack("<ii", 10, 0)),
                snss_command(8, struct.pack("<ii", 1, 0)),
                snss_command(20, struct.pack("<i", 1)),
            ])
            original = r.BLINK_PROFILE_BASES
            r.BLINK_PROFILE_BASES = dict(original, brave=tmp)
            try:
                self.assertEqual(r.resolve_browser_site("brave", None),
                                 "site:github.com")
            finally:
                r.BLINK_PROFILE_BASES = original

    def test_unknown_browser_is_none(self):
        self.assertIsNone(r.resolve_browser_site("tor-browser", None))
        self.assertIsNone(r.resolve_browser_site("foot", None))


if __name__ == "__main__":
    unittest.main()
