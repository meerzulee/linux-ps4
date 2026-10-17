import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("package_release", ROOT / "scripts/ci/package_release.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PublicSourceTests(unittest.TestCase):
    def test_firmware_embedding_is_refused(self):
        text = (ROOT / "config/6.18-baikal-mts2-public.config").read_text()
        package.check_config(text)
        with self.assertRaisesRegex(ValueError, "must not embed"):
            package.check_config(text.replace('CONFIG_EXTRA_FIRMWARE=""', 'CONFIG_EXTRA_FIRMWARE="vendor.bin"'))

    def test_complete_patched_source_excludes_build_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            files = {"COPYING": "GPL source license", "tracked.c": "base", ".gitignore": "*.o\n.config\nignored-source.h\n"}
            for name, data in files.items():
                (source / name).write_text(data)
            subprocess.run(["git", "add", "."], cwd=source, check=True)
            (source / "tracked.c").write_text("patched")
            for name in ["drivers/net/ethernet/psx_mts_net.c", "drivers/net/ethernet/mts_net_core.h", ".config", "build.o"]:
                p = source / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("source")
            (source / "ignored-source.h").write_text("patched source required by build")
            result = package.source_files(source, {"ignored-source.h"})
            self.assertIn("ignored-source.h", result)
            self.assertIn(".config", result)
            self.assertIn("tracked.c", result)
            self.assertIn("drivers/net/ethernet/psx_mts_net.c", result)
            self.assertNotIn("build.o", result)
            firmware = source / "firmware/vendor.bin"
            firmware.parent.mkdir()
            firmware.write_bytes(b"firmware")
            with self.assertRaisesRegex(ValueError, "unexpected staged firmware"):
                package.source_files(source)


if __name__ == "__main__":
    unittest.main()
