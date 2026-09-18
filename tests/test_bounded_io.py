"""Adversarial integration tests; fake producers never touch the clipboard."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "bounded_io.py"

PRODUCER = r'''
import json, os, signal, sys, time
from pathlib import Path

case = os.environ.get("DICT_TEST_CASE", "normal")
is_query = Path(sys.argv[0]).name == "sdcv"
normal = b'[{"word":"hello","definition":"world"}]' if is_query else b"  'hello!'  \nignored"
size = int(os.environ.get("DICT_TEST_SIZE", "0"))

def record():
    with open(os.environ["DICT_TEST_PIDS"], "a") as f:
        f.write(str(os.getpid()) + "\n")

def hang():
    while True:
        time.sleep(1)

if case in ("tree", "orphan_pipe", "orphan_closed"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    record()
    child = os.fork()
    if child == 0:
        record()
        grandchild = os.fork()
        if grandchild == 0:
            record()
        if case == "orphan_closed":
            os.close(1)
            os.close(2)
        hang()
    if case == "tree":
        hang()
    # Wait until both descendants are observable before exiting.
    while len(Path(os.environ["DICT_TEST_PIDS"]).read_text().splitlines()) < 3:
        time.sleep(.005)
    os.write(1, normal)
    sys.exit(0)
elif case == "flood":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    record()
    while True:
        os.write(1, b"x" * 8192)
elif case == "sized":
    os.write(1, b"x" * size)
elif case == "selection_sized":
    os.write(1, b"hello\n" + b"x" * (size - 6))
elif case == "query_sized":
    os.write(1, b"[]" + b" " * (size - 2))
elif case == "stderr":
    os.write(1, normal)
    os.write(2, b"x" * size)
elif case == "stall":
    os.write(1, normal)
    hang()
elif case == "closed":
    os.close(1)
    os.close(2)
    hang()
elif case == "nonzero":
    os.write(1, normal)
    sys.exit(2)
elif case == "invalid":
    os.write(1, b"hello\xff")
elif case == "nul":
    os.write(1, b"hello\0world")
elif case == "sources":
    os.write(1, b"primary" if "--primary" in sys.argv else b"clipboard")
elif case == "fallback":
    os.write(1, b" \n" if "--primary" in sys.argv else b"clipboard")
elif case == "empty":
    sys.exit(1)
elif case == "args":
    os.write(1, json.dumps(sys.argv[1:]).encode())
elif case == "stages":
    os.write(1, b"[]" if "-e" in sys.argv else b'[{"word":"hello","definition":"fuzzy"}]')
elif case == "echo_term":
    os.write(1, json.dumps([{"word": sys.argv[-1], "definition": "definition"}]).encode())
else:
    os.write(1, normal)
'''


class BoundedIOTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dict-io-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.pids = self.directory / "pids"
        for name in ("wl-paste", "sdcv"):
            executable = self.directory / name
            executable.write_text(f"#!{sys.executable}\n" + PRODUCER)
            executable.chmod(0o700)
        self.env = dict(os.environ, PATH=f"{self.directory}:{os.environ['PATH']}",
                        XDG_CACHE_HOME=str(self.directory / "cache"),
                        XDG_DATA_HOME=str(self.directory / "data"),
                        DICT_TEST_PIDS=str(self.pids))

    def command(self, mode):
        return [sys.executable, "-I", str(HELPER), mode] + (["exact", "hello"] if mode == "query" else [])

    def run_helper(self, mode, case="normal", size=0, expected=0):
        env = dict(self.env, DICT_TEST_CASE=case, DICT_TEST_SIZE=str(size))
        start = time.monotonic()
        result = subprocess.run(self.command(mode), env=env, capture_output=True, timeout=7)
        elapsed = time.monotonic() - start
        self.assertEqual(result.returncode, expected, result)
        self.assertEqual(result.stderr, b"")
        if expected != 0:
            self.assertEqual(result.stdout, b"", "Rejected output must not escape the helper")
        self.assertLess(elapsed, {"paste": 1.8, "selection": 2.8, "query": 5.8}[mode])
        return result.stdout

    def assert_reaped(self):
        pids = self.pids.read_text().splitlines()
        self.assertGreaterEqual(len(pids), 1)
        for pid in pids:
            self.assertFalse(Path(f"/proc/{pid}").exists(), f"Surviving or zombie producer {pid}")

    def test_success_and_normalization(self):
        self.assertEqual(self.run_helper("selection"), b"hello")
        self.assertIn(b"hello", self.run_helper("paste"))
        self.assertEqual(json.loads(self.run_helper("query"))[0]["word"], "hello")

    def test_exact_byte_boundaries(self):
        self.assertEqual(len(self.run_helper("paste", "sized", 4096)), 4096)
        self.assertEqual(self.run_helper("selection", "selection_sized", 4096), b"hello")
        self.assertEqual(len(self.run_helper("query", "query_sized", 262144)), 262144)
        for mode in ("selection", "paste", "query"):
            with self.subTest(mode=mode):
                self.run_helper(mode, "stderr", 8192)

    def test_one_byte_overflow(self):
        for mode, case, size in (("selection", "selection_sized", 4097),
                                 ("paste", "sized", 4097), ("query", "query_sized", 262145)):
            with self.subTest(mode=mode):
                self.run_helper(mode, case, size, expected=65)

    def test_stderr_overflow_discards_valid_stdout(self):
        for mode in ("selection", "paste", "query"):
            with self.subTest(mode=mode):
                self.run_helper(mode, "stderr", 8193, expected=65)

    def test_flood_is_stopped_and_reaped(self):
        for mode in ("selection", "paste", "query"):
            with self.subTest(mode=mode):
                self.run_helper(mode, "flood", expected=65)
                self.assert_reaped()

    def test_partial_output_then_stall_is_rejected(self):
        for mode in ("selection", "paste", "query"):
            with self.subTest(mode=mode):
                self.run_helper(mode, "stall", expected=124)

    def test_closed_streams_do_not_bypass_deadline(self):
        self.run_helper("paste", "closed", expected=124)

    def test_process_tree_ignoring_term_is_killed_and_reaped(self):
        self.run_helper("paste", "tree", expected=124)
        self.assertEqual(len(self.pids.read_text().splitlines()), 3)
        self.assert_reaped()

    def test_exited_leader_with_inherited_pipes(self):
        self.run_helper("paste", "orphan_pipe", expected=124)
        self.assert_reaped()

    def test_exited_leader_with_closed_descendant_pipes(self):
        self.run_helper("paste", "orphan_closed")
        self.assert_reaped()

    def test_cancellation_reaps_entire_group(self):
        proc = subprocess.Popen(self.command("query"), env=dict(self.env, DICT_TEST_CASE="tree"),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 2
            while not self.pids.exists() or len(self.pids.read_text().splitlines()) < 3:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.01)
            proc.send_signal(signal.SIGTERM)
            out, err = proc.communicate(timeout=1)
            self.assertEqual((proc.returncode, out, err), (75, b"", b""))
            self.assert_reaped()
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
            proc.stdout.close()
            proc.stderr.close()

    def test_invalid_utf8_and_nul(self):
        for mode in ("selection", "paste", "query"):
            for case in ("invalid", "nul"):
                with self.subTest(mode=mode, case=case):
                    self.run_helper(mode, case, expected=66)

    def test_nonzero_exit_discards_output(self):
        for mode in ("paste", "query"):
            self.run_helper(mode, "nonzero", expected=70)
        self.assertEqual(self.run_helper("selection", "nonzero"), b"")

    def test_clipboard_fallback_and_timestamp_preference(self):
        self.assertEqual(self.run_helper("selection", "sources"), b"primary")
        self.assertEqual(self.run_helper("selection", "fallback"), b"clipboard")
        self.assertEqual(self.run_helper("selection", "empty"), b"")
        cache = Path(self.env["XDG_CACHE_HOME"]) / "omarchy-dict"
        cache.mkdir(parents=True)
        for name, stamp in (("primary", 1), ("clipboard", 2)):
            path = cache / (name + ".time")
            path.touch()
            os.utime(path, (stamp, stamp))
        self.assertEqual(self.run_helper("selection", "sources"), b"clipboard")

    def test_optional_unbounded_library_is_never_sourced(self):
        data = Path(self.env["XDG_DATA_HOME"]) / "omarchy-dict"
        data.mkdir(parents=True)
        (data / "lib.sh").write_text("exit 99\n")
        self.assertEqual(self.run_helper("selection"), b"hello")

    def test_term_limit_is_bytes_and_options_are_separated(self):
        for term, expected in (("x" * 1024, 0), ("x" * 1025, 65), ("界" * 342, 65), ("--help", 0)):
            command = self.command("query")
            command[-1] = term
            result = subprocess.run(command, env=dict(self.env, DICT_TEST_CASE="args"),
                                    capture_output=True, timeout=2)
            self.assertEqual(result.returncode, expected)
            if expected == 0:
                self.assertEqual(json.loads(result.stdout)[-2:], ["--", term])
            else:
                self.assertEqual(result.stdout, b"")

    def test_selection_wrapper_and_output_redirection(self):
        with tempfile.TemporaryFile() as output:
            result = subprocess.run(["bash", str(ROOT / "selection.sh"), "hello"],
                                    env=self.env, stdout=output, stderr=subprocess.PIPE, timeout=2)
            self.assertEqual(result.returncode, 0)
            output.seek(0)
            self.assertEqual(output.read(), b"hello")

    def test_blocked_consumer_has_deadline(self):
        proc = subprocess.Popen(self.command("query"),
                                env=dict(self.env, DICT_TEST_CASE="query_sized", DICT_TEST_SIZE="262144"),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            # Deliberately do not drain stdout: even forwarding must time out.
            self.assertEqual(proc.wait(timeout=6), 124)
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
            proc.stdout.close()
            proc.stderr.close()


if __name__ == "__main__":
    unittest.main()
