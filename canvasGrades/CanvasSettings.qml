import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import qs.Services

PluginSettings {
    id: root
    pluginId: "canvasGrades"

    PluginGlobalVar {
        id: apiTokenSetting
        varName: "apiToken"
        defaultValue: ""
    }

    PluginGlobalVar {
        id: canvasDomainSetting
        varName: "canvasDomain"
        defaultValue: "yourschooldomain.instructure.com"
    }

    PluginGlobalVar {
        id: pillStyleSetting
        varName: "pillStyle"
        defaultValue: "tiers"
    }

    // Test connection state: "idle" | "testing" | "success" | "error"
    property string testState: "idle"
    property string testMessage: ""
    property string selectedPillStyle: "tiers"

    function escapeShellString(str) {
        if (!str) return ""
        return str.replace(/\\/g, "\\\\")
                  .replace(/"/g, "\\\"")
                  .replace(/\$/g, "\\$")
                  .replace(/`/g, "\\`")
    }

    Process {
        id: testProcess
        command: ["/usr/bin/env", "bash", "-c",
            'curl -sf -H "Authorization: Bearer ' +
            escapeShellString(tokenField.text.trim()) +
            '" "https://' +
            escapeShellString(domainField.text.trim()) +
            '/api/v1/users/self" | jq -r \'.name // "Unknown user"\'']
        running: false

        stdout: SplitParser {
            onRead: data => {
                const name = data.trim()
                if (name && name !== "null") {
                    root.testState = "success"
                    root.testMessage = "Connected as: " + name
                } else {
                    root.testState = "error"
                    root.testMessage = "Invalid token or domain"
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 && root.testState === "testing") {
                root.testState = "error"
                root.testMessage = "Connection failed (HTTP error or network issue)"
            }
        }
    }

    Component.onCompleted: {
        const savedToken = PluginService.loadPluginData("canvasGrades", "apiToken", "")
        const savedDomain = PluginService.loadPluginData("canvasGrades", "canvasDomain", "byupw.instructure.com")
        const savedInterval = PluginService.loadPluginData("canvasGrades", "refreshInterval", 300)

        if (savedToken) {
            tokenField.text = savedToken
            PluginService.setGlobalVar("canvasGrades", "apiToken", savedToken)
        }
        domainField.text = savedDomain
        PluginService.setGlobalVar("canvasGrades", "canvasDomain", savedDomain)
        PluginService.setGlobalVar("canvasGrades", "refreshInterval", savedInterval)
    }

    Column {
        width: parent.width
        spacing: Theme.spacingL

        // Header
        Column {
            width: parent.width
            spacing: Theme.spacingXS

            StyledText {
                text: "Canvas Grades Settings"
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            StyledText {
                text: "Display your courses, grades, upcoming assignments, and announcements"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                width: parent.width
            }
        }

        // API Token
        StyledRect {
            width: parent.width
            height: tokenColumn.implicitHeight + Theme.spacingL * 2
            color: Theme.surfaceContainerHigh
            radius: Theme.cornerRadius

            Column {
                id: tokenColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                Row {
                    spacing: Theme.spacingS

                    DankIcon {
                        name: "key"
                        size: Theme.iconSize
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: "API Token"
                        font.weight: Font.Bold
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    DankTextField {
                        id: tokenField
                        width: parent.width - showHideBtn.width - Theme.spacingS
                        placeholderText: "paste your Canvas API token here"
                        echoMode: showToken ? TextInput.Normal : TextInput.Password
                        text: ""

                        property bool showToken: false
                    }

                    Rectangle {
                        id: showHideBtn
                        width: Theme.iconSize * 1.5
                        height: Theme.iconSize * 1.5
                        radius: Theme.iconSize * 0.75
                        color: showHideArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer
                        anchors.verticalCenter: parent.verticalCenter

                        DankIcon {
                            anchors.centerIn: parent
                            name: tokenField.showToken ? "visibility_off" : "visibility"
                            size: Theme.iconSize * 0.8
                            color: Theme.surfaceVariantText
                        }

                        MouseArea {
                            id: showHideArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: tokenField.showToken = !tokenField.showToken
                        }
                    }
                }

                StyledText {
                    text: "Generate at: Settings → Approved Integrations → New Access Token"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    width: parent.width
                }
            }
        }

        // Canvas Domain
        StyledRect {
            width: parent.width
            height: domainColumn.implicitHeight + Theme.spacingL * 2
            color: Theme.surfaceContainerHigh
            radius: Theme.cornerRadius

            Column {
                id: domainColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                Row {
                    spacing: Theme.spacingS

                    DankIcon {
                        name: "language"
                        size: Theme.iconSize
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: "Canvas Domain"
                        font.weight: Font.Bold
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                DankTextField {
                    id: domainField
                    width: parent.width
                    placeholderText: "byupw.instructure.com"
                    text: "byupw.instructure.com"
                }

                StyledText {
                    text: "Your Canvas instance hostname (e.g. byupw.instructure.com)"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }
        }

        // Refresh Interval
        SliderSetting {
            settingKey: "refreshInterval"
            label: "Refresh Interval"
            description: "How often to fetch Canvas data (in seconds)."
            defaultValue: 300
            minimum: 60
            maximum: 1800
            unit: "sec"
            leftIcon: "schedule"
        }

        // Save Button
        DankButton {
            width: parent.width
            text: "Save Settings"
            iconName: "check"

            onClicked: {
                if (!tokenField.text.trim()) {
                    ToastService.showError("API token is required")
                    return
                }
                if (!domainField.text.trim()) {
                    ToastService.showError("Canvas domain is required")
                    return
                }

                const token = tokenField.text.trim()
                const domain = domainField.text.trim()

                PluginService.savePluginData("canvasGrades", "apiToken", token)
                PluginService.savePluginData("canvasGrades", "canvasDomain", domain)

                PluginService.setGlobalVar("canvasGrades", "apiToken", token)
                PluginService.setGlobalVar("canvasGrades", "canvasDomain", domain)

                console.log("Canvas: Settings saved - domain:", domain)
                ToastService.showSuccess("Settings saved successfully!")
                root.testState = "idle"
            }
        }

        // Test Connection Button
        DankButton {
            width: parent.width
            text: root.testState === "testing" ? "Testing..." : "Test Connection"
            iconName: root.testState === "testing" ? "hourglass_empty" : "wifi_tethering"
            enabled: root.testState !== "testing"

            onClicked: {
                if (!tokenField.text.trim() || !domainField.text.trim()) {
                    ToastService.showError("Enter token and domain first")
                    return
                }
                root.testState = "testing"
                root.testMessage = ""
                testProcess.running = true
            }
        }

        // Test result display
        StyledRect {
            visible: root.testState !== "idle"
            width: parent.width
            height: testResultRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: {
                if (root.testState === "success") return Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.12)
                if (root.testState === "error") return Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.12)
                return Theme.surfaceContainerHigh
            }

            Row {
                id: testResultRow
                anchors {
                    left: parent.left; right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Theme.spacingM
                    rightMargin: Theme.spacingM
                }
                spacing: Theme.spacingS

                DankIcon {
                    name: {
                        if (root.testState === "success") return "check_circle"
                        if (root.testState === "error") return "error"
                        return "hourglass_empty"
                    }
                    size: Theme.iconSize
                    color: {
                        if (root.testState === "success") return Theme.primary
                        if (root.testState === "error") return Theme.error
                        return Theme.surfaceVariantText
                    }
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: {
                        if (root.testState === "testing") return "Connecting to Canvas..."
                        return root.testMessage
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: {
                        if (root.testState === "success") return Theme.primary
                        if (root.testState === "error") return Theme.error
                        return Theme.surfaceVariantText
                    }
                    wrapMode: Text.WordWrap
                    width: parent.width - Theme.iconSize - Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
}
