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
    property var queued: []       // requests waiting for the running one, in order
    property var total: null      // last "Time spent" result (report without export)

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
    // "hiddenInBar": true in this widget's shell.json entry, for a bar that shows
    // the timer elsewhere (e.g. an indicator calling the IPC below); the widget
    // then only appears to anchor the open panel.
    readonly property bool hiddenInBar: setting("hiddenInBar", false) === true
    readonly property bool shown: opened || (!hiddenInBar && (tracking || revealHeld || errorText !== ""))
    // With hiddenInBar the widget is never drawn: while the panel is open it
    // stays as a zero-width anchor, so the indicator's timer isn't doubled.
    readonly property bool drawn: shown && !hiddenInBar
    // Only the elapsed time shows in the bar; the tooltip names the project.
    readonly property string barLabel: tracking && !vertical ? duration(elapsed) : ""

    implicitWidth: drawn ? button.implicitWidth : 0
    implicitHeight: shown ? (vertical ? button.implicitHeight : barSize) : 0
    visible: shown

    function duration(seconds) {
        var s = Math.floor(seconds || 0)
        return Math.floor(s / 3600) + ":" + String(Math.floor(s / 60) % 60).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0")
    }
    function isTotal(args) { return args[0] === "report" && args.indexOf("--pdf") < 0 && args.indexOf("--obsidian") < 0 }
    function refresh() { if (!worker.running) request([]) }
    function request(args) {
        if (worker.running) {
            // Run as soon as the current request ends. A newer time-spent
            // query replaces one still waiting; actions all keep their turn.
            if (args.length) queued = queued.filter(function(q) { return !(isTotal(q) && isTotal(args)) }).concat([args])
            return
        }
        worker.args = args
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
        function stop(): void { if (root.tracking) root.request(["stop"]) }
        function status(): string { return JSON.stringify({state: root.trackerState, error: root.errorText, open: root.opened}) }
    }

    Process {
        id: worker
        property bool isAction: false
        property string action: ""
        property var args: []
        property bool received: false
        onRunningChanged: {
            if (running) { watchdog.restart(); return }
            watchdog.stop()
            if (root.queued.length) {
                var next = root.queued[0]
                root.queued = root.queued.slice(1)
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
                    if (root.isTotal(worker.args)) root.total = data.result
                    if (data.result && data.result.edited) {
                        var e = data.result.edited
                        root.records = root.records.map(function(r) { return r.id === e.id ? e : r })
                            .sort(function(x, y) { return y.start < x.start ? -1 : 1 })
                        root.recordMessage = "Record saved: " + e.start.slice(0, 16).replace("T", " ") + " to "
                            + e.end.slice(11, 16) + " (" + root.duration(e.seconds) + ")"
                            + (data.result.clockify_updated ? " · Clockify updated" : "")
                    }
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
                        var sent = ["sent " + (r.pushed || 0)]
                        if (r.push_waiting) sent.push(r.push_waiting + " waiting (rate limit, sync again later)")
                        if (r.push_overlaps) sent.push(r.push_overlaps + " not sent: overlap Clockify time")
                        root.syncMessage = "Received " + parts.join(", ") + " · " + sent.join(", ")
                            + (r.skipped_running ? " · running Clockify timer skipped" : "")
                        if (r.push_error) root.errorText = "Sending stopped: " + r.push_error
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
    readonly property string tooltip: tracking
        ? (running.company + (running.project ? " · " + running.project : "")
           + "\n" + duration(elapsed) + (running.note ? "\n" + running.note : ""))
        : (errorText !== "" ? errorText : "Not tracking")
    readonly property Item button: barLabel !== "" ? timeButton : iconButton

    function pressed(b) {
        if (b === Qt.RightButton && tracking) request(["stop"])
        else toggle()
    }

    // Idle: the plain clock icon, sized like every other bar icon.
    BarIconButton {
        id: iconButton
        anchors.fill: parent
        visible: root.barLabel === ""
        opacity: root.hiddenInBar ? 0 : 1
        enabled: !root.hiddenInBar
        bar: root.bar
        text: "󱎫"
        dimmed: !root.tracking && root.errorText === ""
        active: root.errorText !== "" && !root.tracking
        tooltipText: root.tooltip
        onPressed: function(b) { root.pressed(b) }
    }

    // Tracking: icon and elapsed time as one text button (as command widgets
    // draw text), which pads itself like its neighbours.
    WidgetButton {
        id: timeButton
        anchors.fill: parent
        visible: root.barLabel !== ""
        opacity: root.hiddenInBar ? 0 : 1
        enabled: !root.hiddenInBar
        bar: root.bar
        text: "󱎫  " + root.barLabel
        tooltipText: root.tooltip
        onPressed: function(b) { root.pressed(b) }
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

        // Keyboard: Tab / Shift+Tab and the arrows walk every visible control
        // in reading order; Enter or Space presses buttons and opens pickers
        // (open a picker's list with Enter, arrows choose); Esc closes. Ctrl+Tab still hops to the
        // neighbouring bar panel. Controls get keys first, so text fields keep
        // Left/Right and typing, and an open picker keeps its own arrows.
        content: FocusScope {
            id: keyNav
            anchors.fill: parent
            implicitHeight: form.implicitHeight
            focus: true

            function focusables() {
                var out = []
                function walk(it) {
                    if (!it || !it.visible) return
                    if (it.activeFocusOnTab && it.enabled && it.width > 0) out.push(it)
                    for (var i = 0; i < it.children.length; i++) walk(it.children[i])
                }
                walk(form)
                return out
            }
            function reveal(item) {
                var y = item.mapToItem(flick.contentItem, 0, 0).y
                var max = Math.max(0, flick.contentHeight - flick.height)
                if (y < flick.contentY) flick.contentY = Math.max(0, y - Style.space(8))
                else if (y + item.height > flick.contentY + flick.height)
                    flick.contentY = Math.min(max, y + item.height - flick.height + Style.space(8))
            }
            function focusAt(item) {
                if (!item) return
                item.forceActiveFocus(Qt.TabFocusReason)
                reveal(item)
            }
            function move(step) {
                var list = focusables()
                if (!list.length) return
                var cur = -1
                for (var a = keyNav.Window.activeFocusItem; a && cur < 0; a = a.parent) cur = list.indexOf(a)
                var next = cur < 0 ? (step > 0 ? 0 : list.length - 1) : (cur + step + list.length) % list.length
                focusAt(list[next])
            }
            function focusFirst() { focusAt(focusables()[0]) }

            // The panel hands focus to this scope after opening; pass it on to
            // the first control whenever nothing inside holds it.
            onActiveFocusChanged: if (activeFocus) Qt.callLater(function() {
                if (keyNav.activeFocus && !keyNav.focusables().some(function(it) { return it.activeFocus })) keyNav.focusFirst()
            })
            // Clicking a picker focuses its inner trigger (and closing the list
            // hands focus back there); move it to the picker so arrows walk on.
            Window.onActiveFocusItemChanged: Qt.callLater(function() {
                ring.place()
                var a = keyNav.Window.activeFocusItem
                if (!a || form.pickerOpen) return
                for (var p = a.parent; p && p !== form; p = p.parent)
                    if (p.popupOpen !== undefined && p.activeFocusOnTab) { p.forceActiveFocus(); return }
            })

            Connections {
                target: root
                function onOpenedChanged() { if (root.opened) Qt.callLater(keyNav.focusFirst) }
                // Start/Stop swap places; keep focus on the button that replaced it.
                function onTrackingChanged() { if (root.opened) Qt.callLater(keyNav.focusFirst) }
            }

            Keys.onPressed: function(event) {
                if (form.pickerOpen) return
                var k = event.key
                if (k === Qt.Key_Escape) { root.close(); event.accepted = true; return }
                if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
                    var back = k === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier)
                    if (event.modifiers & Qt.ControlModifier) root.switchPanel(back ? -1 : 1)
                    else move(back ? -1 : 1)
                    event.accepted = true
                    return
                }
                var fwd = LayoutMirroring.enabled ? Qt.Key_Left : Qt.Key_Right
                var bwd = LayoutMirroring.enabled ? Qt.Key_Right : Qt.Key_Left
                if (k === Qt.Key_Down || k === fwd) { move(1); event.accepted = true; return }
                if (k === Qt.Key_Up || k === bwd) { move(-1); event.accepted = true; return }
            }

            Flickable {
                id: flick
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

                // The kit's own focus marks are faint; one accent ring follows
                // the focused control. Pickers and the fold header draw their own.
                Rectangle {
                    id: ring
                    property Item target: null
                    function place() {
                        var a = keyNav.Window.activeFocusItem
                        var list = keyNav.focusables()
                        while (a && list.indexOf(a) < 0) a = a.parent
                        target = a && a.popupOpen === undefined && a !== form.foldHeader ? a : null
                        if (!target) return
                        var p = target.mapToItem(flick.contentItem, 0, 0)
                        x = p.x - 2; y = p.y - 2
                        width = target.width + 4; height = target.height + 4
                    }
                    visible: target !== null && target.visible && target.activeFocus
                    z: 10
                    color: "transparent"
                    radius: Style.cornerRadius + 2
                    border.width: 2
                    border.color: Commons.Color.accent
                }
                Connections {
                    target: form
                    function onImplicitHeightChanged() { Qt.callLater(ring.place) }
                    function onWidthChanged() { Qt.callLater(ring.place) }
                }
            }
        }
    }
}
