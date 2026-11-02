import QtQuick 2.12

Item {
    id: indicator
    objectName: "playerLoadingIndicator"

    property bool active: false
    property string message: ""
    property real progress: -1
    property real downloadSpeed: -1
    property bool cancelEnabled: false
    property color accentColor: "#39a9ff"
    property string fontFamily: "sans-serif"
    property bool revealed: false
    property string displayedMessage: ""
    readonly property bool progressAvailable: isFinite(progress) && progress >= 0
    readonly property int percentage: Math.round(Math.max(0, Math.min(1, progress)) * 100)

    signal cancelRequested()

    width: 152
    implicitHeight: content.implicitHeight
    height: implicitHeight
    visible: opacity > 0
    opacity: revealed ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 120 } }

    function formatSpeed(bytesPerSecond) {
        if (!isFinite(bytesPerSecond) || bytesPerSecond < 0) return ""
        if (bytesPerSecond === 0) return "0 KB/s"
        return bytesPerSecond >= 1024 * 1024
                ? (bytesPerSecond / (1024 * 1024)).toFixed(1) + " MB/s"
                : (bytesPerSecond / 1024).toFixed(1) + " KB/s"
    }

    function updateVisibility() {
        if (active) {
            if (!revealed && !revealTimer.running) revealTimer.start()
        } else {
            revealTimer.stop()
            revealed = false
        }
    }

    onActiveChanged: updateVisibility()
    onMessageChanged: if (message.length) displayedMessage = message
    Component.onCompleted: {
        displayedMessage = message
        updateVisibility()
    }

    Timer {
        id: revealTimer
        interval: 300
        onTriggered: if (indicator.active) indicator.revealed = true
    }

    Column {
        id: content
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 5

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 6

            Canvas {
                id: spinner
                objectName: "loadingSpinner"
                width: 18
                height: 18
                property color accentColor: indicator.accentColor
                onAccentColorChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.lineWidth = 2
                    ctx.strokeStyle = "#70000000"
                    ctx.beginPath()
                    ctx.arc(9, 9, 7, 0, Math.PI * 2)
                    ctx.stroke()
                    ctx.strokeStyle = accentColor
                    ctx.lineCap = "round"
                    ctx.beginPath()
                    ctx.arc(9, 9, 7, -Math.PI / 2, Math.PI)
                    ctx.stroke()
                }
                RotationAnimation on rotation {
                    from: 0
                    to: 360
                    duration: 900
                    loops: Animation.Infinite
                    running: indicator.visible && indicator.opacity > 0
                }
            }

            Text {
                objectName: "loadingMessage"
                height: 18
                text: indicator.displayedMessage + (indicator.progressAvailable ? " " + indicator.percentage + "%" : "")
                textFormat: Text.PlainText
                color: "#f4f6f8"
                font.family: indicator.fontFamily
                font.pixelSize: 12
                verticalAlignment: Text.AlignVCenter
                style: Text.Outline
                styleColor: "#c0000000"
            }
        }

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 120
            height: 3
            radius: 1.5
            color: "#70000000"
            visible: indicator.progressAvailable

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, indicator.progress))
                height: parent.height
                radius: parent.radius
                color: indicator.accentColor
            }
        }

        Text {
            objectName: "loadingSpeed"
            anchors.horizontalCenter: parent.horizontalCenter
            text: indicator.formatSpeed(indicator.downloadSpeed)
            visible: text.length > 0
            color: "#e6eaf0"
            font.family: indicator.fontFamily
            font.pixelSize: 11
            style: Text.Outline
            styleColor: "#c0000000"
        }

        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 56
            height: 24
            visible: indicator.cancelEnabled

            Text {
                anchors.centerIn: parent
                text: "取消"
                color: cancelArea.pressed ? indicator.accentColor : "#e6eaf0"
                font.family: indicator.fontFamily
                font.pixelSize: 11
                style: Text.Outline
                styleColor: "#c0000000"
            }
            MouseArea {
                id: cancelArea
                objectName: "cancelLoadingArea"
                anchors.fill: parent
                enabled: indicator.active && indicator.cancelEnabled
                onClicked: indicator.cancelRequested()
            }
        }
    }
}
