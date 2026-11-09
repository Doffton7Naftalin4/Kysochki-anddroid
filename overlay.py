"""Pinned native-graph overlays plus the unchanged strict BOOT patcher.

Build outputs stay outside the game. Installation creates three absent overlay
files, then installs BOOT through patcher v1. Restore reverses that order. Each
publication is atomic; the durable v2 journal makes partial transactions visible.
No game resource is included in this module or needed merely to import it.
"""
from __future__ import annotations

import argparse
from collections import OrderedDict
from contextlib import contextmanager, ExitStack
import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import zlib

from . import patcher

PatchError = patcher.PatchError
require = patcher._require
BASE_NAMES = ("21f858a58ab6cce7", "68e5a323f59aa64c", "ec181385e7000cf1")
OVERLAY_NAMES = tuple(name + ".patch_0" for name in BASE_NAMES)
GRAPH_KIND, GRAPH_PATH = 0xA486D4045106165C, 0x4D817700197E8EE5
CANDIDATE_KIND, STATE_KIND = "helldivers-camera-candidate-v2", "helldivers-camera-install-v2"
BOOT_FILE, MANIFEST_FILE = "boot.archive", "manifest.json"
PINNED = {
    "boot_sha256": patcher.ORIGINAL_SHA256,
    "base_sha256": {
        BASE_NAMES[0]: "73544bc55b35bed8c2016e838e08752106786204d10d493f242917b295093479",
        BASE_NAMES[1]: "25cc2189cb6722eb38f78cfdc885721a4c82470584640a87d8b2916b01e39d52",
        BASE_NAMES[2]: "035e6b4914d1e66a60caab5aa2a746e38acbf28d50c959752b2b56c7a7990d91",
    },
    "preserve_sha256": {
        "bundle_database.data": "9be2583235f3972f35c3606e33fb5b1be2dcbb5792bbf449e480e12804f929d6",
        BASE_NAMES[0] + ".stream": "6f73f7f55de4de0d193d4ff0ad24f711fa3f8395cc6116da7a2bae7e5c6b9406",
        BASE_NAMES[1] + ".stream": "4f9fab1844a375ff651b89a09c5926c6d1d9eb342638a3b41864ec858f4531f5",
        BASE_NAMES[2] + ".stream": "b0d5ef65fd0787dba9a2f87ef67e239a8d367e67ce8a9452238c7594cf71c198",
    },
    "graph_sha256": "46e1a4590c324a47eda0180f66c75f77ac1cada09eeee68ccf78d6ac2cfb40b4",
    "header_sha256": "40887ae4ad3804185b603dd2561df7a5f49a81e1426446016e5a8b8b9d2a126b",
}


def _safe_path(path):
    path = Path(path).absolute()
    for part in (path, *path.parents):
        require(not part.is_symlink() and not (hasattr(part, "is_junction") and part.is_junction()),
                f"Symlink or junction path refused: {part}")
    return path.resolve()


def file_digest(path):
    path = _safe_path(path)
    require(path.is_file(), f"Expected regular file: {path}")
    with path.open("rb") as stream:
        hasher = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
        return hasher.hexdigest()


def _valid_digest(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def _pins_valid(pins):
    require(isinstance(pins, dict) and set(pins) == set(PINNED), "Invalid pin profile")
    require(isinstance(pins["base_sha256"], dict) and set(pins["base_sha256"]) == set(BASE_NAMES),
            "Exactly three pinned source archives required")
    require(isinstance(pins["preserve_sha256"], dict)
            and set(pins["preserve_sha256"]) == set(PINNED["preserve_sha256"]),
            "Database and all three stream files must stay pinned")
    values = [pins["boot_sha256"], pins["graph_sha256"], pins["header_sha256"],
              *pins["base_sha256"].values(), *pins["preserve_sha256"].values()]
    require(all(_valid_digest(value) for value in values), "Malformed pinned hash")


class Bundle:
    """Bounded random reads over the original independently compressed chunks."""
    def __init__(self, path):
        self.path = _safe_path(path)
        self.blocks, self.cache = [], OrderedDict()
        self.decoded_blocks = 0
        require(self.path.is_file(), "Missing source bundle")
        physical_size = self.path.stat().st_size
        with self.path.open("rb") as stream:
            header = stream.read(12)
            require(len(header) == 12, "Truncated source archive")
            magic, self.size, reserved = struct.unpack("<III", header)
            require(magic == 0xF0000004 and reserved == 0 and self.size > 0,
                    "Unsupported source archive")
            while stream.tell() < physical_size:
                raw = stream.read(4)
                require(len(raw) == 4, "Truncated source chunk length")
                length, = struct.unpack("<I", raw)
                require(0 < length <= 66560 and stream.tell() + length <= physical_size,
                        "Truncated or oversized source chunk")
                self.blocks.append((stream.tell(), length))
                stream.seek(length, 1)
        require(len(self.blocks) == (self.size + 65535) // 65536, "Source archive chunk count mismatch")

    def at(self, position, length):
        require(0 <= position <= self.size and 0 <= length <= self.size - position,
                "Source resource offset outside declared archive")
        result = bytearray()
        while length:
            index, offset = divmod(position, 65536)
            if index not in self.cache:
                start, count = self.blocks[index]
                with self.path.open("rb") as stream:
                    stream.seek(start)
                    packed = stream.read(count)
                require(len(packed) == count, "Source archive changed during read")
                if count == 65536:
                    raw = packed
                else:
                    decoder = zlib.decompressobj()
                    try:
                        raw = decoder.decompress(packed, 65537)
                    except zlib.error as error:
                        raise PatchError("Invalid source chunk") from error
                    require(decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail,
                            "Invalid compressed source chunk")
                minimum = min(65536, self.size - index * 65536)
                require(minimum <= len(raw) <= 65536, "Invalid expanded source chunk")
                self.cache[index] = raw
                self.decoded_blocks += 1
                if len(self.cache) > 8:
                    self.cache.popitem(last=False)
            raw = self.cache[index]
            self.cache.move_to_end(index)
            take = min(length, len(raw) - offset)
            require(take > 0, "Short expanded source chunk")
            result.extend(raw[offset:offset + take])
            position += take
            length -= take
        return bytes(result)

    def graph_resource(self):
        count, = struct.unpack("<I", self.at(0, 4))
        require(0 < count <= 100000 and 260 + count * 16 <= self.size, "Invalid source resource index")
        index = list(struct.iter_unpack("<QQ", self.at(260, count * 16)))
        require(index == sorted(set(index)), "Unsorted or duplicate source resource index")
        require(index.count((GRAPH_KIND, GRAPH_PATH)) == 1, "Expected exactly one player graph resource")
        position = 260 + count * 16
        for identity in index:
            kind, name, variants, stream_offset = struct.unpack("<QQII", self.at(position, 24))
            require((kind, name) == identity and 0 < variants <= 65536, "Invalid source resource header")
            position += 24
            headers = list(struct.iter_unpack("<III", self.at(position, variants * 12)))
            position += variants * 12
            size = sum(header[1] for header in headers)
            require(size <= self.size - position, "Source inline data outside archive")
            if identity == (GRAPH_KIND, GRAPH_PATH):
                # With stream_size=0 this offset can still be the cumulative
                # offset of preceding streamed resources. It is not consumed.
                require(variants == 1 and headers[0][0] == 0 and headers[0][2] == 0,
                        "Player graph must have one inline language-0 variant")
                return self.at(position, headers[0][1])
            position += size
        raise PatchError("Player graph not found")


def _generate_graph(original):
    from .native_state_graph import Graph, build_pose_twins
    return build_pose_twins(Graph.parse(original)).graph.to_bytes()


def _sources(game_dir, pins):
    _pins_valid(pins)
    game = _safe_path(game_dir)
    contents = _safe_path(game / "contents")
    require(contents.is_dir() and contents.is_relative_to(game), "Invalid game contents directory")
    _unchanged_sources(contents, pins)
    originals, headers = [], []
    for name in BASE_NAMES:
        bundle = Bundle(contents / name)
        header, graph = bundle.at(4, 256), bundle.graph_resource()
        require(patcher.digest(header) == pins["header_sha256"], "Unexpected source package magic")
        require(patcher.digest(graph) == pins["graph_sha256"], "Unexpected original player graph")
        headers.append(header)
        originals.append(graph)
    require(len(set(headers)) == len(set(originals)) == 1, "Source graph copies are not identical")
    return game, contents, headers[0], originals[0]


def _unchanged_sources(contents, pins):
    for name, expected in {**pins["base_sha256"], **pins["preserve_sha256"]}.items():
        require(file_digest(contents / name) == expected, f"Pinned game file changed: {name}")


def _overlay_bytes(header, graph):
    identity = struct.pack("<QQ", GRAPH_KIND, GRAPH_PATH)
    payload = struct.pack("<I", 1) + header + identity
    payload += struct.pack("<QQIIIII", GRAPH_KIND, GRAPH_PATH, 1, 0, 0, len(graph), 0) + graph
    result = patcher.encode_archive(payload)
    require(patcher.decode_archive(result) == payload, "Overlay compression roundtrip failed")
    return result


def _boot_candidate(path, pins):
    path = _safe_path(path)
    manifest = patcher._read_json(_safe_path(str(path) + ".json"))
    patcher._receipt_valid(manifest, patcher.CANDIDATE_KIND, pins["boot_sha256"])
    data = patcher._read(path)
    require(patcher.digest(data) == manifest["candidate_sha256"], "BOOT candidate hash mismatch")
    wrapper = patcher.boot_bytecode(patcher.decode_archive(data))
    require(patcher.digest(wrapper) == manifest["wrapper_sha256"], "BOOT wrapper hash mismatch")
    return data, manifest


def _manifest(pins, boot, overlay, graph):
    return {"kind": CANDIDATE_KIND, "version": "0.12.2", "graph_kind": f"{GRAPH_KIND:016x}",
            "graph_path": f"{GRAPH_PATH:016x}", "pins": copy.deepcopy(pins),
            "overlays": list(OVERLAY_NAMES), "overlay_sha256": patcher.digest(overlay),
            "generated_graph_sha256": patcher.digest(graph), "boot_receipt": boot}


def build_candidate(game_dir, boot_candidate_path, output_dir, *, pins=PINNED):
    game, _, header, original = _sources(game_dir, pins)
    output = _safe_path(output_dir)
    patcher._outside(output, game)
    require(output.parent.is_dir() and not output.exists(), "Candidate output must be a new directory")
    boot_path = _safe_path(boot_candidate_path)
    patcher._outside(boot_path, game)
    boot, boot_manifest = _boot_candidate(boot_path, pins)
    graph = _generate_graph(original)
    overlay = _overlay_bytes(header, graph)
    manifest = _manifest(pins, boot_manifest, overlay, graph)
    output.mkdir()
    for name, data in [(BOOT_FILE, boot), (BOOT_FILE + ".json", patcher._json_bytes(boot_manifest)),
                       *((name, overlay) for name in OVERLAY_NAMES),
                       (MANIFEST_FILE, patcher._json_bytes(manifest))]:
        patcher._atomic_write(output / name, data, replace=False)
    return manifest


def verify_candidate(game_dir, candidate_dir, *, pins=PINNED):
    game, _, header, original = _sources(game_dir, pins)
    candidate = _safe_path(candidate_dir)
    patcher._outside(candidate, game)
    expected_names = {BOOT_FILE, BOOT_FILE + ".json", MANIFEST_FILE, *OVERLAY_NAMES}
    require(candidate.is_dir() and {path.name for path in candidate.iterdir()} == expected_names,
            "Candidate directory contains missing or unexpected files")
    for name in expected_names:
        _safe_path(candidate / name)
    _, boot_manifest = _boot_candidate(candidate / BOOT_FILE, pins)
    graph = _generate_graph(original)
    overlay = _overlay_bytes(header, graph)
    expected = _manifest(pins, boot_manifest, overlay, graph)
    require(patcher._read_json(candidate / MANIFEST_FILE) == expected, "Candidate v2 manifest mismatch")
    for name in OVERLAY_NAMES:
        require(patcher._read(candidate / name) == overlay, "Overlay differs from pinned native graph derivation")
    return expected


def _locations(game_dir, state_dir):
    game, state = _safe_path(game_dir), _safe_path(state_dir)
    patcher._outside(state, game)
    contents = _safe_path(game / "contents")
    require(contents.is_dir() and contents.is_relative_to(game), "Invalid game contents directory")
    return game, contents, state


def _patches(contents, owned_hash=None):
    for path in contents.iterdir():
        if ".patch_" not in path.name.casefold():
            continue
        require(owned_hash is not None and path.name in OVERLAY_NAMES,
                f"Foreign patch file refused: {path.name}")
        require(file_digest(path) == owned_hash, f"Owned overlay changed: {path.name}")


def _journal_valid(journal, game, pins, overlay_hash):
    require(isinstance(journal, dict) and journal.get("kind") == STATE_KIND
            and journal.get("game_dir") == str(game) and journal.get("pins") == pins
            and journal.get("overlays") == list(OVERLAY_NAMES)
            and journal.get("overlay_sha256") == overlay_hash,
            "Unrecognized or conflicting v2 install journal")
    patcher._receipt_valid(journal.get("boot_receipt", {}), patcher.CANDIDATE_KIND, pins["boot_sha256"])
    require(journal.get("status") in {"prepared", "installed", "restored", "rolled_back", "recovery_required"},
            "Unknown v2 transaction status")


def _preflight_boot(contents, state, candidate, pins):
    current = patcher._read(_safe_path(contents / patcher.ARCHIVE_NAME))
    backup_path = _safe_path(state / "boot_state" / "original.archive")
    original = patcher._read(backup_path) if backup_path.exists() else current
    require(patcher.digest(original) == pins["boot_sha256"], "Pinned original BOOT backup unavailable")
    boot, manifest = _boot_candidate(candidate / BOOT_FILE, pins)
    require(patcher.digest(current) in {pins["boot_sha256"], manifest["candidate_sha256"]},
            "Unknown current BOOT archive")
    wrapper = patcher.boot_bytecode(patcher.decode_archive(boot))
    require(patcher.decode_archive(boot) == patcher.replace_lua(patcher.decode_archive(original), wrapper),
            "Candidate changes data outside the permitted BOOT replacement")


def _write_journal(state, journal):
    path = state / "receipt.json"
    patcher._atomic_write(path, patcher._json_bytes(journal), replace=path.exists())


@contextmanager
def _locked_windows_file(path, *, delete=False):
    """Keep the exact file identity stable; deny concurrent writes and renames."""
    require(os.name == "nt", "Native overlay mutation requires Windows file-handle guards")
    import ctypes
    from ctypes import wintypes
    path = _safe_path(path)
    require(path.is_file(), f"Expected regular guarded file: {path}")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                  ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel.CloseHandle.restype = wintypes.BOOL
    name = str(path)
    name = "\\\\?\\UNC\\" + name[2:] if name.startswith("\\\\") else "\\\\?\\" + name
    # GENERIC_READ (+DELETE when requested), FILE_SHARE_READ, OPEN_EXISTING,
    # FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT. Never truncate/create.
    handle = kernel.CreateFileW(name, 0x80000000 | (0x10000 if delete else 0), 1,
                                None, 3, 0x200080, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        yield kernel, handle
    finally:
        kernel.CloseHandle(handle)


def _delete_owned_overlay(path, expected_hash):
    """Hash and mark deletion through ONE handle, never digest-then-path-unlink."""
    import ctypes
    from ctypes import wintypes
    with _locked_windows_file(path, delete=True) as (kernel, handle):
        kernel.ReadFile.argtypes = (wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                                    ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p)
        kernel.ReadFile.restype = wintypes.BOOL
        kernel.SetFileInformationByHandle.argtypes = (wintypes.HANDLE, ctypes.c_int,
                                                      ctypes.c_void_p, wintypes.DWORD)
        kernel.SetFileInformationByHandle.restype = wintypes.BOOL
        hasher = hashlib.sha256()
        buffer = ctypes.create_string_buffer(1024 * 1024)
        length = wintypes.DWORD()
        while True:
            if not kernel.ReadFile(handle, buffer, len(buffer), ctypes.byref(length), None):
                raise ctypes.WinError(ctypes.get_last_error())
            if length.value == 0:
                break
            hasher.update(buffer.raw[:length.value])
        require(hasher.hexdigest() == expected_hash, "Owned overlay changed before guarded deletion")
        class FileDispositionInfo(ctypes.Structure):
            _fields_ = [("DeleteFile", ctypes.c_ubyte)]
        disposition = FileDispositionInfo(1)
        # FileDispositionInfo enum=4; the deletion applies to this open file,
        # with WRITE/DELETE sharing denied until CloseHandle completes it.
        if not kernel.SetFileInformationByHandle(handle, 4, ctypes.byref(disposition), ctypes.sizeof(disposition)):
            raise ctypes.WinError(ctypes.get_last_error())


def _restore_locked(game, contents, state, journal, pins, *, status):
    _patches(contents, journal["overlay_sha256"])
    boot_state = _safe_path(state / "boot_state")
    boot_receipt_path = _safe_path(boot_state / "receipt.json")
    if boot_receipt_path.exists():
        receipt = patcher._read_json(boot_receipt_path)
        require(receipt.get("candidate_sha256") == journal["boot_receipt"]["candidate_sha256"],
                "BOOT state and v2 journal disagree")
        patcher.restore(game, boot_state, expected_original_sha256=pins["boot_sha256"])
    else:
        require(file_digest(contents / patcher.ARCHIVE_NAME) == pins["boot_sha256"],
                "BOOT changed without a recoverable v1 receipt")
    # Original BOOT is established before removing any overlay.
    require(file_digest(contents / patcher.ARCHIVE_NAME) == pins["boot_sha256"], "BOOT restoration incomplete")
    for name in OVERLAY_NAMES:
        path = _safe_path(contents / name)
        if path.exists():
            patcher._game_closed()
            _delete_owned_overlay(path, journal["overlay_sha256"])
    journal["status"] = status
    _write_journal(state, journal)
    return journal


def install(game_dir, candidate_dir, state_dir, *, pins=PINNED):
    require(os.name == "nt", "Native overlay installation requires Windows file-handle guards")
    patcher._game_closed()
    game, contents, state = _locations(game_dir, state_dir)
    candidate = _safe_path(candidate_dir)
    manifest = verify_candidate(game, candidate, pins=pins)
    receipt_path = _safe_path(state / "receipt.json")
    with patcher._state_lock(state):
        previous = patcher._read_json(receipt_path) if receipt_path.exists() else None
        if previous is not None:
            _journal_valid(previous, game, pins, manifest["overlay_sha256"])
            require(previous["boot_receipt"] == manifest["boot_receipt"], "State belongs to another BOOT candidate")
            if previous["status"] == "installed":
                _preflight_boot(contents, state, candidate, pins)
                _patches(contents, manifest["overlay_sha256"])
                require(all((contents / name).is_file() for name in OVERLAY_NAMES), "Installed overlay is missing")
                require(file_digest(contents / patcher.ARCHIVE_NAME) == manifest["boot_receipt"]["candidate_sha256"],
                        "Installed BOOT changed")
                return previous
            require(previous["status"] in {"restored", "rolled_back"},
                    "Incomplete transaction: restore from the prepared v2 journal first")
        _patches(contents)
        _preflight_boot(contents, state, candidate, pins)
        journal = {"kind": STATE_KIND, "game_dir": str(game), "pins": copy.deepcopy(pins),
                   "overlays": list(OVERLAY_NAMES), "overlay_sha256": manifest["overlay_sha256"],
                   "boot_receipt": manifest["boot_receipt"], "status": "prepared"}
        _write_journal(state, journal)
        try:
            for name in OVERLAY_NAMES:
                patcher._game_closed()
                path = _safe_path(contents / name)
                artifact = patcher._read(_safe_path(candidate / name))
                require(patcher.digest(artifact) == manifest["overlay_sha256"],
                        "Overlay candidate changed before publication")
                patcher._atomic_write(path, artifact, replace=False)
                require(file_digest(path) == manifest["overlay_sha256"], "Overlay publication hash mismatch")
            _patches(contents, manifest["overlay_sha256"])
            _unchanged_sources(contents, pins)
            _patches(contents, manifest["overlay_sha256"])
            with ExitStack() as locked:
                for name in (BOOT_FILE, BOOT_FILE + ".json"):
                    locked.enter_context(_locked_windows_file(candidate / name))
                _, final_boot_manifest = _boot_candidate(candidate / BOOT_FILE, pins)
                require(final_boot_manifest == manifest["boot_receipt"],
                        "BOOT candidate changed after v2 verification")
                _patches(contents, manifest["overlay_sha256"])
                boot_result = patcher.install(game, candidate / BOOT_FILE, _safe_path(state / "boot_state"),
                                              expected_original_sha256=pins["boot_sha256"])
                require(boot_result["candidate_sha256"] == manifest["boot_receipt"]["candidate_sha256"]
                        and file_digest(contents / patcher.ARCHIVE_NAME) == boot_result["candidate_sha256"],
                        "Installed BOOT identity differs from prepared v2 journal")
            journal["status"] = "installed"
            _write_journal(state, journal)
            return journal
        except Exception as error:
            try:
                _restore_locked(game, contents, state, journal, pins, status="rolled_back")
            except Exception as rollback_error:
                journal["status"] = "recovery_required"
                _write_journal(state, journal)
                raise PatchError(f"Install failed; rollback requires review: {rollback_error}") from error
            raise


def restore(game_dir, state_dir, *, pins=PINNED):
    require(os.name == "nt", "Native overlay restoration requires Windows file-handle guards")
    patcher._game_closed()
    game, contents, state = _locations(game_dir, state_dir)
    _, _, header, original = _sources(game, pins)
    overlay_hash = patcher.digest(_overlay_bytes(header, _generate_graph(original)))
    with patcher._state_lock(state):
        journal = patcher._read_json(_safe_path(state / "receipt.json"))
        _journal_valid(journal, game, pins, overlay_hash)
        return _restore_locked(game, contents, state, journal, pins, status="restored")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("build", "verify", "install", "restore"):
        command = commands.add_parser(name)
        command.add_argument("game_dir", type=Path)
        if name == "build":
            command.add_argument("boot_candidate", type=Path)
            command.add_argument("output_dir", type=Path)
        elif name in {"verify", "install"}:
            command.add_argument("candidate_dir", type=Path)
        if name in {"install", "restore"}:
            command.add_argument("state_dir", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            result = build_candidate(args.game_dir, args.boot_candidate, args.output_dir)
        elif args.command == "verify":
            result = verify_candidate(args.game_dir, args.candidate_dir)
        elif args.command == "install":
            result = install(args.game_dir, args.candidate_dir, args.state_dir)
        else:
            result = restore(args.game_dir, args.state_dir)
        print(json.dumps(result, sort_keys=True, indent=2))
        return 0
    except (PatchError, OSError, ValueError) as error:
        print(f"Refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
