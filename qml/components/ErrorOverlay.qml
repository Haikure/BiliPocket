import QtQuick 2.12
import BiliPlugin 1.0
import ".."

Rectangle {
    id: errorRoot
    anchors.fill: parent
    color: Theme.bgOverlay
    visible: opacity > 0
    opacity: hasError ? 1 : 0
    z: 100

    Behavior on opacity {
        NumberAnimation { duration: Theme.animSlow; easing.type: Easing.OutCubic }
    }

    property bool hasError: errorMessage.length > 0
    property string errorMessage: ""
    property string retryText: "重试"

    signal retryClicked()
    signal dismissed()

    // 拦截穿透点击
    MouseArea { anchors.fill: parent; onClicked: {} }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width * 0.85, 260)
        height: errorCol.height + Theme.spacingLarge * 2
        radius: Theme.radiusXL
        color: Theme.bgCard
        border.color: Theme.withAlpha(Theme.error, 0.3)
        border.width: 1

        // 微妙阴影效果
        Rectangle {
            anchors.fill: parent
            anchors.margins: -1
            radius: parent.radius + 1
            color: "transparent"
            border.color: Theme.withAlpha(Theme.error, 0.1)
            border.width: 1
            z: -1
        }

        Column {
            id: errorCol
            anchors.centerIn: parent
            spacing: Theme.spacingMedium
            width: parent.width - Theme.spacingLarge * 2

            Text {
                text: "⚠"
                color: Theme.error
                font.pixelSize: 20
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
                text: errorMessage
                color: Theme.textPrimary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontBody
                wrapMode: Text.Wrap
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                maximumLineCount: 3
                elide: Text.ElideRight
                lineHeight: 1.3
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingLarge

                // 重试按钮
                Rectangle {
                    width: 60; height: Theme.buttonHeight
                    radius: Theme.radiusRound
                    color: retryArea.pressed ? Theme.primaryDark : Theme.primary

                    Behavior on color { ColorAnimation { duration: Theme.animFast } }
                    Behavior on scale { NumberAnimation { duration: Theme.animFast } }
                    scale: retryArea.pressed ? 0.93 : 1.0

                    Text {
                        text: retryText
                        color: Theme.textOnPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontBody
                        font.bold: true
                        anchors.centerIn: parent
                    }

                    MouseArea {
                        id: retryArea
                        anchors.fill: parent
                        onClicked: errorRoot.retryClicked()
                    }
                }

                // 关闭按钮
                Rectangle {
                    width: 60; height: Theme.buttonHeight
                    radius: Theme.radiusRound
                    color: dismissArea.pressed ? Theme.bgTertiary : "transparent"
                    border.color: Theme.borderLight
                    border.width: 1

                    Behavior on color { ColorAnimation { duration: Theme.animFast } }
                    scale: dismissArea.pressed ? 0.93 : 1.0
                    Behavior on scale { NumberAnimation { duration: Theme.animFast } }

                    Text {
                        text: "关闭"
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontBody
                        anchors.centerIn: parent
                    }

                    MouseArea {
                        id: dismissArea
                        anchors.fill: parent
                        onClicked: errorRoot.dismissed()
                    }
                }
            }
        }
    }
}
