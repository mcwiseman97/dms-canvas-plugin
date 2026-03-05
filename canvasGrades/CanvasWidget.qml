import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    popoutWidth: 420
    popoutHeight: 740

    // Settings from pluginData
    property string apiToken: (pluginData && pluginData.apiToken) ? pluginData.apiToken : ""
    property string canvasDomain: (pluginData && pluginData.canvasDomain) ? pluginData.canvasDomain : "byupw.instructure.com"
    property int refreshInterval: (pluginData && pluginData.refreshInterval) ? pluginData.refreshInterval : 300

    // State
    property var courses: []
    property var assignments: []
    property var missingWork: []
    property var announcements: []
    property bool isLoading: false
    property bool isError: false
    property string errorMessage: ""
    property var lastRefreshTime: null
    property bool isManualRefresh: false

    // Grouped assignment sections
    property var todayItems: {
        var r = []
        for (var i = 0; i < assignments.length; i++)
            if (assignments[i].days_until <= 0) r.push(assignments[i])
        return r
    }
    property var tomorrowItems: {
        var r = []
        for (var i = 0; i < assignments.length; i++)
            if (assignments[i].days_until === 1) r.push(assignments[i])
        return r
    }
    property var weekItems: {
        var r = []
        for (var i = 0; i < assignments.length; i++) {
            var d = assignments[i].days_until
            if (d >= 2 && d <= 6) r.push(assignments[i])
        }
        return r
    }
    property var laterItems: {
        var r = []
        for (var i = 0; i < assignments.length; i++)
            if (assignments[i].days_until >= 7) r.push(assignments[i])
        return r
    }

    // Urgency counts (today + tomorrow both count as urgent for badge)
    property int urgentCount: todayItems.length + tomorrowItems.length
    property int soonCount: weekItems.length

    property color badgeColor: {
        if (urgentCount > 0) return Theme.error
        if (soonCount > 0) return Theme.warning
        return Theme.primary
    }

    // Type classification helpers
    function assignmentType(submissionTypes) {
        if (!submissionTypes || submissionTypes.length === 0) return "assignment"
        var s = submissionTypes
        if (s.indexOf("online_quiz") >= 0) return "quiz"
        if (s.indexOf("discussion_topic") >= 0) return "discussion"
        if (s.indexOf("none") >= 0 || s.indexOf("not_graded") >= 0) return "reading"
        if (s.indexOf("external_tool") >= 0) return "external"
        return "assignment"
    }

    function typeIcon(type) {
        if (type === "quiz")       return "quiz"
        if (type === "discussion") return "forum"
        if (type === "reading")    return "menu_book"
        if (type === "external")   return "open_in_new"
        return "assignment"
    }

    function typeColor(type) {
        if (type === "quiz")       return Theme.warning
        if (type === "discussion") return Theme.tertiary
        if (type === "reading")    return Theme.primary
        return Theme.surfaceText
    }

    Component.onCompleted: {
        Qt.callLater(function() {
            if (apiToken) refreshTimer.start()
        })
    }

    onApiTokenChanged: checkAndStartTimer()
    onRefreshIntervalChanged: {
        if (refreshTimer.running) refreshTimer.restart()
    }

    function checkAndStartTimer() {
        if (apiToken) {
            if (!refreshTimer.running) refreshTimer.start()
        } else {
            refreshTimer.stop()
            courses = []
            assignments = []
            missingWork = []
            announcements = []
        }
    }

    function escapeShellString(str) {
        if (!str) return ""
        return str.replace(/\\/g, "\\\\")
                  .replace(/"/g, "\\\"")
                  .replace(/\$/g, "\\$")
                  .replace(/`/g, "\\`")
    }

    Timer {
        id: refreshTimer
        interval: root.refreshInterval * 1000
        repeat: true
        running: false
        triggeredOnStart: true
        onTriggered: {
            if (root.apiToken) {
                root.isManualRefresh = false
                root.refreshCanvas()
            } else {
                root.isError = true
                root.errorMessage = "Configure Canvas API token in settings"
            }
        }
    }

    function refreshCanvas() {
        if (!apiToken) {
            isError = true
            errorMessage = "Configure Canvas API token in settings"
            return
        }

        const now = Date.now()
        if (lastRefreshTime && (now - lastRefreshTime) < 30000) {
            console.log("Canvas: Skipping refresh (cooldown active)")
            return
        }

        if (canvasProcess.running) {
            console.log("Canvas: Skipping refresh (previous fetch still running)")
            return
        }

        console.log("Canvas: Fetching data from", canvasDomain)
        lastRefreshTime = now
        isLoading = true
        canvasProcess.running = true
    }

    function buildScript() {
        const escapedDomain = escapeShellString(canvasDomain)
        const escapedToken = escapeShellString(apiToken)

        return `
CANVAS_DOMAIN="${escapedDomain}"
CANVAS_TOKEN="${escapedToken}"
BASE_URL="https://\${CANVAS_DOMAIN}/api/v1"
AUTH_HEADER="Authorization: Bearer \${CANVAS_TOKEN}"

TODAY=$(date +%Y-%m-%d)
END_DATE=$(date -d "+14 days" +%Y-%m-%d)
START_7=$(date -d "-7 days" +%Y-%m-%d)
NOW_TS=$(date +%s)

tmp_courses=$(mktemp)
tmp_assignments=$(mktemp)
tmp_missing=$(mktemp)
tmp_announcements=$(mktemp)
cleanup() { rm -f "\${tmp_courses}" "\${tmp_assignments}" "\${tmp_missing}" "\${tmp_announcements}"; }
trap cleanup EXIT

# 1. Fetch active courses with grades
courses_raw=$(curl -s -H "\${AUTH_HEADER}" \\
    "\${BASE_URL}/courses?enrollment_state=active&include[]=total_scores&per_page=50")
curl_exit=$?

if [ \${curl_exit} -ne 0 ] || [ -z "\${courses_raw}" ]; then
    echo '{"error":true,"errorMessage":"Failed to connect to Canvas (check domain)"}'
    exit 0
fi

if echo "\${courses_raw}" | jq -e 'type != "array"' > /dev/null 2>&1; then
    err_msg=$(echo "\${courses_raw}" | jq -r '.errors[0].message // .message // "Invalid token or unauthorized"')
    jq -n --arg m "\${err_msg}" '{"error":true,"errorMessage":$m}'
    exit 0
fi

echo "\${courses_raw}" | jq -c --arg domain "\${CANVAS_DOMAIN}" '
    [.[] |
     select(.access_restricted_by_date != true) |
     select(.enrollments != null and (.enrollments | length) > 0) |
     {
       id: .id,
       name: (.name // "Unknown"),
       code: (.course_code // ""),
       grade: ((.enrollments[0].computed_current_grade) // "--"),
       score: ((.enrollments[0].computed_current_score) // null),
       url: ("https://\\($domain)/courses/\\(.id | tostring)")
     }
    ]
' > "\${tmp_courses}"

course_ids=$(echo "\${courses_raw}" | jq -r '
    [.[] |
     select(.access_restricted_by_date != true) |
     select(.enrollments != null and (.enrollments | length) > 0) |
     .id | tostring
    ] | join(" ")
')

course_map=$(echo "\${courses_raw}" | jq -c '
    [.[] |
     select(.access_restricted_by_date != true) |
     select(.enrollments != null and (.enrollments | length) > 0)] |
    map({key: (.id | tostring), value: .name}) |
    from_entries
')

# 2. Fetch upcoming assignments
if [ -n "\${course_ids}" ]; then
    ctx_params=""
    for cid in \${course_ids}; do
        ctx_params="\${ctx_params}&context_codes[]=course_\${cid}"
    done
    assignments_raw=$(curl -s -H "\${AUTH_HEADER}" \\
        "\${BASE_URL}/calendar_events?type=assignment&start_date=\${TODAY}&end_date=\${END_DATE}&per_page=100\${ctx_params}")
    echo "\${assignments_raw}" | jq -c --argjson now "\${NOW_TS}" '
        if type == "array" then
          [.[] |
           select(.assignment != null) |
           {
             name: (.title // .assignment.name // "Unknown"),
             course: (.context_name // ""),
             due_at: (.assignment.due_at // .start_at // ""),
             days_until: (
               if (.assignment.due_at // .start_at // "") != "" then
                 (((.assignment.due_at // .start_at) | fromdateiso8601) - $now) / 86400 | floor
               else 999 end
             ),
             url: (.html_url // ""),
             course_id: (.context_code | ltrimstr("course_") | tonumber),
             assignment_id: .assignment.id,
             submission_types: (.assignment.submission_types // []),
             markable: ((.assignment.submission_types // []) | (contains(["none"]) or contains(["not_graded"]))),
             points_possible: (.assignment.points_possible // null)
           }
          ] | sort_by(.days_until)
        else [] end
    ' > "\${tmp_assignments}"
else
    echo '[]' > "\${tmp_assignments}"
fi

# 3. Fetch missing submissions
missing_raw=$(curl -s -H "\${AUTH_HEADER}" \\
    "\${BASE_URL}/users/self/missing_submissions?per_page=20")
echo "\${missing_raw}" | jq -c --argjson cmap "\${course_map}" --argjson now "\${NOW_TS}" '
    if type == "array" then
      [.[] |
       {
         name: (.name // "Unknown"),
         course: (\$cmap[(.course_id | tostring)] // "Unknown Course"),
         due_at: (.due_at // ""),
         days_overdue: (
           if (.due_at // "") != "" then
             ($now - ((.due_at | fromdateiso8601))) / 86400 | floor
           else 0 end
         ),
         url: (.html_url // "")
       }
      ]
    else [] end
' > "\${tmp_missing}"

# 4. Fetch announcements
if [ -n "\${course_ids}" ]; then
    ann_params=""
    for cid in \${course_ids}; do
        ann_params="\${ann_params}&context_codes[]=course_\${cid}"
    done
    announcements_raw=$(curl -s -H "\${AUTH_HEADER}" \\
        "\${BASE_URL}/announcements?per_page=10&start_date=\${START_7}\${ann_params}")
    echo "\${announcements_raw}" | jq -c --argjson cmap "\${course_map}" --argjson now "\${NOW_TS}" '
        if type == "array" then
          [.[] |
           {
             title: (.title // "Unknown"),
             course: (\$cmap[(.context_code | ltrimstr("course_"))] // ""),
             posted_at: (.posted_at // ""),
             hours_ago: (
               if (.posted_at // "") != "" then
                 ($now - ((.posted_at | fromdateiso8601))) / 3600 | floor
               else 0 end
             ),
             url: (.html_url // "")
           }
          ]
        else [] end
    ' > "\${tmp_announcements}"
else
    echo '[]' > "\${tmp_announcements}"
fi

jq -cn \\
  --slurpfile courses "\${tmp_courses}" \\
  --slurpfile assignments "\${tmp_assignments}" \\
  --slurpfile missing "\${tmp_missing}" \\
  --slurpfile announcements "\${tmp_announcements}" \\
  '{"error":false,"courses":$courses[0],"assignments":$assignments[0],"missing":$missing[0],"announcements":$announcements[0]}'
`
    }

    Process {
        id: canvasProcess
        command: ["/usr/bin/env", "bash", "-c", buildScript()]
        running: false

        stdout: SplitParser {
            onRead: data => {
                try {
                    const result = JSON.parse(data.trim())

                    if (result.error) {
                        console.error("Canvas: API error -", result.errorMessage)
                        root.isError = true
                        root.errorMessage = result.errorMessage || "Unknown error"
                        root.isLoading = false
                        return
                    }

                    root.isError = false
                    root.isLoading = false
                    root.courses = result.courses || []
                    root.assignments = result.assignments || []
                    root.missingWork = result.missing || []
                    root.announcements = result.announcements || []

                    console.log("Canvas: Loaded",
                        root.courses.length, "courses,",
                        root.assignments.length, "upcoming,",
                        root.missingWork.length, "missing,",
                        root.announcements.length, "announcements")

                    if (root.isManualRefresh) {
                        canvasNotifySuccess.running = true
                    }

                } catch (e) {
                    console.error("Canvas: Failed to parse response -", e, "Data:", data)
                    root.isError = true
                    root.errorMessage = "Failed to parse Canvas response"
                    root.isLoading = false
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            root.isLoading = false
            if (exitCode !== 0 && !root.isError) {
                console.error("Canvas: Script failed with exit code", exitCode)
                root.isError = true
                root.errorMessage = "Script failed (exit " + exitCode + ")"
                if (root.isManualRefresh) {
                    canvasNotifyFail.running = true
                }
            }
        }
    }

    Process {
        id: canvasNotifySuccess
        command: ["notify-send", "-t", "3000", "Canvas Synced", "Data refreshed successfully"]
        running: false
    }

    Process {
        id: canvasNotifyFail
        command: ["notify-send", "-u", "critical", "-t", "5000", "Canvas Sync Failed", root.errorMessage]
        running: false
    }

    Process {
        id: openUrlProcess
        property string urlToOpen: ""
        command: ["xdg-open", urlToOpen]
        running: false
    }

    function openUrl(url) {
        if (url) {
            openUrlProcess.urlToOpen = url
            openUrlProcess.running = true
        }
    }

    Process {
        id: markDoneProcess
        property string courseId: ""
        property string assignmentId: ""
        command: ["/usr/bin/env", "bash", "-c",
            'curl -s -X POST' +
            ' -H "Authorization: Bearer ' + escapeShellString(root.apiToken) + '"' +
            ' -d "submission[submission_type]=none"' +
            ' "https://' + escapeShellString(root.canvasDomain) +
            '/api/v1/courses/' + courseId +
            '/assignments/' + assignmentId + '/submissions"' +
            ' | jq -e ".id" > /dev/null 2>&1 && echo "ok" || echo "error"'
        ]
        running: false
        stdout: SplitParser {
            onRead: data => {
                if (data.trim() === "ok") {
                    root.assignments = root.assignments.filter(function(a) {
                        return !(String(a.course_id) === markDoneProcess.courseId &&
                                 String(a.assignment_id) === markDoneProcess.assignmentId)
                    })
                    ToastService.showSuccess("Marked as done!")
                } else {
                    ToastService.showError("Failed to mark as done")
                }
            }
        }
    }

    function markDone(cid, aid) {
        if (markDoneProcess.running) return
        markDoneProcess.courseId = String(cid)
        markDoneProcess.assignmentId = String(aid)
        markDoneProcess.running = true
    }

    function urgencyColor(daysUntil) {
        if (daysUntil <= 1) return Theme.error
        if (daysUntil <= 6) return Theme.warning
        return Theme.primary
    }

    function formatDue(daysUntil) {
        if (daysUntil < 0) return "overdue"
        if (daysUntil === 0) return "Today"
        if (daysUntil === 1) return "Tomorrow"
        return daysUntil + "d"
    }

    function formatPosted(hoursAgo) {
        if (hoursAgo < 1) return "just now"
        if (hoursAgo < 24) return hoursAgo + "h ago"
        return Math.floor(hoursAgo / 24) + "d ago"
    }

    // Shared assignment row delegate used by all section Repeaters
    Component {
        id: assignRowDelegate

        StyledRect {
            required property var modelData
            required property int index

            width: parent ? parent.width : 0
            height: aTextCol.implicitHeight + Theme.spacingS * 2
            color: aRowMA.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
            radius: Theme.cornerRadius

            Behavior on color { ColorAnimation { duration: 100 } }

            // Outer mouse area (z:0, underneath the button)
            MouseArea {
                id: aRowMA
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                z: 0
                onClicked: root.openUrl(modelData.url)
            }

            // Type icon
            DankIcon {
                id: aIcon
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                name: root.typeIcon(root.assignmentType(modelData.submission_types))
                size: Theme.iconSize * 0.8
                color: root.typeColor(root.assignmentType(modelData.submission_types))
                z: 1
            }

            // Name + course column
            Column {
                id: aTextCol
                anchors.left: aIcon.right
                anchors.leftMargin: Theme.spacingS
                anchors.right: aRightWidget.left
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                z: 1

                StyledText {
                    text: modelData.name
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                    width: parent.width
                }

                StyledText {
                    text: modelData.course
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                    width: parent.width
                }
            }

            // Right widget: due label OR mark-done button
            Item {
                id: aRightWidget
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                width: modelData.markable ? aDoneBtn.width : aDueLbl.implicitWidth
                height: Theme.iconSize
                z: 1

                StyledText {
                    id: aDueLbl
                    visible: !modelData.markable
                    anchors.centerIn: parent
                    text: root.formatDue(modelData.days_until)
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: root.urgencyColor(modelData.days_until)
                }

                Rectangle {
                    id: aDoneBtn
                    visible: modelData.markable
                    anchors.centerIn: parent
                    width: aDoneLbl.implicitWidth + Theme.spacingS * 2
                    height: Theme.iconSize * 0.9
                    radius: height / 2
                    color: aDoneMA.containsMouse ? Theme.primary : Theme.surfaceContainerHighest

                    Behavior on color { ColorAnimation { duration: 100 } }

                    StyledText {
                        id: aDoneLbl
                        anchors.centerIn: parent
                        text: "✓ Done"
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: aDoneMA.containsMouse ? "white" : Theme.surfaceVariantText
                    }

                    MouseArea {
                        id: aDoneMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: (mouse) => {
                            mouse.accepted = true
                            root.markDone(modelData.course_id, modelData.assignment_id)
                        }
                    }
                }
            }
        }
    }

    // Horizontal bar pill
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                name: "school"
                size: Theme.iconSize * 0.85
                color: root.assignments.length > 0 ? root.badgeColor : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter

                opacity: root.isLoading ? 0.6 : 1.0
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }

            Rectangle {
                visible: root.apiToken.length > 0
                height: Theme.iconSize * 0.85
                width: Math.max(height, pillCountLabel.implicitWidth + 8)
                radius: height / 2
                color: root.assignments.length > 0 ? root.badgeColor : Theme.surfaceContainerHigh
                anchors.verticalCenter: parent.verticalCenter

                StyledText {
                    id: pillCountLabel
                    anchors.centerIn: parent
                    text: root.assignments.length.toString()
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: root.assignments.length > 0 ? "white" : Theme.surfaceVariantText
                }
            }

            Row {
                visible: root.missingWork.length > 0
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    name: "warning"
                    size: Theme.iconSize * 0.75
                    color: Theme.error
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.missingWork.length.toString()
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: Theme.error
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    // Vertical bar pill
    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: "school"
                size: Theme.iconSize * 0.85
                color: root.assignments.length > 0 ? root.badgeColor : Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter

                opacity: root.isLoading ? 0.6 : 1.0
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }

            Rectangle {
                visible: root.apiToken.length > 0
                height: Theme.iconSize * 0.85
                width: Math.max(height, vertPillLabel.implicitWidth + 8)
                radius: height / 2
                color: root.assignments.length > 0 ? root.badgeColor : Theme.surfaceContainerHigh
                anchors.horizontalCenter: parent.horizontalCenter

                StyledText {
                    id: vertPillLabel
                    anchors.centerIn: parent
                    text: root.assignments.length.toString()
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: root.assignments.length > 0 ? "white" : Theme.surfaceVariantText
                }
            }
        }
    }

    // Popout position persistence
    property int popoutX: (pluginData && pluginData.popoutX) ? pluginData.popoutX : -1
    property int popoutY: (pluginData && pluginData.popoutY) ? pluginData.popoutY : -1

    function savePopoutPosition(x, y) {
        PluginService.savePluginData("canvasGrades", "popoutX", x)
        PluginService.savePluginData("canvasGrades", "popoutY", y)
        PluginService.setGlobalVar("canvasGrades", "popoutX", x)
        PluginService.setGlobalVar("canvasGrades", "popoutY", y)
    }

    // Popout content
    popoutContent: Component {
        PopoutComponent {
            id: popout

            x: root.popoutX >= 0 ? root.popoutX : x
            y: root.popoutY >= 0 ? root.popoutY : y

            onXChanged: if (visible) Qt.callLater(() => root.savePopoutPosition(x, y))
            onYChanged: if (visible) Qt.callLater(() => root.savePopoutPosition(x, y))

            headerText: "Canvas LMS"
            detailsText: {
                if (!root.apiToken) return "Configure API token in settings"
                if (root.isError) return root.errorMessage
                if (root.isLoading) return "Refreshing..."
                return root.courses.length + " courses"
            }
            showCloseButton: false

            Column {
                width: parent.width
                spacing: Theme.spacingS

                // ── Refresh button ────────────────────────────────────────
                Row {
                    anchors.right: parent.right

                    Rectangle {
                        width: Theme.iconSize * 1.5
                        height: Theme.iconSize * 1.5
                        radius: Theme.iconSize * 0.75
                        color: popoutRefreshArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                        DankIcon {
                            anchors.centerIn: parent
                            name: "refresh"
                            size: Theme.iconSize * 0.8
                            color: popoutRefreshArea.containsMouse ? Theme.primary : Theme.surfaceText

                            NumberAnimation on rotation {
                                from: 0; to: 360
                                duration: 1000
                                loops: Animation.Infinite
                                running: root.isLoading
                            }
                        }

                        MouseArea {
                            id: popoutRefreshArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.isManualRefresh = true
                                root.refreshCanvas()
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.outlineVariant }

                // ── No token / Error states ───────────────────────────────
                StyledRect {
                    visible: !root.apiToken
                    width: parent.width
                    height: noTokenCol.implicitHeight + Theme.spacingL * 2
                    color: Theme.surfaceContainerHigh
                    radius: Theme.cornerRadius

                    Column {
                        id: noTokenCol
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        DankIcon {
                            name: "school"
                            color: Theme.surfaceVariantText
                            size: Theme.iconSize * 1.5
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        StyledText {
                            text: "Configure Canvas API token in settings"
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                            wrapMode: Text.WordWrap
                            width: 260
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }

                StyledRect {
                    visible: root.apiToken && root.isError
                    width: parent.width
                    height: errorCol.implicitHeight + Theme.spacingL * 2
                    color: Theme.surfaceContainerHigh
                    radius: Theme.cornerRadius

                    Column {
                        id: errorCol
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        DankIcon {
                            name: "error"
                            color: Theme.error
                            size: Theme.iconSize * 1.5
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        StyledText {
                            text: root.errorMessage || "Failed to load Canvas data"
                            color: Theme.error
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                            wrapMode: Text.WordWrap
                            width: 260
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }

                // ── AT-A-GLANCE stat tiles ─────────────────────────────────
                Row {
                    visible: root.apiToken && !root.isError
                    width: parent.width
                    spacing: Theme.spacingS

                    // Due tile
                    Rectangle {
                        width: (parent.width - Theme.spacingS * 2) / 3
                        height: 72
                        radius: Theme.cornerRadius
                        color: root.urgentCount > 0 ? Theme.error :
                               root.soonCount > 0   ? Theme.warning :
                               root.assignments.length > 0 ? Theme.primary : Theme.surfaceContainerHigh

                        Column {
                            anchors.centerIn: parent
                            spacing: 2

                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.assignments.length.toString()
                                font.pixelSize: Theme.fontSizeLarge + 4
                                font.weight: Font.Bold
                                color: root.assignments.length > 0 ? "white" : Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Upcoming"
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: root.assignments.length > 0 ? Qt.rgba(1,1,1,0.8) : Theme.surfaceVariantText
                            }
                        }
                    }

                    // Missing tile
                    Rectangle {
                        width: (parent.width - Theme.spacingS * 2) / 3
                        height: 72
                        radius: Theme.cornerRadius
                        color: root.missingWork.length > 0 ? Theme.error : Theme.surfaceContainerHigh

                        Column {
                            anchors.centerIn: parent
                            spacing: 2

                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.missingWork.length.toString()
                                font.pixelSize: Theme.fontSizeLarge + 4
                                font.weight: Font.Bold
                                color: root.missingWork.length > 0 ? "white" : Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Missing"
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: root.missingWork.length > 0 ? Qt.rgba(1,1,1,0.8) : Theme.surfaceVariantText
                            }
                        }
                    }

                    // Announcements tile
                    Rectangle {
                        width: (parent.width - Theme.spacingS * 2) / 3
                        height: 72
                        radius: Theme.cornerRadius
                        color: root.announcements.length > 0 ? Theme.primary : Theme.surfaceContainerHigh

                        Column {
                            anchors.centerIn: parent
                            spacing: 2

                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.announcements.length.toString()
                                font.pixelSize: Theme.fontSizeLarge + 4
                                font.weight: Font.Bold
                                color: root.announcements.length > 0 ? "white" : Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "News"
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: root.announcements.length > 0 ? Qt.rgba(1,1,1,0.8) : Theme.surfaceVariantText
                            }
                        }
                    }
                }

                // ── Grades strip ──────────────────────────────────────────
                Column {
                    visible: root.apiToken && !root.isError && root.courses.length > 0
                    width: parent.width
                    spacing: Theme.spacingXS

                    StyledText {
                        text: "GRADES"
                        font.pixelSize: Theme.fontSizeSmall - 1
                        font.weight: Font.Bold
                        color: Theme.surfaceVariantText
                    }

                    // Course grade rows: 2 per row via Grid
                    Grid {
                        width: parent.width
                        columns: 2
                        columnSpacing: Theme.spacingS
                        rowSpacing: Theme.spacingXS

                        Repeater {
                            model: root.courses

                            StyledRect {
                                required property var modelData
                                width: (parent.width - Theme.spacingS) / 2
                                height: gradeRowInner.implicitHeight + Theme.spacingXS * 2
                                color: gradeChipArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                                radius: Theme.cornerRadius

                                Behavior on color { ColorAnimation { duration: 100 } }

                                Row {
                                    id: gradeRowInner
                                    anchors {
                                        left: parent.left; right: parent.right
                                        verticalCenter: parent.verticalCenter
                                        leftMargin: Theme.spacingS
                                        rightMargin: Theme.spacingXS
                                    }
                                    spacing: Theme.spacingXS

                                    StyledText {
                                        text: modelData.code || modelData.name
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                        width: parent.width - gradeVal.implicitWidth - Theme.spacingXS
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    StyledText {
                                        id: gradeVal
                                        text: {
                                            var g = modelData.grade || "--"
                                            var s = modelData.score
                                            if (s !== null && s !== undefined) return g + " " + Math.round(s) + "%"
                                            return g
                                        }
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Bold
                                        color: Theme.primary
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                MouseArea {
                                    id: gradeChipArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.openUrl(modelData.url)
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    visible: root.apiToken && !root.isError
                    width: parent.width
                    height: 1
                    color: Theme.outlineVariant
                }

                // ── Scrollable assignments + missing + announcements ───────
                Flickable {
                    visible: root.apiToken && !root.isError
                    width: parent.width
                    height: Math.min(contentHeight, root.popoutHeight - 280)
                    contentHeight: mainCol.implicitHeight
                    clip: true

                    Column {
                        id: mainCol
                        width: parent.width
                        spacing: Theme.spacingM

                        // --- TODAY ---
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: root.todayItems.length > 0

                            StyledText {
                                text: "TODAY"
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Bold
                                color: Theme.error
                            }

                            Repeater {
                                model: root.todayItems
                                delegate: assignRowDelegate
                            }
                        }

                        // --- TOMORROW ---
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: root.tomorrowItems.length > 0

                            StyledText {
                                text: "TOMORROW"
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Bold
                                color: Theme.warning
                            }

                            Repeater {
                                model: root.tomorrowItems
                                delegate: assignRowDelegate
                            }
                        }

                        // --- THIS WEEK ---
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: root.weekItems.length > 0

                            StyledText {
                                text: "THIS WEEK"
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Bold
                                color: Theme.surfaceVariantText
                            }

                            Repeater {
                                model: root.weekItems
                                delegate: assignRowDelegate
                            }
                        }

                        // --- LATER ---
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: root.laterItems.length > 0

                            StyledText {
                                text: "LATER"
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Bold
                                color: Theme.surfaceVariantText
                            }

                            Repeater {
                                model: root.laterItems
                                delegate: assignRowDelegate
                            }
                        }

                        // --- MISSING WORK ---
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: root.missingWork.length > 0

                            Rectangle {
                                visible: root.assignments.length > 0
                                width: parent.width
                                height: 1
                                color: Theme.outlineVariant
                            }

                            StyledText {
                                text: "MISSING (" + root.missingWork.length + ")"
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Bold
                                color: Theme.error
                            }

                            Repeater {
                                model: root.missingWork

                                StyledRect {
                                    required property var modelData
                                    width: parent.width
                                    height: missingRow.implicitHeight + Theme.spacingS * 2
                                    color: missingArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                                    radius: Theme.cornerRadius

                                    Behavior on color { ColorAnimation { duration: 100 } }

                                    Row {
                                        id: missingRow
                                        anchors {
                                            left: parent.left; right: parent.right
                                            verticalCenter: parent.verticalCenter
                                            leftMargin: Theme.spacingS
                                            rightMargin: Theme.spacingS
                                        }
                                        spacing: Theme.spacingS

                                        DankIcon {
                                            name: "warning"
                                            size: Theme.iconSize * 0.8
                                            color: Theme.error
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        Column {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width - Theme.iconSize * 0.8 - overdueLabel.implicitWidth - Theme.spacingS * 3
                                            spacing: 2

                                            StyledText {
                                                text: modelData.name
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceText
                                                elide: Text.ElideRight
                                                width: parent.width
                                            }

                                            StyledText {
                                                text: modelData.course
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                color: Theme.surfaceVariantText
                                                elide: Text.ElideRight
                                                width: parent.width
                                            }
                                        }

                                        StyledText {
                                            id: overdueLabel
                                            text: modelData.days_overdue + "d overdue"
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Bold
                                            color: Theme.error
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    MouseArea {
                                        id: missingArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.openUrl(modelData.url)
                                    }
                                }
                            }
                        }

                        // --- ANNOUNCEMENTS ---
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: root.announcements.length > 0

                            Rectangle {
                                visible: root.assignments.length > 0 || root.missingWork.length > 0
                                width: parent.width
                                height: 1
                                color: Theme.outlineVariant
                            }

                            StyledText {
                                text: "ANNOUNCEMENTS"
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Bold
                                color: Theme.surfaceVariantText
                            }

                            Repeater {
                                model: root.announcements

                                StyledRect {
                                    required property var modelData
                                    width: parent.width
                                    height: annRow.implicitHeight + Theme.spacingS * 2
                                    color: annArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                                    radius: Theme.cornerRadius

                                    Behavior on color { ColorAnimation { duration: 100 } }

                                    Row {
                                        id: annRow
                                        anchors {
                                            left: parent.left; right: parent.right
                                            verticalCenter: parent.verticalCenter
                                            leftMargin: Theme.spacingS
                                            rightMargin: Theme.spacingS
                                        }
                                        spacing: Theme.spacingS

                                        DankIcon {
                                            name: "notifications"
                                            size: Theme.iconSize * 0.8
                                            color: Theme.primary
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        Column {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width - Theme.iconSize * 0.8 - annTime.implicitWidth - Theme.spacingS * 3
                                            spacing: 2

                                            StyledText {
                                                text: modelData.title
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceText
                                                elide: Text.ElideRight
                                                width: parent.width
                                            }

                                            StyledText {
                                                text: modelData.course
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                color: Theme.surfaceVariantText
                                                elide: Text.ElideRight
                                                width: parent.width
                                            }
                                        }

                                        StyledText {
                                            id: annTime
                                            text: root.formatPosted(modelData.hours_ago)
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    MouseArea {
                                        id: annArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.openUrl(modelData.url)
                                    }
                                }
                            }
                        }

                        // Bottom padding
                        Item { width: 1; height: Theme.spacingS }
                    }
                }
            }
        }
    }
}
