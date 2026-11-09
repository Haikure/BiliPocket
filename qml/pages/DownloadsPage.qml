import QtQuick 2.15
import "../components" as Components
import ".."

Item {
    id: page
    property var queue: null
    signal playRequested(var mediaTask)
    clip: true
    Component.onCompleted: if (queue) queue.refresh()
    Row {
        id: toolbar
        x: 8; y: 2; spacing: 6
        Text {
            width: Math.max(0, page.width-210); height: 24
            verticalAlignment: Text.AlignVCenter
            text: queue && queue.error ? queue.error : queue ? (queue.paused ? "仅排队 · " : "缓存 · ") + queue.count + " 项" : "缓存"
            elide: Text.ElideRight
            color: Theme.textSecondary; font.family: Theme.fontFamily; font.pixelSize: 10
        }
        Repeater {
            model: ["全部开始", "全部暂停", "清除完成"]
            Rectangle {
                width: 58; height: 24; radius: 7
                enabled: !!page.queue && (index !== 2 || page.queue.completedCount > 0)
                opacity: enabled ? 1 : 0.4
                color: control.pressed ? Theme.primaryDark : Theme.bgTertiary
                Text { anchors.centerIn: parent; text: modelData; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 9 }
                MouseArea {
                    id: control
                    anchors.fill: parent
                    onClicked: {
                        if (index === 0) page.queue.startAll()
                        else if (index === 1) page.queue.pauseAll()
                        else page.queue.clearCompleted()
                    }
                }
            }
        }
    }
    ListView {
        id: list
        anchors.top: toolbar.bottom; anchors.topMargin: 5
        anchors.bottom: parent.bottom; anchors.bottomMargin: 4
        anchors.left: parent.left; anchors.right: parent.right
        anchors.leftMargin: 8; anchors.rightMargin: 8
        spacing: 5; clip: true; boundsBehavior: Flickable.StopAtBounds
        model: page.queue
        cacheBuffer: 60
        delegate: Components.DownloadRow {
            width: list.width
            task: model.task
            queuePaused: page.queue ? page.queue.paused : false
            onRemoveRequested: if (page.queue) page.queue.remove(taskId)
            onPauseRequested: if (page.queue) page.queue.pauseTask(taskId)
            onResumeRequested: if (page.queue) page.queue.resumeTask(taskId)
            onPlayRequested: page.playRequested(mediaTask)
        }
        Text {
            anchors.centerIn: parent
            width: parent.width-24
            visible: list.count===0
            text: page.queue && page.queue.error ? page.queue.error : "暂无缓存\n在视频详情页点击下载"
            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
            color: Theme.textSecondary; font.family: Theme.fontFamily; font.pixelSize: 11
            lineHeight: 1.5
        }
    }
}
