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

                Rectangle {
                    width: parent.width
                    height: 52
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8

                        Column {
                            width: parent.width - 112
                            spacing: 3
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                text: "离屏占位"
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: 11
                                font.bold: true
                            }

                            Text {
                                width: parent.width
                                text: "已加载卡片滚出视野后退回 Canvas 占位"
                                color: Theme.textTertiary
                                font.family: Theme.fontFamily
                                font.pixelSize: 9
                                elide: Text.ElideRight
                            }
                        }

                        Rectangle {
                            width: 44; height: 24; radius: 6
                            color: controller && controller.videoCardOffscreenPlaceholderEnabled ? Theme.withAlpha(Theme.primary, 0.25) : Theme.bgTertiary
                            border.width: 1
                            border.color: controller && controller.videoCardOffscreenPlaceholderEnabled ? Theme.primary : Theme.withAlpha(Theme.primary, 0.16)
                            anchors.verticalCenter: parent.verticalCenter
                            Text { anchors.centerIn: parent; text: "开"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 10 }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setVideoCardOffscreenPlaceholderEnabled(true) }
                            }
                        }

                        Rectangle {
                            width: 44; height: 24; radius: 6
                            color: controller && !controller.videoCardOffscreenPlaceholderEnabled ? Theme.withAlpha(Theme.primary, 0.25) : Theme.bgTertiary
                            border.width: 1
                            border.color: controller && !controller.videoCardOffscreenPlaceholderEnabled ? Theme.primary : Theme.withAlpha(Theme.primary, 0.16)
                            anchors.verticalCenter: parent.verticalCenter
                            Text { anchors.centerIn: parent; text: "关"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 10 }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setVideoCardOffscreenPlaceholderEnabled(false) }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 52
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8

                        Column {
                            width: parent.width - 112
                            spacing: 3
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                text: "启用预加载"
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: 11
                                font.bold: true
                            }

                            Text {
                                width: parent.width
                                text: "详情预热评论/字幕/推荐，UP页预取视频"
                                color: Theme.textTertiary
                                font.family: Theme.fontFamily
                                font.pixelSize: 9
                                elide: Text.ElideRight
                            }
                        }

                        Rectangle {
                            width: 44; height: 24; radius: 6
                            color: controller && controller.videoDetailPreloadEnabled ? Theme.withAlpha(Theme.primary, 0.25) : Theme.bgTertiary
                            border.width: 1
                            border.color: controller && controller.videoDetailPreloadEnabled ? Theme.primary : Theme.withAlpha(Theme.primary, 0.16)
                            anchors.verticalCenter: parent.verticalCenter
                            Text { anchors.centerIn: parent; text: "开"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 10 }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setVideoDetailPreloadEnabled(true) }
                            }
                        }

                        Rectangle {
                            width: 44; height: 24; radius: 6
                            color: controller && !controller.videoDetailPreloadEnabled ? Theme.withAlpha(Theme.primary, 0.25) : Theme.bgTertiary
                            border.width: 1
                            border.color: controller && !controller.videoDetailPreloadEnabled ? Theme.primary : Theme.withAlpha(Theme.primary, 0.16)
                            anchors.verticalCenter: parent.verticalCenter
                            Text { anchors.centerIn: parent; text: "关"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 10 }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setVideoDetailPreloadEnabled(false) }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 52
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8

                        Column {
                            width: parent.width - 112
                            spacing: 3
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                text: "默认字幕"
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: 11
                                font.bold: true
                            }

                            Text {
                                width: parent.width
                                text: "打开视频时自动选中第一个中文字幕"
                                color: Theme.textTertiary
                                font.family: Theme.fontFamily
                                font.pixelSize: 9
                                elide: Text.ElideRight
                            }
                        }

                        Rectangle {
                            width: 44; height: 24; radius: 6
                            color: controller && controller.defaultSubtitleEnabled ? Theme.withAlpha(Theme.primary, 0.25) : Theme.bgTertiary
                            border.width: 1
                            border.color: controller && controller.defaultSubtitleEnabled ? Theme.primary : Theme.withAlpha(Theme.primary, 0.16)
                            anchors.verticalCenter: parent.verticalCenter
                            Text { anchors.centerIn: parent; text: "开"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 10 }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setDefaultSubtitleEnabled(true) }
                            }
                        }

                        Rectangle {
                            width: 44; height: 24; radius: 6
                            color: controller && !controller.defaultSubtitleEnabled ? Theme.withAlpha(Theme.primary, 0.25) : Theme.bgTertiary
                            border.width: 1
                            border.color: controller && !controller.defaultSubtitleEnabled ? Theme.primary : Theme.withAlpha(Theme.primary, 0.16)
                            anchors.verticalCenter: parent.verticalCenter
                            Text { anchors.centerIn: parent; text: "关"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 10 }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setDefaultSubtitleEnabled(false) }
                            }
                        }
                    }
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

                Rectangle {
                    width: parent.width
                    height: 30
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8

                        Text { text: "字体大小"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 64 }

                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: fontMinusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
                            Text { anchors.centerIn: parent; text: "-"; color: Theme.textPrimary; font.pixelSize: 14 }
                            MouseArea {
                                id: fontMinusArea
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleFontSize(controller.subtitleFontSize - 1) }
                            }
                        }

                        Text { text: controller ? controller.subtitleFontSize : 0; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 30; horizontalAlignment: Text.AlignHCenter }

                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: fontPlusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
                            Text { anchors.centerIn: parent; text: "+"; color: Theme.textPrimary; font.pixelSize: 14 }
                            MouseArea {
                                id: fontPlusArea
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleFontSize(controller.subtitleFontSize + 1) }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 30
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8

                        Text { text: "字重"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 64 }

                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: boldMinusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
                            Text { anchors.centerIn: parent; text: "-"; color: Theme.textPrimary; font.pixelSize: 14 }
                            MouseArea {
                                id: boldMinusArea
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleWeight(controller.subtitleWeight - 100) }
                            }
                        }

                        Text { text: controller ? String(controller.subtitleWeight) : "700"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 40; horizontalAlignment: Text.AlignHCenter }

                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: boldPlusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
                            Text { anchors.centerIn: parent; text: "+"; color: Theme.textPrimary; font.pixelSize: 14 }
                            MouseArea {
                                id: boldPlusArea
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleWeight(controller.subtitleWeight + 100) }
                            }
                        }
                    }
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

                Rectangle {
                    width: parent.width
                    height: 30
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8

                        Text { text: "描边"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 64 }

                        Rectangle {
                            width: 44; height: 24; radius: 6
                            color: controller && controller.subtitleOutlineEnabled ? Theme.withAlpha(Theme.primary, 0.25) : Theme.bgTertiary
                            border.width: 1
                            border.color: controller && controller.subtitleOutlineEnabled ? Theme.primary : Theme.withAlpha(Theme.primary, 0.16)
                            Text { anchors.centerIn: parent; text: "开"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 10 }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleOutlineEnabled(true) }
                            }
                        }

                        Rectangle {
                            width: 44; height: 24; radius: 6
                            color: controller && !controller.subtitleOutlineEnabled ? Theme.withAlpha(Theme.primary, 0.25) : Theme.bgTertiary
                            border.width: 1
                            border.color: controller && !controller.subtitleOutlineEnabled ? Theme.primary : Theme.withAlpha(Theme.primary, 0.16)
                            Text { anchors.centerIn: parent; text: "关"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 10 }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleOutlineEnabled(false) }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 30
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8

                        Text { text: "灰底背景"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 64 }

                        Rectangle {
                            width: 44; height: 24; radius: 6
                            color: controller && controller.subtitleBackgroundEnabled ? Theme.withAlpha(Theme.primary, 0.25) : Theme.bgTertiary
                            border.width: 1
                            border.color: controller && controller.subtitleBackgroundEnabled ? Theme.primary : Theme.withAlpha(Theme.primary, 0.16)
                            Text { anchors.centerIn: parent; text: "开"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 10 }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleBackgroundEnabled(true) }
                            }
                        }

                        Rectangle {
                            width: 44; height: 24; radius: 6
                            color: controller && !controller.subtitleBackgroundEnabled ? Theme.withAlpha(Theme.primary, 0.25) : Theme.bgTertiary
                            border.width: 1
                            border.color: controller && !controller.subtitleBackgroundEnabled ? Theme.primary : Theme.withAlpha(Theme.primary, 0.16)
                            Text { anchors.centerIn: parent; text: "关"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 10 }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleBackgroundEnabled(false) }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 30
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8

                        Text { text: "背景不透明"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 64 }

                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: bgOpacityMinusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
                            Text { anchors.centerIn: parent; text: "-"; color: Theme.textPrimary; font.pixelSize: 14 }
                            MouseArea {
                                id: bgOpacityMinusArea
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleBackgroundOpacity((Math.round(controller.subtitleBackgroundOpacity * 10) - 1) / 10) }
                            }
                        }

                        Text { text: controller ? Math.round(controller.subtitleBackgroundOpacity * 100) + "%" : "50%"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 40; horizontalAlignment: Text.AlignHCenter }

                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: bgOpacityPlusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
                            Text { anchors.centerIn: parent; text: "+"; color: Theme.textPrimary; font.pixelSize: 14 }
                            MouseArea {
                                id: bgOpacityPlusArea
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleBackgroundOpacity((Math.round(controller.subtitleBackgroundOpacity * 10) + 1) / 10) }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 30
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8

                        Text { text: "描边粗细"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 64 }

                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: outlineMinusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
                            Text { anchors.centerIn: parent; text: "-"; color: Theme.textPrimary; font.pixelSize: 14 }
                            MouseArea {
                                id: outlineMinusArea
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleOutlineWidth(controller.subtitleOutlineWidth - 1) }
                            }
                        }

                        Text { text: controller ? controller.subtitleOutlineWidth : 1; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 30; horizontalAlignment: Text.AlignHCenter }

                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: outlinePlusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
                            Text { anchors.centerIn: parent; text: "+"; color: Theme.textPrimary; font.pixelSize: 14 }
                            MouseArea {
                                id: outlinePlusArea
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleOutlineWidth(controller.subtitleOutlineWidth + 1) }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 30
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8

                        Text { text: "底边距离"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 64 }

                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: marginMinusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
                            Text { anchors.centerIn: parent; text: "-"; color: Theme.textPrimary; font.pixelSize: 14 }
                            MouseArea {
                                id: marginMinusArea
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleMarginV(controller.subtitleMarginV - 1) }
                            }
                        }

                        Text { text: controller ? controller.subtitleMarginV : 0; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 30; horizontalAlignment: Text.AlignHCenter }

                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: marginPlusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
                            Text { anchors.centerIn: parent; text: "+"; color: Theme.textPrimary; font.pixelSize: 14 }
                            MouseArea {
                                id: marginPlusArea
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleMarginV(controller.subtitleMarginV + 1) }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 30
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8

                        Text { text: "字间距"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 64 }

                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: spacingMinusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
                            Text { anchors.centerIn: parent; text: "-"; color: Theme.textPrimary; font.pixelSize: 14 }
                            MouseArea {
                                id: spacingMinusArea
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleSpacing(subtitleSettingsColumn.round1(controller.subtitleSpacing - 0.1)) }
                            }
                        }

                        Text { text: controller ? subtitleSettingsColumn.round1(controller.subtitleSpacing).toFixed(1) : "0.0"; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 40; horizontalAlignment: Text.AlignHCenter }

                        Rectangle {
                            width: 24; height: 24; radius: 6
                            color: spacingPlusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
                            Text { anchors.centerIn: parent; text: "+"; color: Theme.textPrimary; font.pixelSize: 14 }
                            MouseArea {
                                id: spacingPlusArea
                                anchors.fill: parent
                                onClicked: { if (controller) controller.playback.setSubtitleSpacing(subtitleSettingsColumn.round1(controller.subtitleSpacing + 0.1)) }
                            }
                        }
                    }
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
