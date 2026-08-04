import QtQuick 2.12
import BiliPlugin 1.0
import "../components" as Components
import ".."

Rectangle {
    id: settingsPage
    anchors.fill: parent
    color: Theme.bgPrimary

    property var controller: null
    // 4=设置列表, 5=字幕设置, 6=偏好设置
    property int viewMode: 4

    signal requestSubtitleSettings()
    signal requestPreferenceSettings()

    property bool restartConfirmVisible: false

    // ── 设置页 ──
    Item {
        id: settingsView
        anchors.fill: parent
        visible: viewMode === 4

        ListView {
            anchors.fill: parent
            anchors.margins: Theme.spacingSmall
            model: ListModel {
                ListElement { title: "偏好设置"; action: "preference" }
                ListElement { title: "字幕设置"; action: "subtitle" }
                ListElement { title: "重启 Go 服务端"; action: "restart" }
            }
            spacing: Theme.spacingSmall
            clip: true

            delegate: Rectangle {
                width: parent.width
                height: 36
                radius: Theme.radiusMedium
                color: settingsItemArea.pressed ? Theme.withAlpha(Theme.primary, 0.12) : Theme.bgSecondary
                border.color: Theme.withAlpha(Theme.primary, 0.12)
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: model.title
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    font.bold: true
                }

                MouseArea {
                    id: settingsItemArea
                    anchors.fill: parent
                    onClicked: {
                        if (model.action === "subtitle") {
                            settingsPage.requestSubtitleSettings()
                        } else if (model.action === "preference") {
                            settingsPage.requestPreferenceSettings()
                        } else {
                            settingsPage.restartConfirmVisible = true
                        }
                    }
                }
            }
        }
    }

    // ── 偏好设置 ──
    Item {
        id: preferenceSettingsView
        anchors.fill: parent
        visible: viewMode === 6

        Flickable {
            anchors.fill: parent
            anchors.margins: Theme.spacingSmall
            contentHeight: preferenceSettingsColumn.height
            clip: true
            boundsBehavior: Flickable.DragOverBounds

            Column {
                id: preferenceSettingsColumn
                width: parent.width
                spacing: Theme.spacingSmall

                Components.ToggleRow {
                    width: parent.width
                    label: "离屏占位"
                    description: "已加载卡片滚出视野后退回 Canvas 占位"
                    checked: controller ? controller.videoCardOffscreenPlaceholderEnabled : undefined
                    onToggled: { if (controller) controller.playback.setVideoCardOffscreenPlaceholderEnabled(value) }
                }

                Components.ToggleRow {
                    width: parent.width
                    label: "启用预加载"
                    description: "详情预热评论/字幕/推荐，UP页预取视频"
                    checked: controller ? controller.videoDetailPreloadEnabled : undefined
                    onToggled: { if (controller) controller.playback.setVideoDetailPreloadEnabled(value) }
                }

                Components.ToggleRow {
                    width: parent.width
                    label: "默认字幕"
                    description: "打开视频时自动选中第一个中文字幕"
                    checked: controller ? controller.defaultSubtitleEnabled : undefined
                    onToggled: { if (controller) controller.playback.setDefaultSubtitleEnabled(value) }
                }

                Components.ToggleRow {
                    width: parent.width
                    label: "优先使用MP4流"
                    description: "优先使用MP4流，不可用时回退DASH双流"
                    checked: controller ? controller.preferMp4Stream : undefined
                    onToggled: { if (controller) controller.playback.setPreferMp4Stream(value) }
                }
            }
        }
    }

    // ── 字幕设置 ──
    Item {
        id: subtitleSettingsView
        anchors.fill: parent
        visible: viewMode === 5

        Flickable {
            anchors.fill: parent
            anchors.margins: Theme.spacingSmall
            contentHeight: subtitleSettingsColumn.height
            clip: true
            boundsBehavior: Flickable.DragOverBounds

            Column {
                id: subtitleSettingsColumn
                width: parent.width
                spacing: Theme.spacingSmall

                function round1(v) { return Math.round(v * 10) / 10 }

                Components.StepperRow {
                    width: parent.width
                    label: "字体大小"
                    valueText: controller ? String(controller.subtitleFontSize) : "0"
                    onDecreased: { if (controller) controller.playback.setSubtitleFontSize(controller.subtitleFontSize - 1) }
                    onIncreased: { if (controller) controller.playback.setSubtitleFontSize(controller.subtitleFontSize + 1) }
                }

                Components.StepperRow {
                    width: parent.width
                    label: "字重"
                    valueWidth: 40
                    valueText: controller ? String(controller.subtitleWeight) : "700"
                    onDecreased: { if (controller) controller.playback.setSubtitleWeight(controller.subtitleWeight - 100) }
                    onIncreased: { if (controller) controller.playback.setSubtitleWeight(controller.subtitleWeight + 100) }
                }

                Rectangle {
                    width: parent.width
                    height: 36
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 6

                        Text { text: "字幕颜色"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 64; anchors.verticalCenter: parent.verticalCenter }

                        Repeater {
                            model: [
                                { key: "white", label: "白", color: "#FFFFFF" },
                                { key: "yellow", label: "黄", color: "#FFD54A" },
                                { key: "cyan", label: "青", color: "#7DD3FC" },
                                { key: "black", label: "黑", color: "#000000" }
                            ]

                            Rectangle {
                                width: 38
                                height: 24
                                radius: 6
                                color: controller && controller.subtitleColorPreset === modelData.key
                                       ? Theme.withAlpha(Theme.primary, 0.25)
                                       : Theme.bgTertiary
                                border.width: 1
                                border.color: controller && controller.subtitleColorPreset === modelData.key
                                              ? Theme.primary
                                              : Theme.withAlpha(Theme.primary, 0.16)
                                anchors.verticalCenter: parent.verticalCenter

                                Row {
                                    anchors.centerIn: parent
                                    spacing: 3

                                    Rectangle {
                                        width: 9
                                        height: 9
                                        radius: 4
                                        color: modelData.color
                                        border.width: modelData.key === "white" ? 1 : 0
                                        border.color: Theme.withAlpha(Theme.textPrimary, 0.4)
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Text {
                                        text: modelData.label
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 9
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: { if (controller) controller.playback.setSubtitleColorPreset(modelData.key) }
                                }
                            }
                        }
                    }
                }

                Components.ToggleRow {
                    width: parent.width
                    label: "描边"
                    checked: controller ? controller.subtitleOutlineEnabled : undefined
                    onToggled: { if (controller) controller.playback.setSubtitleOutlineEnabled(value) }
                }

                Components.ToggleRow {
                    width: parent.width
                    label: "灰底背景"
                    checked: controller ? controller.subtitleBackgroundEnabled : undefined
                    onToggled: { if (controller) controller.playback.setSubtitleBackgroundEnabled(value) }
                }

                Components.StepperRow {
                    width: parent.width
                    label: "背景不透明"
                    valueWidth: 40
                    valueText: controller ? Math.round(controller.subtitleBackgroundOpacity * 100) + "%" : "50%"
                    onDecreased: { if (controller) controller.playback.setSubtitleBackgroundOpacity((Math.round(controller.subtitleBackgroundOpacity * 10) - 1) / 10) }
                    onIncreased: { if (controller) controller.playback.setSubtitleBackgroundOpacity((Math.round(controller.subtitleBackgroundOpacity * 10) + 1) / 10) }
                }

                Components.StepperRow {
                    width: parent.width
                    label: "描边粗细"
                    valueText: controller ? String(controller.subtitleOutlineWidth) : "1"
                    onDecreased: { if (controller) controller.playback.setSubtitleOutlineWidth(controller.subtitleOutlineWidth - 1) }
                    onIncreased: { if (controller) controller.playback.setSubtitleOutlineWidth(controller.subtitleOutlineWidth + 1) }
                }

                Components.StepperRow {
                    width: parent.width
                    label: "底边距离"
                    valueText: controller ? String(controller.subtitleMarginV) : "0"
                    onDecreased: { if (controller) controller.playback.setSubtitleMarginV(controller.subtitleMarginV - 1) }
                    onIncreased: { if (controller) controller.playback.setSubtitleMarginV(controller.subtitleMarginV + 1) }
                }

                Components.StepperRow {
                    width: parent.width
                    label: "字间距"
                    valueWidth: 40
                    valueText: controller ? subtitleSettingsColumn.round1(controller.subtitleSpacing).toFixed(1) : "0.0"
                    onDecreased: { if (controller) controller.playback.setSubtitleSpacing(subtitleSettingsColumn.round1(controller.subtitleSpacing - 0.1)) }
                    onIncreased: { if (controller) controller.playback.setSubtitleSpacing(subtitleSettingsColumn.round1(controller.subtitleSpacing + 0.1)) }
                }
            }
        }
    }

    // ── 重启确认 ──
    Rectangle {
        anchors.fill: parent
        visible: restartConfirmVisible
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 92

        Rectangle {
            width: 170
            height: 70
            radius: 10
            color: Theme.bgSecondary
            border.color: Theme.withAlpha(Theme.primary, 0.2)
            border.width: 1
            anchors.centerIn: parent

            Column {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 10

                Text {
                    text: "确认重启 Go 服务端？"
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontBody
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    width: parent.width
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 10

                    Rectangle {
                        width: 56
                        height: 24
                        radius: 6
                        color: cancelRestartArea.pressed ? Theme.withAlpha(Theme.primary, 0.12) : Theme.bgTertiary

                        Text {
                            anchors.centerIn: parent
                            text: "取消"
                            color: Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSmall
                        }

                        MouseArea {
                            id: cancelRestartArea
                            anchors.fill: parent
                            onClicked: settingsPage.restartConfirmVisible = false
                        }
                    }

                    Rectangle {
                        width: 56
                        height: 24
                        radius: 6
                        color: confirmRestartArea.pressed ? Theme.primaryDark : Theme.primary

                        Text {
                            anchors.centerIn: parent
                            text: "确认"
                            color: Theme.textOnPrimary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSmall
                        }

                        MouseArea {
                            id: confirmRestartArea
                            anchors.fill: parent
                            onClicked: {
                                settingsPage.restartConfirmVisible = false
                                if (controller) controller.up.restartGoServer()
                            }
                        }
                    }
                }
            }
        }
    }
}
