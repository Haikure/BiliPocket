import QtQuick 2.12
import ".."

Item {
    id: card
    width: Theme.cardWidth
    height: 60

    property int pNumber: 1
    property string partTitle: "分P标题"
    property string durationText: "00:00"
    property bool isCurrent: false

    signal clicked()

    Rectangle {
        id: background
        anchors.fill: parent
        radius: 8
        
        color: card.isCurrent ? Theme.detailAccentDark : Qt.rgba(1, 1, 1, 0.07)
        border.color: card.isCurrent ? Theme.detailAccent : (mouseArea.pressed ? Theme.detailAccent : "transparent")
        border.width: 1.5

        Behavior on color { ColorAnimation { duration: 150 } }
        Behavior on border.color { ColorAnimation { duration: 120 } }

        Column {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.top: parent.top
            anchors.topMargin: 8
            spacing: 4

            Text {
                text: "P" + card.pNumber
                color: card.isCurrent ? "white" : Theme.detailAccentLight
                font.family: Theme.fontFamily
                font.pixelSize: 10
                font.bold: true
            }

            Text {
                width: parent.width
                text: card.partTitle
                color: card.isCurrent ? "white" : Theme.detailTextBright
                font.family: Theme.fontFamily
                font.pixelSize: 11
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.Wrap
                lineHeight: 1.2
            }
        }

        Text {
            text: card.durationText
            color: card.isCurrent ? Qt.rgba(255,255,255,0.7) : Theme.detailTextSecondary
            font.family: Theme.fontFamily
            font.pixelSize: 9
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 8
            anchors.bottomMargin: 6
        }

        MouseArea {
            id: mouseArea
            anchors.fill: parent
            onClicked: card.clicked()
        }
    }
}
