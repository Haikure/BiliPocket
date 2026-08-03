import QtQuick 2.12
import BiliPlugin 1.0
import ".."

Rectangle {
    id: toast
    width: Math.min(toastText.implicitWidth + 28, parent ? parent.width - 24 : 200)
    height: 26
    radius: Theme.radiusRound
    color: Theme.withAlpha(Theme.bgTertiary, 0.95)
    border.color: Theme.withAlpha(Theme.primary, 0.2)
    border.width: 1
    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
    anchors.bottom: parent ? parent.bottom : undefined
    anchors.bottomMargin: 12
    visible: false
    opacity: 0
    z: 200
    scale: 0.85

    Text {
        id: toastText
        anchors.centerIn: parent
        color: Theme.textPrimary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontBody
        text: ""
        elide: Text.ElideRight
        width: parent.width - 20
        horizontalAlignment: Text.AlignHCenter
    }

    // 消息队列（最多滞留 2 条）：正在显示时新消息入队，避免连续操作互相顶掉
    property var queue: []

    function display(message, duration) {
        // 先停掉上一条的淡出动画，否则其 onFinished 会立刻隐藏新 toast
        hideAnim.stop();
        toastText.text = message;
        toast.visible = true;
        showAnim.restart();
        hideTimer.interval = duration;
        hideTimer.restart();
    }

    function show(message, duration) {
        if (!duration) duration = 2000;
        if (toast.visible) {
            // 正在显示：入队等待；队列满则丢弃最旧的一条
            queue.push({message: message, duration: duration});
            if (queue.length > 2) queue.shift();
            return;
        }
        display(message, duration);
    }

    ParallelAnimation {
        id: showAnim
        NumberAnimation {
            target: toast; property: "opacity"
            from: 0; to: 1; duration: Theme.animNormal
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: toast; property: "scale"
            from: 0.85; to: 1.0; duration: Theme.animNormal
            easing.type: Easing.OutBack
        }
    }

    Timer {
        id: hideTimer
        onTriggered: hideAnim.start()
    }

    ParallelAnimation {
        id: hideAnim
        NumberAnimation {
            target: toast; property: "opacity"
            from: 1; to: 0; duration: Theme.animSlow
            easing.type: Easing.InCubic
        }
        NumberAnimation {
            target: toast; property: "scale"
            from: 1.0; to: 0.85; duration: Theme.animSlow
            easing.type: Easing.InCubic
        }
        onFinished: {
            toast.visible = false
            // 队列非空则继续显示下一条
            if (queue.length > 0) {
                var next = queue.shift()
                display(next.message, next.duration)
            }
        }
    }
}
