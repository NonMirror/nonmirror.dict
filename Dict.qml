import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Dictionary: an English -> Chinese lookup surface (sdcv + ECDICT) that reads
// the current selection, searches interactively, and saves words to an
// Anki-importable vocabulary. Replaces the terminal TUI popups that the
// CTRL+SHIFT+S / D / ALT+S hotkeys used to launch.
//
//   omarchy-shell shell toggle nonmirror.dict '{"mode":"lookup"}'
//   omarchy-shell shell toggle nonmirror.dict '{"mode":"search"}'
//   omarchy-shell shell summon nonmirror.dict '{"mode":"save"}'
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string mode: "lookup"       // lookup | search | save
  property string term: ""             // the search field / lookup term
  property var matches: []             // [{ word, dict, definition }]
  property int selectedIndex: 0
  property bool busy: false
  property bool pending: false
  property string pendingTerm: ""
  property string queryTerm: ""
  property int queryStage: 0           // 0 exact, 1 lowercased exact, 2 fuzzy
  property bool queryFuzzy: false
  property bool noResults: false
  property string statusText: ""
  property bool cursorVisible: true

  property string selectScript: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/nonmirror.dict/selection.sh"
  property string vocabPath: {
    var base = Quickshell.env("XDG_DATA_HOME")
    if (!base || base === "") base = (Quickshell.env("HOME") || "") + "/.local/share"
    return base + "/omarchy-dict/vocab.tsv"
  }

  // Same [menu] surface tokens the command menu uses, so themes style both.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color faint: Util.alpha(foreground, 0.5)
  property color hairline: Util.alpha(foreground, 0.16)
  property color accent: Color.menu.selectedText
  property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int fieldHeight: Math.max(Style.space(38), Style.font.body + Style.spacing.controlPaddingY * 2)
  property int rowHeight: Math.max(Style.space(44), Style.font.body + Style.font.caption + Style.spacing.xs * 3)
  property int cardWidth: Math.min(Style.space(570), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(500), panel.height - Style.gapsOut * 2)

  // --------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var payload = root.parsePayload(payloadJson)
    var requested = String(payload.mode || "")
    root.mode = ["lookup", "search", "save"].indexOf(requested) >= 0 ? requested : "lookup"
    root.matches = []
    root.selectedIndex = 0
    root.busy = false
    root.pending = false
    root.pendingTerm = ""
    root.noResults = false
    root.statusText = root.mode === "search" ? "Type to search" : ""
    root.opened = true

    var provided = payload.term !== undefined && payload.term !== null ? String(payload.term) : ""
    if (root.mode === "search" && provided === "") {
      root.term = ""
    } else if (provided !== "") {
      root.term = provided
      root.runQuery(provided)
    } else {
      root.term = ""
      root.beginCapture()
    }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "nonmirror.dict")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // Keybindings pass the payload as a single shell word; accept both a raw
  // JSON object and one that still carries the quotes the shell did not strip.
  function parsePayload(payloadJson) {
    var raw = String(payloadJson === undefined || payloadJson === null ? "" : payloadJson).trim()
    if (raw.length >= 2) {
      var first = raw.charAt(0)
      var last = raw.charAt(raw.length - 1)
      if ((first === "'" && last === "'") || (first === '"' && last === '"'))
        raw = raw.slice(1, raw.length - 1).trim()
    }
    if (raw === "") return ({})
    try {
      var parsed = JSON.parse(raw)
      return (parsed && typeof parsed === "object") ? parsed : ({})
    } catch (e) {
      return ({})
    }
  }

  // ------------------------------------------------------------- selection

  function beginCapture() {
    root.busy = true
    root.statusText = root.mode === "search" ? "Type to search" : "Reading selection…"
    captureProc.outText = ""
    captureProc.command = ["bash", root.selectScript]
    captureProc.running = true
  }

  // ------------------------------------------------------------- querying

  // Queries are strictly sequential: sdcv answers in milliseconds, and not
  // killing a process keeps the collector from reporting a half-read result
  // for a term the user has already moved past. A term typed while one query
  // is in flight is remembered and run when that one finishes.
  function requestQuery(rawTerm) {
    var t = String(rawTerm === undefined || rawTerm === null ? "" : rawTerm).trim()
    if (root.busy) {
      root.pending = true
      root.pendingTerm = t
      return
    }
    root.runQuery(t)
  }

  function runQuery(rawTerm) {
    var t = String(rawTerm === undefined || rawTerm === null ? "" : rawTerm).trim()
    root.queryTerm = t
    root.queryStage = 0
    root.queryFuzzy = false
    root.matches = []
    root.selectedIndex = 0
    root.noResults = false
    root.statusText = ""
    if (t === "") {
      root.busy = false
      root.statusText = root.mode === "search" ? "Type to search" : ""
      return
    }
    root.busy = true
    root.beginStage()
  }

  function beginStage() {
    var t = root.queryTerm
    var args = ["sdcv", "-n", "-j"]
    if (root.queryStage !== 2) args.push("-e")
    args.push(root.queryStage === 1 ? t.toLowerCase() : t)
    root.queryFuzzy = root.queryStage === 2
    queryProc.outText = ""
    queryProc.errText = ""
    queryProc.command = args
    queryProc.running = true
  }

  function parseEntries(raw) {
    var text = String(raw === undefined || raw === null ? "" : raw).trim()
    if (text === "") return []
    var data
    try { data = JSON.parse(text) } catch (e) { return [] }
    if (!Array.isArray(data)) return []
    var out = []
    for (var i = 0; i < data.length; i++) {
      var e = data[i]
      if (!e || typeof e !== "object") continue
      out.push({
        word: String(e.word === undefined ? "" : e.word),
        dict: String(e.dict === undefined ? "" : e.dict),
        definition: String(e.definition === undefined ? "" : e.definition)
      })
    }
    return out
  }

  function completeQuery(entries) {
    root.busy = false

    if (root.pending) {
      var t = root.pendingTerm
      root.pending = false
      root.pendingTerm = ""
      Qt.callLater(function() { root.requestQuery(t) })
      return
    }

    if (entries.length === 0) {
      root.matches = []
      root.noResults = true
      root.statusText = "No entry for “" + root.queryTerm + "”"
      if (root.mode === "save") {
        root.notify("No entry for " + root.queryTerm)
        root.mode = "lookup"
      }
      return
    }

    var list = entries.slice()
    if (root.queryFuzzy) {
      // sdcv lists the exact match last among its suggestions; the word the
      // user actually asked for should be the one that is selected.
      var want = root.queryTerm.toLowerCase()
      for (var i = 0; i < list.length; i++) {
        if (String(list[i].word).toLowerCase() === want) {
          var hit = list.splice(i, 1)[0]
          list.unshift(hit)
          break
        }
      }
    }
    root.matches = list
    root.selectedIndex = 0
    root.noResults = false
    root.statusText = ""
    root.revealSelection()
    if (root.mode === "save") root.saveCurrent()
  }

  // ------------------------------------------------------------ definition

  function currentEntry() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.matches.length) return null
    return root.matches[root.selectedIndex]
  }

  function entryLines(entry) {
    if (!entry) return []
    var lines = String(entry.definition || "").replace(/\r/g, "").split("\n")
    while (lines.length > 0 && String(lines[0]).trim() === "") lines.shift()
    return lines
  }

  function entryPhonetic(entry) {
    var lines = root.entryLines(entry)
    if (lines.length === 0) return ""
    var m = String(lines[0]).match(/^\*?\s*(\[[^\]]+\].*)$/)
    return m ? m[1].replace(/[[:space:]]+$/, "") : ""
  }

  function entryBody(entry) {
    var lines = root.entryLines(entry)
    if (lines.length > 0 && /^\*?\s*\[[^\]]+\]/.test(String(lines[0]))) lines.shift()
    return lines.join("\n").trim()
  }

  function htmlDefinition(entry) {
    var body = String(entry && entry.definition ? entry.definition : "").replace(/\r/g, "").trim()
    return body
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/\n/g, "<br>")
  }

  function copyText(entry) {
    var phonetic = root.entryPhonetic(entry)
    var parts = [entry.word]
    if (phonetic !== "") parts.push(phonetic)
    var body = root.entryBody(entry)
    if (body !== "") parts.push(body)
    return parts.join("\n")
  }

  function copySelected() {
    var entry = root.currentEntry()
    if (!entry) {
      if (root.term.trim() !== "") root.runQuery(root.term)
      return
    }
    copyProc.command = ["bash", "-c", "printf %s \"$1\" | wl-copy --type text/plain", "dict", root.copyText(entry)]
    copyProc.running = true
    root.statusText = "Copied “" + entry.word + "”"
    statusTimer.restart()
  }

  // Overwrites the last notification from this plugin so repeated saves do
  // not pile up in the notification centre.
  function notify(message) {
    notifyProc.command = ["omarchy-notification-send", "-u", "low", "-g", "󰴑", "Vocabulary", message]
    notifyProc.running = true
  }

  function saveCurrent() {
    var entry = root.currentEntry()
    if (!entry) {
      root.statusText = "Nothing to save"
      statusTimer.restart()
      return
    }
    var word = root.term !== "" ? root.term : entry.word
    saveProc.word = word
    // Mirrors ~/.local/bin/dict-save: term<TAB>definition with <br> newlines,
    // so existing Anki imports keep working.
    saveProc.command = [
      "bash", "-c",
      "mkdir -p \"$(dirname \"$3\")\"; printf '%s\\t%s\\n' \"$1\" \"$2\" >> \"$3\"; wc -l < \"$3\"",
      "dict-save", word, root.htmlDefinition(entry), root.vocabPath
    ]
    saveProc.running = true
  }

  // ------------------------------------------------------------- navigation

  function moveSelection(delta) {
    var count = root.matches.length
    if (count === 0) return
    root.selectedIndex = (root.selectedIndex + delta + count) % count
    root.revealSelection()
  }

  function revealSelection() {
    Qt.callLater(function() {
      if (root.matches.length > 0)
        matchList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function setTerm(value) {
    root.term = String(value)
    if (root.mode === "save") root.mode = "lookup"
    root.selectedIndex = 0
    queryDebounce.restart()
  }

  function singleLine(text) {
    return String(text).replace(/\n/g, "⏎").replace(/\t/g, "⇥")
  }

  function isPrintable(event) {
    return event.text && event.text.length === 1
      && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
      && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)
  }

  // ------------------------------------------------------------------- keys

  function handleKey(event) {
    var key = event.key
    var mods = event.modifiers

    if (key === Qt.Key_Escape) {
      root.dismiss()
      event.accepted = true
      return
    }

    if (key === Qt.Key_S && (mods & Qt.ControlModifier)) {
      root.saveCurrent()
      event.accepted = true
      return
    }

    if (key === Qt.Key_V && (mods & Qt.ControlModifier)) {
      root.requestPaste()
      event.accepted = true
      return
    }

    if (key === Qt.Key_Down || (key === Qt.Key_J && (mods & Qt.AltModifier))) {
      root.moveSelection(1)
      event.accepted = true
      return
    }
    if (key === Qt.Key_Up || (key === Qt.Key_K && (mods & Qt.AltModifier))) {
      root.moveSelection(-1)
      event.accepted = true
      return
    }

    if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      if (root.matches.length === 0 && root.term.trim() !== "") root.runQuery(root.term)
      else root.copySelected()
      event.accepted = true
      return
    }

    // Ctrl+Delete clears the field. Omarchy's shared Util.editsFilter does not
    // cover Delete, so this one chord is handled here.
    if (key === Qt.Key_Delete && mods === Qt.ControlModifier) {
      root.setTerm("")
      event.accepted = true
      return
    }

    // Omarchy's shared text-editing keys (Backspace, Ctrl+Backspace, Ctrl+U).
    if (Util.editsFilter(event, root.term)) {
      root.setTerm(Util.editedFilter(event, root.term))
      event.accepted = true
      return
    }
    if (root.isPrintable(event)) {
      root.setTerm(root.term + event.text)
      event.accepted = true
      return
    }
  }

  // Reads the clipboard on demand (Ctrl+V). Pasting is explicit because the
  // clipboard is often stale relative to what the user means to look up.
  function requestPaste() {
    if (pasteProc.running) return
    pasteProc.running = true
  }

  Timer {
    id: statusTimer
    interval: 2400
    onTriggered: root.statusText = ""
  }

  Timer {
    interval: 530
    repeat: true
    running: root.opened
    onTriggered: root.cursorVisible = !root.cursorVisible
  }

  Timer {
    id: queryDebounce
    interval: 220
    onTriggered: root.requestQuery(root.term)
  }

  // Captures the selection before the first query on the lookup/save paths.
  Process {
    id: captureProc
    property string outText: ""
    stdout: StdioCollector {
      id: captureOut
      waitForEnd: true
      onStreamFinished: captureProc.outText = text
    }
    onExited: function(exitCode, exitStatus) {
      if (!root.opened) return
      var captured = String(captureProc.outText !== "" ? captureProc.outText : captureOut.text).trim()
      root.busy = false
      if (captured === "") {
        root.mode = "search"
        root.term = ""
        root.statusText = "Nothing selected — type a word"
        root.matches = []
        root.noResults = false
        return
      }
      root.term = captured
      root.runQuery(captured)
    }
  }

  // One sdcv call at a time; stages escalate from exact to fuzzy.
  Process {
    id: queryProc
    property string outText: ""
    property string errText: ""
    stdout: StdioCollector {
      id: queryOut
      waitForEnd: true
      onStreamFinished: queryProc.outText = text
    }
    stderr: StdioCollector {
      id: queryErr
      waitForEnd: true
      onStreamFinished: queryProc.errText = text
    }
    onExited: function(exitCode, exitStatus) {
      if (!root.busy) return
      var entries = root.parseEntries(queryProc.outText !== "" ? queryProc.outText : queryOut.text)
      if (entries.length > 0) {
        root.completeQuery(entries)
        return
      }
      var t = root.queryTerm
      if (root.queryStage === 0 && t.toLowerCase() !== t) {
        root.queryStage = 1
        Qt.callLater(root.beginStage)
        return
      }
      if (root.queryStage < 2) {
        root.queryStage = 2
        Qt.callLater(root.beginStage)
        return
      }
      root.completeQuery([])
    }
  }

  Process {
    id: pasteProc
    stdout: StdioCollector {
      id: pasteOut
      waitForEnd: true
    }
    // wl-paste --no-newline
    command: ["wl-paste", "--no-newline", "--type", "text/plain"]
    onExited: function(exitCode, exitStatus) {
      if (!root.opened || exitCode !== 0) return
      var pasted = String(pasteOut.text)
      if (pasted === "") return
      root.setTerm(root.term + pasted)
    }
  }

  Process {
    id: copyProc
  }

  Process {
    id: saveProc
    property string word: ""
    stdout: StdioCollector {
      id: saveOut
      waitForEnd: true
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        root.statusText = "Could not write the vocabulary file"
        statusTimer.restart()
        return
      }
      var count = String(saveOut.text).trim()
      root.statusText = count === ""
        ? "Saved “" + saveProc.word + "”"
        : "Saved “" + saveProc.word + "” — " + count + " in vocabulary"
      statusTimer.restart()
      root.notify("Saved " + saveProc.word)
      if (root.mode === "save") root.mode = "lookup"
    }
  }

  Process {
    id: notifyProc
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-dict"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      anchors.centerIn: parent
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { root.handleKey(event) }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.sm

        // ---------------------------------------------------------- heading
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm

          Text {
            textFormat: Text.PlainText
            text: "Dictionary"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.weight: Font.Medium
          }

          Text {
            textFormat: Text.PlainText
            text: root.mode === "search" ? "SEARCH"
              : (root.mode === "save" ? "SAVE TO VOCABULARY" : "LOOKUP")
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Item { Layout.fillWidth: true }

          Text {
            textFormat: Text.PlainText
            visible: root.busy
            text: "Searching…"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            text: root.statusText
            visible: root.statusText !== "" && !root.busy
            color: root.selectedText
            opacity: 0.85
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ------------------------------------------------------------ input
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: "WORD"
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: root.fieldHeight
          radius: root.cornerRadius
          color: "transparent"
          border.width: Style.spacing.hairline
          border.color: root.border

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            onClicked: keyCatcher.forceActiveFocus()
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.sm
            anchors.rightMargin: Style.spacing.sm
            text: root.term === ""
              ? "Type a word, or Ctrl+V to paste…"
              : root.singleLine(root.term) + (root.cursorVisible ? "▏" : "")
            color: root.term === "" ? root.faint : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            elide: Text.ElideLeft
          }
        }

        // ------------------------------------------- matches + definition
        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.spacing.md

          Rectangle {
            Layout.preferredWidth: Style.space(160)
            Layout.fillHeight: true
            radius: root.cornerRadius
            color: Util.alpha(root.selectedBackground, 0.28)
            border.width: Style.spacing.hairline
            border.color: root.hairline

            Text {
              anchors.centerIn: parent
              width: parent.width - Style.spacing.md * 2
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              visible: root.matches.length === 0
              text: root.busy ? "Searching…"
                : (root.noResults ? "No match"
                : (root.mode === "search" ? "Type to search" : ""))
              color: root.faint
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            ListView {
              id: matchList
              anchors.fill: parent
              anchors.margins: Style.spacing.xs
              model: root.matches
              clip: true
              spacing: Style.spacing.xxs
              boundsBehavior: Flickable.StopAtBounds

              delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool hasCursor: index === root.selectedIndex

                width: ListView.view.width
                height: root.rowHeight
                radius: root.cornerRadius
                color: hasCursor ? root.selectedBackground : "transparent"

                Column {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.spacing.sm
                  anchors.rightMargin: Style.spacing.sm
                  spacing: 0

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: modelData.word
                    color: hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: modelData.dict
                    color: hasCursor ? root.selectedText : root.faint
                    opacity: 0.75
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.selectedIndex = index
                  onClicked: { root.selectedIndex = index; keyCatcher.forceActiveFocus() }
                }
              }
            }
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: root.cornerRadius
            color: "transparent"
            border.width: Style.spacing.hairline
            border.color: root.hairline

            Flickable {
              id: defFlick
              anchors.fill: parent
              anchors.margins: Style.spacing.md
              clip: true
              contentWidth: width
              contentHeight: defColumn.implicitHeight
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: defColumn
                width: defFlick.width
                spacing: Style.spacing.xs

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: {
                    var e = root.currentEntry()
                    return e ? e.word : ""
                  }
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                  font.weight: Font.Medium
                  wrapMode: Text.Wrap
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: {
                    var e = root.currentEntry()
                    return e ? root.entryPhonetic(e) : ""
                  }
                  visible: text !== ""
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  wrapMode: Text.Wrap
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: {
                    var e = root.currentEntry()
                    return e ? root.entryBody(e) : ""
                  }
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  lineHeight: 1.25
                  wrapMode: Text.Wrap
                }
              }
            }
          }
        }

        // ----------------------------------------------------------- footer
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignRight
          text: "↑/↓ select  ·  Enter copy  ·  Ctrl+S save to vocabulary  ·  Ctrl+Del clear  ·  Esc close"
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
