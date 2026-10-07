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
    property bool preparingEmbedded: false
    property bool playbackStarted: false
    property bool externalFallback: false
    property string playbackError: ""
    readonly property bool embeddedMode: !!controller && controller.useEmbeddedPlayer && !externalFallback
    readonly property var embeddedPlayer: embeddedLoader.item
    readonly property bool embeddedBusy: preparingEmbedded || (!!embeddedPlayer && embeddedPlayer.loading)

    function formatTime(value) {
        var seconds = Math.max(0, Math.floor(value || 0))
        var minutes = Math.floor(seconds / 60)
        var remainder = seconds % 60
        return (minutes < 10 ? "0" : "") + minutes + ":" + (remainder < 10 ? "0" : "") + remainder
    }

    function startSelection() {
        launchRequested = false
        if (!controller) return
        if (embeddedMode) {
            if (!embeddedPlayer) return
            preparingEmbedded = true
            controller.playback.prepareEmbeddedPlayback()
        } else {
            controller.playback.launchExternalPlayerCurrentSelection()
            playbackStarted = true
        }
    }

    function requestPlayback() {
        if (!controller) return
        if (embeddedMode && embeddedPlayer && embeddedPlayer.sessionActive
                && (embeddedPlayer.playing || embeddedPlayer.paused)) {
            embeddedPlayer.togglePlayback()
            hideControlsTimer.restart()
            return
        }
        if (controller.isLoading || launchRequested || embeddedBusy) return
        if (controller.playback.externalPlayerRunning()) {
            controller.toastMessage("播放器已在运行，请先关闭当前窗口")
            return
        }
        if (embeddedMode && !embeddedPlayer) return
        playbackError = ""
        launchRequested = true
        if (controller.playUrl && controller.playUrl.length > 0 && controller.playQuality === playQuality)
            startSelection()
        else
            controller.playback.fetchPlayUrl(playQuality)
        if (!controller.isLoading) launchRequested = false
        hideControlsTimer.restart()
        playPauseIcon.refresh()
    }

    function stopPlayback() {
        launchRequested = false
        preparingEmbedded = false
        if (embeddedPlayer) embeddedPlayer.stopAndReport()
        if (controller) controller.playback.cancelEmbeddedPlayback()
    }

    readonly property int btnSize: 36
    readonly property int iconSize: 20
    readonly property int barHeight: 36
    readonly property color accentColor: "#00A1D6"

    Connections {
        target: controller
        function onPlaybackReady(url) {
            if (!launchRequested || !url || url.length === 0 || !controller) return
            startSelection()
        }
        function onIsLoadingChanged() {
            // Failed or cancelled URL requests must allow another attempt.
            if (controller && !controller.isLoading && launchRequested) {
                Qt.callLater(function() {
                    if (controller && !controller.isLoading) launchRequested = false
                })
            }
        }
    }

    Connections {
        target: controller ? controller.playback : null
        function onEmbeddedPlaybackReady(videoUrl, audioUrl, subtitleUrl, startSeconds) {
            if (!preparingEmbedded || !embeddedMode || !embeddedPlayer) return
            preparingEmbedded = false
            embeddedPlayer.openSelection(videoUrl, audioUrl, subtitleUrl, startSeconds)
        }
        function onEmbeddedPlaybackFailed(message) {
            preparingEmbedded = false
            playbackError = message
            controlsVisible = true
        }
    }

    Connections {
        target: embeddedPlayer
        function onPlaybackRequested() { playerPage.requestPlayback() }
        function onCloseRequested() {
            stopPlayback()
            playerPage.backClicked()
        }
        function onFailed(message) {
            playbackError = "播放失败：" + message
            controlsVisible = true
        }
        function onSubtitleFailed(message) {
            if (controller) controller.toastMessage("字幕加载失败：" + message)
        }
        function onProgressReport(position, duration, finished) {
            if (controller) controller.playback.reportEmbeddedProgress(position, duration, finished)
        }
        function onPlayingChanged() {
            playPauseIcon.refresh()
            if (embeddedPlayer && embeddedPlayer.playing) {
                playbackStarted = true
                hideControlsTimer.restart()
            }
            else controlsVisible = true
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
                     && !embeddedPlayer && !playbackStarted
        }

        Loader {
            id: embeddedLoader
            anchors.fill: parent
            active: playerPage.embeddedMode
            source: active ? "../components/EmbeddedPlayer.qml" : ""
            onLoaded: {
                item.displayTitle = Qt.binding(function() {
                    return controller ? controller.videoTitle : ""
                })
                item.coverSource = Qt.binding(function() {
                    return controller && controller.videoPic
                            ? "image://bili/size/640x320/" + encodeURIComponent(controller.videoPic) : ""
                })
                item.showCover = Qt.binding(function() { return !playerPage.playbackStarted })
            }
            onStatusChanged: {
                if (status === Loader.Error) {
                    playbackError = "嵌入播放器加载失败，可使用外部播放器"
                    controlsVisible = true
                }
            }
        }

        // 无视频时的占位提示
        Text {
            id: placeholderText
            anchors.centerIn: parent
            visible: {
                if (!controller) return true;
                return !embeddedPlayer && controlsVisible && !playbackError.length && !embeddedBusy
                        && !(embeddedMode && embeddedPlayer && embeddedPlayer.sessionActive);
            }
            text: controller ? "点击播放按钮以开始" : "正在初始化..."
            color: "#999999"
            font.family: Theme.fontFamily
            font.pixelSize: 13
            horizontalAlignment: Text.AlignHCenter
            lineHeight: 1.4
        }
    }

    Column {
        anchors.centerIn: parent
        width: parent.width - 24
        spacing: 4
        z: 30
        visible: playbackError.length > 0
        Text {
            width: parent.width
            text: playbackError
            color: "#ffd2d2"
            font.family: Theme.fontFamily
            font.pixelSize: 11
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
        }
        Rectangle {
            width: 112
            height: 28
            anchors.horizontalCenter: parent.horizontalCenter
            color: "#333333"
            radius: 4
            visible: embeddedMode
            Text {
                anchors.centerIn: parent
                text: "使用外部播放器"
                color: "white"
                font.family: Theme.fontFamily
                font.pixelSize: 11
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    stopPlayback()
                    externalFallback = true
                    playbackError = ""
                    requestPlayback()
                }
            }
        }
    }

    // ========
    //  第2层：点击区域（z: 10，在视频上方，控制栏下方）
    // ══════════════════════════════════════════
    MouseArea {
        id: videoClickArea
        anchors.fill: parent
        enabled: !embeddedPlayer
        z: 10
        onClicked: {
            controlsVisible = !controlsVisible;
            playPauseIcon.refresh(); // 重新核对播放器状态，更新暂停/播放图标
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
        visible: controlsVisible && !embeddedPlayer
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
                        stopPlayback();
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
        visible: controlsVisible && !embeddedPlayer
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
                        // externalPlayerRunning() 无 notify 信号，交互点手动 refresh()
                        property bool playing: false
                        function refresh() {
                            playing = embeddedMode ? !!embeddedPlayer && embeddedPlayer.playing
                                                   : !!controller && controller.playback.externalPlayerRunning()
                        }
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, width, height);
                            ctx.fillStyle = "#FFFFFF";
                            if (playing) {
                                // 暂停：两条竖条
                                var barWidth = 4;
                                var gap = 5;
                                var totalW = barWidth * 2 + gap;
                                var barX = (width - totalW) / 2;
                                var barY = (height - 16) / 2;
                                ctx.fillRect(barX, barY, barWidth, 16);
                                ctx.fillRect(barX + barWidth + gap, barY, barWidth, 16);
                            } else {
                                // 播放：三角
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
                        }
                        onPlayingChanged: requestPaint()
                        Component.onCompleted: refresh()
                    }
                }

                MouseArea {
                    id: playBtnArea
                    anchors.fill: parent
                    onClicked: {
                        requestPlayback();
                    }
                }
            }

            Text {
                id: currentTimeText
                text: embeddedMode && embeddedPlayer
                      ? formatTime(embeddedPlayer.position) + " / " + formatTime(embeddedPlayer.duration)
                      : controller ? controller.playbackProgressText : "00:00 / 00:00"
                color: "#FFFFFF"
                font.family: Theme.fontFamily
                font.pixelSize: 12
                anchors.verticalCenter: parent.verticalCenter
                width: 112
                elide: Text.ElideRight
            }

            Repeater {
                model: embeddedMode ? ["−10", "+10", "字幕"] : []
                delegate: Rectangle {
                    width: 30
                    height: 30
                    anchors.verticalCenter: parent.verticalCenter
                    radius: 4
                    color: seekButtonArea.pressed ? "#66555555" : "transparent"
                    opacity: index === 2 && (!embeddedPlayer || !embeddedPlayer.hasSubtitle) ? 0.4 : 1
                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: index === 2 && embeddedPlayer && embeddedPlayer.subtitlesEnabled ? accentColor : "white"
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: seekButtonArea
                        anchors.fill: parent
                        onClicked: {
                            if (!embeddedPlayer) return
                            if (index === 2) {
                                if (embeddedPlayer.hasSubtitle)
                                    embeddedPlayer.subtitlesEnabled = !embeddedPlayer.subtitlesEnabled
                            } else {
                                embeddedPlayer.seekTo(embeddedPlayer.position + (index === 0 ? -10 : 10))
                            }
                            hideControlsTimer.restart()
                        }
                    }
                }
            }

        }
    }

    MouseArea {
        id: seekArea
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: bottomBar.top
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        height: 18
        z: 25
        visible: false // EmbeddedPlayer owns the upstream seek controls.
        enabled: visible && !embeddedBusy
        property real preview: 0
        function updatePreview(x) { preview = Math.max(0, Math.min(1, x / width)) }
        onPressed: { updatePreview(mouse.x); hideControlsTimer.stop() }
        onPositionChanged: if (pressed) updatePreview(mouse.x)
        onReleased: {
            embeddedPlayer.seekTo(preview * embeddedPlayer.duration)
            hideControlsTimer.restart()
        }
        onCanceled: hideControlsTimer.restart()
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 4
            radius: 2
            color: "#88ffffff"
            Rectangle {
                width: parent.width * (seekArea.pressed ? seekArea.preview
                       : embeddedPlayer && embeddedPlayer.duration > 0 ? embeddedPlayer.position / embeddedPlayer.duration : 0)
                height: parent.height
                radius: 2
                color: accentColor
            }
        }
    }

    // ══════════════════════════════════════════
    //  Loading 指示器
    // ══════════════════════════════════════════
    Rectangle {
        anchors.centerIn: parent
        z: 50
        visible: launchRequested && !!controller && controller.isLoading
        width: loadingLabel.implicitWidth + 20
        height: 28
        radius: 5
        color: "#b3101620"
        Text {
            id: loadingLabel
            anchors.centerIn: parent
            text: "获取播放地址…  取消"
            color: "#e6eaf0"
            font.family: Theme.fontFamily
            font.pixelSize: 11
        }
        MouseArea {
            anchors.fill: parent
            onClicked: {
                stopPlayback()
                if (controller) controller.cancelAll()
            }
        }
    }

    // ══════════════════════════════════════════
    //  自动隐藏计时器
    // ══════════════════════════════════════════
    Timer {
        id: hideControlsTimer
        interval: 3500
        onTriggered: {
            if (!playbackError.length && (!embeddedMode || (embeddedPlayer && embeddedPlayer.playing)))
                controlsVisible = false
        }
    }


    Component.onCompleted: {
        hideControlsTimer.start();
        if (controller) controller.video.reportCurrentVideoAsRecentViewIfNeeded();
    }

    Component.onDestruction: {
        stopPlayback();
        if (controller) controller.playback.cleanupTempSubtitle();
    }

    onVisibleChanged: if (!visible) stopPlayback()
}
