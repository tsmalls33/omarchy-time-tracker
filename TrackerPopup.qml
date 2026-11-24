import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Panel content. The main view is what you use every day: what is running,
// pick company + project, start/stop, sync Clockify. Reports, Obsidian and
// record management sit in a folded "More" section.
Column {
    id: form

    required property var owner
    readonly property var running: owner.running
    readonly property bool tracking: owner.tracking
    readonly property color fg: owner.bar ? owner.bar.foreground : Commons.Color.foreground
    readonly property string font: owner.bar ? owner.bar.fontFamily : Style.font.family
    readonly property color muted: Qt.darker(fg, 1.4)
    readonly property string noProject: "General company time"

    property string companyName: ""
    property string projectName: ""
    property bool addingCompany: false
    property bool addingProject: false
    property bool showMore: false
    property string deletionCommand: ""
    property int deletionId: 0
    property string deletionLabel: ""
    property string recordValue: ""
    property int editId: 0          // record being edited, 0 = none
    readonly property Item foldHeader: moreHeader

    // Keys go to whatever is being typed in or picked, not the panel.
    readonly property bool editing: noteField.activeFocus || startAtField.activeFocus || newCompanyField.activeFocus || newProjectField.activeFocus
        || reportDate.activeFocus || vaultPath.activeFocus || pushSince.activeFocus || deleteConfirmation.activeFocus || editStart.activeFocus || editEnd.activeFocus
        || pickerOpen
    readonly property bool pickerOpen: totalSpanPicker.popupOpen || totalPicker.popupOpen || companyPicker.popupOpen || projectPicker.popupOpen || period.popupOpen || scope.popupOpen || recordPicker.popupOpen

    readonly property var companyOptions: owner.companies.map(function(c) { return { value: c.name, label: c.name } })
    readonly property var projectOptions: {
        var company = owner.companies.find(function(c) { return c.name === form.companyName })
        return [{ value: "", label: form.noProject }].concat(owner.projects.filter(function(p) {
            return company && p.company_id === company.id
        }).map(function(p) { return { value: p.name, label: p.name } }))
    }
    readonly property bool editLinked: {
        var r = owner.records.find(function(x) { return x.id === form.editId })
        return !!(r && r.clockify_id)
    }
    readonly property var completedRecords: owner.records.filter(function(r) { return r.end !== null })
    readonly property var recordOptions: completedRecords.map(function(r) {
        return { value: String(r.id), label: r.start.slice(0, 16).replace("T", " ") + "  " + owner.duration(r.seconds)
                 + "  " + (r.project || form.noProject), description: r.company }
    })

    spacing: Style.space(12)

    function loadSelection() {
        companyName = owner.trackerState.selected_company || (owner.companies.length ? owner.companies[0].name : "")
        projectName = owner.trackerState.selected_project || ""
        vaultPath.text = owner.trackerState.obsidian_vault || ""
        addingCompany = addingProject = false
        deletionCommand = ""
    }
    function select(company, project) {
        companyName = company
        projectName = project
        if (company === "") return
        var args = ["select", "--company", company]
        if (project) args.push("--project", project)
        owner.request(args)   // remembered for next time, on every machine
    }
    function start() {
        if (companyName === "") return
        var args = ["start", "--company", companyName]
        if (projectName) args.push("--project", projectName)
        if (noteField.text.trim()) args.push("--note", noteField.text.trim())
        if (startAtField.text.trim()) args.push("--at", startAtField.text.trim())
        owner.request(args)
        noteField.clear()
        startAtField.clear()
    }
    // ---------- time spent: one project's total for a time frame ----------
    property string totalPick: ""      // JSON [company, project]; project "" = whole company
    property string totalSpan: "all"
    readonly property var totalOptions: {
        var out = []
        owner.companies.forEach(function(c) {
            out.push({ value: JSON.stringify([c.name, ""]), label: "All projects", description: c.name })
            owner.projects.filter(function(p) { return p.company_id === c.id }).forEach(function(p) {
                out.push({ value: JSON.stringify([c.name, p.name]), label: p.name, description: c.name })
            })
        })
        return out
    }
    function isoDay(d) {
        return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0")
    }
    // First pick: the running timer's project, else the selected one.
    function defaultTotalPick() {
        if (totalPick !== "" || !owner.opened) return false
        var r = owner.running, st = owner.trackerState
        var c = r ? r.company : st.selected_company, p = r ? r.project : st.selected_project
        if (!c) return false
        totalPick = JSON.stringify([c, p || ""])
        return true
    }
    function refreshTotal() {
        if (totalPick === "") return
        var pick = JSON.parse(totalPick)
        var d = new Date()
        var span = {
            today: ["daily", null], yesterday: ["daily", -1], week: ["weekly", null], lastweek: ["weekly", -7],
            month: ["monthly", null], lastmonth: ["monthly", "lastmonth"], year: ["yearly", null], all: ["all", null]
        }[totalSpan]
        var args = ["report", span[0]]
        if (span[1] === "lastmonth") { d.setDate(0); args.push("--date", isoDay(d)) }
        else if (span[1] !== null) { d.setDate(d.getDate() + span[1]); args.push("--date", isoDay(d)) }
        args.push("--company", pick[0])
        if (pick[1]) args.push("--project", pick[1])
        owner.request(args)
    }
    function hoursMinutes(seconds) {
        var m = Math.floor((seconds || 0) / 60)
        return Math.floor(m / 60) + "h " + String(m % 60).padStart(2, "0") + "m"
    }
    readonly property string totalRange: {
        var t = owner.total
        if (!t) return ""
        var end = new Date(t.end_exclusive + "T12:00:00")
        end.setDate(end.getDate() - 1)
        var last = isoDay(end)
        if (t.period === "all") return "since " + t.start
        return t.start === last ? t.start : t.start + " → " + last
    }
    onTotalPickChanged: refreshTotal()
    onTotalSpanChanged: refreshTotal()
    // A running timer keeps counting; ask again now and then while open.
    Timer {
        interval: 60000
        repeat: true
        running: form.owner.opened && form.tracking
        onTriggered: form.refreshTotal()
    }

    function report(format) {
        var args = ["report", period.value]
        if (reportDate.text.trim()) args.push("--date", reportDate.text.trim())
        if (scope.value !== "all") args.push("--company", companyName)
        if (scope.value === "project" && projectName) args.push("--project", projectName)
        args.push(format === "pdf" ? "--pdf" : "--obsidian")
        owner.request(args)
    }

    Connections {
        target: form.owner
        function onOpenedChanged() {
            if (!form.owner.opened) return
            form.loadSelection()
            if (!form.defaultTotalPick()) form.refreshTotal()
        }
        function onTrackerStateChanged() { form.defaultTotalPick() }
        function onCompaniesChanged() {
            if (form.companyName === "" && form.owner.companies.length) form.loadSelection()
        }
    }

    component PlainLabel: Text {
        textFormat: Text.PlainText
        color: form.fg
        font.family: form.font
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
    }
    component Caption: PlainLabel {
        color: form.muted
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        elide: Text.ElideNone
    }
    // A picker is one tab stop: Enter or Space opens its list; arrows pass
    // on to the panel instead of opening it. Its own trigger stops taking
    // Tab, and this ring shows when the picker holds focus.
    function pickerKey(picker, event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            picker.open()
            event.accepted = true
        }
    }
    component PickerRing: Rectangle {
        property Item trigger: null
        Component.onCompleted: {
            function find(it) {
                for (var i = 0; i < it.children.length; i++) {
                    var c = it.children[i]
                    if (c.activeFocusOnTab) return c
                    var d = find(c)
                    if (d) return d
                }
                return null
            }
            trigger = find(parent)
            if (trigger) trigger.activeFocusOnTab = false
        }
        visible: parent.activeFocus
        width: parent.width
        height: trigger ? trigger.height : parent.height
        y: parent.height - height
        z: 10
        color: "transparent"
        radius: Style.cornerRadius
        border.width: 2
        border.color: Commons.Color.accent
    }
    component Action: Button {
        bordered: true
        focusable: true
        foreground: form.fg
        fontFamily: form.font
        opacity: enabled ? 1 : 0.4   // the kit barely marks a disabled button
    }

    // ---------- hero: what is running ----------
    Item {
        width: parent.width
        implicitHeight: Math.max(heroLeft.implicitHeight, heroTime.implicitHeight)

        Row {
            id: heroLeft
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(10); height: width; radius: width / 2
                color: form.tracking ? Commons.Color.accent : Qt.rgba(form.fg.r, form.fg.g, form.fg.b, 0.3)
            }
            Column {
                PlainLabel { text: form.tracking ? "Tracking" : "Not tracking"; font.bold: true }
                PlainLabel {
                    visible: form.tracking
                    width: Math.min(implicitWidth, form.width - heroTime.implicitWidth - Style.space(40))
                    text: form.tracking ? form.running.company + (form.running.project ? " · " + form.running.project : "") : ""
                    color: form.muted
                    font.pixelSize: Style.font.caption
                }
            }
        }
        PlainLabel {
            id: heroTime
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: form.owner.duration(form.owner.elapsed)
            font.pixelSize: Style.font.body * 1.8
            opacity: form.tracking ? 1 : 0.4
        }
    }

    Caption {
        visible: form.tracking && !!form.running.note
        width: parent.width
        text: form.tracking ? form.running.note || "" : ""
    }

    PanelSeparator { width: parent.width; foreground: form.fg }

    // ---------- pick + start (idle) ----------
    Column {
        width: parent.width
        spacing: Style.space(10)
        visible: !form.tracking

        Row {
            width: parent.width
            spacing: Style.space(6)
            SearchableDropdown {
                id: companyPicker
                activeFocusOnTab: true
                Keys.onPressed: function(event) { form.pickerKey(companyPicker, event) }
                PickerRing {}
                width: parent.width - addCompanyButton.width - parent.spacing
                label: "Company"
                options: form.companyOptions
                value: form.companyName
                triggerLabel: form.companyOptions.length ? "" : "Add a company first"
                placeholderText: "Search companies…"
                foreground: form.fg
                fontFamily: form.font
                onChanged: function(v) { form.select(v, "") }
            }
            PanelActionButton {
                id: addCompanyButton
                anchors.bottom: companyPicker.bottom
                iconText: form.addingCompany ? "󰅖" : "󰐕"
                tooltipText: "New company"
                focusable: true
                foreground: form.fg
                fontFamily: form.font
                onClicked: { form.addingCompany = !form.addingCompany; if (form.addingCompany) newCompanyField.forceActiveFocus() }
            }
        }
        Row {
            visible: form.addingCompany
            width: parent.width
            spacing: Style.space(6)
            TextField {
                id: newCompanyField
                width: parent.width - addCompany.width - parent.spacing
                placeholderText: "New company name"
                maximumLength: 200
                foreground: form.fg
                font.family: form.font
                onAccepted: addCompany.clicked()
                Keys.onEscapePressed: form.addingCompany = false
            }
            Action {
                id: addCompany
                text: "Add"
                enabled: !form.owner.busy && newCompanyField.text.trim() !== ""
                onClicked: {
                    var name = newCompanyField.text.trim()
                    if (name === "") return
                    form.owner.request(["add-company", name])
                    form.companyName = name
                    form.projectName = ""
                    newCompanyField.clear()
                    form.addingCompany = false
                }
            }
        }

        Row {
            width: parent.width
            spacing: Style.space(6)
            SearchableDropdown {
                id: projectPicker
                activeFocusOnTab: true
                Keys.onPressed: function(event) { form.pickerKey(projectPicker, event) }
                PickerRing {}
                width: parent.width - addProjectButton.width - parent.spacing
                label: "Project"
                options: form.projectOptions
                value: form.projectName
                triggerLabel: form.noProject
                placeholderText: "Search projects…"
                foreground: form.fg
                fontFamily: form.font
                onChanged: function(v) { form.select(form.companyName, v) }
            }
            PanelActionButton {
                id: addProjectButton
                anchors.bottom: projectPicker.bottom
                enabled: form.companyName !== ""
                iconText: form.addingProject ? "󰅖" : "󰐕"
                tooltipText: "New project"
                focusable: true
                foreground: form.fg
                fontFamily: form.font
                onClicked: { form.addingProject = !form.addingProject; if (form.addingProject) newProjectField.forceActiveFocus() }
            }
        }
        Row {
            visible: form.addingProject
            width: parent.width
            spacing: Style.space(6)
            TextField {
                id: newProjectField
                width: parent.width - addProject.width - parent.spacing
                placeholderText: "New project for " + form.companyName
                maximumLength: 200
                foreground: form.fg
                font.family: form.font
                onAccepted: addProject.clicked()
                Keys.onEscapePressed: form.addingProject = false
            }
            Action {
                id: addProject
                text: "Add"
                enabled: !form.owner.busy && form.companyName !== "" && newProjectField.text.trim() !== ""
                onClicked: {
                    var name = newProjectField.text.trim()
                    if (name === "" || form.companyName === "") return
                    form.owner.request(["add-project", name, "--company", form.companyName])
                    form.projectName = name
                    newProjectField.clear()
                    form.addingProject = false
                }
            }
        }

        TextField {
            id: noteField
            width: parent.width
            placeholderText: "What are you working on? (optional)"
            maximumLength: 2000
            foreground: form.fg
            font.family: form.font
            onAccepted: form.start()
            Keys.onEscapePressed: form.owner.close()
        }
    }

    // ---------- main actions ----------
    Row {
        spacing: Style.space(8)
        Action {
            visible: !form.tracking
            text: "Start"; iconText: "󰐊"
            enabled: !form.owner.busy && form.companyName !== ""
            onClicked: form.start()
        }
        // Empty = now. Otherwise today at 1600 / 16:00 / 0900 / 4pm (checked by tracker.py).
        TextField {
            id: startAtField
            visible: !form.tracking
            width: Style.space(96)
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "at: now"
            maximumLength: 8
            foreground: form.fg
            font.family: form.font
            onAccepted: form.start()
            Keys.onEscapePressed: form.owner.close()
        }
        Action {
            visible: form.tracking
            text: "Stop"; iconText: "󰓛"
            enabled: !form.owner.busy
            onClicked: form.owner.request(["stop"])
        }
        // Clockify is only contacted here, when pressed (clockify_sync.py).
        Action {
            text: "Sync Clockify"; iconText: "󰑐"
            enabled: !form.owner.busy
            onClicked: { form.owner.syncMessage = "Syncing with Clockify…"; form.owner.request(["clockify-sync"]) }
        }
    }

    Caption {
        width: parent.width
        text: form.owner.syncMessage !== "" ? form.owner.syncMessage
            : (form.owner.trackerState.clockify_synced_at
               ? "Clockify last synced " + form.owner.trackerState.clockify_synced_at.replace("T", " ").slice(0, 16) + " UTC"
               : "Clockify never synced")
            + (form.owner.trackerState.clockify_push_since ? " · sends sessions from " + form.owner.trackerState.clockify_push_since : "")
    }

    PlainLabel {
        visible: form.owner.errorText !== ""
        width: parent.width
        wrapMode: Text.WordWrap
        elide: Text.ElideNone
        text: form.owner.errorText
        color: Commons.Color.urgent
        font.pixelSize: Style.font.caption
    }

    PanelSeparator { width: parent.width; foreground: form.fg }

    // ---------- time spent ----------
    Column {
        width: parent.width
        spacing: Style.space(8)

        PanelSectionHeader { text: "Time spent"; foreground: form.fg; fontFamily: form.font }
        Row {
            width: parent.width
            spacing: Style.space(6)
            Dropdown {
                id: totalSpanPicker
                activeFocusOnTab: true
                Keys.onPressed: function(event) { form.pickerKey(totalSpanPicker, event) }
                PickerRing {}
                width: Style.space(130)
                showLabel: false
                value: form.totalSpan
                options: [{ value: "today", label: "Today" }, { value: "yesterday", label: "Yesterday" },
                          { value: "week", label: "This week" }, { value: "lastweek", label: "Last week" },
                          { value: "month", label: "This month" }, { value: "lastmonth", label: "Last month" },
                          { value: "year", label: "This year" }, { value: "all", label: "All time" }]
                foreground: form.fg
                fontFamily: form.font
                onChanged: function(v) { form.totalSpan = v }
            }
            SearchableDropdown {
                id: totalPicker
                activeFocusOnTab: true
                Keys.onPressed: function(event) { form.pickerKey(totalPicker, event) }
                PickerRing {}
                width: parent.width - totalSpanPicker.width - parent.spacing
                showLabel: false
                options: form.totalOptions
                value: form.totalPick
                triggerLabel: "Pick a project"
                placeholderText: "Search projects…"
                foreground: form.fg
                fontFamily: form.font
                onChanged: function(v) { form.totalPick = v }
            }
        }
        // The closed picker shows the project; its client sits faded below.
        Caption {
            x: totalPicker.x + Style.space(2)
            width: totalPicker.width
            visible: form.totalPick !== ""
            text: form.totalPick !== "" ? JSON.parse(form.totalPick)[0] : ""
            elide: Text.ElideRight
            wrapMode: Text.NoWrap
        }
        Item {
            width: parent.width
            implicitHeight: totalValue.implicitHeight
            PlainLabel {
                id: totalValue
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: form.owner.total ? form.hoursMinutes(form.owner.total.total_seconds) : "–"
                font.pixelSize: Style.font.body * 1.8
                font.bold: true
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)
                // Same dot as "Tracking" up top: the total counts the running timer.
                Rectangle {
                    visible: !!form.owner.total && form.owner.total.includes_running_timer
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(8); height: width; radius: width / 2
                    color: Commons.Color.accent
                }
                Caption {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, form.width - totalValue.implicitWidth - Style.space(32))
                    horizontalAlignment: Text.AlignRight
                    text: form.owner.total
                        ? Commons.I18n.formatNumber(form.owner.total.total_hours, 2) + " h · " + form.totalRange
                        : ""
                }
            }
        }
    }

    PanelSeparator { width: parent.width; foreground: form.fg }

    // ---------- folded: reports, Obsidian, records ----------
    Rectangle {
        id: moreHeader
        width: parent.width
        implicitHeight: moreRow.implicitHeight + Style.space(4)
        radius: Style.space(4)
        color: activeFocus ? Style.focusFillFor(form.fg, Commons.Color.accent) : "transparent"
        border.width: activeFocus ? 1 : 0
        border.color: Commons.Color.accent
        activeFocusOnTab: true
        function toggle() {
            form.showMore = !form.showMore
            if (form.showMore) form.owner.request(["records", "--limit", "10000"])
        }
        Keys.onReturnPressed: toggle()
        Keys.onEnterPressed: toggle()
        Keys.onSpacePressed: toggle()

        Row {
            id: moreRow
            anchors.verticalCenter: parent.verticalCenter
            x: Style.space(4)
            spacing: Style.space(8)
            PlainLabel { text: form.showMore ? "󰅀" : "󰅂"; color: form.muted }
            PanelSectionHeader { text: "Records, reports & Obsidian"; foreground: form.fg; fontFamily: form.font }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: moreHeader.toggle()
        }
    }

    Column {
        visible: form.showMore
        width: parent.width
        spacing: Style.space(10)

        // Records
        PanelSectionHeader { text: "Records"; foreground: form.fg; fontFamily: form.font }
        SearchableDropdown {
            id: recordPicker
            activeFocusOnTab: true
            Keys.onPressed: function(event) { form.pickerKey(recordPicker, event) }
            PickerRing {}
            width: parent.width
            showLabel: false
            options: form.recordOptions
            value: form.recordValue
            foreground: form.fg
            fontFamily: form.font
            placeholderText: "Search records…"
            onChanged: function(v) { form.recordValue = v }
        }
        Caption {
            readonly property var opt: form.recordOptions.find(function(o) { return o.value === form.recordValue })
            visible: !!opt
            width: parent.width
            text: opt ? opt.description : ""
            elide: Text.ElideRight
            wrapMode: Text.NoWrap
        }
        Row {
            spacing: Style.space(8)
            Action {
                text: "Edit"; iconText: "󰏫"
                enabled: !form.owner.busy && form.recordValue !== ""
                onClicked: {
                    var r = form.completedRecords.find(function(x) { return String(x.id) === form.recordValue })
                    if (!r) return
                    form.deletionCommand = ""
                    form.editId = r.id
                    editStart.text = r.start.slice(0, 16).replace("T", " ")
                    editEnd.text = r.end.slice(0, 16).replace("T", " ")
                    editStart.forceActiveFocus()
                }
            }
            Action {
                text: "Delete"; iconText: "󰆴"
                enabled: !form.owner.busy && form.recordValue !== ""
                onClicked: {
                    form.editId = 0
                    form.deletionId = parseInt(form.recordValue, 10)
                    var opt = form.recordOptions.find(function(o) { return o.value === form.recordValue })
                    form.deletionLabel = opt ? opt.label + " (" + opt.description + ")" : "#" + form.recordValue
                    form.deletionCommand = "delete-record"
                    deleteConfirmation.clear()
                }
            }
            Action {
                text: "Clear all"; iconText: "󰎟"
                enabled: !form.owner.busy && !form.tracking && form.owner.records.length > 0
                onClicked: { form.editId = 0; form.deletionCommand = "clear-records"; deleteConfirmation.clear() }
            }
            Action {
                text: "Reload"; iconText: "󰑐"
                enabled: !form.owner.busy
                onClicked: { form.deletionCommand = ""; form.owner.request(["records", "--limit", "10000"]) }
            }
        }
        // Edit: date + time of start and end. A time alone (1600, 4pm) keeps the day.
        Column {
            visible: form.editId !== 0
            width: parent.width
            spacing: Style.space(6)
            Caption {
                width: parent.width
                text: "Start and end as 2026-11-18 16:00, or just 1600 / 4pm to keep the day."
                      + (form.editLinked ? " Linked to Clockify: saving changes it there too (one request)." : "")
            }
            Row {
                width: parent.width
                spacing: Style.space(6)
                TextField {
                    id: editStart
                    width: (parent.width - parent.spacing) / 2
                    placeholderText: "Start"
                    maximumLength: 32
                    foreground: form.fg
                    font.family: form.font
                    onAccepted: saveEdit.clicked()
                    Keys.onEscapePressed: form.editId = 0
                }
                TextField {
                    id: editEnd
                    width: (parent.width - parent.spacing) / 2
                    placeholderText: "End"
                    maximumLength: 32
                    foreground: form.fg
                    font.family: form.font
                    onAccepted: saveEdit.clicked()
                    Keys.onEscapePressed: form.editId = 0
                }
            }
            Row {
                spacing: Style.space(8)
                Action {
                    id: saveEdit
                    text: "Save"; iconText: "󰄬"
                    enabled: !form.owner.busy && editStart.text.trim() !== "" && editEnd.text.trim() !== ""
                    onClicked: {
                        if (!enabled) return
                        form.owner.request(["edit-record", String(form.editId), "--start", editStart.text.trim(), "--end", editEnd.text.trim()])
                        form.editId = 0
                    }
                }
                Action {
                    text: "Cancel"
                    onClicked: form.editId = 0
                }
            }
        }
        Column {
            visible: form.deletionCommand !== ""
            width: parent.width
            spacing: Style.space(6)
            Caption {
                width: parent.width
                text: (form.deletionCommand === "clear-records" ? "Permanently delete ALL time records for every company?"
                       : "Permanently delete " + form.deletionLabel + "?") + " Type DELETE to confirm. Exported PDFs and notes stay."
            }
            Row {
                width: parent.width
                spacing: Style.space(6)
                TextField {
                    id: deleteConfirmation
                    width: parent.width - confirmDelete.width - cancelDelete.width - 2 * parent.spacing
                    placeholderText: "DELETE"
                    foreground: form.fg
                    font.family: form.font
                }
                Action {
                    id: confirmDelete
                    text: "Delete"
                    enabled: !form.owner.busy && deleteConfirmation.text === "DELETE"
                    onClicked: {
                        var args = [form.deletionCommand]
                        if (form.deletionCommand === "delete-record") args.push(String(form.deletionId))
                        args.push("--confirm")
                        form.owner.request(args)
                        form.deletionCommand = ""
                        form.recordValue = ""
                        deleteConfirmation.clear()
                    }
                }
                Action {
                    id: cancelDelete
                    text: "Cancel"
                    onClicked: { form.deletionCommand = ""; deleteConfirmation.clear() }
                }
            }
        }
        Caption { visible: text !== ""; width: parent.width; text: form.owner.recordMessage }

        PanelSeparator { width: parent.width; foreground: form.fg }

        // Reports
        PanelSectionHeader { text: "Report"; foreground: form.fg; fontFamily: form.font }
        Row {
            width: parent.width
            spacing: Style.space(6)
            Dropdown {
                id: period
                activeFocusOnTab: true
                Keys.onPressed: function(event) { form.pickerKey(period, event) }
                PickerRing {}
                width: Style.space(120)
                showLabel: false
                value: "weekly"
                options: [{ value: "daily", label: "Day" }, { value: "weekly", label: "Week" },
                          { value: "monthly", label: "Month" }, { value: "yearly", label: "Year" }]
                foreground: form.fg
                fontFamily: form.font
                onChanged: function(v) { period.value = v }
            }
            TextField {
                id: reportDate
                width: parent.width - period.width - parent.spacing
                placeholderText: "Any date in it (YYYY-MM-DD), blank = current"
                maximumLength: 10
                foreground: form.fg
                font.family: form.font
            }
        }
        Dropdown {
            id: scope
            activeFocusOnTab: true
            Keys.onPressed: function(event) { form.pickerKey(scope, event) }
            PickerRing {}
            width: parent.width
            showLabel: false
            value: "all"
            options: [{ value: "all", label: "All companies" },
                      { value: "company", label: "Selected company: " + (form.companyName || "none") },
                      { value: "project", label: "Selected project: " + (form.projectName || form.noProject) }]
            foreground: form.fg
            fontFamily: form.font
            onChanged: function(v) { scope.value = v }
        }
        Row {
            spacing: Style.space(8)
            Action {
                text: "PDF"; iconText: "󰈦"
                enabled: !form.owner.busy && (scope.value === "all" || form.companyName !== "")
                onClicked: form.report("pdf")
            }
            Action {
                text: "Obsidian note"; iconText: "󰠮"
                tooltipText: form.owner.trackerState.obsidian_vault ? "Write this report into the vault" : "Save a vault folder under Obsidian first"
                enabled: !form.owner.busy && !!form.owner.trackerState.obsidian_vault && (scope.value === "all" || form.companyName !== "")
                onClicked: form.report("obsidian")
            }
            Action {
                visible: form.owner.pdfPath !== ""
                text: "Open PDF"; iconText: "󰏌"
                onClicked: { Quickshell.execDetached(["/usr/bin/xdg-open", form.owner.pdfPath]); form.owner.close() }
            }
        }
        Caption {
            visible: form.owner.pdfPath !== ""
            width: parent.width
            wrapMode: Text.WrapAnywhere
            text: "Saved " + form.owner.pdfPath
        }

        PanelSeparator { width: parent.width; foreground: form.fg }

        // Clockify: which local sessions Sync Clockify sends
        PanelSectionHeader { text: "Clockify"; foreground: form.fg; fontFamily: form.font }
        Caption {
            width: parent.width
            text: "Sync Clockify sends finished sessions tracked here from this date on (default: the day of your first sync). Earlier ones stay local."
        }
        Row {
            width: parent.width
            spacing: Style.space(6)
            TextField {
                id: pushSince
                width: parent.width - savePushSince.width - parent.spacing
                text: form.owner.trackerState.clockify_push_since || ""
                placeholderText: "YYYY-MM-DD"
                maximumLength: 10
                foreground: form.fg
                font.family: form.font
                onAccepted: savePushSince.clicked()
            }
            Action {
                id: savePushSince
                text: "Save"
                enabled: !form.owner.busy && /^\d{4}-\d{2}-\d{2}$/.test(pushSince.text.trim())
                onClicked: form.owner.request(["clockify-push-since", pushSince.text.trim()])
            }
        }

        PanelSeparator { width: parent.width; foreground: form.fg }

        // Obsidian
        PanelSectionHeader { text: "Obsidian"; foreground: form.fg; fontFamily: form.font }
        Toggle {
            width: parent.width
            label: "Log each stopped timer"
            description: form.owner.trackerState.obsidian_vault ? "Writes a note per session into the vault" : "Save a vault first"
            checked: form.owner.trackerState.obsidian_autolog === true
            enabled: !form.owner.busy && !!form.owner.trackerState.obsidian_vault
            foreground: form.fg
            fontFamily: form.font
            onClicked: form.owner.request(["auto-obsidian", checked ? "off" : "on"])
        }
        Row {
            width: parent.width
            spacing: Style.space(6)
            TextField {
                id: vaultPath
                width: parent.width - saveVault.width - clearVault.width - 2 * parent.spacing
                placeholderText: "Vault folder, e.g. ~/Documents/Notes"
                maximumLength: 4096
                foreground: form.fg
                font.family: form.font
                onAccepted: saveVault.clicked()
            }
            Action {
                id: saveVault
                text: "Save"
                enabled: !form.owner.busy && vaultPath.text.trim() !== ""
                onClicked: form.owner.request(["vault", vaultPath.text.trim()])
            }
            Action {
                id: clearVault
                text: "Clear"
                enabled: !form.owner.busy && !!form.owner.trackerState.obsidian_vault
                onClicked: { form.owner.request(["vault", "--clear"]); vaultPath.clear() }
            }
        }
        Row {
            spacing: Style.space(8)
            Action {
                text: "Open in Obsidian"; iconText: "󰏌"
                enabled: !!form.owner.trackerState.obsidian_vault
                onClicked: {
                    var uri = form.owner.obsidianUri || "obsidian://open?path=" + encodeURIComponent(form.owner.trackerState.obsidian_vault)
                    Quickshell.execDetached(["/usr/bin/xdg-open", uri])
                    form.owner.close()
                }
            }
            Action {
                visible: (form.owner.trackerState.obsidian_pending || 0) > 0
                text: "Retry " + (form.owner.trackerState.obsidian_pending || 0) + " pending"; iconText: "󰑐"
                enabled: !form.owner.busy
                onClicked: form.owner.request(["retry-obsidian"])
            }
        }

        Caption { width: parent.width; text: "Timezone " + (form.owner.trackerState.timezone || "…") }
    }
}
