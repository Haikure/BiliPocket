// reuseItems 需要 QtQuick 2.15（Qt 5.15）
import QtQuick 2.15
// 封面圆角矩形仍用 OpacityMask：provider 的 round/ 只支持圆形裁剪
import QtGraphicalEffects 1.12
import BiliPlugin 1.0
import "../components" as Components
import "../js/RichText.js" as RichText
import ".."

Rectangle {
    id: detailPage
    width: 320
    height: 170
    color: Theme.detailBg

    property var controller: null
    property string bvid: ""
    property int detailSessionId: 0
    property bool fullTitleVisible: false
    property var rootRef: null
    property bool fullPartTitleVisible: false
    property string fullPartTitleText: ""
    property bool relatedExpanded: false
    property bool relatedImagesDeferred: false
    property bool relatedSectionNearViewport: false
    property bool relatedSectionReady: false

    // 清晰度选择（默认16）
    property int selectedQuality: 16
    property var availableQualities: [16, 32, 64]

    function qualityLabel(qn) {
        switch (qn) {
        case 0: return "仅音频";
        case 16: return "360P";
        case 32: return "480P";
        case 64: return "720P";
        case 80: return "1080P";
        case 112: return "1080P+";
        case 116: return "1080P60";
        case 120: return "4K";
        case 125: return "HDR";
        default: return qn + "P";
        }
    }

    function openVideoLink(link) {
        if (!link || !controller || !controller.video || !controller.video.resolveVideoLink) return
        controller.video.resolveVideoLink(link)
    }

    // 圆形裁剪由 image provider 的 round/ 前缀完成，无需 OpacityMask
    // 统一取 48x48，与其他页面头像共用缓存键
    function avatarImageSource(url) {
        if (!url) return ""
        var s = String(url)
        if (s.indexOf("image://") === 0 || s.indexOf("data:image/") === 0) return s
        return "image://bili/round/size/48x48/" + encodeURIComponent(s)
    }

    function updateQualities() {
        if (controller && controller.acceptQualities && controller.acceptQualities.length > 0) {
            availableQualities = controller.acceptQualities;
        } else {
            availableQualities = [16, 32, 64, 0];
        }
        if (availableQualities.indexOf(selectedQuality) < 0) {
            selectedQuality = availableQualities[0];
        }
        if (rootRef) {
            rootRef.playQualitySelected = selectedQuality;
        }
    }

    signal backClicked()
    signal playRequested(int quality)
    signal commentsRequested()
    signal upRequested(var mid, var aid)
    signal seasonRequested(var props)
    signal videoSelected(string bvid)

    function reportRecentViewForCurrentSession() {
        if (!rootRef || !controller || detailSessionId <= 0) return
        if (rootRef.reportedDetailSessions[detailSessionId]) return
        var reported = rootRef.reportedDetailSessions
        reported[detailSessionId] = true
        rootRef.reportedDetailSessions = reported
        controller.video.reportCurrentVideoAsRecentViewIfNeeded()
    }

    function captureLoadedDetailSnapshot() {
        if (!controller || !controller.video || !controller.video.captureCurrentVideoDetail) return
        if (!controller.videoBvid || controller.videoBvid.length === 0) return
        controller.video.captureCurrentVideoDetail()
    }

    function restoreCachedDetailIfAvailable() {
        if (!controller || !controller.video || !controller.video.restoreCachedVideoDetail) return false
        if (!bvid || bvid.length === 0) return false
        _restoringCachedDetail = true
        var restored = controller.video.restoreCachedVideoDetail(bvid)
        _restoringCachedDetail = false
        if (restored) {
            _pendingRefreshBvid = ""
            _refreshDispatchQueued = false
            _needRestorePartAfterRefresh = false
            if (controller.videoCid > 0 && (!controller.acceptQualities || controller.acceptQualities.length === 0)) {
                controller.playback.fetchAcceptQualities(detailPage.selectedQuality)
                controller.favorite.fetchFavoriteStatus()
                controller.favorite.fetchCoinStatus()
                controller.favorite.fetchLikeStatus()
                controller.favorite.fetchWatchLaterStatus()
                detailPage.reportRecentViewForCurrentSession()
            }
        }
        return restored
    }

    // 分P列表横向滚动位置
    property real savedPartListX: (rootRef && bvid && rootRef.detailPartListXCache && rootRef.detailPartListXCache[bvid] !== undefined)
                              ? rootRef.detailPartListXCache[bvid]
                              : 0

    property int savedPartIndex: 0
    property int savedPartCid: 0
    property bool _needRestorePartAfterRefresh: false
    property bool _restoringPartNow: false
    property bool _restoringCachedDetail: false
    property bool _completed: false
    property int skeletonPaintToken: 0

    onBvidChanged: {
        captureLoadedDetailSnapshot()
        skeletonPaintToken += 1
        savedPartListX = (rootRef && bvid && rootRef.detailPartListXCache && rootRef.detailPartListXCache[bvid] !== undefined)
                         ? rootRef.detailPartListXCache[bvid]
                         : 0
        savedPartIndex = 0
        savedPartCid = 0
        _needRestorePartAfterRefresh = false
        _restoringPartNow = false
        relatedExpanded = false
        if (!restoreCachedDetailIfAvailable()) {
            refreshDetail(true)
        }
    }

    onSavedPartListXChanged: {
        if (rootRef && bvid && rootRef.detailPartListXCache) {
            rootRef.detailPartListXCache[bvid] = savedPartListX
        }
    }
    property bool favoritePickerVisible: false
    property bool subtitlePickerVisible: false
    property bool coinPickerVisible: false
    property bool coinSelectLike: false
    readonly property bool heroImagesActive: visible
    readonly property bool relatedImagesActive: visible && relatedExpanded && !relatedImagesDeferred && relatedSectionNearViewport
    readonly property bool detailContentReady: controller && controller.videoBvid === detailPage.bvid && controller.videoTitle.length > 0

    onRelatedExpandedChanged: {
        if (!relatedExpanded) {
            relatedImagesDeferred = false
            relatedSectionNearViewport = false
            relatedImageResumeTimer.stop()
            return
        }
        Qt.callLater(function() {
            detailPage.updateRelatedSectionNearViewport()
            if (mainFlick && mainFlick.moving) {
                detailPage.deferRelatedImages()
            } else {
                detailPage.resumeRelatedImagesSoon()
            }
        })
    }

    function updateRelatedSectionNearViewport() {
        if (!relatedExpanded || !relatedSectionReady) {
            relatedSectionNearViewport = false
            return
        }

        var sectionTop = relatedSection.y
        var sectionBottom = sectionTop + relatedSection.height
        var viewportTop = mainFlick.contentY - 120
        var viewportBottom = mainFlick.contentY + mainFlick.height + 160
        relatedSectionNearViewport = sectionBottom >= viewportTop && sectionTop <= viewportBottom
    }

    function deferRelatedImages() {
        if (!relatedExpanded) return
        relatedImageResumeTimer.stop()
        relatedImagesDeferred = true
    }

    function resumeRelatedImagesSoon() {
        if (!relatedExpanded) return
        updateRelatedSectionNearViewport()
        relatedImageResumeTimer.restart()
    }

    function restorePartListPosition() {
        if (!videoPartList || !videoPartList.visible) return;
        if (savedPartListX <= 0) return;
        Qt.callLater(function() {
            videoPartList.contentX = savedPartListX;
            Qt.callLater(function() {
                videoPartList.contentX = savedPartListX;
                Qt.callLater(function() {
                    videoPartList.contentX = savedPartListX;
                })
            })
        })
    }

    readonly property color primaryColor: Theme.detailAccent
    readonly property color primaryLight: Theme.detailAccentLight
    readonly property color primaryDark: Theme.detailAccentDark
    readonly property color surfaceColor: Qt.rgba(1, 1, 1, 0.05)
    readonly property color surfaceBorder: Qt.rgba(1, 1, 1, 0.08)

    // ═══════════════════════════════════════════════════════════
    // 背景渐变
    // ═══════════════════════════════════════════════════════════
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#0d1117" }
            GradientStop { position: 0.5; color: "#111827" }
            GradientStop { position: 1.0; color: "#0f172a" }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 顶部浮动返回控件
    // ═══════════════════════════════════════════════════════════
    Item {
        id: topBar
        anchors.top: parent.top
        anchors.left: parent.left
        width: 52
        height: 24
        z: 5

        Rectangle {
            id: backBtn
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.top: parent.top
            anchors.topMargin: 4
            width: 22
            height: 22
            radius: 11
            color: backArea.pressed ? Qt.rgba(0.23, 0.51, 0.96, 0.34) : Qt.rgba(0.23, 0.51, 0.96, 0.12)
            border.width: 1
            border.color: backArea.pressed ? Qt.rgba(0.23, 0.51, 0.96, 0.32) : Qt.rgba(0.38, 0.70, 1.0, 0.22)

            Behavior on color { ColorAnimation { duration: 150 } }
            scale: backArea.pressed ? 0.85 : 1.0
            Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

            Canvas {
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: -1
                width: 12
                height: 12
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.strokeStyle = primaryLight
                    ctx.lineWidth = 2
                    ctx.lineCap = "round"
                    ctx.lineJoin = "round"
                    ctx.beginPath()
                    ctx.moveTo(8, 2)
                    ctx.lineTo(3, 6)
                    ctx.lineTo(8, 10)
                    ctx.stroke()
                }
            }

            MouseArea {
                id: backArea
                anchors.fill: parent
                anchors.margins: -6
                onClicked: detailPage.backClicked()
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 主内容区（垂直滑动）
    // ═══════════════════════════════════════════════════════════
    Flickable {
        id: mainFlick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: topBar.bottom
        anchors.bottom: parent.bottom
        contentHeight: mainColumn.height
        flickableDirection: Flickable.VerticalFlick
        clip: true
        boundsBehavior: Flickable.DragOverBounds
        onContentYChanged: detailPage.updateRelatedSectionNearViewport()
        onMovementStarted: detailPage.deferRelatedImages()
        onFlickStarted: detailPage.deferRelatedImages()
        onMovementEnded: detailPage.resumeRelatedImagesSoon()
        onFlickEnded: detailPage.resumeRelatedImagesSoon()

        Column {
            id: mainColumn
            width: parent.width
            spacing: 7
            topPadding: 7

            // ─────────────────────────────────────────────
            // Hero 区: 封面 + 主信息
            // ─────────────────────────────────────────────
            Item {
                width: parent.width - 16
                anchors.horizontalCenter: parent.horizontalCenter
                height: Math.max(66, heroInfoColumn.implicitHeight + 2)

                Item {
                    id: heroSkeleton
                    anchors.fill: parent
                    visible: opacity > 0
                    opacity: detailPage.detailContentReady ? 0 : 1
                    Behavior on opacity { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic } }

                    Rectangle {
                        width: 110
                        height: 66
                        radius: 8
                        color: Theme.detailSurface
                        anchors.left: parent.left
                        clip: true

                        Canvas {
                            anchors.fill: parent
                            property int paintToken: detailPage.skeletonPaintToken
                            Component.onCompleted: requestPaint()
                            onPaintTokenChanged: requestPaint()
                            onVisibleChanged: if (visible) requestPaint()
                            onWidthChanged: requestPaint()
                            onHeightChanged: requestPaint()
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.fillStyle = Qt.rgba(1, 1, 1, 0.045)
                                ctx.fillRect(0, 0, width, height)
                                ctx.strokeStyle = Qt.rgba(148 / 255, 163 / 255, 184 / 255, 0.26)
                                ctx.lineWidth = 1.4
                                ctx.lineCap = "round"
                                ctx.lineJoin = "round"
                                ctx.beginPath()
                                ctx.moveTo(28, 43)
                                ctx.lineTo(45, 29)
                                ctx.lineTo(58, 40)
                                ctx.lineTo(70, 31)
                                ctx.lineTo(88, 45)
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.arc(78, 20, 4, 0, Math.PI * 2, false)
                                ctx.stroke()
                            }
                        }
                    }

                    Components.SkeletonPill {
                        anchors.left: parent.left
                        anchors.leftMargin: 119
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: 2
                        height: 62
                        paintToken: detailPage.skeletonPaintToken
                        // x/w ≤1 为宽度比例，>1 为绝对像素
                        pills: [
                            { x: 0, y: 0, w: 0.94, h: 9, color: Qt.rgba(148 / 255, 163 / 255, 184 / 255, 0.20) },
                            { x: 0, y: 13, w: 0.70, h: 9, color: Qt.rgba(148 / 255, 163 / 255, 184 / 255, 0.16) },
                            { x: 0, y: 31, w: 0.48, h: 14, color: Qt.rgba(96 / 255, 165 / 255, 250 / 255, 0.16) },
                            { x: 0, y: 52, w: 0.28, h: 7, color: Qt.rgba(148 / 255, 163 / 255, 184 / 255, 0.13) },
                            { x: 0.34, y: 52, w: 0.24, h: 7, color: Qt.rgba(148 / 255, 163 / 255, 184 / 255, 0.13) }
                        ]
                    }
                }

                // 封面容器
                Rectangle {
                    id: coverContainer
                    visible: opacity > 0
                    opacity: detailPage.detailContentReady ? 1 : 0
                    transform: Translate {
                        y: detailPage.detailContentReady ? 0 : 3
                        Behavior on y { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic } }
                    }
                    Behavior on opacity { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutQuad } }
                    width: 110
                    height: 66
                    radius: 8
                    color: Theme.detailSurface
                    anchors.left: parent.left
                    clip: true

                    Image {
                        id: coverImage
                        anchors.fill: parent
                        source: controller && controller.videoPic && detailPage.heroImagesActive
                        ? "image://bili/size/320x170/" + encodeURIComponent(controller.videoPic) : ""
                        // 与 VideoCardCompact 封面同解码尺寸，同 URL 共享内存缓存
                        sourceSize: Qt.size(210, 140)
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                        mipmap: true
                        visible: false
                    }

                    OpacityMask {
                        anchors.fill: coverImage
                        source: coverImage
                        opacity: coverImage.status === Image.Ready ? 1 : 0
                        maskSource: Rectangle {
                            width: coverImage.width
                            height: coverImage.height
                            radius: coverContainer.radius
                            visible: false
                        }
                        Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                    }

                    // 渐变遮罩
                    Rectangle {
                        anchors.fill: parent
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "transparent" }
                            GradientStop { position: 0.5; color: "transparent" }
                            GradientStop { position: 1.0; color: Theme.bgOverlay }
                        }
                    }

                    // 时长（左下）
                    Text {
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 5
                        anchors.bottomMargin: 4
                        text: controller ? controller.videoDuration : "00:00"
                        color: "white"
                        font.pixelSize: 9
                        font.family: Theme.fontFamily
                        font.bold: true
                        style: Text.Outline
                        styleColor: Qt.rgba(0, 0, 0, 0.6)
                    }

                    // 选集标签（右下）
                    Rectangle {
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: 5
                        anchors.bottomMargin: 4
                        height: 13
                        width: collectionText.implicitWidth + 8
                        radius: 6
                        color: Qt.rgba(0, 0, 0, 0.58)
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.18)
                        visible: controller && controller.video.videoPartModel() && controller.video.videoPartModel().count > 1

                        Text {
                            id: collectionText
                            anchors.centerIn: parent
                            text: "选集 " + (controller && controller.video.videoPartModel() ? controller.video.videoPartModel().count : 0) + "P"
                            color: "#F8FAFC"
                            font.pixelSize: 8
                            font.family: Theme.fontFamily
                            font.bold: true
                        }
                    }
                }

                // 播放按钮（封面正中）
                Rectangle {
                    visible: detailPage.detailContentReady && opacity > 0
                    anchors.centerIn: coverContainer
                    width: 30
                    height: 30
                    radius: 15
                    color: playArea.pressed ? primaryDark : primaryColor
                    border.color: Qt.rgba(1, 1, 1, 0.4)
                    border.width: 2

                    scale: playArea.pressed ? 0.82 : 1.0
                    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                    Behavior on color { ColorAnimation { duration: 120 } }

                    // 发光环
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width + 6
                        height: parent.height + 6
                        radius: width / 2
                        color: "transparent"
                        border.color: Qt.rgba(0.23, 0.51, 0.96, 0.4)
                        border.width: 2
                        opacity: playArea.pressed ? 0 : 0.7
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }

                    Canvas {
                        anchors.centerIn: parent
                        width: 12
                        height: 12
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            ctx.fillStyle = "white"
                            ctx.beginPath()
                            ctx.moveTo(3, 2)
                            ctx.lineTo(12, 7)
                            ctx.lineTo(3, 12)
                            ctx.closePath()
                            ctx.fill()
                        }
                    }

                    MouseArea {
                        id: playArea
                        anchors.fill: parent
                        anchors.margins: -8
                        onClicked: detailPage.playRequested(detailPage.selectedQuality)
                    }
                }

                // 右侧信息列
                Column {
                    id: heroInfoColumn
                    visible: opacity > 0
                    opacity: detailPage.detailContentReady ? 1 : 0
                    transform: Translate {
                        y: detailPage.detailContentReady ? 0 : 3
                        Behavior on y { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic } }
                    }
                    Behavior on opacity { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutQuad } }
                    anchors.left: coverContainer.right
                    anchors.leftMargin: 9
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.topMargin: 1
                    spacing: 4

                    // 标题
                    Text {
                        id: titleText
                        width: parent.width
                        text: controller ? controller.videoTitle : ""
                        color: "#f1f5f9"
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                        font.bold: true
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        lineHeight: 1.15

                        opacity: controller ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 300 } }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: detailPage.fullTitleVisible = true
                        }
                    }

                    // UP 主行（合作视频可横向显示多个 UP）
                    Flickable {
                        id: upStaffFlick
                        width: parent.width
                        height: 18
                        contentWidth: upStaffRow.width
                        contentHeight: height
                        flickableDirection: Flickable.HorizontalFlick
                        boundsBehavior: Flickable.StopAtBounds
                        clip: true

                        Row {
                            id: upStaffRow
                            height: parent.height
                            spacing: 5

                            Repeater {
                                model: controller ? controller.videoStaff : []

                                delegate: Rectangle {
                                    id: upChip
                                    property var staffItem: modelData
                                    property var staffMid: Number(staffItem.mid || 0)
                                    height: upStaffFlick.height
                                    width: Math.min(upRow.implicitWidth + 10, upStaffFlick.width)
                                    radius: height / 2
                                    color: upArea.pressed ? Qt.rgba(0.23, 0.51, 0.96, 0.3) : Qt.rgba(0.23, 0.51, 0.96, 0.14)
                                    border.color: Qt.rgba(0.23, 0.51, 0.96, 0.32)
                                    border.width: 1

                                    scale: upArea.pressed ? 0.92 : 1.0
                                    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                                    Behavior on color { ColorAnimation { duration: 120 } }

                                    Row {
                                        id: upRow
                                        anchors.left: parent.left
                                        anchors.leftMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 5

                                        Rectangle {
                                            width: 14
                                            height: 14
                                            radius: 7
                                            color: Theme.detailSurface
                                            anchors.verticalCenter: parent.verticalCenter

                                            Image {
                                                anchors.fill: parent
                                                smooth: true
                                                mipmap: true
                                                source: staffItem.face && detailPage.heroImagesActive
                                                        ? detailPage.avatarImageSource(staffItem.face) : ""
                                                sourceSize: Qt.size(48, 48)
                                                fillMode: Image.PreserveAspectCrop
                                                asynchronous: true
                                            }
                                        }

                                        Text {
                                            text: staffItem.name || "UP主"
                                            color: primaryLight
                                            font.family: Theme.fontFamily
                                            font.pixelSize: 9
                                            font.bold: true
                                            anchors.verticalCenter: parent.verticalCenter
                                            elide: Text.ElideRight
                                            width: Math.min(implicitWidth, 84)
                                        }
                                    }

                                    MouseArea {
                                        id: upArea
                                        anchors.fill: parent
                                        onClicked: {
                                            if (staffMid > 0) {
                                                detailPage.upRequested(staffMid, controller ? controller.videoAid : 0)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 统计信息行：播放 · 弹幕 · 日期
                    Row {
                        spacing: 8
                        height: 11

                        Row {
                            spacing: 3
                            anchors.verticalCenter: parent.verticalCenter

                            Canvas {
                                width: 9
                                height: 9
                                anchors.verticalCenter: parent.verticalCenter
                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.fillStyle = "#94a3b8"
                                    ctx.beginPath()
                                    ctx.moveTo(2, 1)
                                    ctx.lineTo(8, 4.5)
                                    ctx.lineTo(2, 8)
                                    ctx.closePath()
                                    ctx.fill()
                                }
                            }
                            Text {
                                text: controller ? controller.videoViews : "0"
                                color: "#94a3b8"
                                font.family: Theme.fontFamily
                                font.pixelSize: 9
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Row {
                            spacing: 3
                            anchors.verticalCenter: parent.verticalCenter

                            Canvas {
                                width: 9
                                height: 9
                                anchors.verticalCenter: parent.verticalCenter
                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.strokeStyle = "#34d399"
                                    ctx.lineWidth = 1
                                    ctx.lineCap = "round"
                                    ctx.beginPath()
                                    ctx.moveTo(0, 2); ctx.lineTo(7, 2)
                                    ctx.moveTo(2, 4.5); ctx.lineTo(9, 4.5)
                                    ctx.moveTo(0, 7); ctx.lineTo(6, 7)
                                    ctx.stroke()
                                }
                            }
                            Text {
                                text: controller ? controller.videoDanmaku : "0"
                                color: "#94a3b8"
                                font.family: Theme.fontFamily
                                font.pixelSize: 9
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Text {
                            text: controller ? controller.videoPubDate : ""
                            color: "#64748b"
                            font.family: Theme.fontFamily
                            font.pixelSize: 9
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            width: Math.min(implicitWidth, 80)
                        }
                    }
                }
            }

            // ─────────────────────────────────────────────
            // 主操作行: 点赞 · 投币 · 收藏 · 稍后再看
            // ─────────────────────────────────────────────
            Item {
                width: parent.width - 16
                anchors.horizontalCenter: parent.horizontalCenter
                height: 36

                Row {
                    visible: detailPage.detailContentReady && opacity > 0
                    id: actionRow
                    anchors.fill: parent
                    spacing: 6

                    ActionButton {
                        width: (parent.width - parent.spacing * 3) / 4
                        iconType: "like"
                        label: controller ? controller.videoLikes : "0"
                        active: controller && controller.isLiked
                        activeColor: "#f472b6"
                        onTriggered: {
                            if (controller) controller.favorite.toggleLike()
                        }
                    }

                    ActionButton {
                        width: (parent.width - parent.spacing * 3) / 4
                        iconType: "coin"
                        label: controller ? controller.videoCoins : "0"
                        active: controller && controller.isCoined
                        activeColor: "#fbbf24"
                        onTriggered: {
                            if (!controller) return
                            if (controller.isCoined) {
                                controller.toastMessage("已经投过币了")
                            } else {
                                detailPage.coinSelectLike = true
                                detailPage.coinPickerVisible = true
                            }
                        }
                    }

                    ActionButton {
                        width: (parent.width - parent.spacing * 3) / 4
                        iconType: "star"
                        label: controller ? controller.videoFavorites : "0"
                        active: controller && controller.isFavorited
                        activeColor: "#fb7299"
                        onTriggered: {
                            if (!controller) return
                            if (controller.isFavorited) {
                                controller.favorite.toggleFavorite()
                            } else {
                                controller.favorite.fetchFavoriteFolders()
                                detailPage.favoritePickerVisible = true
                            }
                        }
                    }

                    ActionButton {
                        width: (parent.width - parent.spacing * 3) / 4
                        iconType: "watchlater"
                        label: controller && controller.isWatchLater ? "已加" : "稍后"
                        active: controller && controller.isWatchLater
                        activeColor: primaryLight
                        onTriggered: {
                            if (controller) controller.favorite.toggleWatchLater()
                        }
                    }
                }

                Row {
                    visible: !detailPage.detailContentReady
                    anchors.fill: parent
                    spacing: 6
                    Repeater {
                        model: 4
                        Rectangle {
                            width: (parent.width - parent.spacing * 3) / 4
                            height: 36
                            radius: 8
                            color: Qt.rgba(1, 1, 1, 0.05)
                            border.color: Qt.rgba(1, 1, 1, 0.08)
                            border.width: 1
                            Canvas {
                                anchors.centerIn: parent
                                width: 38
                                height: 22
                                property int paintToken: detailPage.skeletonPaintToken
                                Component.onCompleted: requestPaint()
                                onPaintTokenChanged: requestPaint()
                                onVisibleChanged: if (visible) requestPaint()
                                onWidthChanged: requestPaint()
                                onHeightChanged: requestPaint()
                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.fillStyle = Qt.rgba(148 / 255, 163 / 255, 184 / 255, 0.16)
                                    ctx.beginPath()
                                    ctx.arc(width / 2, 7, 5, 0, Math.PI * 2, false)
                                    ctx.fill()
                                    ctx.beginPath()
                                    ctx.moveTo(4, 17)
                                    ctx.lineTo(width - 4, 17)
                                    ctx.quadraticCurveTo(width, 17, width, 20)
                                    ctx.quadraticCurveTo(width, 22, width - 4, 22)
                                    ctx.lineTo(4, 22)
                                    ctx.quadraticCurveTo(0, 22, 0, 20)
                                    ctx.quadraticCurveTo(0, 17, 4, 17)
                                    ctx.fill()
                                }
                            }
                        }
                    }
                }
            }

            // ─────────────────────────────────────────────
            // 工具行: 评论 · 下载 · 字幕
            // ─────────────────────────────────────────────
            Item {
                width: parent.width - 16
                anchors.horizontalCenter: parent.horizontalCenter
                height: 24

                Row {
                    id: toolRow
                    anchors.fill: parent
                    spacing: 6
                    visible: detailPage.detailContentReady

                    ToolButton {
                        width: (parent.width - parent.spacing * 2) / 3
                        iconType: "comment"
                        label: "评论"
                        onTriggered: detailPage.commentsRequested()
                    }

                    ToolButton {
                        width: (parent.width - parent.spacing * 2) / 3
                        iconType: "download"
                        label: "下载"
                        onTriggered: {
                            if (controller) controller.up.downloadVideoToDisk(detailPage.selectedQuality)
                        }
                    }

                    ToolButton {
                        width: (parent.width - parent.spacing * 2) / 3
                        iconType: "subtitle"
                        label: {
                            if (controller && controller.selectedSubtitleLabel && controller.selectedSubtitleLabel.length > 0) {
                                return "字幕·" + controller.selectedSubtitleLabel
                            }
                            return "字幕"
                        }
                        onTriggered: {
                            if (controller) controller.playback.fetchSubtitleList()
                            detailPage.subtitlePickerVisible = true
                        }
                    }
                }

                Row {
                    visible: !detailPage.detailContentReady
                    anchors.fill: parent
                    spacing: 6
                    Repeater {
                        model: 3
                        Rectangle {
                            width: (parent.width - parent.spacing * 2) / 3
                            height: 24
                            radius: 8
                            color: Qt.rgba(1, 1, 1, 0.05)
                            border.color: Qt.rgba(1, 1, 1, 0.08)
                            border.width: 1

                            Canvas {
                                anchors.centerIn: parent
                                width: 46
                                height: 16
                                property int paintToken: detailPage.skeletonPaintToken
                                Component.onCompleted: requestPaint()
                                onPaintTokenChanged: requestPaint()
                                onVisibleChanged: if (visible) requestPaint()
                                onWidthChanged: requestPaint()
                                onHeightChanged: requestPaint()
                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.strokeStyle = Qt.rgba(148 / 255, 163 / 255, 184 / 255, 0.22)
                                    ctx.fillStyle = Qt.rgba(148 / 255, 163 / 255, 184 / 255, 0.16)
                                    ctx.lineWidth = 1.2
                                    ctx.lineCap = "round"
                                    ctx.lineJoin = "round"

                                    if (index === 0) {
                                        ctx.beginPath()
                                        ctx.moveTo(2, 3)
                                        ctx.lineTo(14, 3)
                                        ctx.quadraticCurveTo(17, 3, 17, 6)
                                        ctx.lineTo(17, 9)
                                        ctx.quadraticCurveTo(17, 12, 14, 12)
                                        ctx.lineTo(8, 12)
                                        ctx.lineTo(4, 15)
                                        ctx.lineTo(5, 12)
                                        ctx.lineTo(2, 12)
                                        ctx.quadraticCurveTo(0, 12, 0, 9)
                                        ctx.lineTo(0, 6)
                                        ctx.quadraticCurveTo(0, 3, 2, 3)
                                        ctx.stroke()
                                    } else if (index === 1) {
                                        ctx.beginPath()
                                        ctx.moveTo(8, 1)
                                        ctx.lineTo(8, 10)
                                        ctx.moveTo(4, 7)
                                        ctx.lineTo(8, 11)
                                        ctx.lineTo(12, 7)
                                        ctx.moveTo(2, 14)
                                        ctx.lineTo(14, 14)
                                        ctx.stroke()
                                    } else {
                                        ctx.beginPath()
                                        ctx.moveTo(1, 3)
                                        ctx.lineTo(15, 3)
                                        ctx.lineTo(15, 12)
                                        ctx.lineTo(1, 12)
                                        ctx.closePath()
                                        ctx.stroke()
                                        ctx.beginPath()
                                        ctx.moveTo(4, 6)
                                        ctx.lineTo(12, 6)
                                        ctx.moveTo(5, 9)
                                        ctx.lineTo(11, 9)
                                        ctx.stroke()
                                    }

                                    ctx.beginPath()
                                    ctx.moveTo(24, 5)
                                    ctx.lineTo(width - 4, 5)
                                    ctx.quadraticCurveTo(width, 5, width, 8)
                                    ctx.quadraticCurveTo(width, 11, width - 4, 11)
                                    ctx.lineTo(24, 11)
                                    ctx.quadraticCurveTo(20, 11, 20, 8)
                                    ctx.quadraticCurveTo(20, 5, 24, 5)
                                    ctx.fill()
                                }
                            }
                        }
                    }
                }
            }

            // ─────────────────────────────────────────────
            // 清晰度选择
            // ─────────────────────────────────────────────
            Item {
                width: parent.width - 16
                anchors.horizontalCenter: parent.horizontalCenter
                height: detailPage.detailContentReady ? 24 : 0
                visible: detailPage.detailContentReady

                Text {
                    id: qualityHeader
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "清晰度"
                    color: primaryLight
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    font.bold: true
                }

                Rectangle {
                    id: refreshChip
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: 18
                    width: 36
                    radius: 9
                    color: refreshArea.pressed ? primaryDark : Qt.rgba(1, 1, 1, 0.06)
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.1)

                    scale: refreshArea.pressed ? 0.9 : 1.0
                    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: 100 } }

                    Text {
                        anchors.centerIn: parent
                        text: "刷新"
                        color: "#cbd5e1"
                        font.family: Theme.fontFamily
                        font.pixelSize: 9
                        font.bold: true
                    }

                    MouseArea {
                        id: refreshArea
                        anchors.fill: parent
                        onClicked: {
                            if (controller) controller.playback.fetchAcceptQualities(detailPage.selectedQuality)
                        }
                    }
                }

                Flickable {
                    id: qualityFlick
                    anchors.left: qualityHeader.right
                    anchors.leftMargin: 8
                    anchors.right: refreshChip.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    height: 22
                    contentWidth: qualityRow.implicitWidth
                    contentHeight: height
                    flickableDirection: Flickable.HorizontalFlick
                    clip: true
                    boundsBehavior: Flickable.DragOverBounds

                    Row {
                        id: qualityRow
                        spacing: 4
                        anchors.verticalCenter: parent.verticalCenter

                        Repeater {
                            model: detailPage.availableQualities

                            Rectangle {
                                id: qualityItem
                                height: 18
                                width: Math.max(34, qItemText.implicitWidth + 10)
                                radius: 9
                                color: detailPage.selectedQuality === modelData
                                       ? primaryColor
                                       : Qt.rgba(1, 1, 1, 0.06)
                                border.width: 1
                                border.color: detailPage.selectedQuality === modelData
                                               ? primaryLight
                                               : Qt.rgba(1, 1, 1, 0.1)

                                scale: qualityArea.pressed ? 0.9 : 1.0
                                Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                                Behavior on color { ColorAnimation { duration: 100 } }

                                Text {
                                    id: qItemText
                                    anchors.centerIn: parent
                                    text: qualityLabel(modelData)
                                    color: detailPage.selectedQuality === modelData
                                           ? "white"
                                           : "#cbd5e1"
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 9
                                    font.bold: detailPage.selectedQuality === modelData
                                }

                                MouseArea {
                                    id: qualityArea
                                    anchors.fill: parent
                                    onClicked: {
                                        detailPage.selectedQuality = modelData
                                        if (detailPage.rootRef) {
                                            detailPage.rootRef.playQualitySelected = modelData
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ─────────────────────────────────────────────
            // 选集（仅多P视频）
            // ─────────────────────────────────────────────
            Item {
                id: partsSection
                width: parent.width
                height: visible ? 84 : 0
                visible: controller && !controller.isLoading
                         && controller.video.videoPartModel() && controller.video.videoPartModel().count > 1

                Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                Row {
                    id: partsHeader
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.leftMargin: 8
                    spacing: 5
                    height: 11

                    Canvas {
                        width: 11
                        height: 11
                        anchors.verticalCenter: parent.verticalCenter
                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            ctx.strokeStyle = primaryLight
                            ctx.lineWidth = 1.4
                            ctx.lineCap = "round"
                            ctx.beginPath()
                            ctx.moveTo(1.5, 2); ctx.lineTo(1.5, 9)
                            ctx.moveTo(4.5, 2); ctx.lineTo(4.5, 9)
                            ctx.moveTo(7.5, 2); ctx.lineTo(7.5, 9)
                            ctx.moveTo(10, 2); ctx.lineTo(10, 9)
                            ctx.stroke()
                        }
                    }

                    Text {
                        text: "选集"
                        color: primaryLight
                        font.family: Theme.fontFamily
                        font.pixelSize: 10
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: controller && controller.video.videoPartModel()
                              ? controller.video.videoPartModel().count + "P"
                              : ""
                        color: "#64748b"
                        font.family: Theme.fontFamily
                        font.pixelSize: 9
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                ListView {
                    id: videoPartList
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: partsHeader.bottom
                    anchors.topMargin: 5
                    height: 60
                    orientation: ListView.Horizontal
                    clip: true
                    // VideoPartCard 纯属性驱动、无瞬态状态，复用安全（多P可达数百项）
                    reuseItems: true
                    spacing: 6
                    leftMargin: 8
                    rightMargin: 8

                    model: controller ? controller.video.videoPartModel() : null
                    visible: model && model.count > 0

                    delegate: Components.VideoPartCard {
                        pNumber: model.page
                        partTitle: model.part
                        durationText: model.durationText
                        isCurrent: controller && controller.videoCid === model.cid

                        onClicked: {
                            if (!controller) return
                            detailPage.savedPartListX = videoPartList.contentX
                            detailPage.savedPartIndex = index
                            if (controller.videoCid === model.cid) {
                                detailPage.fullPartTitleText = model.part || ""
                                detailPage.fullPartTitleVisible = true
                            } else {
                                controller.up.playVideoPart(index)
                                detailPage.restorePartListPosition()
                            }
                        }
                    }
                }
            }

            // ─────────────────────────────────────────────
            // 简介
            // ─────────────────────────────────────────────
            Rectangle {
                id: descCard
                width: parent.width - 16
                anchors.horizontalCenter: parent.horizontalCenter
                radius: 10
                color: surfaceColor
                border.color: surfaceBorder
                border.width: 1
                height: detailPage.detailContentReady ? descColumn.implicitHeight + 18 : 48

                Canvas {
                    visible: !detailPage.detailContentReady
                    anchors.fill: parent
                    anchors.margins: 9
                    property int paintToken: detailPage.skeletonPaintToken
                    Component.onCompleted: requestPaint()
                    onPaintTokenChanged: requestPaint()
                    onVisibleChanged: if (visible) requestPaint()
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        ctx.fillStyle = Qt.rgba(96 / 255, 165 / 255, 250 / 255, 0.18)
                        ctx.beginPath()
                        ctx.moveTo(4, 0)
                        ctx.lineTo(42, 0)
                        ctx.quadraticCurveTo(46, 0, 46, 4)
                        ctx.quadraticCurveTo(46, 8, 42, 8)
                        ctx.lineTo(4, 8)
                        ctx.quadraticCurveTo(0, 8, 0, 4)
                        ctx.quadraticCurveTo(0, 0, 4, 0)
                        ctx.fill()
                        ctx.fillStyle = Qt.rgba(148 / 255, 163 / 255, 184 / 255, 0.14)
                        var widths = [width * 0.92, width * 0.76]
                        for (var i = 0; i < widths.length; ++i) {
                            var y = 17 + i * 11
                            var w = widths[i]
                            ctx.beginPath()
                            ctx.moveTo(4, y)
                            ctx.lineTo(w - 4, y)
                            ctx.quadraticCurveTo(w, y, w, y + 4)
                            ctx.quadraticCurveTo(w, y + 8, w - 4, y + 8)
                            ctx.lineTo(4, y + 8)
                            ctx.quadraticCurveTo(0, y + 8, 0, y + 4)
                            ctx.quadraticCurveTo(0, y, 4, y)
                            ctx.fill()
                        }
                    }
                }

                Column {
                    visible: detailPage.detailContentReady && opacity > 0
                    id: descColumn
                    anchors.fill: parent
                    anchors.margins: 9
                    spacing: 6

                    Row {
                        spacing: 5
                        height: 11

                        Canvas {
                            width: 11
                            height: 11
                            anchors.verticalCenter: parent.verticalCenter
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.strokeStyle = primaryLight
                                ctx.lineWidth = 1.2
                                ctx.lineCap = "round"
                                ctx.lineJoin = "round"
                                ctx.beginPath()
                                ctx.moveTo(2, 1); ctx.lineTo(7, 1)
                                ctx.lineTo(10, 4); ctx.lineTo(10, 10)
                                ctx.lineTo(2, 10); ctx.closePath()
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.moveTo(7, 1); ctx.lineTo(7, 4); ctx.lineTo(10, 4)
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.moveTo(4, 6); ctx.lineTo(8, 6)
                                ctx.moveTo(4, 8); ctx.lineTo(8, 8)
                                ctx.stroke()
                            }
                        }

                        Text {
                            text: "简介"
                            color: primaryLight
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                            font.bold: true
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            text: detailPage.bvid && detailPage.bvid.length > 0
                                  ? "· " + detailPage.bvid
                                  : ""
                            color: "#64748b"
                            font.family: Theme.fontFamily
                            font.pixelSize: 9
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Qt.rgba(1, 1, 1, 0.06)
                    }

                    Flickable {
                        id: descFlick
                        width: parent.width
                        height: Math.min(descText.implicitHeight, 80)
                        contentHeight: descText.implicitHeight
                        flickableDirection: Flickable.VerticalFlick
                        clip: true
                        boundsBehavior: Flickable.DragOverBounds

                        Text {
                            id: descText
                            width: parent.width
                            text: RichText.linkifyVideoLinks(controller ? controller.videoDesc : "", "暂无简介")
                            textFormat: Text.RichText
                            color: "#94a3b8"
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                            wrapMode: Text.Wrap
                            lineHeight: 1.35
                            linkColor: Theme.richTextLinkColor
                            onLinkActivated: detailPage.openVideoLink(link)
                        }
                    }
                }
            }

            Rectangle {
                id: seasonEntryCard
                width: parent.width - 16
                anchors.horizontalCenter: parent.horizontalCenter
                visible: controller && controller.videoSeasonId > 0
                height: visible ? 42 : 0
                radius: 10
                color: seasonEntryArea.pressed ? Qt.rgba(0.23, 0.51, 0.96, 0.16) : surfaceColor
                border.color: seasonEntryArea.pressed ? Qt.rgba(0.38, 0.70, 1.0, 0.36) : surfaceBorder
                border.width: 1

                Behavior on color { ColorAnimation { duration: 120 } }
                Behavior on border.color { ColorAnimation { duration: 120 } }

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    spacing: 8

                    Rectangle {
                        width: 24
                        height: 24
                        radius: 12
                        color: Qt.rgba(0.23, 0.51, 0.96, 0.16)
                        border.color: Qt.rgba(0.38, 0.70, 1.0, 0.24)
                        border.width: 1
                        anchors.verticalCenter: parent.verticalCenter

                        Item {
                            width: 12
                            height: 12
                            anchors.centerIn: parent

                            Rectangle {
                                width: 8
                                height: 8
                                radius: 1.8
                                color: "transparent"
                                border.color: primaryLight
                                border.width: 1
                                x: 0
                                y: 4
                            }
                            Rectangle {
                                width: 8
                                height: 8
                                radius: 1.8
                                color: primaryLight
                                x: 4
                                y: 0
                            }
                        }
                    }

                    Column {
                        width: parent.width - 60
                        spacing: 3
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            width: parent.width
                            text: "合集·" + (controller && controller.videoSeasonTitle ? controller.videoSeasonTitle : "合集")
                            color: "#f1f5f9"
                            font.family: Theme.fontFamily
                            font.pixelSize: 11
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width
                            text: controller && controller.videoSeasonTotal > 0
                                  ? "共 " + controller.videoSeasonTotal + " 个视频"
                                  : "点击查看合集视频"
                            color: "#94a3b8"
                            font.family: Theme.fontFamily
                            font.pixelSize: 9
                            elide: Text.ElideRight
                        }
                    }

                    Text {
                        text: "›"
                        color: primaryLight
                        font.family: Theme.fontFamily
                        font.pixelSize: 18
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    id: seasonEntryArea
                    anchors.fill: parent
                    onClicked: {
                        if (!controller || controller.videoSeasonId <= 0) return
                        detailPage.seasonRequested({
                            mid: controller.videoSeasonMid,
                            seasonId: controller.videoSeasonId,
                            title: controller.videoSeasonTitle,
                            cover: controller.videoSeasonCover,
                            total: controller.videoSeasonTotal,
                            currentBvid: detailPage.bvid
                        })
                    }
                }
            }

            Column {
                id: relatedSection
                width: parent.width - 16
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6
                visible: detailPage.detailContentReady && controller && controller.videoBvid === detailPage.bvid
                readonly property var relatedModel: controller ? controller.season.relatedVideoModel() : null
                Component.onCompleted: {
                    detailPage.relatedSectionReady = true
                    detailPage.updateRelatedSectionNearViewport()
                }

                Rectangle {
                    id: relatedEntryCard
                    width: parent.width
                    height: 42
                    radius: 10
                    color: relatedArea.pressed ? Qt.rgba(0.55, 0.36, 0.96, 0.17) : surfaceColor
                    border.color: relatedArea.pressed ? Qt.rgba(0.78, 0.68, 1.0, 0.38) : surfaceBorder
                    border.width: 1

                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on border.color { ColorAnimation { duration: 120 } }

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 8

                        Canvas {
                            width: 24
                            height: 24
                            anchors.verticalCenter: parent.verticalCenter
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)

                                ctx.strokeStyle = "rgba(96,165,250,0.58)"
                                ctx.lineWidth = 1.5
                                ctx.lineCap = "round"
                                ctx.lineJoin = "round"
                                ctx.beginPath()
                                ctx.arc(12, 12, 9, 0, Math.PI * 2)
                                ctx.stroke()

                                ctx.fillStyle = primaryLight
                                ctx.beginPath()
                                ctx.moveTo(10, 8)
                                ctx.lineTo(16, 12)
                                ctx.lineTo(10, 16)
                                ctx.closePath()
                                ctx.fill()
                            }
                        }

                        Column {
                            width: parent.width - 60
                            spacing: 3
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                width: parent.width
                                text: "更多推荐"
                                color: "#f1f5f9"
                                font.family: Theme.fontFamily
                                font.pixelSize: 11
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                text: relatedSection.relatedModel && relatedSection.relatedModel.loading
                                      ? "正在加载相关视频"
                                      : (relatedSection.relatedModel && relatedSection.relatedModel.count > 0
                                         ? "为你找到 " + relatedSection.relatedModel.count + " 个相关视频"
                                         : (detailPage.relatedExpanded ? "暂无推荐" : "点击加载相关视频"))
                                color: "#94a3b8"
                                font.family: Theme.fontFamily
                                font.pixelSize: 9
                                elide: Text.ElideRight
                            }
                        }

                        Canvas {
                            width: 14
                            height: 14
                            anchors.verticalCenter: parent.verticalCenter
                            rotation: detailPage.relatedExpanded ? 90 : 0
                            Behavior on rotation { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.strokeStyle = primaryLight
                                ctx.lineWidth = 2
                                ctx.lineCap = "round"
                                ctx.lineJoin = "round"
                                ctx.beginPath()
                                ctx.moveTo(5, 3)
                                ctx.lineTo(9, 7)
                                ctx.lineTo(5, 11)
                                ctx.stroke()
                            }
                        }
                    }

                    MouseArea {
                        id: relatedArea
                        anchors.fill: parent
                        onClicked: {
                            if (!controller || controller.videoBvid !== detailPage.bvid) return
                            detailPage.relatedExpanded = true
                            var model = relatedSection.relatedModel
                            if (model && (model.count > 0 || model.loading)) return
                            Qt.callLater(function() {
                                if (controller && controller.videoBvid === detailPage.bvid) {
                                    controller.season.fetchRelatedVideos()
                                }
                            })
                        }
                    }
                }

                Item {
                    width: parent.width
                    height: detailPage.relatedExpanded ? 135 : 0
                    visible: detailPage.relatedExpanded
                    clip: true

                    ListView {
                        id: relatedList
                        anchors.fill: parent
                        orientation: ListView.Horizontal
                        spacing: 6
                        clip: true
                        // VideoCardCompact 已适配 pooled/reused，可安全复用
                        reuseItems: true
                        cacheBuffer: 240
                        displayMarginBeginning: 80
                        displayMarginEnd: 80
                        model: relatedSection.relatedModel
                        leftMargin: 2
                        rightMargin: 2
                        visible: relatedSection.relatedModel && relatedSection.relatedModel.count > 0

                        delegate: Components.VideoCardCompact {
                            width: Theme.cardWidth
                            height: relatedList.height
                            videoTitle: model.title || ""
                            coverUrl: model.pic || ""
                            imageActive: detailPage.relatedImagesActive
                            preferOffscreenPlaceholder: true
                            upName: model.ownerName || ""
                            viewCount: model.views || ""
                            durationText: model.durationText || ""
                            bvid: model.bvid || ""
                            partCount: model.partCount || 1
                            titleScale: 0.9
                            subScale: 0.85
                            onClicked: {
                                if (bvid && bvid !== detailPage.bvid) detailPage.videoSelected(bvid)
                            }
                        }
                    }

                    Row {
                        visible: relatedSection.relatedModel && relatedSection.relatedModel.loading && relatedSection.relatedModel.count === 0
                        anchors.left: parent.left
                        anchors.leftMargin: 2
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6
                        Repeater {
                            model: 3
                            Components.VideoCardCompact {
                                width: Theme.cardWidth
                                height: 135
                                placeholder: true
                                    titleScale: 0.9
                                subScale: 0.85
                            }
                        }
                    }

                    Text {
                        visible: relatedSection.relatedModel && !relatedSection.relatedModel.loading && relatedSection.relatedModel.count === 0
                        anchors.centerIn: parent
                        text: "暂无推荐"
                        color: "#64748b"
                        font.family: Theme.fontFamily
                        font.pixelSize: 9
                    }
                }
            }

            // 底部保留轻微呼吸感
            Item {
                width: parent.width
                height: 3
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // ActionButton 组件 - 主操作按钮（图标在上、文本在下）
    // ═══════════════════════════════════════════════════════════
    component ActionButton: Rectangle {
        id: actionBtn
        property string iconType: ""
        property string label: ""
        property bool active: false
        property color activeColor: "#f472b6"
        signal triggered()

        height: 36
        radius: 8
        color: active
               ? Qt.rgba(activeColor.r, activeColor.g, activeColor.b, 0.18)
               : (actionArea.pressed ? Qt.rgba(1, 1, 1, 0.13) : Qt.rgba(1, 1, 1, 0.05))
        border.color: active
                      ? Qt.rgba(activeColor.r, activeColor.g, activeColor.b, 0.55)
                      : Qt.rgba(1, 1, 1, 0.08)
        border.width: 1

        scale: actionArea.pressed ? 0.92 : 1.0
        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 120 } }
        Behavior on border.color { ColorAnimation { duration: 120 } }

        Column {
            anchors.centerIn: parent
            spacing: 2

            Canvas {
                id: actIcon
                width: 14
                height: 14
                anchors.horizontalCenter: parent.horizontalCenter
                property bool _active: actionBtn.active
                property color _activeColor: actionBtn.activeColor
                property string _type: actionBtn.iconType
                on_ActiveChanged: requestPaint()

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    var col = _active ? _activeColor : "#cbd5e1"

                    if (_type === "like") {
                        ctx.save()
                        ctx.scale(width / 11, height / 11)
                        ctx.strokeStyle = col
                        ctx.lineWidth = 1.4
                        ctx.lineCap = "round"
                        ctx.lineJoin = "round"
                        ctx.beginPath()
                        ctx.moveTo(2, 5.3)
                        ctx.lineTo(4.2, 5.3)
                        ctx.lineTo(5.6, 2.4)
                        ctx.quadraticCurveTo(6.2, 1.4, 7.0, 2.0)
                        ctx.lineTo(6.6, 5.0)
                        ctx.lineTo(9.4, 5.0)
                        ctx.lineTo(8.4, 9.1)
                        ctx.lineTo(4.0, 9.1)
                        ctx.lineTo(2.0, 8.2)
                        ctx.closePath()
                        ctx.stroke()
                        ctx.restore()
                    } else if (_type === "coin") {
                        ctx.strokeStyle = col
                        ctx.lineWidth = 1.4
                        ctx.beginPath()
                        ctx.arc(7, 7, 6, 0, Math.PI * 2)
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.arc(7, 7, 3, 0, Math.PI * 2)
                        ctx.stroke()
                    } else if (_type === "star") {
                        ctx.fillStyle = col
                        ctx.beginPath()
                        var cx = 7, cy = 7, outerR = 6.5, innerR = 2.6
                        for (var i = 0; i < 5; i++) {
                            var oA = (i * 72 - 90) * Math.PI / 180
                            var iA = ((i * 72) + 36 - 90) * Math.PI / 180
                            if (i === 0) ctx.moveTo(cx + outerR * Math.cos(oA), cy + outerR * Math.sin(oA))
                            else ctx.lineTo(cx + outerR * Math.cos(oA), cy + outerR * Math.sin(oA))
                            ctx.lineTo(cx + innerR * Math.cos(iA), cy + innerR * Math.sin(iA))
                        }
                        ctx.closePath()
                        ctx.fill()
                    } else if (_type === "watchlater") {
                        ctx.strokeStyle = col
                        ctx.lineWidth = 1.4
                        ctx.lineCap = "round"
                        ctx.beginPath()
                        ctx.arc(7, 7, 5.5, 0, Math.PI * 2)
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.moveTo(7, 7); ctx.lineTo(7, 4.2)
                        ctx.moveTo(7, 7); ctx.lineTo(9.7, 8.4)
                        ctx.stroke()
                    }
                }
            }

            Text {
                text: actionBtn.label
                color: actionBtn.active ? actionBtn.activeColor : "#cbd5e1"
                font.family: Theme.fontFamily
                font.pixelSize: 9
                font.bold: actionBtn.active
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }

        MouseArea {
            id: actionArea
            anchors.fill: parent
            onClicked: actionBtn.triggered()
        }
    }

    // ═══════════════════════════════════════════════════════════
    // ToolButton 组件 - 工具按钮（图标 + 横向文本）
    // ═══════════════════════════════════════════════════════════
    component ToolButton: Rectangle {
        id: toolBtn
        property string iconType: ""
        property string label: ""
        signal triggered()

        height: 24
        radius: 12
        color: toolArea.pressed ? primaryDark : primaryColor
        scale: toolArea.pressed ? 0.92 : 1.0
        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 100 } }

        Row {
            anchors.centerIn: parent
            spacing: 4

            Canvas {
                width: 11
                height: 11
                anchors.verticalCenter: parent.verticalCenter
                property string _type: toolBtn.iconType

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.strokeStyle = "white"
                    ctx.fillStyle = "white"
                    ctx.lineWidth = 1.2
                    ctx.lineCap = "round"
                    ctx.lineJoin = "round"

                    if (_type === "comment") {
                        ctx.beginPath()
                        ctx.moveTo(2, 1.5)
                        ctx.lineTo(9, 1.5)
                        ctx.quadraticCurveTo(10.5, 1.5, 10.5, 3)
                        ctx.lineTo(10.5, 6.5)
                        ctx.quadraticCurveTo(10.5, 8, 9, 8)
                        ctx.lineTo(5, 8)
                        ctx.lineTo(2.5, 10.2)
                        ctx.lineTo(2.5, 8)
                        ctx.quadraticCurveTo(0.5, 8, 0.5, 6.5)
                        ctx.lineTo(0.5, 3)
                        ctx.quadraticCurveTo(0.5, 1.5, 2, 1.5)
                        ctx.closePath()
                        ctx.stroke()
                    } else if (_type === "download") {
                        ctx.beginPath()
                        ctx.moveTo(5.5, 1); ctx.lineTo(5.5, 7.2)
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.moveTo(2.5, 4.8); ctx.lineTo(5.5, 7.8); ctx.lineTo(8.5, 4.8)
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.moveTo(1, 10); ctx.lineTo(10, 10)
                        ctx.stroke()
                    } else if (_type === "subtitle") {
                        ctx.beginPath()
                        ctx.rect(0.5, 2, 10, 7)
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.moveTo(2, 5); ctx.lineTo(4, 5)
                        ctx.moveTo(5, 5); ctx.lineTo(8.5, 5)
                        ctx.moveTo(2, 7); ctx.lineTo(5, 7)
                        ctx.moveTo(6, 7); ctx.lineTo(8.5, 7)
                        ctx.stroke()
                    }
                }
            }

            Text {
                text: toolBtn.label
                color: "white"
                font.family: Theme.fontFamily
                font.pixelSize: 8
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                width: Math.min(implicitWidth, toolBtn.width - 24)
            }
        }

        MouseArea {
            id: toolArea
            anchors.fill: parent
            onClicked: toolBtn.triggered()
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 全屏标题浮层
    // ═══════════════════════════════════════════════════════════
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.82)
        z: 200
        visible: detailPage.fullTitleVisible

        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Text {
            anchors.centerIn: parent
            width: parent.width - 40
            text: controller ? controller.videoTitle : ""
            color: "white"
            font.family: Theme.fontFamily
            font.pixelSize: 14
            font.bold: true
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }

        MouseArea {
            anchors.fill: parent
            onClicked: detailPage.fullTitleVisible = false
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.82)
        z: 201
        visible: detailPage.fullPartTitleVisible

        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Text {
            anchors.centerIn: parent
            width: parent.width - 40
            text: detailPage.fullPartTitleText
            color: "white"
            font.family: Theme.fontFamily
            font.pixelSize: 14
            font.bold: true
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }

        MouseArea {
            anchors.fill: parent
            onClicked: detailPage.fullPartTitleVisible = false
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 字幕选择弹窗
    // ═══════════════════════════════════════════════════════════
    Item {
        id: subtitlePickerOverlay
        anchors.fill: parent
        visible: detailPage.subtitlePickerVisible
        z: 94

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.55)
        }

        Rectangle {
            id: subtitlePickerDialog
            anchors.centerIn: parent
            width: Math.min(parent.width - 40, 220)
            height: Math.min(parent.height - 20, 145)
            radius: 10
            color: Qt.rgba(0.08, 0.1, 0.14, 0.98)
            border.color: Qt.rgba(1, 1, 1, 0.12)
            border.width: 1
            z: 2

            Column {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                Text {
                    text: "选择字幕"
                    color: "white"
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    font.bold: true
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: "当前字幕已选中 ✅"
                    visible: controller && controller.selectedSubtitleId > 0
                    color: "#9ae6b4"
                    font.family: Theme.fontFamily
                    font.pixelSize: 9
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                ListView {
                    id: subtitleListDialog
                    width: parent.width
                    height: parent.height - 30
                    model: controller ? controller.subtitleList : []
                    clip: true
                    spacing: 4
                    z: 3

                    Text {
                        anchors.centerIn: parent
                        text: "没有字幕"
                        visible: !controller || controller.subtitleList.length === 0
                        color: "#94a3b8"
                        font.family: Theme.fontFamily
                        font.pixelSize: 10
                    }

                    header: Item {
                        width: subtitleListDialog.width
                        height: 42

                        Rectangle {
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 30
                            radius: 6
                            color: noSubArea.pressed ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.04)

                            scale: noSubArea.pressed ? 0.92 : 1.0
                            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            Behavior on color { ColorAnimation { duration: 100 } }

                            Text {
                                anchors.centerIn: parent
                                width: parent.width - 12
                                text: "不使用字幕"
                                color: "white"
                                font.family: Theme.fontFamily
                                font.pixelSize: 10
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                            }

                            MouseArea {
                                id: noSubArea
                                anchors.fill: parent
                                onClicked: {
                                    if (controller) controller.playback.clearSelectedSubtitle();
                                    detailPage.subtitlePickerVisible = false;
                                }
                            }
                        }
                    }

                    delegate: Rectangle {
                        width: subtitleListDialog.width
                        height: 34
                        radius: 6
                        color: subChooseArea.pressed ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.04)

                        scale: subChooseArea.pressed ? 0.92 : 1.0
                        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: 100 } }

                        Text {
                            anchors.centerIn: parent
                            width: parent.width - 12
                            text: {
                                var label = modelData.lan_doc || modelData.lan || ("字幕" + (index + 1));
                                var subtitleId = modelData.subtitleId || modelData.id || 0;
                                if (controller && controller.selectedSubtitleId === subtitleId) {
                                    return label + " ✅";
                                }
                                return label;
                            }
                            color: "white"
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                        }

                        MouseArea {
                            id: subChooseArea
                            anchors.fill: parent
                            onClicked: {
                                if (controller) {
                                    var label = modelData.lan_doc || modelData.lan || ("字幕" + (index + 1));
                                    controller.playback.selectSubtitle(modelData.subtitleId || modelData.id || 0, label);
                                }
                                detailPage.subtitlePickerVisible = false;
                            }
                        }
                    }
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            z: 1
            onClicked: {
                if (!subtitlePickerDialog.contains(mapToItem(subtitlePickerDialog, mouse.x, mouse.y))) {
                    detailPage.subtitlePickerVisible = false;
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 投币选择弹窗
    // ═══════════════════════════════════════════════════════════
    Item {
        id: coinPickerOverlay
        anchors.fill: parent
        visible: detailPage.coinPickerVisible
        z: 95

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.55)
        }

        Rectangle {
            id: coinPickerDialog
            anchors.centerIn: parent
            width: 150
            height: 110
            radius: 10
            color: Qt.rgba(0.08, 0.1, 0.14, 0.98)
            border.color: Qt.rgba(1, 1, 1, 0.12)
            border.width: 1
            z: 2

            Column {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8

                Text {
                    text: "选择投币数量"
                    color: "white"
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    font.bold: true
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Rectangle {
                    width: parent.width
                    height: 22
                    radius: 6
                    color: coinLikeArea.pressed ? Qt.rgba(1, 1, 1, 0.08) : "transparent"

                    scale: coinLikeArea.pressed ? 0.92 : 1.0
                    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: 100 } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 6

                        Rectangle {
                            width: 12
                            height: 12
                            radius: 3
                            color: detailPage.coinSelectLike ? primaryColor : "transparent"
                            border.color: detailPage.coinSelectLike ? primaryColor : Qt.rgba(1, 1, 1, 0.35)
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: detailPage.coinSelectLike ? "✓" : ""
                                color: "white"
                                font.pixelSize: 8
                                font.bold: true
                            }
                        }

                        Text {
                            text: "同时点赞"
                            color: "#cbd5e1"
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                        }
                    }

                    MouseArea {
                        id: coinLikeArea
                        anchors.fill: parent
                        onClicked: detailPage.coinSelectLike = !detailPage.coinSelectLike
                    }
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 10

                    Repeater {
                        model: [1, 2]

                        Rectangle {
                            width: 44
                            height: 28
                            radius: 6
                            color: coinChooseArea.pressed ? primaryDark : primaryColor

                            scale: coinChooseArea.pressed ? 0.9 : 1.0
                            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            Behavior on color { ColorAnimation { duration: 100 } }

                            Text {
                                anchors.centerIn: parent
                                text: modelData + "币"
                                color: "white"
                                font.family: Theme.fontFamily
                                font.pixelSize: 10
                                font.bold: true
                            }

                            MouseArea {
                                id: coinChooseArea
                                anchors.fill: parent
                                onClicked: {
                                    if (controller) controller.favorite.addCoin(modelData, detailPage.coinSelectLike)
                                    detailPage.coinPickerVisible = false
                                }
                            }
                        }
                    }
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            z: 1
            onClicked: {
                if (!coinPickerDialog.contains(mapToItem(coinPickerDialog, mouse.x, mouse.y))) {
                    detailPage.coinPickerVisible = false
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 收藏夹选择弹窗
    // ═══════════════════════════════════════════════════════════
    Item {
        id: favoritePickerOverlay
        anchors.fill: parent
        visible: detailPage.favoritePickerVisible
        z: 95

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.55)
        }

        Rectangle {
            id: favoritePickerDialog
            anchors.centerIn: parent
            width: Math.min(parent.width - 40, 220)
            height: Math.min(parent.height - 20, 145)
            radius: 10
            color: Qt.rgba(0.08, 0.1, 0.14, 0.98)
            border.color: Qt.rgba(1, 1, 1, 0.12)
            border.width: 1
            z: 2

            Column {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                Text {
                    text: "选择收藏夹"
                    color: "white"
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    font.bold: true
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                ListView {
                    id: favoriteFolderListDialog
                    width: parent.width
                    height: parent.height - 30
                    model: controller ? controller.favorite.favoriteFolderModel() : null
                    clip: true
                    spacing: 4
                    z: 3

                    delegate: Rectangle {
                        width: favoriteFolderListDialog.width
                        height: 34
                        radius: 6
                        color: favChooseArea.pressed ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.04)

                        scale: favChooseArea.pressed ? 0.92 : 1.0
                        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: 100 } }

                        Text {
                            anchors.centerIn: parent
                            width: parent.width - 12
                            text: model.title || "未命名收藏夹"
                            color: "white"
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                        }

                        MouseArea {
                            id: favChooseArea
                            anchors.fill: parent
                            onClicked: {
                                if (controller) controller.favorite.toggleFavoriteTo(model.id)
                                detailPage.favoritePickerVisible = false
                            }
                        }
                    }
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            z: 1
            onClicked: {
                if (!favoritePickerDialog.contains(mapToItem(favoritePickerDialog, mouse.x, mouse.y))) {
                    detailPage.favoritePickerVisible = false
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 下载进度遮罩
    // ═══════════════════════════════════════════════════════════
    Rectangle {
        id: downloadProgressOverlay
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.75)
        visible: controller && controller.isDownloading
        z: 100

        Behavior on opacity { NumberAnimation { duration: 200 } }
        opacity: visible ? 1 : 0

        // 吞掉点击，避免穿透到下层页面；取消只通过下方按钮触发
        MouseArea {
            anchors.fill: parent
        }

        Column {
            anchors.centerIn: parent
            width: parent.width - 80
            spacing: 8

            Text {
                text: controller ? controller.downloadStatus : "准备下载..."
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
                    color: primaryColor
                    Behavior on width { NumberAnimation { duration: 150 } }
                }
            }

            // 与进度条拉开一点间距
            Item { width: 1; height: 4 }

            // 取消下载按钮（与工具行按钮同款：主题色胶囊 + 按下变深 + 缩放反馈）
            Rectangle {
                id: cancelDownloadBtn
                anchors.horizontalCenter: parent.horizontalCenter
                width: 100
                height: 24
                radius: 12
                color: cancelDownloadArea.pressed ? primaryDark : primaryColor
                scale: cancelDownloadArea.pressed ? 0.92 : 1.0
                Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: 100 } }

                Row {
                    anchors.centerIn: parent
                    spacing: 4

                    Canvas {
                        width: 11
                        height: 11
                        anchors.verticalCenter: parent.verticalCenter
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, width, height);
                            // 停止图标（方块）
                            ctx.fillStyle = "white";
                            ctx.beginPath();
                            ctx.rect(1.5, 1.5, 8, 8);
                            ctx.fill();
                        }
                    }

                    Text {
                        text: "取消下载"
                        color: "white"
                        font.family: Theme.fontFamily
                        font.pixelSize: 8
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    id: cancelDownloadArea
                    anchors.fill: parent
                    onClicked: {
                        if (controller) controller.playback.cancelDownload();
                    }
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 入场动画 + 生命周期
    // ═══════════════════════════════════════════════════════════
    property double _lastRefreshMs: 0
    property string _pendingRefreshBvid: ""
    property bool _enterAnimationDone: false
    property bool _refreshDispatchQueued: false

    function schedulePendingRefresh() {
        if (_refreshDispatchQueued) return
        _refreshDispatchQueued = true
        Qt.callLater(function() {
            detailPage._refreshDispatchQueued = false
            detailPage.runPendingRefresh()
        })
    }

    Timer {
        id: relatedImageResumeTimer
        interval: 120
        repeat: false
        onTriggered: {
            detailPage.updateRelatedSectionNearViewport()
            detailPage.relatedImagesDeferred = false
        }
    }

    function runPendingRefresh() {
        if (!controller || _pendingRefreshBvid.length === 0) return
        if (_pendingRefreshBvid !== bvid) {
            _pendingRefreshBvid = ""
            return
        }
        if (!visible || !_enterAnimationDone) return
        var requestBvid = _pendingRefreshBvid
        _pendingRefreshBvid = ""
        controller.video.fetchVideoDetail(requestBvid)
    }

    function refreshDetail(force) {
        if (!controller || bvid.length === 0) return;
        var nowMs = Date.now();
        var hasPendingRefresh = _pendingRefreshBvid.length > 0
        if (!force && !hasPendingRefresh && (nowMs - _lastRefreshMs) < 400) return;
        _lastRefreshMs = nowMs;
        _pendingRefreshBvid = bvid;
        if (visible && _enterAnimationDone) {
            schedulePendingRefresh()
        }
    }

    Component.onCompleted: {
        _completed = true
        skeletonPaintToken += 1

        if (rootRef && rootRef.playQualitySelected > 0) {
            selectedQuality = rootRef.playQualitySelected
        }
        updateQualities()

        _enterAnimationDone = false
        if (controller && bvid.length > 0 && !detailContentReady) {
            if (!restoreCachedDetailIfAvailable()) {
                refreshDetail(true)
            }
        }

        enterAnimation.restart()
    }

    onVisibleChanged: {
        if (visible) {
            restorePartListPosition()

            if (controller) {
                savedPartCid = controller.videoCid || 0
            }
            if (_completed && controller && controller.videoBvid !== detailPage.bvid) {
                skeletonPaintToken += 1
                _enterAnimationDone = false
                enterAnimation.restart()
                if (!restoreCachedDetailIfAvailable()) {
                    _needRestorePartAfterRefresh = true
                    refreshDetail(false)
                }
            } else if (_completed && _pendingRefreshBvid.length > 0 && _enterAnimationDone) {
                schedulePendingRefresh()
            }
        } else {
            if (videoPartList) savedPartListX = videoPartList.contentX
            if (controller) savedPartCid = controller.videoCid || 0
            captureLoadedDetailSnapshot()
        }
    }

    Connections {
        target: controller
        function onAcceptQualitiesChanged() {
            detailPage.updateQualities();
            detailPage.captureLoadedDetailSnapshot();
        }
        function onVideoDetailChanged() {
            if (controller && controller.videoCid > 0 && controller.videoBvid === detailPage.bvid) {
                if (!detailPage._restoringCachedDetail) {
                    controller.playback.fetchAcceptQualities(detailPage.selectedQuality)
                    controller.favorite.fetchFavoriteStatus()
                    controller.favorite.fetchCoinStatus()
                    controller.favorite.fetchLikeStatus()
                    controller.favorite.fetchWatchLaterStatus()
                    detailPage.reportRecentViewForCurrentSession()
                }
                detailPage.captureLoadedDetailSnapshot()
            }

            if (detailPage._needRestorePartAfterRefresh && !detailPage._restoringPartNow) {
                detailPage._needRestorePartAfterRefresh = false

                var partModel = controller ? controller.video.videoPartModel() : null
                var canRestore = partModel && partModel.count > detailPage.savedPartIndex

                if (canRestore && detailPage.savedPartIndex > 0
                        && (controller.videoCid || 0) !== (detailPage.savedPartCid || 0)) {
                    detailPage._restoringPartNow = true
                    Qt.callLater(function() {
                        controller.up.playVideoPart(detailPage.savedPartIndex)
                        Qt.callLater(function() {
                            detailPage._restoringPartNow = false
                            detailPage.restorePartListPosition()
                        })
                    })
                }
            }

            detailPage.restorePartListPosition()
        }
        function onLoginStateChanged() {
            if (controller && controller.loggedIn && controller.videoCid > 0) {
                controller.favorite.fetchFavoriteStatus()
                controller.favorite.fetchCoinStatus()
                controller.favorite.fetchLikeStatus()
                controller.favorite.fetchWatchLaterStatus()
            }
        }
        function onFavoriteStatusChanged() { detailPage.captureLoadedDetailSnapshot(); }
        function onCoinStatusChanged() { detailPage.captureLoadedDetailSnapshot(); }
        function onLikeStatusChanged() { detailPage.captureLoadedDetailSnapshot(); }
        function onWatchLaterStatusChanged() { detailPage.captureLoadedDetailSnapshot(); }
        function onSubtitleListChanged() { detailPage.captureLoadedDetailSnapshot(); }
        function onSelectedSubtitleChanged() { detailPage.captureLoadedDetailSnapshot(); }
    }

    ParallelAnimation {
        id: enterAnimation
        onFinished: {
            detailPage._enterAnimationDone = true
            detailPage.schedulePendingRefresh()
        }

        NumberAnimation {
            target: mainColumn
            property: "opacity"
            from: 0
            to: 1
            duration: 350
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            target: topBar
            property: "opacity"
            from: 0
            to: 1
            duration: 400
            easing.type: Easing.OutCubic
        }
    }
}
