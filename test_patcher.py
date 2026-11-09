"""Independent fixtures exercise archive integrity and real filesystem transitions."""
import hashlib
import importlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

LUA = 0xA14E8DFA2CD117E2
BOOT = 0x37048A618ABDDC81
ORIGINAL_SCRIPT = b"\x1bLJ\x01\x02old-script"
WRAPPER = b"\x1bLJ\x01\x02new-wrapper-with-more-bytes"
HEADER = bytes(range(256))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fixture_payload(duplicate=False):
    """Hand-built entries include two variants, an opaque trailer and stream offsets."""
    identities = [(0x1234, 0xAA), (LUA, BOOT), (0x5678, 0xBB)]
    if duplicate:
        identities[2] = (LUA, BOOT)
    prefix = struct.pack("<I", 3) + HEADER
    prefix += b"".join(struct.pack("<QQ", *item) for item in identities)
    first = struct.pack("<QQII", *identities[0], 2, 0xDEADBEEF)
    first += struct.pack("<III", 13, 3, 7) + struct.pack("<III", 17, 4, 9)
    first += b"ONE" + b"TWO!"
    script = struct.pack("<II", len(ORIGINAL_SCRIPT), 2) + ORIGINAL_SCRIPT
    second = struct.pack("<QQIIIII", LUA, BOOT, 1, 0, 23, len(script), 0) + script
    if duplicate:
        third_data = struct.pack("<II", len(ORIGINAL_SCRIPT), 2) + ORIGINAL_SCRIPT
    else:
        third_data = b"TAIL-DATA"
    third = struct.pack("<QQIIIII", *identities[2], 1, 81, 19, len(third_data), 12) + third_data
    return prefix + first + second + third + b"opaque-package-trailer"


def fixture_archive(payload=None, padded=True):
    payload = fixture_payload() if payload is None else payload
    expanded = payload
    if padded:
        expanded += b"\0" * (-len(expanded) % 65536)
    chunks = []
    for start in range(0, len(expanded), 65536):
        raw = expanded[start:start + 65536]
        compressed = zlib.compress(raw)
        packed = compressed if len(compressed) < 65536 else raw
        chunks.append(struct.pack("<I", len(packed)) + packed)
    return struct.pack("<III", 0xF0000004, len(payload), 0) + b"".join(chunks)


class PatcherTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(Path(__file__).with_name("patcher.py").is_file(),
                        "patcher API not implemented")
        self.api = importlib.import_module("package.patcher")
        self.temporary = tempfile.TemporaryDirectory(dir=Path(__file__).parent, prefix=".test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.game = self.root / "game"
        self.target = self.game / "contents" / "9e13b2414b41b842"
        self.target.parent.mkdir(parents=True)
        self.original = fixture_archive()
        self.original_sha = sha(self.original)
        self.target.write_bytes(self.original)
        self.wrapper = self.root / "wrapper.luac"
        self.wrapper.write_bytes(WRAPPER)
        self.candidate = self.root / "candidate.archive"
        self.state = self.root / "state"

    def build(self):
        return self.api.build_candidate(self.target, self.wrapper, self.candidate,
                                        expected_original_sha256=self.original_sha)

    def install(self):
        with patch.object(self.api, "running_game_processes", return_value=[]):
            return self.api.install(self.game, self.candidate, self.state,
                                    expected_original_sha256=self.original_sha)

    def restore(self):
        with patch.object(self.api, "running_game_processes", return_value=[]):
            return self.api.restore(self.game, self.state,
                                    expected_original_sha256=self.original_sha)

    def test_decode_accepts_independent_padded_and_unpadded_archives(self):
        for padded in (True, False):
            self.assertEqual(self.api.decode_archive(fixture_archive(padded=padded)), fixture_payload())

    def test_archive_roundtrip_crosses_raw_and_compressed_chunk_boundaries(self):
        # Deterministic pseudo-random bytes force a raw chunk; zeros force compression.
        noise = b"".join(hashlib.sha256(struct.pack("<I", n)).digest() for n in range(2048))
        payload = noise + b"\0" * 65536 + b"final"
        encoded = self.api.encode_archive(payload)
        self.assertEqual(struct.unpack_from("<I", encoded, 12)[0], 65536)
        self.assertEqual(self.api.decode_archive(encoded), payload)

    def test_decode_rejects_truncated_chunk_and_incomplete_zlib(self):
        for damaged in (self.original[:8], self.original[:-1], self.original + b"\x01"):
            with self.subTest(length=len(damaged)), self.assertRaises(self.api.PatchError):
                self.api.decode_archive(damaged)

    def test_decode_rejects_nonzero_padding_and_extra_zlib_stream(self):
        bad_padding = struct.pack("<III", 0xF0000004, 1, 0)
        packed = zlib.compress(b"A!" + b"\0" * 65534)
        bad_padding += struct.pack("<I", len(packed)) + packed
        packed = zlib.compress(b"A") + zlib.compress(b"B")
        concatenated = struct.pack("<IIII", 0xF0000004, 1, 0, len(packed)) + packed
        for damaged in (bad_padding, concatenated):
            with self.assertRaises(self.api.PatchError):
                self.api.decode_archive(damaged)

    def test_decode_rejects_wrong_magic_reserved_and_declared_length(self):
        for offset, value in ((0, 0), (4, 999999), (8, 1)):
            damaged = bytearray(self.original)
            struct.pack_into("<I", damaged, offset, value)
            with self.subTest(offset=offset), self.assertRaises(self.api.PatchError):
                self.api.decode_archive(bytes(damaged))

    def test_replace_changes_only_boot_inline_length_and_data(self):
        payload = fixture_payload()
        changed = self.api.replace_lua(payload, WRAPPER)
        old_inline = struct.pack("<II", len(ORIGINAL_SCRIPT), 2) + ORIGINAL_SCRIPT
        new_inline = struct.pack("<II", len(WRAPPER), 2) + WRAPPER
        expected = payload.replace(struct.pack("<III", 23, len(old_inline), 0),
                                   struct.pack("<III", 23, len(new_inline), 0), 1)
        expected = expected.replace(old_inline, new_inline, 1)
        self.assertEqual(changed, expected)

    def test_replace_rejects_missing_or_duplicate_boot_resource(self):
        missing = fixture_payload().replace(struct.pack("<Q", BOOT), struct.pack("<Q", BOOT + 1))
        for payload in (missing, fixture_payload(duplicate=True)):
            with self.assertRaises(self.api.PatchError):
                self.api.replace_lua(payload, WRAPPER)

    def test_replace_rejects_malformed_lua_and_index(self):
        payload = fixture_payload()
        wrong_format = payload.replace(struct.pack("<II", len(ORIGINAL_SCRIPT), 2),
                                       struct.pack("<II", len(ORIGINAL_SCRIPT), 1), 1)
        bad_index = bytearray(payload)
        struct.pack_into("<Q", bad_index, 260, 0xFFFFFFFF)
        for damaged in (payload[:310], wrong_format, bytes(bad_index)):
            with self.assertRaises(self.api.PatchError):
                self.api.replace_lua(damaged, WRAPPER)

    def test_replace_rejects_incompatible_luajit_bytecode_version(self):
        with self.assertRaises(self.api.PatchError):
            self.api.replace_lua(fixture_payload(), b"\x1bLJ\x02" + WRAPPER[4:])

    def test_build_creates_candidate_receipt_without_changing_original(self):
        receipt = self.build()
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual(receipt["original_sha256"], self.original_sha)
        self.assertEqual(receipt["candidate_sha256"], sha(self.candidate.read_bytes()))
        payload = self.api.decode_archive(self.candidate.read_bytes())
        self.assertIn(struct.pack("<II", len(WRAPPER), 2) + WRAPPER, payload)
        self.assertTrue(Path(str(self.candidate) + ".json").is_file())

    def test_build_rejects_wrong_original_hash_and_empty_wrapper(self):
        with self.assertRaises(self.api.PatchError):
            self.api.build_candidate(self.target, self.wrapper, self.candidate)
        self.wrapper.write_bytes(b"")
        with self.assertRaises(self.api.PatchError):
            self.build()
        self.assertFalse(self.candidate.exists())

    def test_build_refuses_output_inside_game_or_overwriting_other_file(self):
        self.candidate.write_bytes(b"unrelated")
        with self.assertRaises(self.api.PatchError):
            self.build()
        with self.assertRaises(self.api.PatchError):
            self.api.build_candidate(self.target, self.wrapper, self.game / "candidate",
                                     expected_original_sha256=self.original_sha)
        self.assertEqual(self.candidate.read_bytes(), b"unrelated")

    def test_install_and_restore_are_idempotent_and_backup_stays_original(self):
        self.build()
        candidate_bytes = self.candidate.read_bytes()
        self.assertEqual(self.install()["status"], "installed")
        self.assertEqual(self.target.read_bytes(), candidate_bytes)
        self.assertEqual(self.install()["status"], "installed")
        self.assertEqual((self.state / "original.archive").read_bytes(), self.original)
        self.assertEqual(self.restore()["status"], "restored")
        self.assertEqual(self.restore()["status"], "restored")
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual(self.install()["status"], "installed")

    def test_install_rejects_unknown_target_content(self):
        self.build()
        self.target.write_bytes(b"other-game-update")
        with self.assertRaises(self.api.PatchError):
            self.install()
        self.assertEqual(self.target.read_bytes(), b"other-game-update")
        self.assertFalse(self.state.exists())

    def test_install_rejects_conflicting_backup(self):
        self.build()
        self.state.mkdir()
        (self.state / "original.archive").write_bytes(b"unrelated-backup")
        with self.assertRaises(self.api.PatchError):
            self.install()
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual((self.state / "original.archive").read_bytes(), b"unrelated-backup")

    def test_restore_rejects_changed_backup_or_updated_game(self):
        self.build()
        self.install()
        backup = self.state / "original.archive"
        backup.write_bytes(b"modified")
        with self.assertRaises(self.api.PatchError):
            self.restore()
        backup.write_bytes(self.original)
        self.target.write_bytes(b"game-update-after-install")
        with self.assertRaises(self.api.PatchError):
            self.restore()
        self.assertEqual(self.target.read_bytes(), b"game-update-after-install")

    def test_install_rejects_candidate_changed_after_build(self):
        self.build()
        self.candidate.write_bytes(self.candidate.read_bytes() + b"tampered")
        with self.assertRaises(self.api.PatchError):
            self.install()
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_install_rejects_forged_candidate_that_changes_unrelated_resources(self):
        self.build()
        payload = self.api.decode_archive(self.candidate.read_bytes()).replace(b"ONE", b"BAD", 1)
        self.candidate.write_bytes(self.api.encode_archive(payload))
        manifest_path = Path(str(self.candidate) + ".json")
        manifest = json.loads(manifest_path.read_text())
        manifest["candidate_sha256"] = sha(self.candidate.read_bytes())
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaises(self.api.PatchError):
            self.install()
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_install_and_restore_refuse_running_game_before_writes(self):
        self.build()
        with patch.object(self.api, "running_game_processes", return_value=["helldivers.exe"]):
            with self.assertRaises(self.api.PatchError):
                self.api.install(self.game, self.candidate, self.state,
                                 expected_original_sha256=self.original_sha)
        self.assertFalse(self.state.exists())
        self.install()
        candidate_bytes = self.target.read_bytes()
        with patch.object(self.api, "running_game_processes", return_value=["helldivers.exe"]):
            with self.assertRaises(self.api.PatchError):
                self.api.restore(self.game, self.state, expected_original_sha256=self.original_sha)
        self.assertEqual(self.target.read_bytes(), candidate_bytes)

    def test_restore_requires_receipt_and_refuses_state_inside_game(self):
        with self.assertRaises(self.api.PatchError):
            self.restore()
        self.build()
        with self.assertRaises(self.api.PatchError):
            self.api.install(self.game, self.candidate, self.game / "state",
                             expected_original_sha256=self.original_sha)

    def test_failed_atomic_replacement_leaves_original_and_recoverable_backup(self):
        self.build()
        real_replace = self.api.os.replace

        def fail_game_replace(source, destination):
            if Path(destination) == self.target:
                raise OSError("simulated replace failure")
            return real_replace(source, destination)

        with patch.object(self.api, "running_game_processes", return_value=[]):
            with patch.object(self.api.os, "replace", side_effect=fail_game_replace):
                with self.assertRaises(OSError):
                    self.api.install(self.game, self.candidate, self.state,
                                     expected_original_sha256=self.original_sha)
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual((self.state / "original.archive").read_bytes(), self.original)
        self.assertEqual(list(self.target.parent.glob("*.tmp")), [])
        self.assertEqual(self.install()["status"], "installed")

    def change_target_while_temporary_file_is_flushed(self, operation):
        real_mkstemp = self.api.tempfile.mkstemp
        real_fsync = self.api.os.fsync
        game_temporary_started = False

        def observe_temporary(*args, **kwargs):
            nonlocal game_temporary_started
            result = real_mkstemp(*args, **kwargs)
            if Path(kwargs["dir"]) == self.target.parent:
                game_temporary_started = True
            return result

        def update_after_preparation(descriptor):
            real_fsync(descriptor)
            if game_temporary_started:
                self.target.write_bytes(b"concurrent-game-update")

        with patch.object(self.api.tempfile, "mkstemp", side_effect=observe_temporary):
            with patch.object(self.api.os, "fsync", side_effect=update_after_preparation):
                with self.assertRaises(self.api.PatchError):
                    operation()
        self.assertEqual(self.target.read_bytes(), b"concurrent-game-update")

    def test_install_preserves_update_that_arrives_during_temporary_write(self):
        self.build()
        self.change_target_while_temporary_file_is_flushed(self.install)

    def test_restore_preserves_update_that_arrives_during_temporary_write(self):
        self.build()
        self.install()
        self.change_target_while_temporary_file_is_flushed(self.restore)


if __name__ == "__main__":
    unittest.main()
