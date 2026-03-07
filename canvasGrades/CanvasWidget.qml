import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    popoutWidth: 700
    popoutHeight: 740

    // Settings from pluginData
    property string apiToken: (pluginData && pluginData.apiToken) ? pluginData.apiToken : ""
    property string canvasDomain: (pluginData && pluginData.canvasDomain) ? pluginData.canvasDomain : "byupw.instructure.com"
    property int refreshInterval: (pluginData && pluginData.refreshInterval) ? pluginData.refreshInterval : 300
    property string pillStyle: (pluginData && pluginData.pillStyle) ? pluginData.pillStyle : "tiers"

    property string nextDueLabel: {
        if (assignments.length === 0) return "0"
        var d = assignments[0].days_until
        if (d <= 0) return "Today"
        if (d === 1) return "Tomorrow"
        return d + "d"
    }
    property color nextDueColor: {
        if (assignments.length === 0) return Theme.surfaceContainerHigh
        var d = assignments[0].days_until
        if (d <= 1) return Theme.error
        if (d <= 6) return Theme.warning
        return Theme.primary
    }

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

    // Extended feature state
    property var assignmentGroups: ({})
    property int unreadInboxCount: 0
    property int unreadDiscussions: 0

    // Calendar state
    property int calendarYear: new Date().getFullYear()
    property int calendarMonth: new Date().getMonth()
    property var calendarDayMap: {
        var map = {}
        var _ = assignments  // ensure reactive binding
        for (var i = 0; i < assignments.length; i++) {
            var a = assignments[i]
            if (a.due_at) {
                var d = new Date(a.due_at)
                var key = d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate()
                map[key] = (map[key] || 0) + 1
            }
        }
        return map
    }

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
        if (type === "quiz")       return "description"
        if (type === "discussion") return "forum"
        if (type === "reading")    return "menu_book"
        if (type === "external")   return "open_in_new"
        return "assignment"
    }

    function typeColor(type) {
        if (type === "quiz")       return Theme.warning
        if (type === "discussion") return Theme.info
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
            assignmentGroups = ({})
            unreadInboxCount = 0
            unreadDiscussions = 0
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
END_DATE=$(date -d "+90 days" +%Y-%m-%d)
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
        "\${BASE_URL}/calendar_events?type=assignment&start_date=\${TODAY}&end_date=\${END_DATE}&per_page=100&include[]=submission\${ctx_params}")
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
             points_possible: (.assignment.points_possible // null),
             score: (.assignment.submission.score // null),
             grade: (.assignment.submission.grade // null),
             workflow_state: (.assignment.submission.workflow_state // "unsubmitted"),
             has_feedback: ((.assignment.submission.submission_comments_count // 0) > 0)
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
           select(.read_state != "read") |
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

# 5. Fetch additional data in parallel
# Unread inbox count (single lightweight call)
tmp_inbox=\$(mktemp)
curl -s -H "\${AUTH_HEADER}" "\${BASE_URL}/conversations/unread_count" > "\${tmp_inbox}" &

# Assignment groups + discussion unread counts per course
declare -A gfiles dfiles
if [ -n "\${course_ids}" ]; then
    for cid in \${course_ids}; do
        gf=\$(mktemp)
        df=\$(mktemp)
        gfiles[\$cid]=\$gf
        dfiles[\$cid]=\$df
        curl -s -H "\${AUTH_HEADER}" "\${BASE_URL}/courses/\${cid}/assignment_groups?include[]=current_grades&per_page=50" > "\$gf" &
        curl -s -H "\${AUTH_HEADER}" "\${BASE_URL}/courses/\${cid}/discussion_topics?per_page=50" > "\$df" &
    done
fi
wait

unread_inbox=\$(jq '.unread_count // 0' "\${tmp_inbox}" 2>/dev/null || echo 0)
rm -f "\${tmp_inbox}"

groups_json='{}'
unread_disc=0
if [ -n "\${course_ids}" ]; then
    for cid in \${course_ids}; do
        gf="\${gfiles[\$cid]}"
        df="\${dfiles[\$cid]}"
        if [ -f "\${gf}" ]; then
            gdata=\$(jq -c '[.[] | select(.group_weight > 0) | {name:.name,weight:.group_weight,score:(.current_score//null),grade:(.current_grade//null)}]' "\${gf}" 2>/dev/null || echo '[]')
            groups_json=\$(echo "\${groups_json}" | jq -c --arg cid "\${cid}" --argjson g "\${gdata}" '.[\$cid] = \$g')
            rm -f "\${gf}"
        fi
        if [ -f "\${df}" ]; then
            cnt=\$(jq '[.[] | select(.unread_count > 0)] | length' "\${df}" 2>/dev/null || echo 0)
            unread_disc=\$((unread_disc + cnt))
            rm -f "\${df}"
        fi
    done
fi

jq -cn \\
  --slurpfile courses "\${tmp_courses}" \\
  --slurpfile assignments "\${tmp_assignments}" \\
  --slurpfile missing "\${tmp_missing}" \\
  --slurpfile announcements "\${tmp_announcements}" \\
  --argjson groups "\${groups_json}" \\
  --argjson unread_inbox "\${unread_inbox}" \\
  --argjson unread_disc "\${unread_disc}" \\
  '{"error":false,"courses":$courses[0],"assignments":$assignments[0],"missing":$missing[0],"announcements":$announcements[0],"groups":$groups,"unread_inbox":$unread_inbox,"unread_discussions":$unread_disc}'
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
                    root.assignmentGroups = result.groups || ({})
                    root.unreadInboxCount = result.unread_inbox || 0
                    root.unreadDiscussions = result.unread_discussions || 0

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

    function monthName(m) {
        return ["January","February","March","April","May","June",
                "July","August","September","October","November","December"][m]
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

            // Instructor feedback dot (shown when submission has comments)
            Rectangle {
                visible: modelData.has_feedback === true
                width: 8
                height: 8
                radius: 4
                color: Theme.info
                anchors.top: aIcon.top
                anchors.right: aIcon.right
                anchors.rightMargin: -2
                anchors.topMargin: -2
                z: 2
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

            // Right widget: grade chip OR due label OR mark-done button
            Item {
                id: aRightWidget
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                width: {
                    var graded = modelData.workflow_state === "graded" || (modelData.grade != null && String(modelData.grade) !== "")
                    if (graded) return aGradeChip.width
                    if (modelData.markable) return aDoneBtn.width
                    return aDueLbl.implicitWidth
                }
                height: Theme.iconSize
                z: 1

                // Grade chip (shown when assignment is graded)
                Rectangle {
                    id: aGradeChip
                    visible: modelData.workflow_state === "graded" || (modelData.grade != null && String(modelData.grade) !== "")
                    anchors.centerIn: parent
                    width: aGradeLbl.implicitWidth + Theme.spacingS * 2
                    height: Theme.iconSize * 0.9
                    radius: height / 2
                    color: {
                        if (modelData.score != null && modelData.points_possible != null && modelData.points_possible > 0)
                            return (modelData.score / modelData.points_possible) >= 0.7 ? Qt.rgba(0.15, 0.65, 0.3, 0.25) : Qt.rgba(0.8, 0.2, 0.2, 0.2)
                        return Theme.surfaceContainerHighest
                    }

                    StyledText {
                        id: aGradeLbl
                        anchors.centerIn: parent
                        text: {
                            if (modelData.score != null && modelData.points_possible != null)
                                return Math.round(modelData.score) + "/" + modelData.points_possible
                            return String(modelData.grade || "")
                        }
                        font.pixelSize: Theme.fontSizeSmall - 1
                        font.weight: Font.Bold
                        color: {
                            if (modelData.score != null && modelData.points_possible != null && modelData.points_possible > 0)
                                return (modelData.score / modelData.points_possible) >= 0.7 ? "#4caf50" : Theme.error
                            return Theme.primary
                        }
                    }
                }

                StyledText {
                    id: aDueLbl
                    visible: !modelData.markable && !(modelData.workflow_state === "graded" || (modelData.grade != null && String(modelData.grade) !== ""))
                    anchors.centerIn: parent
                    text: root.formatDue(modelData.days_until)
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: root.urgencyColor(modelData.days_until)
                }

                Rectangle {
                    id: aDoneBtn
                    visible: modelData.markable && !(modelData.workflow_state === "graded" || (modelData.grade != null && String(modelData.grade) !== ""))
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
    // Reusable urgency badge: colored pill for a count
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

            // ── Style: total — single badge, urgency color ────────────
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "total"
                height: Theme.iconSize * 0.85
                width: Math.max(height, hTotalLbl.implicitWidth + 8)
                radius: height / 2
                color: root.assignments.length > 0 ? root.badgeColor : Theme.surfaceContainerHigh
                anchors.verticalCenter: parent.verticalCenter
                StyledText {
                    id: hTotalLbl
                    anchors.centerIn: parent
                    text: root.assignments.length.toString()
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: root.assignments.length > 0 ? "white" : Theme.surfaceVariantText
                }
            }

            // ── Style: tiers — red / yellow / blue tier badges ────────
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "tiers" && root.assignments.length === 0
                height: Theme.iconSize * 0.85; width: height; radius: height / 2
                color: Theme.surfaceContainerHigh
                anchors.verticalCenter: parent.verticalCenter
                StyledText { anchors.centerIn: parent; text: "0"; font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: Theme.surfaceVariantText }
            }
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "tiers" && root.urgentCount > 0
                height: Theme.iconSize * 0.85
                width: Math.max(height, hTierUrgLbl.implicitWidth + 8)
                radius: height / 2; color: Theme.error
                anchors.verticalCenter: parent.verticalCenter
                StyledText { id: hTierUrgLbl; anchors.centerIn: parent; text: root.urgentCount.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: "white" }
            }
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "tiers" && root.soonCount > 0
                height: Theme.iconSize * 0.85
                width: Math.max(height, hTierSoonLbl.implicitWidth + 8)
                radius: height / 2; color: Theme.warning
                anchors.verticalCenter: parent.verticalCenter
                StyledText { id: hTierSoonLbl; anchors.centerIn: parent; text: root.soonCount.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: "white" }
            }
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "tiers" && root.laterItems.length > 0
                height: Theme.iconSize * 0.85
                width: Math.max(height, hTierLateLbl.implicitWidth + 8)
                radius: height / 2; color: Theme.primary
                anchors.verticalCenter: parent.verticalCenter
                StyledText { id: hTierLateLbl; anchors.centerIn: parent; text: root.laterItems.length.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: "white" }
            }

            // ── Style: next — next due label + small total ────────────
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "next" && root.assignments.length > 0
                height: Theme.iconSize * 0.85
                width: Math.max(height, hNextLbl.implicitWidth + 8)
                radius: height / 2; color: root.nextDueColor
                anchors.verticalCenter: parent.verticalCenter
                StyledText { id: hNextLbl; anchors.centerIn: parent; text: root.nextDueLabel; font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: "white" }
            }
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "next"
                height: Theme.iconSize * 0.85
                width: Math.max(height, hNextTotalLbl.implicitWidth + 8)
                radius: height / 2
                color: root.assignments.length > 0 ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                anchors.verticalCenter: parent.verticalCenter
                StyledText { id: hNextTotalLbl; anchors.centerIn: parent; text: root.assignments.length.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: root.assignments.length > 0 ? Theme.surfaceText : Theme.surfaceVariantText }
            }

            // ── Style: urgent — red urgent count + total ──────────────
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "urgent" && root.urgentCount > 0
                height: Theme.iconSize * 0.85
                width: Math.max(height, hUrgLbl.implicitWidth + 8)
                radius: height / 2; color: Theme.error
                anchors.verticalCenter: parent.verticalCenter
                StyledText { id: hUrgLbl; anchors.centerIn: parent; text: root.urgentCount.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: "white" }
            }
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "urgent"
                height: Theme.iconSize * 0.85
                width: Math.max(height, hUrgTotalLbl.implicitWidth + 8)
                radius: height / 2
                color: root.assignments.length > 0 ? root.badgeColor : Theme.surfaceContainerHigh
                anchors.verticalCenter: parent.verticalCenter
                StyledText { id: hUrgTotalLbl; anchors.centerIn: parent; text: root.assignments.length.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: root.assignments.length > 0 ? "white" : Theme.surfaceVariantText }
            }

            // ── Missing + Inbox (all styles) ──────────────────────────
            Row {
                visible: root.missingWork.length > 0
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter
                DankIcon { name: "warning"; size: Theme.iconSize * 0.75; color: Theme.error; anchors.verticalCenter: parent.verticalCenter }
                StyledText { text: root.missingWork.length.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: Theme.error; anchors.verticalCenter: parent.verticalCenter }
            }
            Row {
                visible: root.unreadInboxCount > 0
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter
                DankIcon { name: "mail"; size: Theme.iconSize * 0.75; color: Theme.primary; anchors.verticalCenter: parent.verticalCenter }
                StyledText { text: root.unreadInboxCount.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: Theme.primary; anchors.verticalCenter: parent.verticalCenter }
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

            // total
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "total"
                height: Theme.iconSize * 0.85; width: Math.max(height, vTotalLbl.implicitWidth + 8); radius: height / 2
                color: root.assignments.length > 0 ? root.badgeColor : Theme.surfaceContainerHigh
                anchors.horizontalCenter: parent.horizontalCenter
                StyledText { id: vTotalLbl; anchors.centerIn: parent; text: root.assignments.length.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: root.assignments.length > 0 ? "white" : Theme.surfaceVariantText }
            }

            // tiers
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "tiers" && root.assignments.length === 0
                height: Theme.iconSize * 0.85; width: height; radius: height / 2; color: Theme.surfaceContainerHigh
                anchors.horizontalCenter: parent.horizontalCenter
                StyledText { anchors.centerIn: parent; text: "0"; font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: Theme.surfaceVariantText }
            }
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "tiers" && root.urgentCount > 0
                height: Theme.iconSize * 0.85; width: Math.max(height, vTierUrgLbl.implicitWidth + 8); radius: height / 2; color: Theme.error
                anchors.horizontalCenter: parent.horizontalCenter
                StyledText { id: vTierUrgLbl; anchors.centerIn: parent; text: root.urgentCount.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: "white" }
            }
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "tiers" && root.soonCount > 0
                height: Theme.iconSize * 0.85; width: Math.max(height, vTierSoonLbl.implicitWidth + 8); radius: height / 2; color: Theme.warning
                anchors.horizontalCenter: parent.horizontalCenter
                StyledText { id: vTierSoonLbl; anchors.centerIn: parent; text: root.soonCount.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: "white" }
            }
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "tiers" && root.laterItems.length > 0
                height: Theme.iconSize * 0.85; width: Math.max(height, vTierLateLbl.implicitWidth + 8); radius: height / 2; color: Theme.primary
                anchors.horizontalCenter: parent.horizontalCenter
                StyledText { id: vTierLateLbl; anchors.centerIn: parent; text: root.laterItems.length.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: "white" }
            }

            // next
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "next" && root.assignments.length > 0
                height: Theme.iconSize * 0.85; width: Math.max(height, vNextLbl.implicitWidth + 8); radius: height / 2; color: root.nextDueColor
                anchors.horizontalCenter: parent.horizontalCenter
                StyledText { id: vNextLbl; anchors.centerIn: parent; text: root.nextDueLabel; font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: "white" }
            }
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "next"
                height: Theme.iconSize * 0.85; width: Math.max(height, vNextTotalLbl.implicitWidth + 8); radius: height / 2
                color: root.assignments.length > 0 ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                anchors.horizontalCenter: parent.horizontalCenter
                StyledText { id: vNextTotalLbl; anchors.centerIn: parent; text: root.assignments.length.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: root.assignments.length > 0 ? Theme.surfaceText : Theme.surfaceVariantText }
            }

            // urgent
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "urgent" && root.urgentCount > 0
                height: Theme.iconSize * 0.85; width: Math.max(height, vUrgLbl.implicitWidth + 8); radius: height / 2; color: Theme.error
                anchors.horizontalCenter: parent.horizontalCenter
                StyledText { id: vUrgLbl; anchors.centerIn: parent; text: root.urgentCount.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: "white" }
            }
            Rectangle {
                visible: root.apiToken.length > 0 && root.pillStyle === "urgent"
                height: Theme.iconSize * 0.85; width: Math.max(height, vUrgTotalLbl.implicitWidth + 8); radius: height / 2
                color: root.assignments.length > 0 ? root.badgeColor : Theme.surfaceContainerHigh
                anchors.horizontalCenter: parent.horizontalCenter
                StyledText { id: vUrgTotalLbl; anchors.centerIn: parent; text: root.assignments.length.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: root.assignments.length > 0 ? "white" : Theme.surfaceVariantText }
            }

            // Inbox (all styles)
            Row {
                visible: root.unreadInboxCount > 0
                spacing: 2
                anchors.horizontalCenter: parent.horizontalCenter
                DankIcon { name: "mail"; size: Theme.iconSize * 0.7; color: Theme.primary; anchors.verticalCenter: parent.verticalCenter }
                StyledText { text: root.unreadInboxCount.toString(); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: Theme.primary; anchors.verticalCenter: parent.verticalCenter }
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

            headerText: {
                var parts = root.canvasDomain.split('.')
                if (root.canvasDomain.endsWith('.instructure.com')) return parts[0].toUpperCase()
                return parts.length >= 2 ? parts[parts.length - 2].toUpperCase() : root.canvasDomain.toUpperCase()
            }
            detailsText: {
                if (!root.apiToken) return "Configure API token in settings"
                if (root.isError) return root.errorMessage
                if (root.isLoading) return "Refreshing..."
                return root.courses.length + " courses"
            }
            showCloseButton: false

            Row {
                width: parent.width
                height: root.popoutHeight
                spacing: 0

                // ── Left: Calendar panel ──────────────────────────────────
                Item {
                    width: 260
                    height: parent.height
                    clip: true

                    Column {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        anchors.bottomMargin: 20
                        clip: true
                        spacing: Theme.spacingXS

                        // Month/Year navigation header
                        Item {
                            width: parent.width
                            height: Theme.iconSize * 1.4

                            Rectangle {
                                id: calPrevBtn
                                width: Theme.iconSize * 1.4
                                height: Theme.iconSize * 1.4
                                radius: height / 2
                                color: calPrevMA.containsMouse ? Theme.surfaceContainerHighest : "transparent"
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left

                                DankIcon {
                                    anchors.centerIn: parent
                                    name: "chevron_left"
                                    size: Theme.iconSize * 0.8
                                    color: Theme.surfaceText
                                }
                                MouseArea {
                                    id: calPrevMA
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (root.calendarMonth === 0) { root.calendarMonth = 11; root.calendarYear-- }
                                        else root.calendarMonth--
                                    }
                                }
                            }

                            StyledText {
                                text: root.monthName(root.calendarMonth) + " " + root.calendarYear
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                                anchors.centerIn: parent
                            }

                            Rectangle {
                                id: calNextBtn
                                width: Theme.iconSize * 1.4
                                height: Theme.iconSize * 1.4
                                radius: height / 2
                                color: calNextMA.containsMouse ? Theme.surfaceContainerHighest : "transparent"
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.right: parent.right

                                DankIcon {
                                    anchors.centerIn: parent
                                    name: "chevron_right"
                                    size: Theme.iconSize * 0.8
                                    color: Theme.surfaceText
                                }
                                MouseArea {
                                    id: calNextMA
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (root.calendarMonth === 11) { root.calendarMonth = 0; root.calendarYear++ }
                                        else root.calendarMonth++
                                    }
                                }
                            }
                        }

                        // Day-of-week labels
                        Row {
                            spacing: 0
                            Repeater {
                                model: ["Su","Mo","Tu","We","Th","Fr","Sa"]
                                StyledText {
                                    width: 34
                                    text: modelData
                                    font.pixelSize: Theme.fontSizeSmall - 2
                                    color: Theme.surfaceVariantText
                                    horizontalAlignment: Text.AlignHCenter
                                }
                            }
                        }

                        // Day grid: 6 weeks × 7 days = 42 cells
                        Grid {
                            columns: 7
                            spacing: 0

                            Repeater {
                                model: 42
                                delegate: Item {
                                    property int firstWeekday: new Date(root.calendarYear, root.calendarMonth, 1).getDay()
                                    property int daysInMonth: new Date(root.calendarYear, root.calendarMonth + 1, 0).getDate()
                                    property int dayOffset: index - firstWeekday
                                    property bool inMonth: dayOffset >= 0 && dayOffset < daysInMonth
                                    property int dayNum: dayOffset + 1
                                    property bool isToday: {
                                        if (!inMonth) return false
                                        var t = new Date()
                                        return root.calendarYear === t.getFullYear() && root.calendarMonth === t.getMonth() && dayNum === t.getDate()
                                    }
                                    property string dayKey: root.calendarYear + "-" + (root.calendarMonth + 1) + "-" + dayNum
                                    property int assignCount: (inMonth && root.calendarDayMap[dayKey]) ? root.calendarDayMap[dayKey] : 0

                                    width: 34
                                    height: 40
                                    opacity: inMonth ? 1.0 : 0.0

                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.margins: 2
                                        radius: 4
                                        color: isToday ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.2) : "transparent"
                                    }

                                    StyledText {
                                        anchors.top: parent.top
                                        anchors.topMargin: 4
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: inMonth ? dayNum.toString() : ""
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: isToday ? Theme.primary : Theme.surfaceText
                                        font.weight: isToday ? Font.Bold : Font.Normal
                                    }

                                    Rectangle {
                                        visible: assignCount > 0
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 3
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: Math.max(16, calBadgeLbl.implicitWidth + 4)
                                        height: 14
                                        radius: 7
                                        color: Theme.primary

                                        StyledText {
                                            id: calBadgeLbl
                                            anchors.centerIn: parent
                                            text: assignCount.toString()
                                            font.pixelSize: 9
                                            font.weight: Font.Bold
                                            color: "white"
                                        }
                                    }
                                }
                            }
                        }

                        // --- Unread Discussions ---
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: root.unreadDiscussions > 0

                            Rectangle {
                                width: parent.width
                                height: 1
                                color: Theme.outlineVariant
                            }

                            Row {
                                spacing: Theme.spacingXS
                                width: parent.width

                                DankIcon {
                                    name: "forum"
                                    size: Theme.iconSize * 0.8
                                    color: Theme.info
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: root.unreadDiscussions + " unread discussion" + (root.unreadDiscussions !== 1 ? "s" : "")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.info
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }

                        // --- Announcements (below calendar) ---
                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS
                            visible: root.announcements.length > 0

                            Rectangle {
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
                                    height: leftAnnRow.implicitHeight + Theme.spacingS * 2
                                    color: leftAnnArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                                    radius: Theme.cornerRadius

                                    Behavior on color { ColorAnimation { duration: 100 } }

                                    Row {
                                        id: leftAnnRow
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
                                            width: parent.width - Theme.iconSize * 0.8 - Theme.spacingS * 2
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
                                    }

                                    MouseArea {
                                        id: leftAnnArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.openUrl(modelData.url)
                                    }
                                }
                            }
                        }
                    }
                }

                // ── Divider ───────────────────────────────────────────────
                Rectangle {
                    width: 1
                    height: parent.height
                    color: Theme.outlineVariant
                }

                // ── Right: existing content ───────────────────────────────
                Item {
                    width: root.popoutWidth - 261
                    height: parent.height
                    clip: true

                    Column {
                        id: rightTopCol
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.topMargin: Theme.spacingS
                        anchors.leftMargin: Theme.spacingS
                        anchors.rightMargin: Theme.spacingS
                        spacing: Theme.spacingS

                // ── Refresh button ────────────────────────────────────────
                Item {
                    width: parent.width
                    height: Theme.iconSize * 1.5
                    Rectangle {
                        anchors.right: parent.right
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
                        rowSpacing: Theme.spacingS

                        Repeater {
                            model: root.courses

                            StyledRect {
                                required property var modelData
                                width: (parent.width - Theme.spacingS) / 2
                                height: gradeChipCol.implicitHeight + Theme.spacingS * 2
                                color: gradeChipArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                                radius: Theme.cornerRadius

                                Behavior on color { ColorAnimation { duration: 100 } }

                                Column {
                                    id: gradeChipCol
                                    anchors {
                                        left: parent.left; right: parent.right
                                        verticalCenter: parent.verticalCenter
                                        leftMargin: Theme.spacingS
                                        rightMargin: Theme.spacingS
                                    }
                                    spacing: Theme.spacingXS

                                    Row {
                                        width: parent.width
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

                                    StyledText {
                                        width: parent.width
                                        visible: text.length > 0
                                        text: {
                                            var groups = root.assignmentGroups
                                            var g = groups ? groups[String(modelData.id)] : null
                                            if (!g || g.length === 0) return ""
                                            var parts = []
                                            for (var i = 0; i < Math.min(g.length, 4); i++) {
                                                var grp = g[i]
                                                var s = (grp.score !== null && grp.score !== undefined) ? Math.round(grp.score) + "%" : "--"
                                                parts.push(grp.name.substring(0, 6) + ": " + s)
                                            }
                                            return parts.join(" · ")
                                        }
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
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

                    } // rightTopCol

                // ── Scrollable assignments + missing + announcements ───────
                Flickable {
                    visible: root.apiToken && !root.isError
                    anchors.top: rightTopCol.bottom
                    anchors.topMargin: Theme.spacingS
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingS
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.bottom: parent.bottom
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

                        // Bottom padding
                        Item { width: 1; height: Theme.spacingS }
                    }
                }
                } // right Item
            } // Row
        }
    }
}
