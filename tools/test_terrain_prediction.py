"""Build and run deterministic fixtures against the actual C++ terrain predictor."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
build = subprocess.run([sys.executable, "-m", "SCons", "-Q", "-f", "tools/terrain_prediction_test.scons"], cwd=root)
if build.returncode:
    sys.exit(build.returncode)
exe = root / "crashlog/native_tests/terrain_prediction_test"
if sys.platform == "win32":
    exe = exe.with_suffix(".exe")
sys.exit(subprocess.run([str(exe)], cwd=root).returncode)
