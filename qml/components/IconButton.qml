import QtQuick 2.12
import BiliPlugin 1.0
import ".."

Rectangle {
    id: btn
    width: 36
    height: Theme.touchMinSize
    radius: Theme.radiusMedium
    color: btnArea.pressed
    ? Theme.withAlpha(Theme.primary, 0.15)
    : (active ? Theme.withAlpha(Theme.primary, 0.08) : "transparent")

    Behavior on color { ColorAnimation { duration: Theme.animFast } }
    Behavior on scale { NumberAnimation { duration: Theme.animFast } }

    scale: btnArea.pressed ? 0.92 : 1.0

    property string icon: ""
    property string label: ""
    property string value: ""
    property bool active: false

    signal clicked()

    Row {
        anchors.centerIn: parent
        spacing: 3

        Text {
            text: icon
            font.pixelSize: Theme.fontBody
            color: active ? Theme.primary : Theme.textTertiary
            anchors.verticalCenter: parent.verticalCenter
        }

        Text {
            text: value.length > 0 ? value : label
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontTiny
            color: active ? Theme.primary : Theme.textSecondary
            anchors.verticalCenter: parent.verticalCenter
            visible: text.length > 0
        }
    }

    MouseArea {
        id: btnArea
        anchors.fill: parent
        anchors.margins: -2
        onClicked: btn.clicked()
    }
}
