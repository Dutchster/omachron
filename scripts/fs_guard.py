#!/usr/bin/env python3
"""Descriptor-based filesystem transactions for the Omachron plugin.

Every stateful path the plugin touches under ~/.config/omarchy/omachron is
mediated here, and every operation happens relative to directory file
descriptors that were opened with O_NOFOLLOW and verified with fstat before
use. After the trusted-chain walk no absolute pathname is ever handed to a
mutating syscall, so a same-uid process re-pointing a component mid-flight
can neither redirect a write, expose a swapped file to the reader, nor
steer a cleanup: the check and the act share one held inode.

The trusted chain starts at $HOME (from the trusted environment) and
descends .config/omarchy/omachron[/icons]. The shared parents ($HOME,
.config, omarchy) are commonly symlinked by dotfile managers (stow,
chezmoi, yadm), so a symlink there is legitimate configuration: it is
resolved once at open time and the *resolved* directory is then verified
on the held fd — a directory we do not own, or one writable by other
users, is a trust failure. The two directories this plugin owns outright
(omachron, icons) are held to the strict standard: O_NOFOLLOW — a symlink
component fails closed, nothing is repaired, nothing is touched — and
their mode is pinned to 0700 via fchmod on the held fd, which cannot
race. Every mutation below happens relative to those verified fds.

Subcommands and exit codes are the contract with Service.qml and
fetch_site_icon.sh; tests/test_fs_guard.py pins both sides.

  load-history    validated history bytes on stdout
  save-history    stdin JSON -> atomic replace of history.json
  list-icons      validated icon filenames, one per line
  icon-scratch    sweep stale scratch dirs, create a fresh one, print path
  icon-publish    <scratch-basename> <domain>: move verified icon into place
  icon-discard    <scratch-basename>: remove a run's scratch dir

  0 ok            4 seeded (fresh empty history)
  1 usage         5 recovered (bad history quarantined, fresh seed served)
  2 trust-fail    6 bad input
  3 io-fail

Cleanup identity: icon scratch directories are recorded, at creation, in
icons/.fetch.journal. The sweep deletes only names the journal lists —
never a directory that merely matches a name/uid/mode/age signature, which
a same-uid process could stage — and even then non-recursively: only the
two filenames a run creates are unlinked and rmdir is left to fail if
anything else was placed inside. Journal damage degrades toward leaking a
bounded scratch dir, never toward deleting someone else's data.
"""

import errno
import json
import os
import re
import secrets
import stat
import sys
import time

MAX_HISTORY = 10 * 1024 * 1024  # byte ceiling for history.json
MAX_ICON = 2 * 1024 * 1024      # matches max_bytes in fetch_site_icon.sh
MAX_ICONS = 512                 # listing cap
MAX_NAME = 258                  # 253-char hostname + ".png" + slack
MAX_DOMAIN = 253
JOURNAL_MAX = 65536
SCRATCH_TTL = 3600              # seconds before an orphaned scratch dir is stale
MAX_QUARANTINE = 3              # quarantined history files kept per reason pool

# Textually identical to the domain regex in fetch_site_icon.sh (a drift
# test asserts this); the has-a-letter rule from the line below it lives in
# valid_domain().
DOMAIN_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,62})?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62})?)+$")
SCRATCH_RE = re.compile(r"^\.fetch\.[0-9a-f]{24}$")

HISTORY = "history.json"
JOURNAL = ".fetch.journal"

EXIT_OK = 0
EXIT_USAGE = 1
EXIT_TRUST = 2
EXIT_IO = 3
EXIT_SEEDED = 4
EXIT_RECOVERED = 5
EXIT_BAD_INPUT = 6

O_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
# O_NONBLOCK so opening a pre-positioned fifo returns instead of hanging;
# it has no effect on regular-file reads.
O_LEAF = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
O_CREATE = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC


class TrustError(Exception):
    """A trusted-chain invariant failed; the command must fail closed."""


def _parse_strict(data):
    """Parse history JSON exactly as strictly as the QML consumer will.

    Python's json module accepts NaN/Infinity literals that QML's
    JSON.parse rejects, and any top-level type; serving either would make
    the consumer fail on content this side vouched for. Raises ValueError
    unless the payload is a standard-JSON object."""
    def _reject_constant(_name):
        raise ValueError("non-standard JSON constant")
    obj = json.loads(data, parse_constant=_reject_constant)
    if not isinstance(obj, dict):
        raise ValueError("top-level value is not an object")
    return obj


def valid_domain(s):
    return (
        len(s) <= MAX_DOMAIN
        and DOMAIN_RE.match(s) is not None
        and re.search(r"[A-Za-z]", s) is not None
    )


def _verify_dir(fd, label, exclusive):
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode):
        raise TrustError(label + ": not a directory")
    if st.st_uid != os.geteuid():
        raise TrustError(label + ": owned by another user")
    mode = stat.S_IMODE(st.st_mode)
    if exclusive:
        # Ours outright: pin the mode on the held fd (cannot race).
        if mode & 0o077:
            os.fchmod(fd, 0o700)
    elif mode & 0o002:
        # Shared parent we must not chmod. Other-writable means anyone can
        # rename the chain below it, so it cannot be trusted. Group-write
        # alone is tolerated: user-private-group systems (umask 002) keep
        # $HOME and .config group-writable by design, and the group there
        # contains only the user.
        raise TrustError(label + ": world writable")


def _open_child(parent_fd, name, exclusive):
    # Shared parents may legitimately be symlinks (dotfile managers);
    # they are resolved at open time and the resolved directory is then
    # verified on the held fd. The plugin's own directories are opened
    # O_NOFOLLOW: a symlink there is a staged redirection, never ours.
    flags = O_DIR | (os.O_NOFOLLOW if exclusive else 0)
    for attempt in (0, 1):
        try:
            fd = os.open(name, flags, dir_fd=parent_fd)
            break
        except OSError as e:
            if e.errno in (errno.ELOOP, errno.ENOTDIR):
                raise TrustError(name + ": symlink or non-directory in trusted chain")
            if e.errno != errno.ENOENT or attempt:
                raise
            try:
                os.mkdir(name, 0o700, dir_fd=parent_fd)
            except FileExistsError:
                pass  # raced into existence; the reopen verifies whatever won
    try:
        _verify_dir(fd, name, exclusive)
    except BaseException:
        os.close(fd)
        raise
    return fd


def open_data_dir(need_icons):
    """Walk/create the trusted chain; return (omachron_fd, icons_fd | None)."""
    home = os.environ.get("HOME")
    if not home:
        raise TrustError("HOME is unset")
    fd = os.open(home, O_DIR)
    try:
        _verify_dir(fd, "$HOME", exclusive=False)
    except BaseException:
        os.close(fd)
        raise
    for name, exclusive in ((".config", False), ("omarchy", False), ("omachron", True)):
        child = _open_child(fd, name, exclusive)
        os.close(fd)
        fd = child
    icons_fd = None
    if need_icons:
        try:
            icons_fd = _open_child(fd, "icons", exclusive=True)
        except BaseException:
            os.close(fd)
            raise
    return fd, icons_fd


def _read_fd(fd, size):
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = os.read(fd, min(1 << 20, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _write_all(fd, data):
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]


# ---------------------------------------------------------------- history


def _quarantine(data_fd, reason):
    name = "%s.%s-%d-%s" % (HISTORY, reason, int(time.time()), secrets.token_hex(4))
    os.rename(HISTORY, name, src_dir_fd=data_fd, dst_dir_fd=data_fd)
    print("quarantined %s history as %s" % (reason, name), file=sys.stderr)


def _prune_quarantine(data_fd):
    # Keep the newest MAX_QUARANTINE quarantined files so repeated bad
    # loads cannot grow siblings without bound, and reclaim save temps
    # orphaned by a helper the caller's deadline killed mid-write (a
    # fatal signal skips the in-process unlink). Both happen in the same
    # descriptor-relative pass; a fresh temp is left alone in case its
    # writer is still alive.
    prefixes = tuple(HISTORY + "." + r + "-" for r in ("invalid", "oversized", "corrupt"))
    now = time.time()
    found = []
    for entry in os.scandir(data_fd):
        if not entry.is_file(follow_symlinks=False):
            continue
        if entry.name.startswith(prefixes):
            found.append((entry.stat(follow_symlinks=False).st_mtime, entry.name))
        elif entry.name.startswith(".save-"):
            if now - entry.stat(follow_symlinks=False).st_mtime > SCRATCH_TTL:
                try:
                    os.unlink(entry.name, dir_fd=data_fd)
                except OSError:
                    pass
    found.sort()
    for _, name in found[: max(0, len(found) - MAX_QUARANTINE)]:
        try:
            os.unlink(name, dir_fd=data_fd)
        except OSError:
            pass


def _seed(data_fd):
    """Create an empty history under O_EXCL (refuses even a dangling
    symlink); False when something raced the name into existence."""
    try:
        fd = os.open(HISTORY, O_CREATE, 0o600, dir_fd=data_fd)
    except FileExistsError:
        return False
    try:
        _write_all(fd, b"{}\n")
        os.fsync(fd)
    finally:
        os.close(fd)
    os.fsync(data_fd)
    return True


def cmd_load_history():
    data_fd, icons_fd = open_data_dir(need_icons=True)
    os.close(icons_fd)  # created/verified as a side effect of startup
    recovered = False
    for _ in range(4):  # quarantine+seed converges in at most two passes
        try:
            fd = os.open(HISTORY, O_LEAF, dir_fd=data_fd)
        except OSError as e:
            if e.errno == errno.ELOOP:
                _quarantine(data_fd, "invalid")
                recovered = True
                continue
            if e.errno != errno.ENOENT:
                raise
            if not _seed(data_fd):
                continue  # lost a creation race; reopen whatever won
            sys.stdout.write("{}")
            return EXIT_RECOVERED if recovered else EXIT_SEEDED
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
                os.close(fd)
                _quarantine(data_fd, "invalid")
                recovered = True
                continue
            if st.st_size > MAX_HISTORY:
                os.close(fd)
                _quarantine(data_fd, "oversized")
                recovered = True
                continue
            data = _read_fd(fd, st.st_size)
            try:
                _parse_strict(data)
            except ValueError:
                os.close(fd)
                _quarantine(data_fd, "corrupt")
                recovered = True
                continue
            os.fchmod(fd, 0o600)
        except OSError:
            os.close(fd)
            raise
        os.close(fd)
        _prune_quarantine(data_fd)
        sys.stdout.buffer.write(data)
        return EXIT_RECOVERED if recovered else EXIT_OK
    return EXIT_IO


def cmd_save_history():
    data = sys.stdin.buffer.read(MAX_HISTORY + 1)
    if len(data) > MAX_HISTORY:
        print("refusing oversized history payload", file=sys.stderr)
        return EXIT_BAD_INPUT
    try:
        _parse_strict(data)
    except ValueError:
        print("refusing non-JSON history payload", file=sys.stderr)
        return EXIT_BAD_INPUT
    data_fd, _ = open_data_dir(need_icons=False)
    tmp = ".save-" + secrets.token_hex(8)
    fd = os.open(tmp, O_CREATE, 0o600, dir_fd=data_fd)
    try:
        _write_all(fd, data)
        os.fsync(fd)
        os.close(fd)
        os.rename(tmp, HISTORY, src_dir_fd=data_fd, dst_dir_fd=data_fd)
    except BaseException:
        try:
            os.unlink(tmp, dir_fd=data_fd)
        except OSError:
            pass
        raise
    os.fsync(data_fd)
    return EXIT_OK


# ------------------------------------------------------------------ icons


def cmd_list_icons():
    data_fd, icons_fd = open_data_dir(need_icons=True)
    os.close(data_fd)
    names = []
    for entry in os.scandir(icons_fd):
        if len(names) >= MAX_ICONS:
            print("icon listing truncated at %d entries" % MAX_ICONS, file=sys.stderr)
            break
        name = entry.name
        if (
            name.endswith(".png")
            and len(name) <= MAX_NAME
            and valid_domain(name[:-4])
            and entry.is_file(follow_symlinks=False)
        ):
            names.append(name)
    sys.stdout.write("".join(n + "\n" for n in sorted(names)))
    return EXIT_OK


def _read_journal(icons_fd):
    try:
        fd = os.open(JOURNAL, O_LEAF, dir_fd=icons_fd)
    except OSError:
        return {}
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_size > JOURNAL_MAX:
            return {}  # damaged journal only forfeits cleanup, never deletes
        raw = _read_fd(fd, st.st_size)
    finally:
        os.close(fd)
    entries = {}
    for line in raw.decode("utf-8", "replace").splitlines():
        parts = line.split(" ")
        if len(parts) == 2 and SCRATCH_RE.match(parts[0]) and parts[1].isdigit():
            entries[parts[0]] = int(parts[1])
    return entries


def _write_journal(icons_fd, entries):
    tmp = ".fetch.journal.tmp-" + secrets.token_hex(8)
    payload = "".join("%s %d\n" % (n, t) for n, t in sorted(entries.items())).encode()
    fd = os.open(tmp, O_CREATE, 0o600, dir_fd=icons_fd)
    try:
        _write_all(fd, payload)
        os.fsync(fd)
        os.close(fd)
        os.rename(tmp, JOURNAL, src_dir_fd=icons_fd, dst_dir_fd=icons_fd)
    except BaseException:
        try:
            os.unlink(tmp, dir_fd=icons_fd)
        except OSError:
            pass
        raise


def _remove_scratch(icons_fd, name):
    """Unlink exactly the files a run creates, then rmdir. Never recursive:
    anything someone else placed inside keeps the directory standing."""
    try:
        dfd = os.open(name, O_DIR | os.O_NOFOLLOW, dir_fd=icons_fd)
    except OSError:
        return  # gone, or a symlink/non-dir staged under our name: untouched
    try:
        st = os.fstat(dfd)
        if (
            stat.S_ISDIR(st.st_mode)
            and st.st_uid == os.geteuid()
            and stat.S_IMODE(st.st_mode) == 0o700
        ):
            for f in ("icon", "page"):
                try:
                    os.unlink(f, dir_fd=dfd)
                except OSError:
                    pass
    finally:
        os.close(dfd)
    try:
        os.rmdir(name, dir_fd=icons_fd)
    except OSError:
        pass  # ENOTEMPTY et al: leave it standing


def _sweep(icons_fd, entries):
    now = int(time.time())
    for name in [n for n, t in entries.items() if now - t > SCRATCH_TTL]:
        # Only journaled names — recorded by us at creation — are ever
        # examined; a staged dir matching name/uid/mode/age is invisible.
        del entries[name]
        _remove_scratch(icons_fd, name)
    # Also reclaim stale journal/publish temp FILES a killed helper left
    # behind (their random names are minted only by this module, and only
    # an aged regular file is unlinked — nothing is ever descended into).
    for entry in os.scandir(icons_fd):
        if (
            (entry.name.startswith(".fetch.journal.tmp-") or entry.name.startswith(".publish-"))
            and entry.is_file(follow_symlinks=False)
            and now - entry.stat(follow_symlinks=False).st_mtime > SCRATCH_TTL
        ):
            try:
                os.unlink(entry.name, dir_fd=icons_fd)
            except OSError:
                pass


def cmd_icon_scratch():
    data_fd, icons_fd = open_data_dir(need_icons=True)
    os.close(data_fd)
    entries = _read_journal(icons_fd)
    _sweep(icons_fd, entries)
    name = ".fetch." + secrets.token_hex(12)
    # Journal before mkdir: if the journal write fails, nothing exists
    # yet; if the mkdir then fails, the entry points at nothing, which the
    # sweep already tolerates and eventually drops. The reverse order
    # could orphan an unjournaled directory nothing may ever reclaim.
    entries[name] = int(time.time())
    _write_journal(icons_fd, entries)
    os.mkdir(name, 0o700, dir_fd=icons_fd)
    print(os.path.join(os.environ["HOME"], ".config", "omarchy", "omachron", "icons", name))
    return EXIT_OK


def cmd_icon_publish(base, domain):
    if not SCRATCH_RE.match(base) or not valid_domain(domain):
        return EXIT_BAD_INPUT
    data_fd, icons_fd = open_data_dir(need_icons=True)
    os.close(data_fd)
    try:
        sfd = os.open(base, O_DIR | os.O_NOFOLLOW, dir_fd=icons_fd)
    except OSError as e:
        if e.errno in (errno.ELOOP, errno.ENOTDIR):
            raise TrustError(base + ": scratch name is a symlink or non-directory")
        raise
    try:
        st = os.fstat(sfd)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o700:
            raise TrustError(base + ": not our private scratch directory")
        ifd = os.open("icon", O_LEAF, dir_fd=sfd)
        try:
            ist = os.fstat(ifd)
            if not stat.S_ISREG(ist.st_mode) or ist.st_uid != os.geteuid():
                raise TrustError("icon: not our regular file")
            if not 0 < ist.st_size <= MAX_ICON:
                print("icon: empty or oversized", file=sys.stderr)
                return EXIT_BAD_INPUT
            # Publish the VERIFIED inode, not whatever the name resolves
            # to by rename time: link the held fd's inode to a temp name
            # (via its /proc magic link) and rename that into place, so
            # the check and the publish share one inode.
            tmp = ".publish-" + secrets.token_hex(8)
            os.link("/proc/self/fd/%d" % ifd, tmp, dst_dir_fd=icons_fd)
        finally:
            os.close(ifd)
        try:
            os.rename(tmp, domain + ".png", src_dir_fd=icons_fd, dst_dir_fd=icons_fd)
        except BaseException:
            try:
                os.unlink(tmp, dir_fd=icons_fd)
            except OSError:
                pass
            raise
        for leftover in ("icon", "page"):
            try:
                os.unlink(leftover, dir_fd=sfd)
            except OSError:
                pass
    finally:
        os.close(sfd)
    try:
        os.rmdir(base, dir_fd=icons_fd)
    except OSError:
        pass
    entries = _read_journal(icons_fd)
    if entries.pop(base, None) is not None:
        _write_journal(icons_fd, entries)
    os.fsync(icons_fd)
    return EXIT_OK


def cmd_icon_discard(base):
    if not SCRATCH_RE.match(base):
        return EXIT_BAD_INPUT
    data_fd, icons_fd = open_data_dir(need_icons=True)
    os.close(data_fd)
    _remove_scratch(icons_fd, base)
    entries = _read_journal(icons_fd)
    if entries.pop(base, None) is not None:
        _write_journal(icons_fd, entries)
    return EXIT_OK


# ------------------------------------------------------------------- main


def main(argv):
    commands = {
        "load-history": (cmd_load_history, 0),
        "save-history": (cmd_save_history, 0),
        "list-icons": (cmd_list_icons, 0),
        "icon-scratch": (cmd_icon_scratch, 0),
        "icon-publish": (cmd_icon_publish, 2),
        "icon-discard": (cmd_icon_discard, 1),
    }
    if len(argv) < 2 or argv[1] not in commands:
        print("usage: fs_guard.py <subcommand> [args]", file=sys.stderr)
        return EXIT_USAGE
    func, nargs = commands[argv[1]]
    if len(argv) != 2 + nargs:
        print("usage: fs_guard.py %s takes %d argument(s)" % (argv[1], nargs), file=sys.stderr)
        return EXIT_USAGE
    try:
        return func(*argv[2:])
    except TrustError as e:
        print("trust failure: %s" % e, file=sys.stderr)
        return EXIT_TRUST
    except OSError as e:
        print("io failure: %s" % e, file=sys.stderr)
        return EXIT_IO


if __name__ == "__main__":
    sys.exit(main(sys.argv))
