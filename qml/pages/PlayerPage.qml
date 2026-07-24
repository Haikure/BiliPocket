import QtQuick 2.12
import BiliPlugin 1.0
import "../components" as Components
import ".."

// ══════════════════════════════════════════
//  修复：调整整体布局的 z 层级
// ══════════════════════════════════════════

Rectangle {
    id: playerPage
    width: 320
    height: 170
    color: "#000000"

    property var controller: null
    property int playQuality: 16
    signal backClicked()

    property bool controlsVisible: true
    property bool launchRequested: false

    readonly property int btnSize: 36
    readonly property int iconSize: 20
    readonly property int barHeight: 36
    readonly property color accentColor: "#00A1D6"

    function launchExternalPlayer(path) {
        if (!path || path.length === 0) return;
        if (controller) controller.playback.launchExternalPlayer(path);
    }

    Connections {
        target: controller
        function onPlaybackReady(url) {
            if (!launchRequested || !url || url.length === 0 || !controller) return
            controller.playback.launchExternalPlayerCurrentSelection()
        }
    }

    // ══════════════════════════════════════════
    //  第1层：占位画面（最底层 z: 0）
    // ══════════════════════════════════════════
    Rectangle {
        id: videoContainer
        anchors.fill: parent
        color: "#000000"
        z: 0

        Image {
            anchors.fill: parent
            source: controller && controller.videoPic
                    ? "image://bili/size/640x320/" + encodeURIComponent(controller.videoPic)
                    : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            opacity: 1
            visible: controller && controller.videoPic && controller.videoPic.length > 0
        }

        Connections {
            target: controller

            function onDownloadStateChanged() {
                // 下载完成且有临时文件路径时，启动外部播放器
                if (launchRequested && controller && !controller.isDownloading) {
                    if (controller.dashVideoUrl && controller.dashVideoUrl.length > 0 &&
                        controller.dashAudioUrl && controller.dashAudioUrl.length > 0) {
                        controller.playback.launchExternalPlayerCurrentSelection();
                    }
                }
            }
        }

        // 无视频时的占位提示
        Text {
            id: placeholderText
            anchors.centerIn: parent
            visible: {
                if (!controller) return true;
                if (controller.isDownloading) return true;
                if (controller.tempVideoPath && controller.tempVideoPath.length > 0) return true;
                return controlsVisible;
            }
            text: {
                if (controller) {
                    if (controller.isDownloading)
                        return "正在下载视频...";
                    if (controller.tempVideoPath && controller.tempVideoPath.length > 0)
                        return "已启动外部播放器";
                    return "点击播放按钮以开始";
                }
                return "正在初始化...";
            }
            color: "#999999"
            font.family: Theme.fontFamily
            font.pixelSize: 13
            horizontalAlignment: Text.AlignHCenter
            lineHeight: 1.4
        }
    }

    // ========
    //  第2层：点击区域（z: 10，在视频上方，控制栏下方）
    // ══════════════════════════════════════════
    MouseArea {
        id: videoClickArea
        anchors.fill: parent
        z: 10
        onClicked: {
            controlsVisible = !controlsVisible;
            if (controlsVisible) hideControlsTimer.restart();
        }
    }

    // ══════════════════════════════════════════
    //  第3层：顶部控制栏（z: 20）
    // ══════════════════════════════════════════
    Rectangle {
        id: topBar
        width: parent.width
        height: barHeight
        anchors.top: parent.top
        z: 20
        visible: controlsVisible
        opacity: controlsVisible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }

        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.85) }
            GradientStop { position: 1.0; color: "transparent" }
        }

        Row {
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 10
            spacing: 8

            Item {
                width: btnSize
                height: btnSize
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    anchors.centerIn: parent
                    width: 30
                    height: 26
                    radius: 4
                    color: backBtnArea.pressed ? Qt.rgba(1, 1, 1, 0.2) : "transparent"

                    Canvas {
                        anchors.centerIn: parent
                        width: 18
                        height: 18
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, width, height);
                            ctx.strokeStyle = "#FFFFFF";
                            ctx.lineWidth = 2.5;
                            ctx.lineCap = "round";
                            ctx.lineJoin = "round";
                            ctx.beginPath();
                            ctx.moveTo(12, 3);
                            ctx.lineTo(5, 9);
                            ctx.lineTo(12, 15);
                            ctx.stroke();
                        }
                    }
                }

                MouseArea {
                    id: backBtnArea
                    anchors.fill: parent
                    onClicked: {
                        playerPage.backClicked();
                    }
                }
            }

            Text {
                text: controller ? controller.videoTitle : ""
                color: "#FFFFFF"
                font.family: Theme.fontFamily
                font.pixelSize: 13
                font.bold: true
                elide: Text.ElideRight
                width: parent.width - btnSize - 24
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // ══════════════════════════════════════════
    //  第3层：底部控制栏（z: 20）
    // ══════════════════════════════════════════
    Rectangle {
        id: bottomBar
        width: parent.width
        height: barHeight
        anchors.bottom: parent.bottom
        z: 20
        visible: controlsVisible
        opacity: controlsVisible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }

        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.85) }
        }

        Row {
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 10
            spacing: 10

            Item {
                width: btnSize
                height: btnSize
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    anchors.centerIn: parent
                    width: 30
                    height: 26
                    radius: 4
                    color: playBtnArea.pressed ? Qt.rgba(1, 1, 1, 0.2) : "transparent"

                    Canvas {
                        id: playPauseIcon
                        anchors.centerIn: parent
                        width: iconSize
                        height: iconSize
                        property bool playing: false
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, width, height);
                            ctx.fillStyle = "#FFFFFF";
                            var triWidth = 14;
                            var triHeight = 16;
                            var offsetX = (width - triWidth) / 2 + 2;
                            var offsetY = (height - triHeight) / 2;
                            ctx.beginPath();
                            ctx.moveTo(offsetX, offsetY);
                            ctx.lineTo(offsetX, offsetY + triHeight);
                            ctx.lineTo(offsetX + triWidth, offsetY + triHeight / 2);
                            ctx.closePath();
                            ctx.fill();
                        }
                        Component.onCompleted: requestPaint()
                    }
                }

                MouseArea {
                    id: playBtnArea
                    anchors.fill: parent
                    onClicked: {
                        if (!controller) return;
                        if (controller.playback.externalPlayerRunning()) {
                            controller.toastMessage("播放器已在运行，请先关闭当前窗口");
                            return;
                        }
                        launchRequested = true;
                        controller.toastMessage("正在启动播放器...");
                        if (controller.playUrl && controller.playUrl.length > 0) {
                            controller.playback.launchExternalPlayerCurrentSelection();
                        } else {
                            controller.playback.fetchPlayUrl(playQuality);
                        }
                        hideControlsTimer.restart();
                    }
                }
            }

            Text {
                id: currentTimeText
                text: controller ? controller.playbackProgressText : "00:00 / 00:00"
                color: "#FFFFFF"
                font.family: Theme.fontFamily
                font.pixelSize: 12
                anchors.verticalCenter: parent.verticalCenter
                width: 112
                elide: Text.ElideRight
            }

        }
    }

    // ══════════════════════════════════════════
    //  第4层：下载进度（z: 100，最顶层）
    // ══════════════════════════════════════════
    Rectangle {
        id: downloadProgressOverlay
        anchors.centerIn: parent
        width: Math.min(parent.width * 0.8, 300)
        height: 80
        radius: 8
        color: Qt.rgba(0, 0, 0, 0.85)
        visible: controller && controller.isDownloading
        z: 100

        Column {
            anchors.centerIn: parent
            width: parent.width - 20
            spacing: 8

            Text {
                text: controller ? controller.downloadStatus : "正在下载..."
                color: "#FFFFFF"
                font.family: Theme.fontFamily
                font.pixelSize: 12
                anchors.horizontalCenter: parent.horizontalCenter
                wrapMode: Text.WordWrap
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
            }

            Rectangle {
                width: parent.width
                height: 4
                radius: 2
                color: Qt.rgba(1, 1, 1, 0.3)
                Rectangle {
                    width: parent.width * (controller ? controller.downloadProgress : 0)
                    height: parent.height
                    radius: 2
                    color: accentColor
                }
            }
        }

        // 点击任意位置取消下载
        MouseArea {
            anchors.fill: parent
            onClicked: {
                if (controller) {
                    controller.playback.cancelDownload();
                }
            }
        }
    }

    // ══════════════════════════════════════════
    //  Loading 指示器
    // ══════════════════════════════════════════
    Components.LoadingIndicator {
        anchors.centerIn: parent
        z: 50
        running: controller && controller.isLoading && !controller.isDownloading
        message: controller && controller.isDownloading ? "正在下载视频..." : "获取播放地址..."
        onCancelRequested: {
            if (controller) controller.cancelAll();
        }
    }

    // ══════════════════════════════════════════
    //  自动隐藏计时器
    // ══════════════════════════════════════════
    Timer {
        id: hideControlsTimer
        interval: 3500
        onTriggered: controlsVisible = false
    }


    Component.onCompleted: {
        hideControlsTimer.start();
        if (controller) controller.video.reportCurrentVideoAsRecentViewIfNeeded();
    }

    Component.onDestruction: {
        if (controller) controller.playback.cleanupTempVideo();
    }
}
