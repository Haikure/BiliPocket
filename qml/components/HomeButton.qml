import QtQuick 2.12
import ".."

Item {
    id: button
    width: 32
    height: 28
    property color backgroundColor: "transparent"
    signal clicked()
    Accessible.role: Accessible.Button
    Accessible.name: "返回主页"
    Accessible.onPressAction: button.clicked()

    Rectangle {
        anchors.centerIn: parent
        width: 28; height: 24; radius: 7
        color: touch.pressed ? Theme.withAlpha(Theme.primary, 0.24) : button.backgroundColor
        Canvas {
            anchors.centerIn: parent
            width: 18; height: 18
            onPaint: {
                var c = getContext("2d")
                c.clearRect(0, 0, width, height)
                c.strokeStyle = Theme.primary
                c.lineWidth = 1.6
                c.lineCap = "round"; c.lineJoin = "round"
                c.beginPath()
                c.moveTo(1.5, 8); c.lineTo(9, 2); c.lineTo(16.5, 8)
                c.moveTo(3.5, 7); c.lineTo(3.5, 16); c.lineTo(7, 16)
                c.lineTo(7, 11); c.lineTo(11, 11); c.lineTo(11, 16)
                c.lineTo(14.5, 16); c.lineTo(14.5, 7)
                c.stroke()
            }
        }
    }
    MouseArea { id: touch; anchors.fill: parent; onClicked: button.clicked() }
}
