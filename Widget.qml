import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar widget. While a timer runs it shows the clock icon, the project (or
// company) and the elapsed time. While idle it collapses to nothing and only
// peeks out, icon alone, when the center of the bar is hovered, the same way
// the inactive indicators do. Clicking opens the panel (TrackerPopup.qml).
//
// All data goes through bridge.py, one JSON request per run. Actions pressed
// while a refresh is in flight are queued, not dropped.
Panel {
    id: root
    moduleName: "peter.time-tracker"
    ipcTarget: "peter.time-tracker"
    manageIpc: false

    property var trackerState: ({running: null, selected_company: null, selected_project: null})
    property var companies: []
    property var projects: []
    property var records: []
    property string recordMessage: ""
    property string syncMessage: ""
    property string errorText: ""
    property string pdfPath: ""
    property string obsidianPath: ""
    property string obsidianUri: ""
    property real now: Date.now()
    property var queued: null

    readonly property bool vertical: bar ? bar.vertical : false
    readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
    readonly property var running: trackerState.running
    readonly property bool tracking: running !== null && running !== undefined
    readonly property real elapsed: tracking ? Math.max(0, (now - Date.parse(running.start)) / 1000) : 0
    readonly property bool busy: worker.running
    // Omarchy's shell resolves plugin files to qs:/// URLs (file:// on older
    // shells); both map straight onto the filesystem path.
    readonly property string bridge: decodeURIComponent(Qt.resolvedUrl("bridge.py").toString().replace(/^(?:file|qs):\/\//, ""))

    // ---------- bar presence: hidden while idle, peeking with the center hover ----------
    readonly property bool revealHeld: !!bar && bar.centerSectionRevealHeld === true && bar.centerHoverRevealSuppressed !== true
    readonly property bool shown: tracking || revealHeld || opened || errorText !== ""
    readonly property int maxLabel: Math.max(6, Number(setting("maxProjectLength", 24)) || 24)
    readonly property string activeName: tracking ? (running.project || running.company || "") : ""
    readonly property string barLabel: tracking && !vertical
        ? (activeName !== "" ? truncate(activeName, maxLabel) + "  " : "") + duration(elapsed) : ""

    implicitWidth: shown ? button.implicitWidth : 0
    implicitHeight: shown ? (vertical ? button.implicitHeight : barSize) : 0
    visible: shown

    function truncate(s, max) { s = String(s || ""); return s.length > max ? s.slice(0, max - 1) + "…" : s }
    function duration(seconds) {
        var s = Math.floor(seconds || 0)
        return Math.floor(s / 3600) + ":" + String(Math.floor(s / 60) % 60).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0")
    }
    function refresh() { if (!worker.running) request([]) }
    function request(args) {
        if (worker.running) {
            if (args.length) queued = args   // run as soon as the current request ends
            return
        }
        worker.isAction = args.length > 0
        worker.action = args.length ? args[0] : ""
        worker.received = false
        worker.command = ["/usr/bin/python3", "-E", "-s", "-B", root.bridge, JSON.stringify({args: args})]
        worker.running = true
    }

    onOpenedChanged: if (opened) refresh()

    ShellIpc {
        target: "peter.time-tracker"
        function toggle(): void { root.toggle() }
        function open(): void { root.open() }
        function close(): void { root.close() }
        function status(): string { return JSON.stringify({state: root.trackerState, error: root.errorText, open: root.opened}) }
    }

    Process {
        id: worker
        property bool isAction: false
        property string action: ""
        property bool received: false
        onRunningChanged: {
            if (running) { watchdog.restart(); return }
            watchdog.stop()
            if (root.queued) {
                var next = root.queued
                root.queued = null
                Qt.callLater(function() { root.request(next) })
            }
        }
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var data = JSON.parse(text)
                    worker.received = true
                    if (!data.ok) {
                        root.errorText = data.error
                        if (worker.action === "clockify-sync") root.syncMessage = ""
                        return
                    }
                    if (worker.isAction || root.errorText.indexOf("could not load") !== -1) root.errorText = ""
                    if (data.result && data.result.warning) root.errorText = data.result.warning
                    root.trackerState = data.status
                    root.companies = data.companies
                    root.projects = data.projects
                    root.now = Date.now()
                    if (worker.action === "records") root.records = data.result
                    if (data.result && data.result.deleted_records !== undefined) {
                        var deletedId = data.result.deleted_id
                        root.records = deletedId === null ? [] : root.records.filter(function(r) { return r.id !== deletedId })
                        root.recordMessage = data.result.deleted_records + " record(s) deleted."
                    }
                    if (worker.action === "clockify-sync" && data.result) {
                        var r = data.result
                        var parts = [r.added + " new", r.updated + " updated", r.removed + " removed"]
                        if (r.new_companies) parts.push(r.new_companies + " new companies")
                        if (r.new_projects) parts.push(r.new_projects + " new projects")
                        root.syncMessage = "Synced: " + parts.join(", ") + (r.skipped_running ? " (running Clockify timer skipped)" : "")
                    }
                    if (data.result && data.result.pdf_path) root.pdfPath = data.result.pdf_path
                    if (data.result && data.result.obsidian_path) {
                        root.obsidianPath = data.result.obsidian_path
                        root.obsidianUri = data.result.obsidian_uri
                    }
                } catch (e) { root.errorText = "Unable to read timer data: " + e }
            }
        }
        onExited: function(exitCode) {
            if (exitCode !== 0 && !received) root.errorText = "Time Tracker could not load its data (exit " + exitCode + ")."
        }
    }
    Timer {
        id: watchdog
        interval: 60000
        onTriggered: {
            worker.running = false
            root.errorText = "Time Tracker timed out. Check status before retrying an action."
        }
    }
    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    Timer { interval: 1000; running: root.tracking; repeat: true; onTriggered: root.now = Date.now() }

    // ---------- bar button ----------
    TextMetrics {
        id: labelMetrics
        font.family: bar ? bar.fontFamily : Style.font.family
        font.pixelSize: button.fontSize
        text: root.barLabel
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "󱎫"
        labelText: root.barLabel
        slotSize: root.barLabel !== "" ? Style.bar.iconSlot + labelMetrics.advanceWidth + Style.space(10) : Style.bar.iconSlot
        dimmed: !root.tracking && root.errorText === ""
        active: root.errorText !== "" && !root.tracking
        tooltipText: root.tracking
            ? (root.running.company + (root.running.project ? " · " + root.running.project : "")
               + "\n" + root.duration(root.elapsed) + (root.running.note ? "\n" + root.running.note : ""))
            : (root.errorText !== "" ? root.errorText : "Not tracking")
        onPressed: function(b) {
            if (b === Qt.RightButton && root.tracking) root.request(["stop"])
            else root.toggle()
        }
    }

    // ---------- panel ----------
    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: panel.loadedContent
        contentWidth: panel.fittedContentWidth(Style.space(400))
        contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

        content: PanelKeyCatcher {
            anchors.fill: parent
            implicitHeight: form.implicitHeight
            blocked: form.editing
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.switchPanel(direction) }

            Flickable {
                anchors.fill: parent
                contentWidth: width
                contentHeight: form.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height

                TrackerPopup {
                    id: form
                    width: parent.width
                    owner: root
                }
            }
        }
    }
}
