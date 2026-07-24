import QtQuick 2.12
import BiliPlugin 1.0
import ".."

Rectangle {
    id: titleBar
    width: parent ? parent.width : 320
    height: Theme.titleBarHeight
    color: Theme.bgSecondary
    z: 10

    property string title: ""
    property string titleSuffix: ""
    property bool showBack: true
    property bool showSearch: false
    property int titleSideReserve: 55

    signal backClicked()
    signal searchClicked()

    // ── 返回按钮 ──
    Rectangle {
        id: backBtn
        visible: showBack
        width: 56
        height: parent.height
        color: "transparent"
        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
            id: backBtnCore
            anchors.centerIn: parent
            width: 38; height: 22
            radius: Theme.radiusMedium
            color: backArea.pressed
            ? Theme.withAlpha(Theme.primary, 0.2) : "transparent"

            Behavior on color { ColorAnimation { duration: Theme.animFast } }

            Row {
                anchors.centerIn: parent
                spacing: 2

                Text {
                    text: "‹"
                    color: Theme.primary
                    font.pixelSize: Theme.fontLarge
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: "返回"
                    color: Theme.primary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        MouseArea {
            id: backArea
            anchors.fill: parent
            anchors.margins: -10
            onClicked: titleBar.backClicked()
        }
    }

    // ── 标题 ──
    Row {
        id: titleGroup
        property int maxWidth: Math.max(0, parent.width - titleBar.titleSideReserve * 2)
        anchors.centerIn: parent
        width: Math.min(maxWidth, titleText.implicitWidth + (suffixText.visible ? spacing + suffixText.implicitWidth : 0))
        height: parent.height
        spacing: suffixText.visible ? 4 : 0

        Text {
            id: titleText
            width: Math.max(0, titleGroup.width - (suffixText.visible ? titleGroup.spacing + suffixText.implicitWidth : 0))
            text: titleBar.title
            color: Theme.textPrimary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontMedium
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            horizontalAlignment: suffixText.visible ? Text.AlignRight : Text.AlignHCenter
        }

        Text {
            id: suffixText
            visible: titleBar.titleSuffix.length > 0
            text: titleBar.titleSuffix
            color: Theme.textSecondary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSmall
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    // ── 搜索按钮 ──
    Rectangle {
        id: searchBtn
        visible: showSearch
        width: 36
        height: parent.height
        color: "transparent"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
            anchors.centerIn: parent
            width: 28; height: 22
            radius: Theme.radiusMedium
            color: searchArea.pressed
            ? Theme.withAlpha(Theme.primary, 0.2) : "transparent"

            Behavior on color { ColorAnimation { duration: Theme.animFast } }

            Canvas {
                anchors.centerIn: parent
                width: 16
                height: 16
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.strokeStyle = Theme.primary
                    ctx.lineWidth = 1.8
                    ctx.lineCap = "round"
                    ctx.beginPath()
                    ctx.arc(7, 7, 5, 0, Math.PI * 2)
                    ctx.stroke()
                    ctx.beginPath()
                    ctx.moveTo(11, 11)
                    ctx.lineTo(15, 15)
                    ctx.stroke()
                }
            }
        }

        MouseArea {
            id: searchArea
            anchors.fill: parent
            onClicked: titleBar.searchClicked()
        }
    }

    // ── 底部分割线 + 微光效果 ──
    Rectangle {
        width: parent.width; height: 1
        anchors.bottom: parent.bottom
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.3; color: Theme.withAlpha(Theme.primary, 0.3) }
            GradientStop { position: 0.7; color: Theme.withAlpha(Theme.primary, 0.3) }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }
}
