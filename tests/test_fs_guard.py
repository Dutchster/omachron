"""Black-box tests for scripts/fs_guard.py, the descriptor-based helper
behind every stateful path the plugin touches, plus drift tests pinning the
command strings in Service.qml and fetch_site_icon.sh to the helper's
contract.

Each test drives the helper as a subprocess against a fresh throwaway
$HOME, exactly the way Service.qml and fetch_site_icon.sh invoke it.
Negative ownership cases (a foreign-uid file or directory) cannot be
staged without root, so only the same-uid positive paths are exercised
here; the uid checks themselves are single fstat comparisons on held fds.
"""

import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT, "scripts", "fs_guard.py")
SERVICE_QML = os.path.join(ROOT, "Service.qml")
FETCH_SH = os.path.join(ROOT, "scripts", "fetch_site_icon.sh")

sys.path.insert(0, os.path.join(ROOT, "scripts"))
import fs_guard  # noqa: E402


def run(home, *args, stdin=None):
    env = {"HOME": home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
    return subprocess.run(
        [sys.executable, GUARD, *args],
        input=stdin,
        capture_output=True,
        env=env,
        timeout=30,
    )


def data_dir(home):
    return os.path.join(home, ".config", "omarchy", "omachron")


def icons_dir(home):
    return os.path.join(data_dir(home), "icons")


def history_path(home):
    return os.path.join(data_dir(home), "history.json")


class GuardCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self.addCleanup(self._tmp.cleanup)


class LoadHistoryTests(GuardCase):
    def test_first_run_seeds_empty_history(self):
        r = run(self.home, "load-history")
        self.assertEqual(r.returncode, fs_guard.EXIT_SEEDED)
        self.assertEqual(r.stdout, b"{}")
        st = os.lstat(history_path(self.home))
        self.assertTrue(stat.S_ISREG(st.st_mode))
        self.assertEqual(stat.S_IMODE(st.st_mode), 0o600)
        self.assertTrue(os.path.isdir(icons_dir(self.home)))
        self.assertEqual(
            stat.S_IMODE(os.stat(data_dir(self.home)).st_mode), 0o700
        )

    def test_valid_history_returned_byte_exact_and_mode_pinned(self):
        run(self.home, "load-history")
        payload = b'{"days": {"2026-08-01": {"total": 5, "apps": {}}}}'
        with open(history_path(self.home), "wb") as f:
            f.write(payload)
        os.chmod(history_path(self.home), 0o644)
        r = run(self.home, "load-history")
        self.assertEqual(r.returncode, fs_guard.EXIT_OK)
        self.assertEqual(r.stdout, payload)
        self.assertEqual(stat.S_IMODE(os.lstat(history_path(self.home)).st_mode), 0o600)

    def test_symlink_leaf_quarantined_and_reseeded(self):
        run(self.home, "load-history")
        target = os.path.join(self.home, "victim.json")
        with open(target, "w") as f:
            f.write('{"stolen": true}')
        os.unlink(history_path(self.home))
        os.symlink(target, history_path(self.home))
        r = run(self.home, "load-history")
        self.assertEqual(r.returncode, fs_guard.EXIT_RECOVERED)
        self.assertEqual(r.stdout, b"{}")
        self.assertFalse(os.path.islink(history_path(self.home)))
        # The symlink itself was renamed aside; its target is untouched.
        with open(target) as f:
            self.assertEqual(f.read(), '{"stolen": true}')
        moved = [n for n in os.listdir(data_dir(self.home)) if ".invalid-" in n]
        self.assertEqual(len(moved), 1)

    def test_dangling_symlink_not_followed_by_seed(self):
        run(self.home, "load-history")
        target = os.path.join(self.home, "planted.json")
        os.unlink(history_path(self.home))
        os.symlink(target, history_path(self.home))
        r = run(self.home, "load-history")
        self.assertEqual(r.returncode, fs_guard.EXIT_RECOVERED)
        # Seeding went through O_EXCL on the real name, never the target.
        self.assertFalse(os.path.exists(target))
        self.assertFalse(os.path.islink(history_path(self.home)))

    def test_fifo_leaf_does_not_hang(self):
        run(self.home, "load-history")
        os.unlink(history_path(self.home))
        os.mkfifo(history_path(self.home))
        r = run(self.home, "load-history")  # run() has a hard timeout
        self.assertEqual(r.returncode, fs_guard.EXIT_RECOVERED)
        self.assertFalse(stat.S_ISFIFO(os.lstat(history_path(self.home)).st_mode))

    def test_oversized_history_evicted(self):
        run(self.home, "load-history")
        with open(history_path(self.home), "wb") as f:
            f.write(b"[" + b"1," * (fs_guard.MAX_HISTORY // 2) + b"1]")
        r = run(self.home, "load-history")
        self.assertEqual(r.returncode, fs_guard.EXIT_RECOVERED)
        self.assertEqual(r.stdout, b"{}")
        moved = [n for n in os.listdir(data_dir(self.home)) if ".oversized-" in n]
        self.assertEqual(len(moved), 1)

    def test_corrupt_history_preserved_byte_identical(self):
        run(self.home, "load-history")
        garbage = b'{"days": {truncated'
        with open(history_path(self.home), "wb") as f:
            f.write(garbage)
        r = run(self.home, "load-history")
        self.assertEqual(r.returncode, fs_guard.EXIT_RECOVERED)
        moved = [n for n in os.listdir(data_dir(self.home)) if ".corrupt-" in n]
        self.assertEqual(len(moved), 1)
        with open(os.path.join(data_dir(self.home), moved[0]), "rb") as f:
            self.assertEqual(f.read(), garbage)

    def test_quarantine_files_capped(self):
        run(self.home, "load-history")
        base = int(time.time())
        for i in range(5):
            name = "history.json.corrupt-%d-%02x%02x" % (base - i, i, i)
            path = os.path.join(data_dir(self.home), name)
            with open(path, "w") as f:
                f.write("junk")
            os.utime(path, (base - i * 60, base - i * 60))
        r = run(self.home, "load-history")
        self.assertEqual(r.returncode, fs_guard.EXIT_OK)
        kept = [n for n in os.listdir(data_dir(self.home)) if ".corrupt-" in n]
        self.assertEqual(len(kept), fs_guard.MAX_QUARANTINE)

    def test_nonstandard_or_scalar_json_quarantined(self):
        # Python's json accepts NaN/Infinity and any top-level type; QML's
        # JSON.parse does not, so serving either would wedge the consumer
        # on content this side vouched for. Both must quarantine+reseed.
        for payload in (b'{"days": NaN}', b"null", b"42", b'"scalar"'):
            with tempfile.TemporaryDirectory() as home:
                run(home, "load-history")
                with open(history_path(home), "wb") as f:
                    f.write(payload)
                r = run(home, "load-history")
                self.assertEqual(r.returncode, fs_guard.EXIT_RECOVERED, payload)
                self.assertEqual(r.stdout, b"{}", payload)
                moved = [n for n in os.listdir(data_dir(home)) if ".corrupt-" in n]
                self.assertEqual(len(moved), 1, payload)

    def test_stale_save_temp_reclaimed_fresh_kept(self):
        run(self.home, "load-history")
        stale = os.path.join(data_dir(self.home), ".save-deadbeef00000000")
        fresh = os.path.join(data_dir(self.home), ".save-cafebabe00000000")
        for p in (stale, fresh):
            with open(p, "w") as f:
                f.write("{}")
        old = time.time() - fs_guard.SCRATCH_TTL - 60
        os.utime(stale, (old, old))
        run(self.home, "load-history")
        self.assertFalse(os.path.exists(stale))
        self.assertTrue(os.path.exists(fresh))

    def test_symlinked_own_dir_fails_closed(self):
        # The plugin-owned leaf (omachron) is held to the strict
        # O_NOFOLLOW standard: a symlink there is a staged redirection.
        run(self.home, "load-history")
        elsewhere = os.path.join(self.home, "elsewhere")
        os.mkdir(elsewhere)
        real = data_dir(self.home)
        os.rename(real, elsewhere + "/omachron")
        os.symlink(elsewhere + "/omachron", real)
        r = run(self.home, "load-history")
        self.assertEqual(r.returncode, fs_guard.EXIT_TRUST)
        self.assertEqual(r.stdout, b"")
        # The redirected tree is untouched.
        self.assertTrue(os.path.exists(elsewhere + "/omachron/history.json"))

    def test_symlinked_shared_parent_is_legitimate(self):
        # Dotfile managers (stow, chezmoi, yadm) routinely symlink
        # ~/.config or ~/.config/omarchy; the resolved directory is
        # verified on the held fd instead of being rejected.
        run(self.home, "load-history")
        stowed = os.path.join(self.home, "dotfiles-omarchy")
        omarchy = os.path.join(self.home, ".config", "omarchy")
        os.rename(omarchy, stowed)
        os.symlink(stowed, omarchy)
        r = run(self.home, "load-history")
        self.assertEqual(r.returncode, fs_guard.EXIT_OK)
        self.assertEqual(r.stdout, b"{}\n")

    def test_world_writable_shared_parent_fails_closed(self):
        run(self.home, "load-history")
        os.chmod(os.path.join(self.home, ".config", "omarchy"), 0o707)
        r = run(self.home, "load-history")
        self.assertEqual(r.returncode, fs_guard.EXIT_TRUST)

    def test_group_writable_shared_parent_tolerated(self):
        # umask-002 user-private-group systems keep config dirs
        # group-writable by design; that must not brick persistence.
        run(self.home, "load-history")
        os.chmod(os.path.join(self.home, ".config", "omarchy"), 0o775)
        r = run(self.home, "load-history")
        self.assertEqual(r.returncode, fs_guard.EXIT_OK)


class SaveHistoryTests(GuardCase):
    def test_round_trip(self):
        run(self.home, "load-history")
        payload = json.dumps({"days": {"2026-08-01": {"total": 7, "apps": {"zen": 7}}}}).encode()
        r = run(self.home, "save-history", stdin=payload)
        self.assertEqual(r.returncode, fs_guard.EXIT_OK)
        with open(history_path(self.home), "rb") as f:
            self.assertEqual(f.read(), payload)
        # No temp files left behind.
        stray = [n for n in os.listdir(data_dir(self.home)) if n.startswith(".save-")]
        self.assertEqual(stray, [])

    def test_rejects_oversized_payload(self):
        r = run(self.home, "save-history", stdin=b"x" * (fs_guard.MAX_HISTORY + 1))
        self.assertEqual(r.returncode, fs_guard.EXIT_BAD_INPUT)

    def test_rejects_non_json_payload(self):
        r = run(self.home, "save-history", stdin=b"not json")
        self.assertEqual(r.returncode, fs_guard.EXIT_BAD_INPUT)

    def test_refuses_symlinked_parent(self):
        run(self.home, "load-history")
        elsewhere = os.path.join(self.home, "elsewhere")
        os.mkdir(elsewhere)
        real = data_dir(self.home)
        os.rename(real, elsewhere + "/omachron")
        os.symlink(elsewhere + "/omachron", real)
        r = run(self.home, "save-history", stdin=b"{}")
        self.assertEqual(r.returncode, fs_guard.EXIT_TRUST)


class ListIconsTests(GuardCase):
    def test_lists_only_schema_valid_regular_pngs(self):
        run(self.home, "load-history")
        d = icons_dir(self.home)
        for name in ("example.com.png", "sub.example.org.png"):
            with open(os.path.join(d, name), "wb") as f:
                f.write(b"png")
        # Rejected: symlink, wrong suffix, no dot, IP-looking, overlong.
        os.symlink(os.path.join(d, "example.com.png"), os.path.join(d, "link.example.com.png"))
        with open(os.path.join(d, "noext"), "wb") as f:
            f.write(b"x")
        with open(os.path.join(d, "nodot.png"), "wb") as f:
            f.write(b"x")
        with open(os.path.join(d, "1.2.3.4.png"), "wb") as f:
            f.write(b"x")
        long = "a" * 100 + ".example.com.png"  # 100-char label exceeds the 63-char limit
        with open(os.path.join(d, long), "wb") as f:
            f.write(b"x")
        r = run(self.home, "list-icons")
        self.assertEqual(r.returncode, fs_guard.EXIT_OK)
        self.assertEqual(
            r.stdout.decode().split(), ["example.com.png", "sub.example.org.png"]
        )

    def test_listing_capped_at_max_icons(self):
        run(self.home, "load-history")
        d = icons_dir(self.home)
        for i in range(fs_guard.MAX_ICONS + 88):
            with open(os.path.join(d, "host%04d.example.com.png" % i), "wb") as f:
                f.write(b"x")
        r = run(self.home, "list-icons")
        self.assertEqual(r.returncode, fs_guard.EXIT_OK)
        self.assertEqual(len(r.stdout.decode().split()), fs_guard.MAX_ICONS)


class ScratchSweepTests(GuardCase):
    def scratch(self):
        r = run(self.home, "icon-scratch")
        self.assertEqual(r.returncode, fs_guard.EXIT_OK)
        path = r.stdout.decode().strip()
        self.assertTrue(os.path.isdir(path))
        return path

    def backdate_journal(self, names):
        journal = os.path.join(icons_dir(self.home), ".fetch.journal")
        old = int(time.time()) - fs_guard.SCRATCH_TTL - 60
        with open(journal, "w") as f:
            for n in names:
                f.write("%s %d\n" % (n, old))

    def test_scratch_created_private_and_journaled(self):
        path = self.scratch()
        st = os.lstat(path)
        self.assertEqual(stat.S_IMODE(st.st_mode), 0o700)
        base = os.path.basename(path)
        self.assertRegex(base, fs_guard.SCRATCH_RE)
        with open(os.path.join(icons_dir(self.home), ".fetch.journal")) as f:
            self.assertIn(base, f.read())

    def test_journaled_aged_scratch_swept(self):
        path = self.scratch()
        base = os.path.basename(path)
        with open(os.path.join(path, "icon"), "wb") as f:
            f.write(b"x")
        with open(os.path.join(path, "page"), "wb") as f:
            f.write(b"x")
        self.backdate_journal([base])
        self.scratch()  # a new run sweeps
        self.assertFalse(os.path.exists(path))

    def test_unjournaled_matching_dir_never_touched(self):
        # Same name shape, uid, mode, and age as a real scratch dir — but
        # never journaled, so the sweep must not even examine it.
        staged = os.path.join(icons_dir(self.home), ".fetch." + "ab" * 12)
        run(self.home, "load-history")
        os.makedirs(staged, mode=0o700)
        inside = os.path.join(staged, "icon")
        with open(inside, "wb") as f:
            f.write(b"someone else's data")
        old = time.time() - fs_guard.SCRATCH_TTL - 3600
        os.utime(staged, (old, old))
        self.scratch()
        self.assertTrue(os.path.exists(inside))

    def test_stuffed_journaled_dir_left_standing(self):
        path = self.scratch()
        base = os.path.basename(path)
        with open(os.path.join(path, "icon"), "wb") as f:
            f.write(b"x")
        extra = os.path.join(path, "unexpected")
        with open(extra, "wb") as f:
            f.write(b"keep me")
        self.backdate_journal([base])
        self.scratch()
        # Known names unlinked, foreign content kept, dir left standing.
        self.assertFalse(os.path.exists(os.path.join(path, "icon")))
        self.assertTrue(os.path.exists(extra))
        self.assertTrue(os.path.isdir(path))
        with open(os.path.join(icons_dir(self.home), ".fetch.journal")) as f:
            self.assertNotIn(base, f.read())  # entry dropped, no retry

    def test_journaled_symlink_untouched(self):
        victim = os.path.join(self.home, "victim")
        os.mkdir(victim)
        with open(os.path.join(victim, "icon"), "wb") as f:
            f.write(b"precious")
        run(self.home, "load-history")
        base = ".fetch." + "cd" * 12
        os.symlink(victim, os.path.join(icons_dir(self.home), base))
        self.backdate_journal([base])
        self.scratch()
        self.assertTrue(os.path.exists(os.path.join(victim, "icon")))

    def test_corrupt_journal_deletes_nothing(self):
        path = self.scratch()
        journal = os.path.join(icons_dir(self.home), ".fetch.journal")
        with open(journal, "w") as f:
            f.write("\x00garbage\nnot a journal line\n")
        self.scratch()
        self.assertTrue(os.path.isdir(path))

    def test_stale_journal_temp_reclaimed(self):
        self.scratch()
        stale = os.path.join(icons_dir(self.home), ".fetch.journal.tmp-deadbeef00000000")
        with open(stale, "w") as f:
            f.write("x")
        old = time.time() - fs_guard.SCRATCH_TTL - 60
        os.utime(stale, (old, old))
        self.scratch()
        self.assertFalse(os.path.exists(stale))


class PublishDiscardTests(GuardCase):
    def scratch(self):
        r = run(self.home, "icon-scratch")
        self.assertEqual(r.returncode, fs_guard.EXIT_OK)
        return r.stdout.decode().strip()

    def test_publish_moves_icon_into_place(self):
        path = self.scratch()
        base = os.path.basename(path)
        with open(os.path.join(path, "icon"), "wb") as f:
            f.write(b"png bytes")
        with open(os.path.join(path, "page"), "wb") as f:
            f.write(b"html")
        r = run(self.home, "icon-publish", base, "example.com")
        self.assertEqual(r.returncode, fs_guard.EXIT_OK)
        dest = os.path.join(icons_dir(self.home), "example.com.png")
        with open(dest, "rb") as f:
            self.assertEqual(f.read(), b"png bytes")
        self.assertFalse(os.path.exists(path))
        with open(os.path.join(icons_dir(self.home), ".fetch.journal")) as f:
            self.assertNotIn(base, f.read())
        # No publish temp files linger.
        stray = [n for n in os.listdir(icons_dir(self.home)) if n.startswith(".publish-")]
        self.assertEqual(stray, [])

    def test_publish_rejects_bad_domain_and_basename(self):
        path = self.scratch()
        base = os.path.basename(path)
        with open(os.path.join(path, "icon"), "wb") as f:
            f.write(b"x")
        for domain in ("1.2.3.4", "no-dot", "evil/../path", "-bad.com", ""):
            r = run(self.home, "icon-publish", base, domain)
            self.assertEqual(r.returncode, fs_guard.EXIT_BAD_INPUT, domain)
        r = run(self.home, "icon-publish", "../escape", "example.com")
        self.assertEqual(r.returncode, fs_guard.EXIT_BAD_INPUT)

    def test_publish_refuses_symlinked_scratch(self):
        victim = os.path.join(self.home, "victim")
        os.mkdir(victim)
        with open(os.path.join(victim, "icon"), "wb") as f:
            f.write(b"x")
        run(self.home, "load-history")
        base = ".fetch." + "ef" * 12
        os.symlink(victim, os.path.join(icons_dir(self.home), base))
        r = run(self.home, "icon-publish", base, "example.com")
        self.assertEqual(r.returncode, fs_guard.EXIT_TRUST)
        self.assertFalse(
            os.path.exists(os.path.join(icons_dir(self.home), "example.com.png"))
        )

    def test_publish_rejects_oversized_icon(self):
        path = self.scratch()
        base = os.path.basename(path)
        with open(os.path.join(path, "icon"), "wb") as f:
            f.truncate(fs_guard.MAX_ICON + 1)
        r = run(self.home, "icon-publish", base, "example.com")
        self.assertEqual(r.returncode, fs_guard.EXIT_BAD_INPUT)

    def test_discard_removes_scratch_and_is_idempotent(self):
        path = self.scratch()
        base = os.path.basename(path)
        with open(os.path.join(path, "icon"), "wb") as f:
            f.write(b"x")
        r = run(self.home, "icon-discard", base)
        self.assertEqual(r.returncode, fs_guard.EXIT_OK)
        self.assertFalse(os.path.exists(path))
        r = run(self.home, "icon-discard", base)
        self.assertEqual(r.returncode, fs_guard.EXIT_OK)


class DriftTests(unittest.TestCase):
    """Pin the command strings in Service.qml and fetch_site_icon.sh to the
    helper contract, the same way the shipped JSON data files are pinned
    across languages: if one side moves without the other, this fails."""

    @classmethod
    def setUpClass(cls):
        with open(SERVICE_QML) as f:
            cls.qml = f.read()
        with open(FETCH_SH) as f:
            cls.sh = f.read()

    def test_service_invokes_guard_subcommands(self):
        # All three invocations go through the single guardCommand wrapper
        # so deadline/probe/sentinel semantics cannot drift between them.
        wrapper = 'command -v python3 >/dev/null 2>&1 && exec python3 \\"$1\\" " + sub + " || exit 127'
        self.assertEqual(self.qml.count(wrapper), 1)
        for sub in ("load-history", "save-history", "list-icons"):
            self.assertIn('guardCommand("%s")' % sub, self.qml, sub)
        self.assertIn("root.guardPath", self.qml)

    def test_qml_icon_revalidation_matches_guard(self):
        # The QML defense-in-depth copy of the listing schema must track
        # the helper's: same domain regex (with the .png suffix), same
        # has-a-letter rule, same item and name caps.
        qml_re = fs_guard.DOMAIN_RE.pattern[:-1] + "\\.png$"
        self.assertIn(qml_re, self.qml)
        self.assertIn("/[A-Za-z]/.test(f.slice(0, -4))", self.qml)
        self.assertIn("Math.min(lines.length, %d)" % fs_guard.MAX_ICONS, self.qml)
        self.assertIn("f.length <= %d" % fs_guard.MAX_NAME, self.qml)

    def test_fetcher_argv_carries_only_the_domain(self):
        self.assertIn(
            '"bash", root.iconFetcherPath, root.iconFetching]', self.qml
        )

    def test_fetch_script_uses_guard_lifecycle(self):
        for frag in (
            '"$guard" icon-scratch',
            '"$guard" icon-publish "$base" "$domain"',
            '"$guard" icon-discard "$base"',
        ):
            self.assertIn(frag, self.sh, frag)
        for trap in ("trap 'exit 129' HUP", "trap 'exit 130' INT", "trap 'exit 143' TERM"):
            self.assertIn(trap, self.sh, trap)

    def test_domain_regex_identical_in_both_producers(self):
        m = re.search(r"\$domain =~ (\^\S+\$) \]\]", self.sh)
        self.assertIsNotNone(m, "domain regex not found in fetch_site_icon.sh")
        shell_re = m.group(1).replace("\\.", ".")
        guard_re = fs_guard.DOMAIN_RE.pattern.replace("\\.", ".")
        self.assertEqual(shell_re, guard_re)


if __name__ == "__main__":
    unittest.main()
