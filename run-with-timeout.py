#!/usr/bin/env python3
"""Run one staged-review model process with heartbeats and optional deadline."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


class ForwardedSignal(Exception):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


def positive_number(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def nonnegative_number(value: str) -> float:
    parsed = float(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return parsed


def terminate_process_group(process: subprocess.Popen[bytes], grace: float) -> None:
    """Terminate the isolated child process group, escalating after grace."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return

    deadline = time.monotonic() + grace
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.05)

    # The direct process can exit while one of its descendants remains. Probe
    # and kill the whole group rather than relying only on process.poll().
    try:
        os.killpg(process.pid, 0)
    except ProcessLookupError:
        pass
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=max(grace, 0.1))
    except subprocess.TimeoutExpired:
        pass


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--timeout",
        required=True,
        type=nonnegative_number,
        help="hard deadline in seconds; zero waits for natural completion",
    )
    parser.add_argument("--progress-interval", required=True, type=positive_number)
    parser.add_argument("--grace", required=True, type=nonnegative_number)
    parser.add_argument("--label", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--stdin")
    parser.add_argument("--stdout", required=True)
    parser.add_argument("--stderr", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    stdout_path = Path(args.stdout)
    stderr_path = Path(args.stderr)
    stdout_path.parent.mkdir(parents=True, exist_ok=True)
    stderr_path.parent.mkdir(parents=True, exist_ok=True)

    stdin_handle = open(args.stdin, "rb") if args.stdin else subprocess.DEVNULL
    with open(stdout_path, "wb") as stdout_handle, open(stderr_path, "wb") as stderr_handle:
        try:
            process = subprocess.Popen(
                args.command,
                cwd=args.cwd,
                stdin=stdin_handle,
                stdout=stdout_handle,
                stderr=stderr_handle,
                start_new_session=True,
            )
        except OSError as exc:
            message = f"staged-review watchdog: failed to start {args.label}: {exc}\n"
            stderr_handle.write(message.encode())
            stderr_handle.flush()
            print(message, end="", file=sys.stderr)
            if args.stdin:
                stdin_handle.close()
            return 127

        forwarded_signal = False

        def forward(signum: int, _frame: object) -> None:
            nonlocal forwarded_signal
            if forwarded_signal:
                return
            forwarded_signal = True
            raise ForwardedSignal(signum)

        previous = {
            signum: signal.signal(signum, forward)
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        }
        started = time.monotonic()
        next_progress = args.progress_interval
        try:
            while True:
                result = process.poll()
                if result is not None:
                    return result if result >= 0 else 128 - result

                elapsed = time.monotonic() - started
                if args.timeout > 0 and elapsed >= args.timeout:
                    message = (
                        f"staged-review watchdog: {args.label} timed out after "
                        f"{args.timeout:g}s; terminating process group {process.pid}\n"
                    )
                    stderr_handle.write(message.encode())
                    stderr_handle.flush()
                    print(message, end="", file=sys.stderr)
                    terminate_process_group(process, args.grace)
                    return 124

                if elapsed >= next_progress:
                    deadline = f"{args.timeout:g}s" if args.timeout > 0 else "unbounded"
                    print(
                        f"staged-review: {args.label} still running "
                        f"({int(elapsed)}s/{deadline})",
                        file=sys.stderr,
                        flush=True,
                    )
                    next_progress += args.progress_interval
                if args.timeout > 0:
                    time.sleep(min(0.2, max(args.timeout - elapsed, 0.01)))
                else:
                    time.sleep(0.2)
        except ForwardedSignal as exc:
            terminate_process_group(process, args.grace)
            return 128 + exc.signum
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)
            if args.stdin:
                stdin_handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
