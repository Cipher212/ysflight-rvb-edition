"""Bridge regression tests; no model calls or game-code changes."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import codex_bridge as bridge
import codex_bridge_runtime as runtime


class BridgeTests(unittest.TestCase):
    def setUp(self):
        base = bridge.ROOT / "crashlog"
        base.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="codex_bridge_test_", dir=base)
        self.root = Path(self.temp.name).resolve()
        # Keep recursive temporary cleanup inside this specifically allocated test directory.
        self.assertEqual(self.root.parent, base.resolve())
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(patch.stopall)
        patch.object(bridge, "ROOT", self.root).start()
        patch.object(bridge, "find_codex", return_value="fake-codex").start()
        patch.object(bridge, "workspace_state", side_effect=self.inventory).start()
        self.behavior = "completed"
        self.edits = False
        self.actual_run = runtime.run_logged
        patch.object(bridge, "run_logged", side_effect=self.fake_run).start()

    def inventory(self, root):
        return {p.name: ["??", [p.stat().st_mtime_ns, p.stat().st_size]] for p in root.iterdir() if p.is_file()}

    def report(self, **updates):
        report = {"status": "completed", "summary": "Done", "changed_files": [], "checks_run": [], "notes": []}
        report.update(updates)
        return report

    def fake_run(self, argv, cwd, env, seconds, out, err, prompt=None):
        if argv[0] != "fake-codex":
            return self.actual_run(argv, cwd, env, seconds, out, err, prompt)
        self.assertEqual(argv[-1], "-")
        self.assertIn("--no-daemon", argv)
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", argv)
        self.assertNotIn("--model", argv)
        self.assertIn("Claude remains the lead architect", prompt)
        self.assertIn("Do not reset, stash, revert, stage, commit or push", prompt)
        if self.edits:
            (self.root / "already_dirty.txt").write_text("worker changed existing dirty work", encoding="utf-8")
        out.write_text('{"type":"thread.started","thread_id":"fixture"}\n', encoding="utf-8")
        if self.behavior != "incomplete":
            with out.open("a", encoding="utf-8") as stream:
                stream.write('{"type":"turn.completed"}\n')
        err.write_text("", encoding="utf-8")
        status = self.behavior if self.behavior in ("blocked", "failed") else "completed"
        last = Path(argv[argv.index("--output-last-message") + 1])
        last.write_text("{}" if self.behavior == "empty_report" else json.dumps(self.report(status=status)), encoding="utf-8")
        return {"exit_code": 99 if self.behavior == "bad_exit" else 0,
                "timed_out": self.behavior == "timeout", "seconds": 0.1}

    def job(self, mode="implement", command=None):
        commands = [] if mode == "read-only" else [{"argv": command or [sys.executable, "-c", "print('verified')"]}]
        return bridge.validate_job({"task": "Fixture — preserve literal $(whoami) and `quotes`.", "mode": mode, "verify": commands})

    def delegate(self, job):
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            code = bridge.delegate(job, 30)
        summary = json.loads(out.getvalue())
        result = json.loads(Path(summary["result_file"]).read_text(encoding="utf-8"))
        return code, result

    def test_completed_and_verified(self):
        code, result = self.delegate(self.job())
        self.assertEqual(code, 0)
        self.assertTrue(result["verified"])
        self.assertTrue(result["verification"][0]["passed"])
        self.assertEqual(result["thread_id"], "fixture")

    def test_exit_error_cannot_be_hidden_by_completed_report(self):
        self.behavior = "bad_exit"
        code, result = self.delegate(self.job())
        self.assertEqual(code, 1)
        self.assertFalse(result["verified"])
        self.assertEqual(result["verification"], [])

    def test_incomplete_turn_fails(self):
        self.behavior = "incomplete"
        self.assertEqual(self.delegate(self.job())[0], 1)

    def test_empty_report_fails(self):
        self.behavior = "empty_report"
        self.assertEqual(self.delegate(self.job())[0], 1)

    def test_worker_timeout_fails(self):
        self.behavior = "timeout"
        self.assertEqual(self.delegate(self.job())[0], 1)

    def test_blocked_worker_does_not_run_verification(self):
        self.behavior = "blocked"
        code, result = self.delegate(self.job())
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["verification"], [])

    def test_failed_verifier_preserves_edits_and_reports_them(self):
        (self.root / "already_dirty.txt").write_text("before", encoding="utf-8")
        self.edits = True
        code, result = self.delegate(self.job(command=[sys.executable, "-c", "raise SystemExit(7)"]))
        self.assertEqual(code, 1)
        self.assertEqual(result["changed_paths"], ["already_dirty.txt"])
        self.assertEqual(result["verification"][0]["exit_code"], 7)
        self.assertIn("worker changed", (self.root / "already_dirty.txt").read_text())

    def test_readonly_completion_does_not_claim_verification(self):
        code, result = self.delegate(self.job("read-only"))
        self.assertEqual(code, 0)
        self.assertFalse(result["verified"])

    def test_readonly_edits_fail(self):
        self.edits = True
        code, result = self.delegate(self.job("read-only"))
        self.assertEqual(code, 1)
        self.assertIn("read-only", result["reason"])

    def test_existing_lock_is_not_removed(self):
        root = self.root / "crashlog/codex_bridge"
        root.mkdir(parents=True)
        lock = root / "writer.lock"
        lock.write_text("another owner", encoding="utf-8")
        code, _ = self.delegate(self.job())
        self.assertEqual(code, 1)
        self.assertEqual(lock.read_text(), "another owner")

    def test_verifier_argv_is_not_interpreted_as_shell_code(self):
        literal = " spaces — $(whoami) & `hello` "
        code, result = self.delegate(self.job(command=[sys.executable, "-c", "import sys; print(sys.argv[1])", literal]))
        self.assertEqual(code, 0)
        self.assertEqual((Path(result["job_dir"]) / "verify_01.stdout.log").read_text(encoding="utf-8").strip(), literal.strip())

    def test_implementation_requires_verification(self):
        with self.assertRaises(ValueError):
            bridge.validate_job({"task": "change code"})

    def test_external_verification_directory_rejected(self):
        with self.assertRaises(ValueError):
            bridge.validate_job({"task": "task", "verify": [{"argv": ["python"], "cwd": ".."}]})

    def test_invalid_job_fields_and_arguments_rejected(self):
        for value in ([], {"task": ""}, {"task": "x", "mode": "anything"},
                      {"task": "x", "verify": [{"argv": "python tools/run_tests.py"}]},
                      {"task": "x", "verify": [{"argv": ["py\0thon"]}]},
                      {"task": "x", "mode": "read-only", "extra": True}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                bridge.validate_job(value)

    def test_invalid_timeouts_rejected(self):
        for value in (0, -1, 7201, True, 0.5, "60"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                bridge.seconds(value)

    def test_invalid_final_report_rejected(self):
        for value in ({}, self.report(status="success"), self.report(summary=""), self.report(changed_files=[1])):
            with self.subTest(value=value), self.assertRaises(ValueError):
                bridge.validate_report(value)

    def test_error_event_overrides_completion(self):
        path = self.root / "events"
        path.write_text('{"type":"thread.started","thread_id":"a"}\n{"type":"turn.completed"}\n{"type":"error"}\n')
        with self.assertRaises(RuntimeError):
            runtime.completed_turn(path)

    def test_status_inventory_handles_spaces_and_rename(self):
        (self.root / "new name.txt").write_text("new")
        response = subprocess.CompletedProcess([], 0, b'R  new name.txt\0old name.txt\0?? other.txt\0')
        with patch.object(runtime.subprocess, "run", return_value=response) as mocked:
            state = runtime.workspace_state(self.root)
        self.assertEqual(set(state), {"new name.txt", "old name.txt", "other.txt"})
        self.assertIn("--no-optional-locks", mocked.call_args.args[0])
        self.assertIsNone(state["old name.txt"][1])

    def test_real_process_stdin_and_timeout(self):
        out, err = self.root / "out", self.root / "err"
        text = "multi\nline — $(literal)"
        result = self.actual_run([sys.executable, "-c", "import sys; print(sys.stdin.read())"], self.root,
                                 runtime.codex_environment(), 10, out, err, text)
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(out.read_text(encoding="utf-8").strip(), text)
        result = self.actual_run([sys.executable, "-c", "import time; time.sleep(30)"], self.root,
                                 runtime.codex_environment(), 1, out, err)
        self.assertTrue(result["timed_out"])
        self.assertNotEqual(result["exit_code"], 0)

    def test_atomic_json_write(self):
        path = self.root / "result.json"
        runtime.write_json(path, {"status": "running"})
        runtime.write_json(path, {"status": "completed"})
        self.assertEqual(json.loads(path.read_text())["status"], "completed")
        self.assertFalse(path.with_suffix(".json.tmp").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
