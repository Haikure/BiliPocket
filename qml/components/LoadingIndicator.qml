import QtQuick 2.12
import BiliPlugin 1.0
import ".."

Item {
    id: loadingRoot
    width: parent ? parent.width : 100
    height: contentColumn.implicitHeight + Theme.spacingSmall * 2
    visible: running
    opacity: running ? 1 : 0
    z: 50

    property bool running: false
    property string message: "加载中..."
    property bool cancelEnabled: true
    property string cancelText: "取消"

    signal cancelRequested()

    Behavior on opacity {
        NumberAnimation { duration: Theme.animNormal }
    }

    Column {
        id: contentColumn
        anchors.centerIn: parent
        spacing: Theme.spacingSmall

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 6

            Repeater {
                model: 3
                Rectangle {
                    width: 6; height: 6
                    radius: 3
                    color: Theme.primary
                    opacity: 0.3

                    SequentialAnimation on opacity {
                        running: loadingRoot.running
                        loops: Animation.Infinite
                        PropertyAction { value: 0.3 }
                        PauseAnimation { duration: index * 180 }
                        NumberAnimation { from: 0.3; to: 1.0; duration: 350; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 1.0; to: 0.3; duration: 350; easing.type: Easing.InOutSine }
                        PauseAnimation { duration: (2 - index) * 180 }
                    }

                    SequentialAnimation on scale {
                        running: loadingRoot.running
                        loops: Animation.Infinite
                        PropertyAction { value: 1.0 }
                        PauseAnimation { duration: index * 180 }
                        NumberAnimation { from: 1.0; to: 1.4; duration: 350; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 1.4; to: 1.0; duration: 350; easing.type: Easing.InOutSine }
                        PauseAnimation { duration: (2 - index) * 180 }
                    }
                }
            }
        }

        Text {
            text: loadingRoot.message
            color: Theme.textTertiary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontTiny
            anchors.horizontalCenter: parent.horizontalCenter
        }

        Rectangle {
            visible: loadingRoot.cancelEnabled
            height: 20
            width: cancelTextItem.implicitWidth + 16
            radius: 10
            color: cancelArea.pressed
                   ? Theme.withAlpha(Theme.primary, 0.18)
                   : Theme.withAlpha(Theme.primary, 0.08)
            border.color: Theme.withAlpha(Theme.primary, 0.25)
            border.width: 1
            anchors.horizontalCenter: parent.horizontalCenter

            Text {
                id: cancelTextItem
                anchors.centerIn: parent
                text: loadingRoot.cancelText
                color: Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontTiny
            }

            MouseArea {
                id: cancelArea
                anchors.fill: parent
                onClicked: loadingRoot.cancelRequested()
            }
        }
    }
}
