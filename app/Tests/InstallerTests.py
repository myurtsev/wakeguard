#!/usr/bin/env python3
"""Run the actual installer scripts against disposable files and fake host APIs."""

import json
import hashlib
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


PROJECT = Path(__file__).resolve().parents[1]
LABEL = "nl.local.WakeGuard"
HOST_PATHS = ("/Library", "/var/db", "/Applications", "/dev/console")
FAKE_COMMANDS = {
    "/usr/bin/stat": "stat",
    "/usr/sbin/chown": "chown",
    "/bin/launchctl": "launchctl",
    "/usr/libexec/PlistBuddy": "PlistBuddy",
    "/usr/bin/plutil": "plutil",
}
REAL_COMMANDS = {
    "/bin/sh", "/bin/mkdir", "/bin/chmod", "/bin/rm", "/bin/cat",
    "/bin/sleep", "/usr/bin/printf",
}

# Only this stub simulates ownership, daemon state, and recovery. File modes,
# symlinks, hardlinks, script branches, and shell failures remain real.
FAKE_PROGRAM = r'''
import json, os, pathlib, plistlib, stat, sys
root = pathlib.Path(os.environ["WAKEGUARD_FIXTURE"]).resolve()
kind = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
def path(value):
    item = pathlib.Path(value)
    if not item.is_absolute() or not item.resolve().is_relative_to(root):
        raise SystemExit("Fixture escaped: " + value)
    return item
with (root / "events.jsonl").open("a") as stream:
    stream.write(json.dumps([kind, *args]) + "\n")
ownership = root / "ownership.json"
owners = json.loads(ownership.read_text())
if kind == "stat":
    assert len(args) == 3 and args[0] == "-f"
    item = path(args[2])
    if item == root / "host/dev/console":
        assert args[1] == "%u"
        print(os.environ.get("FAKE_UID", "501"))
    else:
        value = item.stat()
        uid = owners.get(str(item), 0)
        mode = format(stat.S_IMODE(value.st_mode), "o")
        formats = {"%u:%Lp": f"{uid}:{mode}",
                   "%u:%l:%Lp": f"{uid}:{value.st_nlink}:{mode}"}
        print(formats[args[1]])
elif kind == "chown":
    uid = args[0].split(":")[0]
    for value in args[1:]:
        owners[str(path(value))] = 0 if uid == "root" else int(uid)
    ownership.write_text(json.dumps(owners))
elif kind == "PlistBuddy":
    assert args[:2] == ["-c", "Print :CFBundleIdentifier"]
    with path(args[2]).open("rb") as stream:
        print(plistlib.load(stream)["CFBundleIdentifier"])
elif kind == "plutil":
    assert args[:5] == ["-extract", "uid", "raw", "-o", "-"]
    value = json.loads(path(args[5]).read_text())["uid"]
    assert type(value) is int
    print(value)
elif kind == "launchctl":
    loaded = root / "loaded"
    if args == ["print", "system/nl.local.WakeGuard"]:
        raise SystemExit(0 if loaded.exists() else 1)
    if args == ["bootout", "system/nl.local.WakeGuard"]:
        if os.environ.get("FAKE_BOOTOUT_FAIL") == "1":
            raise SystemExit(9)
        loaded.unlink(missing_ok=True)
    elif args == ["enable", "system/nl.local.WakeGuard"]:
        pass
    elif len(args) == 3 and args[:2] == ["bootstrap", "system"]:
        assert path(args[2]) == root / "host/Library/LaunchDaemons/nl.local.WakeGuard.plist"
        loaded.touch()
        (root / "host/var/db/nl.local.WakeGuard/status.json").write_text('{"active":false}\n')
    else:
        raise SystemExit("Unexpected launchctl scope: " + repr(args))
elif kind == "nl.local.WakeGuard.helper":
    assert args == ["--recover"]
    if os.environ.get("FAKE_RECOVER_FAIL") == "1":
        raise SystemExit(8)
    (root / "host/var/db/nl.local.WakeGuard/owns-sleep").unlink(missing_ok=True)
else:
    raise SystemExit("Unexpected fixture command: " + kind)
'''


class Fixture:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wakeguard-installer-")
        self.root = Path(self.temporary.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir(mode=0o755)
        self.data = self.root / "host/var/db" / LABEL
        self.helper = self.root / "host/Library/PrivilegedHelperTools" / (LABEL + ".helper")
        self.plist = self.root / "host/Library/LaunchDaemons" / (LABEL + ".plist")
        self.app = self.root / "host/Applications/WakeGuard.app"
        for directory in (self.data.parent, self.helper.parent, self.plist.parent, self.app.parent,
                          self.root / "host/dev"):
            directory.mkdir(parents=True, mode=0o755, exist_ok=True)
        (self.root / "ownership.json").write_text("{}")
        self.environment = {
            "PATH": str(self.bin) + ":/usr/bin:/bin",
            "WAKEGUARD_FIXTURE": str(self.root), "FAKE_UID": "501",
        }
        for name in FAKE_COMMANDS.values():
            self.executable(self.bin / name)

    def close(self):
        self.temporary.cleanup()

    def executable(self, destination):
        destination.write_text("#!" + sys.executable + "\n" + FAKE_PROGRAM)
        destination.chmod(0o755)

    def owner(self, target, uid):
        file = self.root / "ownership.json"
        owners = json.loads(file.read_text())
        owners[str(target)] = uid
        file.write_text(json.dumps(owners))

    def events(self):
        file = self.root / "events.jsonl"
        return [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []

    def payload(self):
        self.executable(self.helper)
        self.plist.write_bytes(plistlib.dumps({"Label": LABEL}))
        self.plist.chmod(0o644)

    def marker(self):
        self.data.mkdir(mode=0o755, exist_ok=True)
        (self.data / "owns-sleep").touch()

    def run(self, name, target="/"):
        source = (PROJECT / "Packaging" / name).read_text()
        # Reject new host APIs before executing anything. Every host target and
        # privileged command is replaced; only ordinary file utilities remain.
        commands = set(re.findall(r"/(?:usr|bin|sbin)[A-Za-z0-9_./-]*", source))
        unknown = commands - REAL_COMMANDS - set(FAKE_COMMANDS)
        if unknown:
            raise AssertionError("Unapproved installer commands: " + repr(unknown))
        if "/usr/bin/pmset" in source or re.search(r"(?:^|\n|;)\s*(?:sudo|installer|osascript)\s", source):
            raise AssertionError("Installer fixture must never invoke privileged host tools")
        for original, replacement in FAKE_COMMANDS.items():
            source = source.replace(original, str(self.bin / replacement))
        for original in HOST_PATHS:
            source = source.replace(original, str(self.root / "host") + original)
        scrubbed = source
        for original in HOST_PATHS:
            scrubbed = scrubbed.replace(str(self.root / "host") + original, "FIXTURE")
        if any(path in scrubbed for path in HOST_PATHS):
            raise AssertionError("Unrewritten host path")
        script = self.root / name
        script.write_text(source)
        return subprocess.run(
            ["/bin/sh", str(script), "package.pkg", "/", target],
            cwd=self.root, env=self.environment, capture_output=True, text=True, timeout=15,
        )


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)

    def succeeded(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def rejected_before_recovery(self):
        result = self.fixture.run("preinstall")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(event[0].endswith(".helper") for event in self.fixture.events()))
        self.assertFalse((self.fixture.data / ".install-uid").exists())

    def test_fresh_install_enrolls_before_postinstall(self):
        self.succeeded(self.fixture.run("preinstall"))
        enrollment = self.fixture.data / ".install-uid"
        self.assertEqual(enrollment.read_text(), "501\n")
        self.assertEqual(stat.S_IMODE(enrollment.stat().st_mode), 0o600)
        self.assertFalse((self.fixture.data / "config.json").exists())

    def test_valid_postinstall_sets_permissions_uid_and_system_scope(self):
        self.succeeded(self.fixture.run("preinstall"))
        self.fixture.payload()
        self.fixture.helper.chmod(0o700)
        self.fixture.plist.chmod(0o600)
        self.fixture.owner(self.fixture.helper, 501)
        self.succeeded(self.fixture.run("postinstall"))
        self.assertEqual(json.loads((self.fixture.data / "config.json").read_text()), {"uid": 501})
        self.assertEqual(json.loads((self.fixture.data / "lease.json").read_text()), {})
        owners = json.loads((self.fixture.root / "ownership.json").read_text())
        for path, mode, uid in (
            (self.fixture.data, 0o755, 0), (self.fixture.helper.parent, 0o755, 0),
            (self.fixture.plist.parent, 0o755, 0), (self.fixture.helper, 0o755, 0),
            (self.fixture.plist, 0o644, 0), (self.fixture.data / "config.json", 0o644, 0),
            (self.fixture.data / "lease.json", 0o600, 501),
        ):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), mode)
            self.assertEqual(owners.get(str(path), 0), uid)
        self.assertFalse((self.fixture.data / ".install-uid").exists())
        events = self.fixture.events()
        self.assertIn(["launchctl", "enable", "system/" + LABEL], events)
        self.assertIn(["launchctl", "bootstrap", "system", str(self.fixture.plist)], events)

    def test_nonstartup_volume_rejected_before_host_action(self):
        for name in ("preinstall", "postinstall"):
            with self.subTest(script=name):
                self.assertNotEqual(self.fixture.run(name, "/Volumes/Other").returncode, 0)
                self.assertEqual(self.fixture.events(), [])
                self.assertFalse(self.fixture.data.exists())

    def test_uid_switch_between_scripts_rejected(self):
        self.succeeded(self.fixture.run("preinstall"))
        self.fixture.payload()
        self.fixture.environment["FAKE_UID"] = "502"
        self.assertNotEqual(self.fixture.run("postinstall").returncode, 0)
        self.assertFalse((self.fixture.data / "config.json").exists())
        self.assertFalse(any(event[:2] == ["launchctl", "bootstrap"] for event in self.fixture.events()))

    def test_invalid_console_uid_rejected(self):
        self.fixture.environment["FAKE_UID"] = "0"
        self.rejected_before_recovery()

    def test_group_and_world_writable_helper_rejected(self):
        self.fixture.payload()
        self.fixture.marker()
        for mode in (0o775, 0o757, 0o777):
            with self.subTest(mode=oct(mode)):
                self.fixture.helper.chmod(mode)
                self.rejected_before_recovery()

    def test_nonroot_helper_rejected(self):
        self.fixture.payload()
        self.fixture.marker()
        self.fixture.owner(self.fixture.helper, 501)
        self.rejected_before_recovery()

    def test_symlink_helper_rejected(self):
        self.fixture.payload()
        self.fixture.marker()
        real = self.fixture.root / "real-helper"
        self.fixture.helper.rename(real)
        self.fixture.helper.symlink_to(real)
        self.rejected_before_recovery()

    def test_hardlinked_helper_rejected(self):
        self.fixture.payload()
        self.fixture.marker()
        os.link(self.fixture.helper, self.fixture.root / "linked-helper")
        self.rejected_before_recovery()

    def test_unsafe_parent_rejected(self):
        self.fixture.payload()
        self.fixture.marker()
        self.fixture.helper.parent.chmod(0o775)
        self.rejected_before_recovery()

    def test_symlink_parent_rejected(self):
        self.fixture.payload()
        self.fixture.marker()
        parent = self.fixture.helper.parent
        relocated = self.fixture.root / "relocated-helper-directory"
        parent.rename(relocated)
        parent.symlink_to(relocated)
        self.rejected_before_recovery()

    def test_other_app_not_overwritten(self):
        info = self.fixture.app / "Contents/Info.plist"
        info.parent.mkdir(parents=True)
        original = plistlib.dumps({"CFBundleIdentifier": "other.vendor.app"})
        info.write_bytes(original)
        self.rejected_before_recovery()
        self.assertEqual(info.read_bytes(), original)
        self.assertFalse(any(event[0] == "launchctl" for event in self.fixture.events()))

    def test_recovery_only_after_bootout(self):
        self.fixture.payload()
        self.fixture.marker()
        (self.fixture.root / "loaded").touch()
        self.succeeded(self.fixture.run("preinstall"))
        events = self.fixture.events()
        bootout = events.index(["launchctl", "bootout", "system/" + LABEL])
        recovery = events.index([LABEL + ".helper", "--recover"])
        self.assertLess(bootout, recovery)
        self.assertFalse((self.fixture.data / "owns-sleep").exists())
        self.assertEqual((self.fixture.data / ".install-uid").read_text(), "501\n")

    def test_failed_recovery_aborts_enrollment(self):
        self.fixture.payload()
        self.fixture.marker()
        self.fixture.environment["FAKE_RECOVER_FAIL"] = "1"
        self.assertNotEqual(self.fixture.run("preinstall").returncode, 0)
        self.assertIn([LABEL + ".helper", "--recover"], self.fixture.events())
        self.assertTrue((self.fixture.data / "owns-sleep").exists())
        self.assertFalse((self.fixture.data / ".install-uid").exists())

    def test_bootout_failure_aborts_before_recovery(self):
        self.fixture.payload()
        self.fixture.marker()
        (self.fixture.root / "loaded").touch()
        self.fixture.environment["FAKE_BOOTOUT_FAIL"] = "1"
        self.rejected_before_recovery()

    def history(self, uid):
        self.fixture.data.mkdir(mode=0o755, exist_ok=True)
        config = self.fixture.data / "config.json"
        config.write_text(json.dumps({"uid": uid}))
        config.chmod(0o644)
        audit = self.fixture.data / "audit.json"
        history = self.fixture.data / "history.json"
        for file in (audit, history):
            file.write_text('{"fixture":"private history"}')
            file.chmod(0o600)
        self.fixture.owner(history, uid)
        return audit, history

    def test_same_account_history_retained(self):
        files = self.history(501)
        original = [file.read_bytes() for file in files]
        self.succeeded(self.fixture.run("preinstall"))
        self.fixture.payload()
        self.succeeded(self.fixture.run("postinstall"))
        self.assertEqual([file.read_bytes() for file in files], original)

    def test_new_account_private_history_removed_after_recovery(self):
        files = self.history(502)
        self.fixture.payload()
        self.fixture.marker()
        self.succeeded(self.fixture.run("preinstall"))
        self.assertFalse(any(file.exists() for file in files))
        self.assertIn([LABEL + ".helper", "--recover"], self.fixture.events())
        self.fixture.payload()
        self.succeeded(self.fixture.run("postinstall"))
        self.assertEqual(json.loads((self.fixture.data / "config.json").read_text()), {"uid": 501})

    def test_history_without_account_rejected(self):
        self.history(501)
        (self.fixture.data / "config.json").unlink()
        self.rejected_before_recovery()

    def test_unsafe_history_metadata_rejected(self):
        audit, history = self.history(501)
        for file in (audit, history):
            with self.subTest(file=file.name):
                file.chmod(0o644)
                self.rejected_before_recovery()
                file.chmod(0o600)
                alias = self.fixture.root / "history-hardlink"
                os.link(file, alias)
                self.rejected_before_recovery()
                alias.unlink()
                real = self.fixture.root / "real-history"
                file.rename(real)
                file.symlink_to(real)
                self.rejected_before_recovery()
                file.unlink()
                real.rename(file)

    def test_history_wrong_account_owner_rejected(self):
        _, history = self.history(501)
        self.fixture.owner(history, 502)
        self.rejected_before_recovery()

    def test_reenrollment_removes_only_validated_old_account_uuid_temporary(self):
        self.history(502)
        self.fixture.payload()
        self.fixture.marker()
        for index, (uid, mode) in enumerate(((502, 0o600), (0, 0o644))):
            temporary = self.fixture.data / (f".00000000-0000-0000-0000-{index:012d}")
            temporary.write_text("private crash fixture")
            temporary.chmod(mode)
            self.fixture.owner(temporary, uid)
        unknown = self.fixture.data / ".not-a-UUID"
        unknown.write_text("preserve unknown file")
        self.succeeded(self.fixture.run("preinstall"))
        self.assertEqual([path.name for path in self.fixture.data.glob(".00000000-*")], [])
        self.assertEqual(unknown.read_text(), "preserve unknown file")

    def test_uuid_temporary_unsafe_owner_mode_symlink_or_hardlink_rejected(self):
        self.history(502)
        temporary = self.fixture.data / ".00000000-0000-0000-0000-000000000001"
        temporary.write_text("private crash fixture")
        temporary.chmod(0o600)
        self.fixture.owner(temporary, 503)
        self.assertNotEqual(self.fixture.run("preinstall").returncode, 0)
        self.assertTrue(temporary.exists())
        self.fixture.owner(temporary, 502)
        temporary.chmod(0o666)
        self.assertNotEqual(self.fixture.run("preinstall").returncode, 0)
        self.assertTrue(temporary.exists())
        temporary.chmod(0o600)
        alias = self.fixture.root / "crash-hardlink"
        os.link(temporary, alias)
        self.assertNotEqual(self.fixture.run("preinstall").returncode, 0)
        alias.unlink()
        real = self.fixture.root / "real-crash-file"
        temporary.rename(real)
        temporary.symlink_to(real)
        self.assertNotEqual(self.fixture.run("preinstall").returncode, 0)
        self.assertTrue(temporary.is_symlink())
        self.assertFalse((self.fixture.data / ".install-uid").exists())


def check_package(package, helper):
    """Inspect the actual produced archive; never invoke Installer or launchd."""
    with tempfile.TemporaryDirectory(prefix="wakeguard-package-") as temporary:
        expanded = Path(temporary) / "expanded"
        subprocess.run(["/usr/sbin/pkgutil", "--expand-full", str(package), str(expanded)], check=True)
        info = ET.parse(expanded / "PackageInfo").getroot()
        assert info.attrib["identifier"] == "nl.local.WakeGuard.helper-installer"
        with (PROJECT / "Packaging/Info.plist").open("rb") as plist:
            version = plistlib.load(plist)["CFBundleShortVersionString"]
        assert info.attrib["version"] == version
        assert info.attrib["overwrite-permissions"] == "false"
        assert info.attrib["auth"] == "root"
        payload = expanded / "Payload"
        expected = {
            "Library/PrivilegedHelperTools/nl.local.WakeGuard.helper",
            "Library/LaunchDaemons/nl.local.WakeGuard.plist",
        }
        files = {str(path.relative_to(payload)) for path in payload.rglob("*")
                 if path.is_file() and not path.name.startswith("._")}
        assert files == expected, files
        assert not (payload / "Applications").exists()
        assert not info.findall("bundle")
        installed_helper = payload / "Library/PrivilegedHelperTools/nl.local.WakeGuard.helper"
        assert hashlib.sha256(installed_helper.read_bytes()).digest() == hashlib.sha256(helper.read_bytes()).digest()
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(installed_helper)], check=True)
        assert subprocess.check_output(["/usr/bin/lipo", "-archs", str(installed_helper)], text=True).strip() == "arm64"
        for script in ("preinstall", "postinstall"):
            assert (expanded / "Scripts" / script).read_bytes() == (PROJECT / "Packaging" / script).read_bytes()
    print("Helper-only package checks passed; application is never an installer payload")


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "--package" and sys.argv[3] == "--helper":
        check_package(Path(sys.argv[2]).resolve(), Path(sys.argv[4]).resolve())
    else:
        unittest.main(verbosity=2)
