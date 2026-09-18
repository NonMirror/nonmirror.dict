"""Run the production controller/Process blocks in offscreen Quickshell.

Only presentation imports, style properties, and the PanelWindow are replaced
with inert stubs. No real clipboard, desktop overlay, or vocabulary is touched.
"""

import json
import shutil
import subprocess
import unittest

import test_bounded_io as fixtures


@unittest.skipUnless(shutil.which("quickshell"), "Quickshell is required for QML integration tests")
class QmlTests(unittest.TestCase):
    def setUp(self):
        fixtures.BoundedIOTests.setUp(self)

    def run_qml(self, setup, check, case="normal", size=0, extra=""):
        source = (fixtures.ROOT / "Dict.qml").read_text()
        source = source.split("  PanelWindow {", 1)[0]
        source = source.replace("import qs.Commons\n", "").replace("import qs.Ui\n", "")
        start = source.index("  // Same [menu]")
        end = source.index("  // --------------------------------------------------------------- lifecycle")
        source = source[:start] + source[end:]
        # Count actual parser invocations to detect parsing of rejected bytes.
        source = source.replace("function parseEntries(raw) {", "function parseEntries(raw) { parseCalls++;")
        source += '''
  property int parseCalls: 0
  property int ticks: 0
  property int phase: 0
  Item { id: keyCatcher }
  QtObject { id: matchList; function positionViewAtIndex(index, mode) {} }
  function verify(condition, message) {
    if (!condition) { console.log("TEST FAIL: " + message); Qt.quit() }
    return condition
  }
'''
        source += extra + "\n"
        source += f"  Component.onCompleted: {{ ioScript = {json.dumps(str(fixtures.HELPER))}; {setup} }}\n"
        source += '''
  Timer {
    interval: 25
    repeat: true
    running: true
    onTriggered: {
      ticks++
      if (ticks > 260) { console.log("TEST FAIL: deadline"); Qt.quit(); return }
'''
        source += check + "\n    }\n  }\n}\n"
        path = self.directory / "shell.qml"
        path.write_text(source)
        env = dict(self.env, QT_QPA_PLATFORM="offscreen", DICT_TEST_CASE=case, DICT_TEST_SIZE=str(size))
        result = subprocess.run(["quickshell", "--no-color", "-p", str(path)],
                                env=env, capture_output=True, text=True, timeout=9)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertNotIn("TEST FAIL", output)
        self.assertNotIn("ReferenceError", output)
        self.assertNotIn("TypeError", output)
        self.assertIn("TEST PASS", output)

    def test_selection_reaches_lookup(self):
        self.run_qml('root.open("{}");', '''
      if (root.opened && !root.busy) {
        if (!verify(root.term === "hello" && root.matches.length === 1 && parseCalls === 1,
                    "selection must complete the real QML query")) return
        console.log("TEST PASS"); Qt.quit()
      }
''')

    def test_query_overflow_never_parsed_or_retried(self):
        self.run_qml('root.open(\'{"term":"Hello"}\');', '''
      if (!root.busy) {
        if (!verify(parseCalls === 0 && root.matches.length === 0 && root.queryStage === 0
                    && root.statusText.indexOf("size limit") >= 0, "overflow must fail closed")) return
        console.log("TEST PASS"); Qt.quit()
      }
''', case="query_sized", size=262145)

    def test_exact_lowercase_fuzzy_stages(self):
        self.run_qml('root.open(\'{"term":"Hello"}\');', '''
      if (!root.busy) {
        if (!verify(parseCalls === 3 && root.queryStage === 2 && root.matches.length === 1
                    && root.matches[0].definition === "fuzzy", "all lookup stages must complete")) return
        console.log("TEST PASS"); Qt.quit()
      }
''', case="stages")

    def test_successive_queries_do_not_reuse_collector_data(self):
        self.run_qml('root.open(\'{"term":"first"}\');', '''
      if (!root.busy && phase === 0) {
        if (!verify(root.matches.length === 1 && root.matches[0].word === "first", "first query")) return
        phase = 1
        root.requestQuery("second")
      } else if (!root.busy && phase === 1) {
        if (!verify(root.matches.length === 1 && root.matches[0].word === "second"
                    && parseCalls === 2, "collector must contain only the current response")) return
        console.log("TEST PASS"); Qt.quit()
      }
''', case="echo_term")

    def test_stderr_overflow_never_parsed(self):
        self.run_qml('root.open(\'{"term":"Hello"}\');', '''
      if (!root.busy) {
        if (!verify(parseCalls === 0 && root.matches.length === 0
                    && root.statusText.indexOf("size limit") >= 0, "stderr overflow must fail closed")) return
        console.log("TEST PASS"); Qt.quit()
      }
''', case="stderr", size=8193)

    def test_paste_overflow_preserves_term(self):
        self.run_qml('root.open(\'{"mode":"search"}\'); root.term = "keep"; root.requestPaste();', '''
      if (!pasteProc.running) {
        if (!verify(root.term === "keep" && parseCalls === 0
                    && root.statusText.indexOf("size limit") >= 0, "paste must reject all oversized bytes")) return
        console.log("TEST PASS"); Qt.quit()
      }
''', case="sized", size=4097)

    def test_term_byte_limit_including_accumulated_paste(self):
        self.run_qml('root.open(\'{"mode":"search"}\'); root.term = "x".repeat(1010); root.requestPaste();', '''
      if (!pasteProc.running) {
        if (!verify(root.term.length === 1010 && !root.acceptTerm("界".repeat(342))
                    && root.acceptTerm("界".repeat(341)), "UTF-8 and accumulated term limits")) return
        console.log("TEST PASS"); Qt.quit()
      }
''')

    def test_close_reopen_waits_for_cancelled_helper(self):
        self.run_qml('root.open(\'{"term":"Hello"}\');', '''
      if (phase === 0 && ticks === 8) {
        root.open('{"mode":"search"}')
        phase = 1
      }
      if (phase === 1 && root.opened && !root.reopenPending && !queryProc.running) {
        if (!verify(root.mode === "search" && root.term === "" && parseCalls === 0
                    && !root.busy, "reopen must ignore cancelled results")) return
        console.log("TEST PASS"); Qt.quit()
      }
''', case="tree")
        fixtures.BoundedIOTests.assert_reaped(self)

    def test_queued_query_recovers_after_failed_query(self):
        self.run_qml('root.open(\'{"term":"Hello"}\'); root.setTerm("latest"); root.requestQuery("latest");', '''
      if (!root.busy && !root.pending && root.queryTerm === "latest") {
        if (!verify(parseCalls === 0 && root.statusText.indexOf("size limit") >= 0,
                    "pending query must finish without rendering stale data")) return
        console.log("TEST PASS"); Qt.quit()
      }
''', case="query_sized", size=262145)


if __name__ == "__main__":
    unittest.main()
