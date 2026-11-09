"""Guarded Helldivers (2015) boot-Lua archive patcher. Python stdlib only.

Format reference: https://github.com/Zekfad/helldivers/tree/master/formats
The command line accepts only the pinned original archive. Library callers may
specify an expected hash explicitly for controlled fixtures or another reviewed cut.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import csv
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib

ORIGINAL_SHA256 = "5ded3de9994ced0ee70597115c46c3604b754897b10de689c5b127ea8b1750a8"
ARCHIVE_NAME = "9e13b2414b41b842"
LUA_KIND = 0xA14E8DFA2CD117E2
BOOT_PATH = 0x37048A618ABDDC81
CHUNK_SIZE = 65536
MAX_EXPANDED_SIZE = 1024 * 1024 * 1024
CANDIDATE_KIND = "helldivers-camera-candidate-v1"
STATE_KIND = "helldivers-camera-install-v1"


class PatchError(ValueError):
    """Input or local state cannot be verified; no game replacement is allowed."""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _require(condition, message):
    if not condition:
        raise PatchError(message)


def decode_archive(data: bytes) -> bytes:
    _require(len(data) >= 12, "Truncated archive header")
    magic, size, reserved = struct.unpack_from("<III", data)
    _require(magic == 0xF0000004 and reserved == 0, "Unsupported archive header")
    _require(0 < size <= MAX_EXPANDED_SIZE, "Invalid expanded size")
    expanded = bytearray()
    offset = 12
    while offset < len(data):
        _require(offset + 4 <= len(data), "Truncated chunk length")
        length, = struct.unpack_from("<I", data, offset)
        offset += 4
        _require(0 < length <= CHUNK_SIZE + 1024 and offset + length <= len(data),
                 "Invalid or truncated chunk")
        packed = data[offset:offset + length]
        offset += length
        if length == CHUNK_SIZE:
            raw = packed
        else:
            try:
                decoder = zlib.decompressobj()
                raw = decoder.decompress(packed, CHUNK_SIZE + 1)
                _require(decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail,
                         "Incomplete, concatenated or oversized compressed chunk")
            except zlib.error as error:
                raise PatchError("Invalid zlib chunk") from error
        _require(0 < len(raw) <= CHUNK_SIZE, "Invalid expanded chunk length")
        _require(offset == len(data) or len(raw) == CHUNK_SIZE, "Short non-final chunk")
        expanded.extend(raw)
        _require(len(expanded) <= ((size + CHUNK_SIZE - 1) // CHUNK_SIZE) * CHUNK_SIZE,
                 "Archive expands beyond declared size and final padding")
    _require(len(expanded) >= size, "Expanded data shorter than declaration")
    _require(not any(expanded[size:]), "Nonzero data beyond declared size")
    return bytes(expanded[:size])


def encode_archive(payload: bytes) -> bytes:
    _require(0 < len(payload) <= MAX_EXPANDED_SIZE, "Invalid payload size")
    result = bytearray(struct.pack("<III", 0xF0000004, len(payload), 0))
    for offset in range(0, len(payload), CHUNK_SIZE):
        raw = payload[offset:offset + CHUNK_SIZE].ljust(CHUNK_SIZE, b"\0")
        packed = zlib.compress(raw, 9)
        if len(packed) >= CHUNK_SIZE:
            packed = raw
        result.extend(struct.pack("<I", len(packed)))
        result.extend(packed)
    return bytes(result)


@dataclass(frozen=True)
class Variant:
    kind: int
    path: int
    variant_count: int
    header_offset: int
    data_offset: int
    inline_size: int
    stream_size: int


def parse_package(payload: bytes) -> tuple[int, list[Variant]]:
    _require(len(payload) >= 260, "Truncated package header")
    count, = struct.unpack_from("<I", payload)
    _require(0 < count <= 100000 and 260 + count * 16 <= len(payload), "Invalid package index")
    index = [struct.unpack_from("<QQ", payload, 260 + n * 16) for n in range(count)]
    offset = 260 + count * 16
    variants = []
    for identity in index:
        _require(offset + 24 <= len(payload), "Truncated resource header")
        kind, path, variant_count, _stream_offset = struct.unpack_from("<QQII", payload, offset)
        _require((kind, path) == identity, "Resource/index mismatch")
        _require(0 < variant_count <= 65536, "Invalid variant count")
        header_start = offset + 24
        offset = header_start + variant_count * 12
        _require(offset <= len(payload), "Truncated variant headers")
        for n in range(variant_count):
            header = header_start + n * 12
            _unknown, inline_size, stream_size = struct.unpack_from("<III", payload, header)
            _require(offset + inline_size <= len(payload), "Truncated variant data")
            variants.append(Variant(kind, path, variant_count, header, offset, inline_size, stream_size))
            offset += inline_size
    # Trailing opaque package bytes are deliberately retained unchanged.
    return count, variants


def _boot(payload: bytes) -> Variant:
    _, variants = parse_package(payload)
    targets = [v for v in variants if v.kind == LUA_KIND and v.path == BOOT_PATH]
    _require(len(targets) == 1, "Expected exactly one boot Lua resource")
    target = targets[0]
    _require(target.variant_count == 1 and target.stream_size == 0 and target.inline_size >= 8,
             "Unsupported boot resource variants or streaming")
    size, format_id = struct.unpack_from("<II", payload, target.data_offset)
    _require(format_id == 2 and size + 8 == target.inline_size, "Invalid boot LuaJIT resource")
    return target


def boot_bytecode(payload: bytes) -> bytes:
    target = _boot(payload)
    return payload[target.data_offset + 8:target.data_offset + target.inline_size]


def replace_lua(payload: bytes, wrapper: bytes) -> bytes:
    _require(wrapper.startswith(b"\x1bLJ\x01") and len(wrapper) >= 5,
             "Expected compiled LuaJIT 2.0 bytecode (dump version 1)")
    target = _boot(payload)
    inline = struct.pack("<II", len(wrapper), 2) + wrapper
    length_offset = target.header_offset + 4
    return (payload[:length_offset] + struct.pack("<I", len(inline))
            + payload[length_offset + 4:target.data_offset] + inline
            + payload[target.data_offset + target.inline_size:])


def _read(path: Path) -> bytes:
    _require(path.is_file() and not path.is_symlink(), f"Expected regular file: {path}")
    _require(path.stat().st_size <= MAX_EXPANDED_SIZE, f"File too large: {path}")
    return path.read_bytes()


def _outside(path: Path, directory: Path):
    _require(not path.is_relative_to(directory), f"Path must be outside game directory: {path}")


def _atomic_write(path: Path, data: bytes, *, replace: bool, expected_current_sha256=None):
    """Create a complete sibling first; publish atomically, never overwrite on create."""
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            if expected_current_sha256 is not None:
                _require(digest(_read(path)) == expected_current_sha256,
                         "Target changed before atomic replacement")
            os.replace(temporary, path)
        else:
            try:
                os.link(temporary, path)
            except FileExistsError as error:
                raise PatchError(f"Refusing existing file: {path}") from error
    finally:
        Path(temporary).unlink(missing_ok=True)


def _json_bytes(value: dict) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _read_json(path: Path) -> dict:
    try:
        value = json.loads(_read(path))
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise PatchError(f"Invalid JSON receipt: {path}") from error
    _require(isinstance(value, dict), "Receipt must be a JSON object")
    return value


def build_candidate(original_path, wrapper_path, output_path, *, expected_original_sha256=ORIGINAL_SHA256):
    original_path, wrapper_path, output_path = map(Path, (original_path, wrapper_path, output_path))
    original_path, wrapper_path, output_path = original_path.resolve(), wrapper_path.resolve(), output_path.resolve()
    _require(output_path not in (original_path, wrapper_path), "Output cannot overwrite input")
    if original_path.name == ARCHIVE_NAME and original_path.parent.name.casefold() == "contents":
        _outside(output_path, original_path.parent.parent)
    _require(not output_path.exists() and not Path(str(output_path) + ".json").exists(),
             "Candidate or receipt already exists")
    original = _read(original_path)
    _require(digest(original) == expected_original_sha256, "Original archive SHA256 is not the pinned cut")
    wrapper = _read(wrapper_path)
    payload = replace_lua(decode_archive(original), wrapper)
    candidate = encode_archive(payload)
    _require(decode_archive(candidate) == payload, "Candidate roundtrip verification failed")
    receipt = {"kind": CANDIDATE_KIND, "archive": ARCHIVE_NAME,
               "original_sha256": expected_original_sha256, "candidate_sha256": digest(candidate),
               "wrapper_sha256": digest(wrapper), "boot_path": f"{BOOT_PATH:016x}",
               "expanded_size": len(payload)}
    _require(output_path.parent.is_dir(), "Output parent directory does not exist")
    _atomic_write(output_path, candidate, replace=False)
    _atomic_write(Path(str(output_path) + ".json"), _json_bytes(receipt), replace=False)
    return receipt


def running_game_processes() -> list[str]:
    """Fail closed if process enumeration fails. No processes are stopped."""
    try:
        options = {"capture_output": True, "text": True, "errors": "replace", "check": True,
                   "timeout": 15}
        if os.name == "nt":
            result = subprocess.run(["tasklist", "/FO", "CSV", "/NH"],
                                    creationflags=subprocess.CREATE_NO_WINDOW, **options)
            names = [row[0] for row in csv.reader(io.StringIO(result.stdout)) if row]
        else:
            result = subprocess.run(["ps", "-A", "-o", "comm="], **options)
            names = [Path(line.strip()).name for line in result.stdout.splitlines()]
    except (OSError, subprocess.SubprocessError) as error:
        raise PatchError("Cannot verify game process state") from error
    return [name for name in names if name.casefold() in {"helldivers.exe", "helldivers64.exe", "helldivers"}]


def _game_closed():
    _require(not running_game_processes(), "Close Helldivers before changing game archives")


@contextmanager
def _state_lock(state: Path):
    state.mkdir(parents=True, exist_ok=True)
    lock = state / ".operation.lock"
    try:
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as error:
        raise PatchError("State directory locked; check no patcher is running before removing stale lock") from error
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(str(os.getpid()))
        yield
    finally:
        lock.unlink(missing_ok=True)


def _receipt_valid(receipt, kind, expected):
    _require(receipt.get("kind") == kind and receipt.get("archive") == ARCHIVE_NAME
             and receipt.get("original_sha256") == expected
             and receipt.get("boot_path") == f"{BOOT_PATH:016x}", "Unrecognized or conflicting receipt")
    for key in ("candidate_sha256", "wrapper_sha256"):
        value = receipt.get(key)
        _require(isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value),
                 f"Invalid receipt digest: {key}")


def _locations(game_dir, state_dir):
    game, state = Path(game_dir).resolve(), Path(state_dir).resolve()
    _outside(state, game)
    target = game / "contents" / ARCHIVE_NAME
    _require(target.resolve().is_relative_to(game) and not target.is_symlink(), "Unsafe archive path")
    return target, state


def install(game_dir, candidate_path, state_dir, *, expected_original_sha256=ORIGINAL_SHA256):
    _game_closed()
    target, state = _locations(game_dir, state_dir)
    candidate_path = Path(candidate_path).resolve()
    _outside(candidate_path, Path(game_dir).resolve())
    manifest = _read_json(Path(str(candidate_path) + ".json"))
    _receipt_valid(manifest, CANDIDATE_KIND, expected_original_sha256)
    candidate = _read(candidate_path)
    _require(digest(candidate) == manifest["candidate_sha256"], "Candidate SHA256 differs from build receipt")
    current = _read(target)
    _require(digest(current) in (expected_original_sha256, manifest["candidate_sha256"]),
             "Game archive changed; refusing unknown target content")
    with _state_lock(state):
        backup_path, receipt_path = state / "original.archive", state / "receipt.json"
        if receipt_path.exists():
            receipt = _read_json(receipt_path)
            _receipt_valid(receipt, STATE_KIND, expected_original_sha256)
            _require(receipt.get("target") == str(target)
                     and receipt["candidate_sha256"] == manifest["candidate_sha256"],
                     "State belongs to another target or candidate")
        else:
            _require(digest(current) == expected_original_sha256, "Patched target has no install receipt")
        if backup_path.exists():
            original = _read(backup_path)
            _require(digest(original) == expected_original_sha256, "Conflicting or modified backup")
        else:
            _require(digest(current) == expected_original_sha256, "Original backup is missing")
            original = current
        payload = decode_archive(candidate)
        wrapper = boot_bytecode(payload)
        _require(digest(wrapper) == manifest["wrapper_sha256"], "Wrapper SHA256 differs from build receipt")
        _require(payload == replace_lua(decode_archive(original), wrapper),
                 "Candidate changes data outside the permitted boot Lua replacement")
        if not backup_path.exists():
            _atomic_write(backup_path, original, replace=False)
        receipt = dict(manifest, kind=STATE_KIND, target=str(target), status="prepared")
        _atomic_write(receipt_path, _json_bytes(receipt), replace=receipt_path.exists())
        _game_closed()
        _require(_read(target) == current, "Game archive changed during preparation")
        if current != candidate:
            _atomic_write(target, candidate, replace=True, expected_current_sha256=digest(current))
        _require(digest(_read(target)) == manifest["candidate_sha256"], "Installed hash verification failed")
        receipt["status"] = "installed"
        _atomic_write(receipt_path, _json_bytes(receipt), replace=True)
        return receipt


def restore(game_dir, state_dir, *, expected_original_sha256=ORIGINAL_SHA256):
    _game_closed()
    target, state = _locations(game_dir, state_dir)
    receipt_path, backup_path = state / "receipt.json", state / "original.archive"
    receipt = _read_json(receipt_path)
    _receipt_valid(receipt, STATE_KIND, expected_original_sha256)
    _require(receipt.get("target") == str(target), "State belongs to a different game directory")
    with _state_lock(state):
        original, current = _read(backup_path), _read(target)
        _require(digest(original) == expected_original_sha256, "Original backup SHA256 changed")
        _require(digest(current) in (expected_original_sha256, receipt["candidate_sha256"]),
                 "Game archive changed; refusing to overwrite an unrelated update")
        _game_closed()
        _require(_read(target) == current, "Game archive changed during restoration")
        if current != original:
            _atomic_write(target, original, replace=True, expected_current_sha256=digest(current))
        _require(digest(_read(target)) == expected_original_sha256, "Restored hash verification failed")
        receipt["status"] = "restored"
        _atomic_write(receipt_path, _json_bytes(receipt), replace=True)
        return receipt


def inspect_archive(path) -> dict:
    archive = _read(Path(path))
    payload = decode_archive(archive)
    count, _ = parse_package(payload)
    wrapper = boot_bytecode(payload)
    return {"archive_sha256": digest(archive), "expanded_sha256": digest(payload),
            "expanded_size": len(payload), "resource_count": count,
            "boot_bytecode_sha256": digest(wrapper), "boot_bytecode_size": len(wrapper),
            "pinned_original": digest(archive) == ORIGINAL_SHA256}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inspect_parser = commands.add_parser("inspect", help="Read-only archive inspection")
    inspect_parser.add_argument("archive", type=Path)
    build_parser = commands.add_parser("build", help="Build candidate outside game installation")
    build_parser.add_argument("original", type=Path)
    build_parser.add_argument("wrapper", type=Path)
    build_parser.add_argument("output", type=Path)
    install_parser = commands.add_parser("install", help="Install verified candidate, saving original backup")
    install_parser.add_argument("game_dir", type=Path)
    install_parser.add_argument("candidate", type=Path)
    install_parser.add_argument("state_dir", type=Path)
    restore_parser = commands.add_parser("restore", help="Restore verified backup only over known content")
    restore_parser.add_argument("game_dir", type=Path)
    restore_parser.add_argument("state_dir", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "inspect":
            result = inspect_archive(args.archive)
        elif args.command == "build":
            result = build_candidate(args.original, args.wrapper, args.output)
        elif args.command == "install":
            result = install(args.game_dir, args.candidate, args.state_dir)
        else:
            result = restore(args.game_dir, args.state_dir)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (PatchError, OSError) as error:
        print(f"Refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
