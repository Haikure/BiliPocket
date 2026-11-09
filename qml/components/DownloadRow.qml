import QtQuick 2.15
import QtGraphicalEffects 1.12
import ".."

Item {
    id: row
    height: 52
    property var task: ({})
    property bool queuePaused: false
    property real reveal: 0
    readonly property bool taskPaused: !!task.paused || (queuePaused && !task.runWhilePaused)
    readonly property bool controllable: task.state !== "complete" && task.state !== "deleting"
    readonly property bool transferring: task.state === "downloading" && !taskPaused
    readonly property bool merging: task.state === "merging" && !taskPaused
    readonly property real downloadProgress: Math.max(0, Math.min(1, task.progress || 0))
    readonly property string progressLabel: Math.floor(downloadProgress * 100) + "%"
    readonly property bool showProgress: downloadProgress > 0 &&
        (task.state === "downloading" || task.state === "paused" || task.state === "queued" ||
         task.state === "resolving" || task.state === "error")
    signal removeRequested(string taskId)
    signal pauseRequested(string taskId)
    signal resumeRequested(string taskId)
    signal playRequested(var mediaTask)

    function qualityLabel(q) {
        return ({16:"360P",32:"480P",64:"720P",80:"1080P",112:"1080P+",116:"1080P60",120:"4K",125:"HDR"})[q] || "音频"
    }
    function speedLabel(bytes) {
        return bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + " MB/s" : Math.round(bytes / 1024) + " KB/s"
    }
    onTaskChanged: { badges.requestPaint(); progressMask.requestPaint() }
    Behavior on reveal { enabled: !swipe.pressed; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    Rectangle {
        anchors.right: parent.right
        visible: row.reveal > 0
        width: 48; height: parent.height; radius: 9
        color: trashArea.pressed ? "#bc303d" : "#e14955"
        Canvas {
            anchors.centerIn: parent
            width: 18; height: 20
            onPaint: {
                var c = getContext("2d"); c.clearRect(0,0,width,height)
                c.strokeStyle = "white"; c.lineWidth = 1.5; c.lineCap = "round"; c.lineJoin = "round"
                c.beginPath(); c.moveTo(3,6); c.lineTo(4,17); c.lineTo(14,17); c.lineTo(15,6)
                c.moveTo(2,4); c.lineTo(16,4); c.moveTo(6,4); c.lineTo(6,2); c.lineTo(12,2); c.lineTo(12,4)
                c.moveTo(7,8); c.lineTo(7,14); c.moveTo(11,8); c.lineTo(11,14); c.stroke()
            }
        }
        MouseArea { id: trashArea; anchors.fill: parent; enabled: row.reveal > 28; onClicked: row.removeRequested(row.task.id) }
    }

    Rectangle {
        id: card
        x: -row.reveal
        width: row.width; height: row.height; radius: 9
        color: swipe.pressed && !swipe.moved ? Theme.bgCardHover : Theme.bgCard
        antialiasing: true

        Rectangle {
            id: coverBox
            x: 5; y: 5; width: 72; height: 42; radius: 6
            color: Theme.bgTertiary
            Image {
                id: cover
                anchors.fill: parent
                source: row.task.cover ? "image://bili/size/144x84/" + encodeURIComponent(row.task.cover) : ""
                sourceSize: Qt.size(144,84)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true; smooth: true; mipmap: true
                visible: false
            }
            OpacityMask {
                anchors.fill: parent
                source: cover
                maskSource: Rectangle { width: 72; height: 42; radius: 6; antialiasing: true }
            }
        }
        Text {
            x: 84; y: 5; width: parent.width - 92; height: 16
            text: row.task.title || "视频"
            color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11
            elide: Text.ElideRight
        }
        Canvas {
            id: badges
            x: 84; y: 22; width: parent.width - 92; height: 13
            onPaint: {
                var c = getContext("2d"); c.clearRect(0,0,width,height)
                c.font = "bold 9px sans-serif"; c.textBaseline = "middle"
                var labels = [row.task.kind || "DASH", row.qualityLabel(row.task.actualQuality || row.task.quality)]
                var x = 0
                for (var i=0; i<labels.length; ++i) {
                    var w = Math.ceil(c.measureText(labels[i]).width) + 10
                    c.fillStyle = i === 0 ? "#183d51" : "#343844"
                    c.beginPath(); c.roundedRect(x,0,w,13,3,3); c.fill()
                    c.fillStyle = i === 0 ? "#8ddfff" : "#d4dce9"
                    c.fillText(labels[i],x+5,7); x += w+4
                }
            }
        }
        Text {
            x: 84; y: 36; width: parent.width - 92; height: 12
            text: {
                if (row.task.state === "complete") return "点击播放 · " + (row.task.status || "已完成")
                if (!row.controllable) return row.task.status || "已完成"
                if (row.taskPaused || row.task.state === "paused") return "已暂停" + (row.showProgress ? " · " + row.progressLabel : "") + " · 点击继续"
                if (row.task.state === "error") return "点击重试 · " + (row.showProgress ? row.progressLabel + " · " : "") + (row.task.status || "下载失败")
                if (row.transferring) return (row.task.status || "下载中") + "  " + row.progressLabel + "  " + row.speedLabel(row.task.speed || 0)
                return (row.task.status || "等待下载") + (row.showProgress ? "  " + row.progressLabel : "")
            }
            elide: Text.ElideRight
            color: row.task.state === "error" ? "#ff8a92" : Theme.textSecondary
            font.family: Theme.fontFamily; font.pixelSize: 8
        }

        // Draw the overlay inside the same rounded path. Rectangle.clip only
        // clips a rectangle and would leave square green corners on the card.
        Canvas {
            id: progressMask
            anchors.fill: parent
            visible: row.showProgress
            onVisibleChanged: if (visible) requestPaint()
            onPaint: {
                var c = getContext("2d"); c.clearRect(0,0,width,height)
                c.save(); c.beginPath(); c.roundedRect(0,0,width,height,9,9); c.clip()
                c.fillStyle = "#303bd38a"
                c.fillRect(0,0,width*row.downloadProgress,height)
                c.restore()
            }
        }
        Item {
            x: 9; y: parent.height-3; width: parent.width-18; height: 2
            visible: row.merging
            clip: true
            Rectangle {
                id: mergeBar
                width: 62; height: 2; radius: 1; color: "#46b8ff"
                SequentialAnimation on x {
                    running: row.merging && row.visible
                    loops: Animation.Infinite
                    NumberAnimation { from: 0; to: card.width-80; duration: 650; easing.type: Easing.InOutSine }
                    NumberAnimation { from: card.width-80; to: 0; duration: 650; easing.type: Easing.InOutSine }
                }
            }
        }
        MouseArea {
            id: swipe
            objectName: "downloadSwipe"
            anchors.fill: parent
            property real startX: 0
            property real startY: 0
            property real startReveal: 0
            property bool horizontal: false
            property bool moved: false
            preventStealing: horizontal
            onPressed: { startX=mapToItem(row,mouse.x,mouse.y).x; startY=mouse.y; startReveal=row.reveal; horizontal=false; moved=false }
            onPositionChanged: {
                if (!pressed) return
                // Map through the moving card so the drag does not feed back on itself.
                var dx = mapToItem(row,mouse.x,mouse.y).x - startX
                var dy = mouse.y - startY
                if (Math.abs(dx)>10 || Math.abs(dy)>10) moved=true
                if (!horizontal && Math.abs(dx)>10 && Math.abs(dx)>Math.abs(dy)*1.4) horizontal=true
                if (horizontal) row.reveal=Math.max(0,Math.min(54,startReveal-dx))
            }
            onReleased: { row.reveal=row.reveal>24 ? 54 : 0; horizontal=false }
            onCanceled: { row.reveal=row.reveal>24 ? 54 : 0; horizontal=false }
            onClicked: {
                if (moved) return
                if (row.reveal>0) { row.reveal=0; return }
                if (row.task.state === "complete") { row.playRequested(row.task); return }
                if (!row.controllable) return
                if (row.taskPaused || row.task.state === "paused" || row.task.state === "error")
                    row.resumeRequested(row.task.id)
                else
                    row.pauseRequested(row.task.id)
            }
        }
    }
}
