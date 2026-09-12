from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


RUNNER = Path(__file__).resolve().parents[1] / "run-with-timeout.py"


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


class TimeoutRunnerTests(unittest.TestCase):
    def run_runner(
        self,
        directory: Path,
        command: list[str],
        *,
        timeout: float = 3,
        progress: float = 0.1,
        grace: float = 0.1,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(RUNNER),
                "--timeout",
                str(timeout),
                "--progress-interval",
                str(progress),
                "--grace",
                str(grace),
                "--label",
                "test attempt",
                "--cwd",
                str(directory),
                "--stdout",
                str(directory / "stdout.log"),
                "--stderr",
                str(directory / "stderr.log"),
                "--",
                *command,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_success_preserves_exit_and_logs(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            result = self.run_runner(
                directory,
                [sys.executable, "-c", "print('review complete')"],
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual((directory / "stdout.log").read_text(), "review complete\n")
            self.assertEqual((directory / "stderr.log").read_text(), "")

    def test_zero_timeout_waits_for_natural_completion(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            result = self.run_runner(
                directory,
                [
                    sys.executable,
                    "-c",
                    "import time; time.sleep(0.35); print('review complete')",
                ],
                timeout=0,
                progress=0.1,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual((directory / "stdout.log").read_text(), "review complete\n")
            self.assertIn("still running", result.stderr)
            self.assertIn("/unbounded)", result.stderr)
            self.assertNotIn("timed out", result.stderr)

    def test_timeout_reports_progress_and_kills_descendants(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            pid_file = directory / "child.pid"
            program = """
import pathlib, subprocess, sys, time
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
pathlib.Path(sys.argv[1]).write_text(str(child.pid))
time.sleep(60)
"""
            started = time.monotonic()
            result = self.run_runner(
                directory,
                [sys.executable, "-c", program, str(pid_file)],
                timeout=0.5,
            )
            self.assertEqual(result.returncode, 124)
            self.assertLess(time.monotonic() - started, 3)
            self.assertIn("still running", result.stderr)
            self.assertIn("timed out after 0.5s", result.stderr)
            self.assertIn("timed out after 0.5s", (directory / "stderr.log").read_text())

            child_pid = int(pid_file.read_text())
            deadline = time.monotonic() + 2
            while process_exists(child_pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(process_exists(child_pid), "timed-out descendant survived")

    def test_term_is_forwarded_to_the_isolated_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            pid_file = directory / "child.pid"
            program = """
import pathlib, sys, time
pathlib.Path(sys.argv[1]).write_text(str(__import__('os').getpid()))
time.sleep(60)
"""
            command = [
                sys.executable,
                str(RUNNER),
                "--timeout",
                "30",
                "--progress-interval",
                "10",
                "--grace",
                "0.1",
                "--label",
                "signal test",
                "--cwd",
                str(directory),
                "--stdout",
                str(directory / "stdout.log"),
                "--stderr",
                str(directory / "stderr.log"),
                "--",
                sys.executable,
                "-c",
                program,
                str(pid_file),
            ]
            runner = subprocess.Popen(command)
            deadline = time.monotonic() + 3
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(pid_file.exists(), "child did not start")
            child_pid = int(pid_file.read_text())

            runner.send_signal(signal.SIGTERM)
            self.assertEqual(runner.wait(timeout=3), 128 + signal.SIGTERM)
            deadline = time.monotonic() + 2
            while process_exists(child_pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(process_exists(child_pid), "signalled descendant survived")

    def test_repeated_term_does_not_interrupt_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            pid_file = directory / "child.pid"
            program = """
import os, pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
time.sleep(60)
"""
            command = [
                sys.executable,
                str(RUNNER),
                "--timeout",
                "0",
                "--progress-interval",
                "10",
                "--grace",
                "0.3",
                "--label",
                "repeated signal test",
                "--cwd",
                str(directory),
                "--stdout",
                str(directory / "stdout.log"),
                "--stderr",
                str(directory / "stderr.log"),
                "--",
                sys.executable,
                "-c",
                program,
                str(pid_file),
            ]
            runner = subprocess.Popen(command, stderr=subprocess.PIPE, text=True)
            deadline = time.monotonic() + 3
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(pid_file.exists(), "child did not start")
            child_pid = int(pid_file.read_text())

            runner.send_signal(signal.SIGTERM)
            time.sleep(0.05)
            runner.send_signal(signal.SIGTERM)
            _, stderr = runner.communicate(timeout=3)
            self.assertEqual(runner.returncode, 128 + signal.SIGTERM)
            self.assertNotIn("Traceback", stderr)
            deadline = time.monotonic() + 2
            while process_exists(child_pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(process_exists(child_pid), "signalled descendant survived")


if __name__ == "__main__":
    unittest.main()
