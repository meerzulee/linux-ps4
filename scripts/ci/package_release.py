#!/usr/bin/env python3
"""Package one firmware-free kernel build and its complete corresponding source."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

TARGET = "6.18-baikal-mts2-public"
RELEASE = "6.18.44-ps4-baikal-mts2-public1"
MODULE = f"lib/modules/{RELEASE}/kernel/drivers/net/ethernet/psx_mts_net.ko"


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def check_config(text):
    if not re.search(r'^CONFIG_EXTRA_FIRMWARE=""$', text, re.M):
        raise ValueError("public kernel must not embed device firmware")
    for required in [f'CONFIG_LOCALVERSION="-{RELEASE.split("-", 1)[1]}"', "CONFIG_PS4_MTS=m"]:
        if required not in text.splitlines():
            raise ValueError(f"missing public build setting: {required}")


def source_files(source, patched_paths=()):
    raw = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=source)
    names = set(os.fsdecode(n) for n in raw.split(b"\0") if n)
    names.add(".config")
    names.update(patched_paths)
    result = []
    for name in sorted(names):
        p = Path(name)
        if p.is_absolute() or ".." in p.parts or ".git" in p.parts:
            raise ValueError(f"unsafe source archive path: {name}")
        # CONFIG_EXTRA_FIRMWARE is empty; no project firmware is corresponding source.
        if p.parts[0] == "firmware":
            raise ValueError("unexpected staged firmware in the public source tree")
        if (source / p).exists() or (source / p).is_symlink():
            result.append(name)
    for required in ["COPYING", ".config", "drivers/net/ethernet/psx_mts_net.c", "drivers/net/ethernet/mts_net_core.h"]:
        if required not in result:
            raise ValueError(f"incomplete corresponding source: {required}")
    return result


def main():
    repo = Path.cwd()
    output = repo / "output" / TARGET
    source = Path(os.environ.get("PS4_KERNEL_BUILD_ROOT", repo)) / "src" / TARGET
    if (output / "version.txt").read_text().strip() != RELEASE:
        raise ValueError("unexpected release")
    check_config((output / "config").read_text())
    check_config((source / ".config").read_text())
    subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=output, check=True)
    patched_paths = set()
    series = repo / "patches/6.18-baikal-mts2/series"
    for line in series.read_text().splitlines():
        name = line.split("#", 1)[0].strip()
        if not name:
            continue
        patch = (series.parent / name).resolve()
        raw = subprocess.check_output(["git", "apply", "--numstat", "-z", str(patch)])
        for entry in raw.split(b"\0"):
            if entry:
                patched_paths.add(os.fsdecode(entry.split(b"\t", 2)[2]))
    names = source_files(source, patched_paths)
    destination = repo / "dist"
    destination.mkdir(exist_ok=False)
    archive = f"modules-{RELEASE}.tar.zst"
    for name in ["bzImage", "config", "System.map", "manifest.txt", "version.txt", archive]:
        shutil.copy2(output / name, destination / name)
    shutil.copy2(output / "SHA256SUMS", destination / "BUILD-SHA256SUMS")
    shutil.copy2(repo / "bootargs/6.18-baikal-mts2-omarchy-usb.txt", destination / "bootargs.txt")
    (destination / "vram.txt").write_text("1024\n")
    shutil.copy2(repo / "docs/TESTING-MTS2-PUBLIC.md", destination / "TESTING.md")
    shutil.copy2(repo / "scripts/dev/activate-mts2-public", destination / "activate-mts2-public")
    with tempfile.TemporaryDirectory(prefix="ps4-release-") as directory:
        temporary = Path(directory)
        # Refuse archive paths/types that could escape the staging directory.
        listing = subprocess.check_output(["tar", "--zstd", "-tf", str(output / archive)]).decode().splitlines()
        if any(Path(n).is_absolute() or ".." in Path(n).parts or not n.startswith("lib/") for n in listing):
            raise ValueError("unsafe module archive")
        subprocess.run(["tar", "--zstd", "-xf", str(output / archive), "-C", str(temporary)], check=True)
        module = temporary / MODULE
        if module.is_symlink() or not module.is_file():
            raise ValueError("missing matching MTS module")
        if subprocess.check_output(["modinfo", "-F", "vermagic", str(module)]).decode().split()[0] != RELEASE:
            raise ValueError("MTS module release mismatch")
        note = temporary / "module-note.bin"
        subprocess.run(["objcopy", "--dump-section", f".note.gnu.build-id={note}", str(module)], check=True)
        manifest = {
            "schema": 1,
            "kernel_release": RELEASE,
            "kernel_config_sha256": digest(output / "config"),
            "module_path": "/usr/" + MODULE,
            "module_sha256": digest(module),
            "loaded_note_hex": note.read_bytes().hex(),
        }
        if not manifest["loaded_note_hex"]:
            raise ValueError("missing module build identity")
        (destination / "ethernet-candidate.json").write_text(json.dumps(manifest, indent=2) + "\n")
        inputs = temporary / "PS4-BUILD-INPUTS.tar.gz"
        # export-ignore excludes historical binary checkpoints and firmware from this archive.
        with inputs.open("wb") as stream:
            subprocess.run(["git", "archive", "--format=tar.gz", "--prefix=ps4-build-inputs/", "HEAD"], stdout=stream, check=True)
        with tarfile.open(inputs) as members:
            for member in members:
                name = member.name.removeprefix("ps4-build-inputs/")
                if name.startswith(("firmware/", "checkpoint/")) and member.isfile():
                    raise ValueError(f"unexpected historical asset in build inputs: {name}")
        shutil.copy2(output / "manifest.txt", temporary / "PS4-BUILD-MANIFEST.txt")
        (temporary / "PS4-REBUILD.md").write_text(
            "This tree contains the complete patched Linux source and resolved .config.\n"
            "PS4-BUILD-INPUTS.tar.gz supplies the target, ordered patches and build scripts.\n"
            "Use that repository's README and target6.18-baikal-mts2-public to rebuild,\n"
            "or compile this configured tree with ARCH=x86_64 LOCALVERSION= and the\n"
            "KBUILD_RELEASE_* values from the target. Native compiler identity is in\n"
            "PS4-BUILD-MANIFEST.txt. Firmware is deliberately not embedded or bundled.\n"
        )
        files = temporary / "source-files.list"
        files.write_bytes(b"\0".join(os.fsencode(n) for n in names) + b"\0")
        subprocess.run([
            "tar", "--zstd", "--sort=name", "--mtime=@1786233600", "--owner=0", "--group=0", "--numeric-owner",
            f"--transform=flags=r;s,^,linux-{RELEASE}/,", "-cf", str(destination / f"source-{RELEASE}.tar.zst"),
            "-C", str(source), "--null", "-T", str(files), "-C", str(temporary), "--no-null",
            "PS4-BUILD-INPUTS.tar.gz", "PS4-BUILD-MANIFEST.txt", "PS4-REBUILD.md",
        ], check=True, env={**os.environ, "ZSTD_CLEVEL": "8", "ZSTD_NBTHREADS": "2"})
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"]).decode().strip()
    run_url = f"https://github.com/{os.environ.get('GITHUB_REPOSITORY', 'meerzulee/linux-ps4')}/actions/runs/{os.environ.get('GITHUB_RUN_ID', 'local')}"
    (destination / "CI-BUILD.json").write_text(json.dumps({"commit": commit, "workflow_run": run_url, "target": TARGET, "release": RELEASE, "hardware_acceptance": "not tested; differs from private EXP016 build by release/config/compiler", "embedded_firmware": False, "module": manifest}, indent=2) + "\n")
    (destination / "RELEASE-NOTES.md").write_text(
        f"# Experimental PS4 Baikal Ethernet — {RELEASE}\n\n"
        "For advanced testers with a PS4 Slim Baikal B1 and a recoverable external Linux USB. "
        "PS4 Pro, other southbridges and PS5 are not qualified.\n\n"
        "The MTS2 Ethernet driver passed limited DHCP, bidirectional transfer and HTTPS tests "
        "in the private EXP016 build. **This public CI build has not been boot-tested.** "
        "It uses a separate release name and CONFIG_EXTRA_FIRMWARE=\"\"; firmware must be "
        "supplied separately in the compatible initramfs/rootfs. Built-in Wi-Fi may need "
        "firmware early in initramfs; do not assume it is available as recovery.\n\n"
        "Download bzImage AND the matching full modules archive, config, bootargs.txt, "
        "vram.txt, ethernet-candidate.json, activate-mts2-public, TESTING.md and SHA256SUMS. "
        "A compatible loader/initramfs/rootfs is required separately. The supplied command "
        "line is for an ext4 OMARCHY-PS4 partitioned USB and its Omarchy initramfs.\n\n"
        "Read TESTING.md before use. The explicit helper is one attempt per boot; nothing "
        "is enabled automatically. Do not unload/reset/rearm a published driver. Safe DMA "
        "drain, suspend, cable recovery and repeated boot qualification remain pending. "
        "The stable r1 release is unchanged.\n\n"
        f"Complete corresponding source: source-{RELEASE}.tar.zst (patched Linux, config, "
        "original license notices and this project's build inputs). No firmware, console "
        "payload, root filesystem, private capture or keys are included.\n\n"
        f"Source commit: {commit}\n\nCI build: {run_url}\n\n"
        "Verify all files with `sha256sum -c SHA256SUMS` (Linux) or "
        "`shasum -a 256 -c SHA256SUMS` (macOS). Report model/southbridge, uname -r, build "
        "hashes, psx0 status and relevant redacted logs. Do not post MAC/IP/serial/keys.\n"
    )
    (destination / "SHA256SUMS").write_text("".join(f"{digest(p)}  {p.name}\n" for p in sorted(destination.iterdir()) if p.is_file()))
    print(f"PASS: packaged {RELEASE}, complete corresponding source, no embedded firmware")


if __name__ == "__main__":
    main()
