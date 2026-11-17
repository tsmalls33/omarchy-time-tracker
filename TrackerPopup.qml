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

    // Keys go to whatever is being typed in or picked, not the panel.
    readonly property bool editing: noteField.activeFocus || newCompanyField.activeFocus || newProjectField.activeFocus
        || reportDate.activeFocus || vaultPath.activeFocus || pushSince.activeFocus || deleteConfirmation.activeFocus
        || companyPicker.popupOpen || projectPicker.popupOpen || period.popupOpen || scope.popupOpen || recordPicker.popupOpen

    readonly property var companyOptions: owner.companies.map(function(c) { return { value: c.name, label: c.name } })
    readonly property var projectOptions: {
        var company = owner.companies.find(function(c) { return c.name === form.companyName })
        return [{ value: "", label: form.noProject }].concat(owner.projects.filter(function(p) {
            return company && p.company_id === company.id
        }).map(function(p) { return { value: p.name, label: p.name } }))
    }
    readonly property var completedRecords: owner.records.filter(function(r) { return r.end !== null })
    readonly property var recordOptions: completedRecords.map(function(r) {
        return { value: String(r.id), label: r.start.slice(0, 16).replace("T", " ") + "  " + owner.duration(r.seconds)
                 + "  " + r.company + (r.project ? " · " + r.project : "") }
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
        owner.request(args)
        noteField.clear()
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
        function onOpenedChanged() { if (form.owner.opened) form.loadSelection() }
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
    component Action: Button {
        bordered: true
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

    // ---------- folded: reports, Obsidian, records ----------
    Item {
        width: parent.width
        implicitHeight: moreRow.implicitHeight + Style.space(4)

        Row {
            id: moreRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)
            PlainLabel { text: form.showMore ? "󰅀" : "󰅂"; color: form.muted }
            PanelSectionHeader { text: "Reports, Obsidian & records"; foreground: form.fg; fontFamily: form.font }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                form.showMore = !form.showMore
                if (form.showMore) form.owner.request(["records", "--limit", "10000"])
            }
        }
    }

    Column {
        visible: form.showMore
        width: parent.width
        spacing: Style.space(10)

        // Reports
        PanelSectionHeader { text: "Report"; foreground: form.fg; fontFamily: form.font }
        Row {
            width: parent.width
            spacing: Style.space(6)
            Dropdown {
                id: period
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

        PanelSeparator { width: parent.width; foreground: form.fg }

        // Records
        PanelSectionHeader { text: "Records"; foreground: form.fg; fontFamily: form.font }
        Dropdown {
            id: recordPicker
            width: parent.width
            showLabel: false
            options: form.recordOptions
            value: form.recordValue
            foreground: form.fg
            fontFamily: form.font
            onChanged: function(v) { form.recordValue = v }
        }
        Row {
            spacing: Style.space(8)
            Action {
                text: "Delete"; iconText: "󰆴"
                enabled: !form.owner.busy && form.recordValue !== ""
                onClicked: {
                    form.deletionId = parseInt(form.recordValue, 10)
                    var opt = form.recordOptions.find(function(o) { return o.value === form.recordValue })
                    form.deletionLabel = opt ? opt.label : "#" + form.recordValue
                    form.deletionCommand = "delete-record"
                    deleteConfirmation.clear()
                }
            }
            Action {
                text: "Clear all"; iconText: "󰎟"
                enabled: !form.owner.busy && !form.tracking && form.owner.records.length > 0
                onClicked: { form.deletionCommand = "clear-records"; deleteConfirmation.clear() }
            }
            Action {
                text: "Reload"; iconText: "󰑐"
                enabled: !form.owner.busy
                onClicked: { form.deletionCommand = ""; form.owner.request(["records", "--limit", "10000"]) }
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
        Caption { width: parent.width; text: "Timezone " + (form.owner.trackerState.timezone || "…") }
    }
}
