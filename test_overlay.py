"""Controlled archive fixtures and real filesystem transactions; no game writes."""
import importlib
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

from package import patcher
from package.test_patcher import fixture_archive, sha, WRAPPER, HEADER

NAMES = ("21f858a58ab6cce7", "68e5a323f59aa64c", "ec181385e7000cf1")
KIND, NAME = 0xA486D4045106165C, 0x4D817700197E8EE5
GRAPH = b"controlled-source-graph-not-a-game-asset"


def graph_archive(graph=GRAPH, extra=b""):
    identity = struct.pack("<QQ", KIND, NAME)
    payload = struct.pack("<I", 1) + HEADER + identity
    payload += struct.pack("<QQIIIII", KIND, NAME, 1, 0, 0, len(graph), 0) + graph + extra
    return fixture_archive(payload)


class OverlayTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(Path(__file__).with_name("overlay.py").is_file(),
                        "guarded multi-file overlay API missing")
        self.api = importlib.import_module("package.overlay")
        self.temp = tempfile.TemporaryDirectory(dir=Path(__file__).parent, prefix=".overlay-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.game = self.root / "game"
        self.contents = self.game / "contents"
        self.contents.mkdir(parents=True)
        self.original = fixture_archive()
        (self.contents / patcher.ARCHIVE_NAME).write_bytes(self.original)
        self.base = graph_archive()
        for name in NAMES:
            (self.contents / name).write_bytes(self.base)
        preserved = {"bundle_database.data": b"database", **{name + ".stream": name.encode() for name in NAMES}}
        for name, data in preserved.items():
            (self.contents / name).write_bytes(data)
        self.pins = {"boot_sha256": sha(self.original),
                     "base_sha256": dict.fromkeys(NAMES, sha(self.base)),
                     "preserve_sha256": {name: sha(data) for name, data in preserved.items()},
                     "graph_sha256": sha(GRAPH), "header_sha256": sha(HEADER)}
        self.wrapper = self.root / "wrapper.luac"
        self.wrapper.write_bytes(WRAPPER)
        self.boot = self.root / "boot.archive"
        patcher.build_candidate(self.contents / patcher.ARCHIVE_NAME, self.wrapper, self.boot,
                                expected_original_sha256=sha(self.original))
        self.candidate, self.state = self.root / "candidate", self.root / "state"
        # The native graph serializer has its own primary-asset suite. These
        # fixtures isolate transaction behavior from that separate large input.
        self.transform = patch.object(self.api, "_generate_graph", side_effect=lambda value: value + b"-twins")
        self.transform.start()
        self.addCleanup(self.transform.stop)
        self.closed = patch.object(patcher, "running_game_processes", return_value=[])
        self.closed.start()
        self.addCleanup(self.closed.stop)

    def build(self):
        return self.api.build_candidate(self.game, self.boot, self.candidate, pins=self.pins)

    def install(self):
        return self.api.install(self.game, self.candidate, self.state, pins=self.pins)

    def restore(self):
        return self.api.restore(self.game, self.state, pins=self.pins)

    def test_build_has_three_identical_single_graph_overlays_and_unchanged_sources(self):
        manifest = self.build()
        overlays = [self.candidate / (name + ".patch_0") for name in NAMES]
        self.assertEqual(len({path.read_bytes() for path in overlays}), 1)
        payload = patcher.decode_archive(overlays[0].read_bytes())
        count, variants = patcher.parse_package(payload)
        self.assertEqual((count, len(variants)), (1, 1))
        record = variants[0]
        self.assertEqual((record.kind, record.path, record.stream_size), (KIND, NAME, 0))
        self.assertEqual(payload[record.data_offset:], GRAPH + b"-twins")
        self.assertEqual(manifest["kind"], "helldivers-camera-candidate-v2")
        for name in NAMES:
            self.assertEqual((self.contents / name).read_bytes(), self.base)
        self.assertFalse(self.state.exists())

    def test_install_orders_overlays_before_boot_and_restore_keeps_backup(self):
        self.build()
        writes = []
        atomic = patcher._atomic_write
        def record(path, data, **kwargs):
            if path.parent == self.contents:
                writes.append(path.name)
            return atomic(path, data, **kwargs)
        with patch.object(patcher, "_atomic_write", side_effect=record):
            receipt = self.install()
        self.assertEqual(writes, [name + ".patch_0" for name in NAMES] + [patcher.ARCHIVE_NAME])
        self.assertEqual(receipt["status"], "installed")
        backup = self.state / "boot_state" / "original.archive"
        self.assertEqual(backup.read_bytes(), self.original)
        self.restore()
        self.assertEqual((self.contents / patcher.ARCHIVE_NAME).read_bytes(), self.original)
        self.assertTrue(backup.is_file())
        self.assertTrue(all(not (self.contents / (name + ".patch_0")).exists() for name in NAMES))
        self.assertEqual(self.restore()["status"], "restored")

    def test_any_foreign_patch_even_noncontiguous_or_other_archive_blocks_without_writes(self):
        self.build()
        for name in (NAMES[0] + ".patch_0", NAMES[1] + ".patch_9", "ffffffffffffffff.patch_0"):
            foreign = self.contents / name
            foreign.write_bytes(b"foreign")
            with self.subTest(name=name), self.assertRaises(patcher.PatchError):
                self.install()
            self.assertEqual(foreign.read_bytes(), b"foreign")
            self.assertEqual((self.contents / patcher.ARCHIVE_NAME).read_bytes(), self.original)
            foreign.unlink()

    def test_running_game_and_modified_base_or_database_refuse_before_prepared_journal(self):
        self.build()
        with patch.object(patcher, "running_game_processes", return_value=["helldivers.exe"]):
            with self.assertRaises(patcher.PatchError):
                self.install()
        for name in (NAMES[0], "bundle_database.data", NAMES[2] + ".stream"):
            path = self.contents / name
            old = path.read_bytes()
            path.write_bytes(old + b"updated")
            with self.subTest(name=name), self.assertRaises(patcher.PatchError):
                self.install()
            path.write_bytes(old)
        self.assertFalse((self.state / "receipt.json").exists())

    def test_overlay_candidate_tamper_or_extra_file_refused(self):
        self.build()
        target = self.candidate / (NAMES[0] + ".patch_0")
        old = target.read_bytes()
        target.write_bytes(old + b"tamper")
        with self.assertRaises(patcher.PatchError):
            self.install()
        target.write_bytes(old)
        (self.candidate / "unreviewed.data").write_bytes(b"extra")
        with self.assertRaises(patcher.PatchError):
            self.install()
        self.assertEqual((self.contents / patcher.ARCHIVE_NAME).read_bytes(), self.original)

    def test_failure_after_second_overlay_rolls_back_only_owned_files_and_boot_first(self):
        self.build()
        atomic = patcher._atomic_write
        writes = []
        def failing(path, data, **kwargs):
            if path.parent == self.contents:
                writes.append(path.name)
                if path.name == NAMES[2] + ".patch_0":
                    raise OSError("injected third overlay publication failure")
            return atomic(path, data, **kwargs)
        with patch.object(patcher, "_atomic_write", side_effect=failing):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual((self.contents / patcher.ARCHIVE_NAME).read_bytes(), self.original)
        self.assertTrue(all(not (self.contents / (name + ".patch_0")).exists() for name in NAMES))
        self.assertEqual(json.loads((self.state / "receipt.json").read_text())["status"], "rolled_back")

    def test_crash_after_overlay_creation_retains_prepared_journal_for_explicit_restore(self):
        self.build()
        atomic = patcher._atomic_write
        def crash(path, data, **kwargs):
            result = atomic(path, data, **kwargs)
            if path.parent == self.contents and path.name == NAMES[1] + ".patch_0":
                raise SystemExit("simulated process termination")
            return result
        with patch.object(patcher, "_atomic_write", side_effect=crash):
            with self.assertRaises(SystemExit):
                self.install()
        journal = json.loads((self.state / "receipt.json").read_text())
        self.assertEqual(journal["status"], "prepared")
        with self.assertRaises(patcher.PatchError):
            self.install()
        self.restore()
        self.assertTrue(all(not (self.contents / (name + ".patch_0")).exists() for name in NAMES))

    def test_boot_publication_failure_restores_boot_before_removing_overlays(self):
        self.build()
        atomic = patcher._atomic_write
        happened = []
        failed = False
        def crash_after_boot(path, data, **kwargs):
            nonlocal failed
            result = atomic(path, data, **kwargs)
            if path == self.contents / patcher.ARCHIVE_NAME:
                happened.append("original" if data == self.original else "candidate")
                if not failed:
                    failed = True
                    raise OSError("injected failure after BOOT publication")
            return result
        with patch.object(patcher, "_atomic_write", side_effect=crash_after_boot):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual(happened, ["candidate", "original"])
        self.assertEqual((self.contents / patcher.ARCHIVE_NAME).read_bytes(), self.original)
        self.assertTrue(all(not (self.contents / (name + ".patch_0")).exists() for name in NAMES))

    def test_restore_refuses_changed_owned_overlay_and_preserves_unknown_bytes(self):
        self.build()
        self.install()
        target = self.contents / (NAMES[0] + ".patch_0")
        target.write_bytes(b"foreign replacement")
        before = (self.contents / patcher.ARCHIVE_NAME).read_bytes()
        with self.assertRaises(patcher.PatchError):
            self.restore()
        self.assertEqual(target.read_bytes(), b"foreign replacement")
        self.assertEqual((self.contents / patcher.ARCHIVE_NAME).read_bytes(), before)

    def test_install_idempotence_and_state_conflicting_target_refused(self):
        self.build()
        self.install()
        self.assertEqual(self.install()["status"], "installed")
        journal_path = self.state / "receipt.json"
        journal = json.loads(journal_path.read_text())
        journal["game_dir"] = str(self.root / "other-game")
        journal_path.write_text(json.dumps(journal))
        with self.assertRaises(patcher.PatchError):
            self.restore()

    def test_candidate_verification_rederives_graph_instead_of_trusting_updated_hashes(self):
        self.build()
        path = self.candidate / (NAMES[0] + ".patch_0")
        bad = graph_archive(b"unreviewed graph")
        for name in NAMES:
            (self.candidate / (name + ".patch_0")).write_bytes(bad)
        manifest_path = self.candidate / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["overlay_sha256"] = sha(bad)
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaises(patcher.PatchError):
            self.install()
        self.assertEqual((self.contents / patcher.ARCHIVE_NAME).read_bytes(), self.original)

    def test_streaming_reader_skips_unrelated_large_inline_data(self):
        prefix = b"X" * (65536 * 40)
        identities = ((1, 1), (KIND, NAME))
        payload = struct.pack("<I", 2) + HEADER + b"".join(struct.pack("<QQ", *p) for p in identities)
        payload += struct.pack("<QQIIIII", 1, 1, 1, 0, 0, len(prefix), 0) + prefix
        payload += struct.pack("<QQIIIII", KIND, NAME, 1, 0, 0, len(GRAPH), 0) + GRAPH
        path = self.root / "large-base"
        path.write_bytes(fixture_archive(payload))
        reader = self.api.Bundle(path)
        self.assertEqual(reader.graph_resource(), GRAPH)
        self.assertLess(reader.decoded_blocks, 6)

    def test_inline_only_graph_accepts_opaque_cumulative_stream_offset(self):
        payload = bytearray(patcher.decode_archive(self.base))
        struct.pack_into("<I", payload, 260 + 16 + 20, 0x12345678)
        path = self.root / "source-with-prior-streamed-resources"
        path.write_bytes(fixture_archive(bytes(payload)))
        try:
            value = self.api.Bundle(path).graph_resource()
        except patcher.PatchError as error:
            self.fail(f"Inline-only graph rejected an unused stream offset: {error}")
        self.assertEqual(value, GRAPH)

    def test_idempotent_install_still_requires_original_backup(self):
        self.build()
        self.install()
        (self.state / "boot_state" / "original.archive").unlink()
        with self.assertRaises(patcher.PatchError):
            self.install()

    def test_foreign_patch_appearing_after_preflight_never_activates_boot(self):
        self.build()
        atomic = patcher._atomic_write
        foreign = self.contents / "ffffffffffffffff.patch_0"
        def concurrent_change(path, data, **kwargs):
            result = atomic(path, data, **kwargs)
            if path.parent == self.contents and path.name == OVERLAY_FIRST:
                foreign.write_bytes(b"concurrent foreign mod")
            return result
        OVERLAY_FIRST = NAMES[0] + ".patch_0"
        with patch.object(patcher, "_atomic_write", side_effect=concurrent_change):
            with self.assertRaises(patcher.PatchError):
                self.install()
        self.assertEqual((self.contents / patcher.ARCHIVE_NAME).read_bytes(), self.original)
        self.assertEqual(foreign.read_bytes(), b"concurrent foreign mod")

    def test_state_directory_inside_game_refused(self):
        self.build()
        with self.assertRaises(patcher.PatchError):
            self.api.install(self.game, self.candidate, self.game / "unsafe-state", pins=self.pins)
        self.assertFalse((self.game / "unsafe-state").exists())

    def test_candidate_changed_after_verification_is_never_published(self):
        self.build()
        atomic = patcher._atomic_write
        bad_candidate = self.candidate / (NAMES[1] + ".patch_0")
        published = []
        def change_after_journal(path, data, **kwargs):
            result = atomic(path, data, **kwargs)
            if path == self.state / "receipt.json" and json.loads(data)["status"] == "prepared":
                bad_candidate.write_bytes(b"changed after candidate verification")
            if path.parent == self.contents:
                published.append((path.name, data))
            return result
        with patch.object(patcher, "_atomic_write", side_effect=change_after_journal):
            with self.assertRaises(patcher.PatchError):
                self.install()
        self.assertFalse(any(data == b"changed after candidate verification" for _, data in published))
        self.assertTrue(all(not (self.contents / (name + ".patch_0")).exists() for name in NAMES))
        self.assertEqual((self.contents / patcher.ARCHIVE_NAME).read_bytes(), self.original)

    def test_foreign_patch_arriving_during_last_hash_scan_prevents_boot_activation(self):
        self.build()
        scan = self.api._unchanged_sources
        count = 0
        def change_during_scan(contents, pins):
            nonlocal count
            scan(contents, pins)
            count += 1
            if count == 2:
                (contents / "ffffffffffffffff.patch_0").write_bytes(b"foreign during slow hash scan")
        with patch.object(self.api, "_unchanged_sources", side_effect=change_during_scan):
            with self.assertRaises(patcher.PatchError):
                self.install()
        self.assertEqual((self.contents / patcher.ARCHIVE_NAME).read_bytes(), self.original)

    def test_owned_delete_requires_exact_digest_and_keeps_foreign_file(self):
        self.assertTrue(callable(getattr(self.api, "_delete_owned_overlay", None)),
                        "same-handle verified Windows deletion missing")
        path = self.root / "owned.patch_0"
        path.write_bytes(b"foreign")
        with self.assertRaises(patcher.PatchError):
            self.api._delete_owned_overlay(path, sha(b"owned"))
        self.assertEqual(path.read_bytes(), b"foreign")
        path.write_bytes(b"owned")
        self.api._delete_owned_overlay(path, sha(b"owned"))
        self.assertFalse(path.exists())

    def test_owned_delete_blocks_replacement_and_writes_between_hash_and_deletion(self):
        self.assertTrue(callable(getattr(self.api, "_delete_owned_overlay", None)),
                        "same-handle verified Windows deletion missing")
        path, replacement = self.root / "owned.patch_0", self.root / "foreign-replacement"
        path.write_bytes(b"owned")
        replacement.write_bytes(b"foreign")
        expected = sha(b"owned")
        native_hasher = self.api.hashlib.sha256
        observed = []
        owner = self
        class ProbeHasher:
            def __init__(self):
                self.inner = native_hasher()
            def update(self, data):
                self.inner.update(data)
            def hexdigest(self):
                with owner.assertRaises(OSError):
                    os.replace(replacement, path)
                observed.append("replacement-denied")
                with owner.assertRaises(OSError):
                    path.write_bytes(b"foreign write after hash")
                observed.append("write-denied")
                return self.inner.hexdigest()
        with patch.object(self.api.hashlib, "sha256", side_effect=ProbeHasher):
            self.api._delete_owned_overlay(path, expected)
        self.assertEqual(observed, ["replacement-denied", "write-denied"])
        self.assertFalse(path.exists())
        self.assertEqual(replacement.read_bytes(), b"foreign")

    def test_owned_delete_fails_closed_when_writer_already_holds_file(self):
        self.assertTrue(callable(getattr(self.api, "_delete_owned_overlay", None)),
                        "same-handle verified Windows deletion missing")
        path = self.root / "writer.patch_0"
        path.write_bytes(b"owned")
        with path.open("ab"):
            with self.assertRaises(OSError):
                self.api._delete_owned_overlay(path, sha(b"owned"))
        self.assertEqual(path.read_bytes(), b"owned")

    def test_boot_candidate_and_receipt_are_locked_through_strict_v1_install(self):
        self.build()
        other_wrapper = self.root / "other-wrapper.luac"
        other_wrapper.write_bytes(WRAPPER + b"different-but-valid")
        other_boot = self.root / "other-boot.archive"
        patcher.build_candidate(self.contents / patcher.ARCHIVE_NAME, other_wrapper, other_boot,
                                expected_original_sha256=sha(self.original))
        replacement = other_boot.read_bytes()
        replacement_receipt = Path(str(other_boot) + ".json").read_bytes()
        native_install = patcher.install
        attempted = []
        def replace_during_install(*args, **kwargs):
            for path, data in ((self.candidate / "boot.archive", replacement),
                               (self.candidate / "boot.archive.json", replacement_receipt)):
                with self.assertRaises(OSError):
                    path.write_bytes(data)
                attempted.append(path.name)
            return native_install(*args, **kwargs)
        with patch.object(patcher, "install", side_effect=replace_during_install):
            receipt = self.install()
        self.assertEqual(attempted, ["boot.archive", "boot.archive.json"])
        self.assertEqual(sha((self.contents / patcher.ARCHIVE_NAME).read_bytes()),
                         receipt["boot_receipt"]["candidate_sha256"])
        self.restore()

    def test_non_windows_install_refuses_before_any_filesystem_mutation(self):
        self.build()
        with patch.object(self.api.os, "name", "posix"):
            try:
                self.install()
            except patcher.PatchError:
                pass
            except Exception as error:
                self.fail(f"Missing early Windows guard: {type(error).__name__}: {error}")
            else:
                self.fail("Non-Windows install accepted")
        self.assertFalse(self.state.exists())
        self.assertFalse(any((self.contents / (name + ".patch_0")).exists() for name in NAMES))

    def test_foreign_patch_arriving_during_final_boot_validation_prevents_activation(self):
        self.build()
        validate = self.api._boot_candidate
        count = 0
        def change_during_boot_validation(path, pins):
            nonlocal count
            value = validate(path, pins)
            count += 1
            if count == 3:
                (self.contents / "ffffffffffffffff.patch_0").write_bytes(b"foreign during BOOT validation")
            return value
        with patch.object(self.api, "_boot_candidate", side_effect=change_during_boot_validation):
            with self.assertRaises(patcher.PatchError):
                self.install()
        self.assertEqual((self.contents / patcher.ARCHIVE_NAME).read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
