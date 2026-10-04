"""Process execution and workspace inventories for the Claude -> Codex bridge."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time


def codex_environment():
    env = os.environ.copy()
    # The desktop sandbox can hide Known Folder APIs despite a valid USERPROFILE.
    if not env.get("CODEX_HOME"):
        env["CODEX_HOME"] = str(Path.home() / ".codex")
    env["PYTHONIOENCODING"] = "utf-8"
    return env


def find_codex():
    found = shutil.which("codex.exe") or shutil.which("codex")
    if found:
        return found
    # Desktop updates change the hash directory; never pin that directory in CLAUDE.md.
    local = os.environ.get("LOCALAPPDATA")
    candidates = list((Path(local) / "OpenAI/Codex/bin").glob("*/codex.exe")) if local else []
    if candidates:
        return str(max(candidates, key=lambda p: p.stat().st_mtime))
    raise FileNotFoundError("Codex CLI not found. Install/sign in to Codex, then run --doctor.")


def workspace_state(root):
    result = subprocess.run(
        ["git", "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"],
        cwd=root, capture_output=True, check=True, timeout=30,
    )
    entries = result.stdout.decode("utf-8", errors="surrogateescape").split("\0")
    state = {}
    i = 0
    while i < len(entries) and entries[i]:
        status, name = entries[i][:2], entries[i][3:]
        names = [name]
        if "R" in status or "C" in status:
            i += 1
            names.append(entries[i])
        for name in names:
            try:
                stat = (root / name).lstat()
                stamp = [stat.st_mtime_ns, stat.st_size]
            except FileNotFoundError:
                stamp = None
            state[name] = [status, stamp]
        i += 1
    return state


def changed_paths(before, after):
    return sorted(name for name in before.keys() | after.keys() if before.get(name) != after.get(name))


def write_json(path, value):
    # Claude can poll result.json; replace it atomically rather than expose half a JSON document.
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    temp.replace(path)


@contextmanager
def writer_lock(path, job_dir):
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        raise RuntimeError(f"Another Codex worker owns {path}. Wait; do not edit its assigned files.") from None
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump({"pid": os.getpid(), "job_dir": str(job_dir)}, stream)
        yield
    finally:
        path.unlink(missing_ok=True)


def stop_process_tree(proc):
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=15, creationflags=subprocess.CREATE_NO_WINDOW,
        )
    else:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if proc.poll() is None:
        proc.kill()
    proc.wait(timeout=15)


def run_logged(argv, cwd, env, seconds, stdout_path, stderr_path, prompt=None):
    started = time.monotonic()
    options = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {"start_new_session": True}
    with stdout_path.open("wb") as out, stderr_path.open("wb") as err:
        proc = subprocess.Popen(
            argv, cwd=cwd, env=env, stdin=subprocess.PIPE if prompt is not None else subprocess.DEVNULL,
            stdout=out, stderr=err, text=True, encoding="utf-8", **options,
        )
        timed_out = False
        try:
            proc.communicate(prompt, timeout=seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            stop_process_tree(proc)
        except BaseException:
            stop_process_tree(proc)
            raise
    return {"exit_code": proc.returncode, "timed_out": timed_out, "seconds": round(time.monotonic() - started, 2)}


def completed_turn(events_path):
    thread_id = None
    completed = False
    with events_path.open(encoding="utf-8") as stream:
        for line in stream:
            if not line.strip():
                continue
            event = json.loads(line)
            kind = event.get("type")
            if kind == "thread.started":
                thread_id = event.get("thread_id")
            elif kind == "turn.completed":
                completed = True
            elif kind in ("turn.failed", "error"):
                raise RuntimeError(f"Codex reported {kind}; inspect events.jsonl and stderr.log.")
    if not thread_id or not completed:
        raise RuntimeError("Codex did not report a thread and a completed turn.")
    return thread_id
