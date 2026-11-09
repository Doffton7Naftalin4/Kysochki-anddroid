"""Private HELLDIVERS 0.12.2 preview installer with guarded native overlays."""
import sys

if sys.version_info < (3, 10):
    print("Se requiere Python 3.10 o superior.", file=sys.stderr)
    raise SystemExit(2)

import argparse
import os
from pathlib import Path
import subprocess

import build_mod as builder
from package import patcher

VERSION = "0.12.2"
ROOT = Path(__file__).resolve().parent
STATE = ROOT / "state"
DEFAULT_GAME = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers")
UNKNOWN_TARGET = (
    "El archivo del juego no es el original fijado ni este candidato 0.12.2. "
    "Si estaba instalada una version anterior, ejecuta Restaurar.cmd de esa version antes de instalar 0.12.2. "
    "Conserva la carpeta y el respaldo anteriores; no fuerces archivos."
)


def validate_candidate(candidate):
    manifest_path = Path(str(candidate) + ".json")
    receipt_path = candidate.parent / "build-receipt.json"
    patcher._require(all(path.is_file() for path in (candidate, manifest_path, receipt_path)),
                     "Candidato local incompleto; no se regenerara ni forzara.")
    manifest = patcher._read_json(manifest_path)
    receipt = patcher._read_json(receipt_path)
    patcher._receipt_valid(manifest, patcher.CANDIDATE_KIND, patcher.ORIGINAL_SHA256)
    patcher._receipt_valid(receipt, patcher.CANDIDATE_KIND, patcher.ORIGINAL_SHA256)
    patcher._require(all(receipt.get(key) == value for key, value in manifest.items()),
                     "Los recibos del candidato local no coinciden.")
    for source, key in (("sky.lua", "sky_sha256"), ("mod.lua", "module_sha256"), ("view.lua", "view_sha256"), ("aim.lua", "aim_sha256"), ("pose.lua", "pose_sha256"), ("actions.lua", "actions_sha256"), ("stratagems.lua", "stratagems_sha256")):
        patcher._require(receipt.get(key) == patcher.digest(patcher._read(ROOT / source)),
                         source + " cambio desde la compilacion o falta su hash; no se reutilizara el candidato.")
    return manifest


def candidate_for(game):
    output = ROOT / "build" / ("v" + VERSION)
    candidate = output / "candidate.archive"
    manifest_path = Path(str(candidate) + ".json")
    receipt_path = output / "build-receipt.json"
    target = game / "contents" / patcher.ARCHIVE_NAME
    if any(path.exists() for path in (candidate, manifest_path, receipt_path)):
        manifest = validate_candidate(candidate)
    else:
        patcher._require(patcher.digest(patcher._read(target)) == patcher.ORIGINAL_SHA256,
                         UNKNOWN_TARGET)
        print("Compilando candidato 0.12.2 con el archivo original de este PC...")
        builder.build(target)
        manifest = validate_candidate(candidate)
    patcher._require(patcher.digest(patcher._read(target)) in
                     (patcher.ORIGINAL_SHA256, manifest["candidate_sha256"]), UNKNOWN_TARGET)
    return candidate


def native_candidate_for(game):
    from package import overlay
    boot = candidate_for(game)
    output = boot.parent / "native"
    if output.exists():
        overlay.verify_candidate(game, output)
    else:
        print("Generando controlador nativo desde los paquetes originales locales...")
        overlay.build_candidate(game, boot, output)
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description="HD Camera 0.12.2 Preview: prueba privada experimental.")
    parser.add_argument("command", choices=("install", "restore"))
    parser.add_argument("game", nargs="?", type=Path, default=DEFAULT_GAME,
                        help="Carpeta de HELLDIVERS; usar la misma para instalar y restaurar.")
    args = parser.parse_args(argv)
    try:
        patcher._require(os.name == "nt", "Solo compatible con Windows.")
        patcher._require(builder.VERSION == VERSION, "Version del builder inesperada.")
        game = args.game.resolve()
        patcher._locations(game, STATE)
        from package import overlay
        if args.command == "install":
            receipt = overlay.install(game, native_candidate_for(game), STATE)
            print("Instalado y hash comprobado. Empieza OFF; F8 activa/desactiva.")
            print("F9 cambia TOP -> SHOULDER -> FIRST. Revisa el estado en el titulo.")
            print("F10 compara pose corporal BODY ON/OFF sin cambiar camara ni apuntado.")
        else:
            receipt = overlay.restore(game, STATE)
            print("Original restaurado y hash comprobado.")
        print("Estado:", receipt["status"])
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Operacion rechazada: " + str(error), file=sys.stderr)
        print("No fuerces ni borres state. Conserva carpeta y error para revisar.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
