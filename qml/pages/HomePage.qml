import QtQuick 2.12
import BiliPlugin 1.0
import "../components" as Components
import ".."

Rectangle {
    id: homePage
    width: 320
    height: 170
    color: Theme.bgPrimary

    property var controller: null
    property var rootRef: null
    property int initialTabIndex: 0

    signal videoSelected(string bvid)
    signal searchRequested()
    signal loginRequested()
    signal rankingRequested()
    signal dynamicRequested()
    signal backButtonClicked()

    // ── 内容区状态 ──
    property int tabIndex: 0
    property bool moreMenuVisible: false
    property bool isLoading: controller ? controller.isLoading : false
    property int recommendDebounceMs: 3500
    property double lastRecommendRefreshMs: 0
    property bool initialPopularRequested: false
    property bool popularModelAttached: false
    property bool popularLoadingMore: false
    readonly property bool popularImagesActive: visible && tabIndex === 0
    readonly property bool rankingImagesActive: visible && tabIndex === 1
    readonly property bool profileImagesActive: visible && tabIndex === 3

    function requestInitialPopular() {
        if (!controller || initialPopularRequested) return
        var model = controller.feed.popularModel()
        if (model && model.count > 0) {
            initialPopularRequested = true
            popularModelAttached = true
            return
        }
        initialPopularRequested = true
        controller.feed.fetchPopular()
        popularModelAttached = true
    }

    Timer {
        id: initialPopularTimer
        interval: 50
        repeat: false
        onTriggered: homePage.requestInitialPopular()
    }

    function switchTab(index) {
        // index: 0=推荐, 1=排行, 2=搜索, 3=我的, 4=更多
        if (index === 4) {
            moreMenuVisible = !moreMenuVisible
            return
        }

        moreMenuVisible = false

        if (index === 1) {
            rankingRequested()
            return
        }

        if (index === 2) {
            searchRequested()
            return
        }

        // 已登录时，点击“我的”直接进入 UserPage
        if (index === 3) {
            loginRequested()
            return
        }

        // 只有在“推荐”页内再次点击时才刷新
        if (index === 0 && tabIndex === 0 && controller) {
            var nowMs = Date.now();
            if (nowMs - lastRecommendRefreshMs < recommendDebounceMs) {
                controller.toastMessage("操作过快，请稍后再试")
                return
            }
            lastRecommendRefreshMs = nowMs
            initialPopularTimer.stop()
            initialPopularRequested = true
            popularModelAttached = true
            controller.feed.fetchPopular(1, 10)
            controller.toastMessage("已刷新推荐")
            return
        }

        if (tabIndex === index) return
        tabIndex = index
        if (rootRef) rootRef.homeTabIndex = tabIndex

    }

    // ── 内容区 (无标题栏，高度 = 170 - 26 = 144px) ──
    Item {
        id: contentArea
        anchors {
            top: parent.top
            bottom: tabBar.top
            left: parent.left
            right: parent.right
        }
        clip: true

        // ──── Tab 0: 推荐 ────
        Item {
            anchors.fill: parent
            visible: tabIndex === 0
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120 } }

            ListView {
            id: popularList
            anchors.fill: parent
            anchors.margins: 4
            model: controller && homePage.popularModelAttached ? controller.feed.popularModel() : null
            orientation: ListView.Horizontal
            spacing: 6
            clip: true

                // 性能优化
                cacheBuffer: 640
                displayMarginBeginning: 160
                displayMarginEnd: 160

                delegate: VideoCardCompact {
                    height: popularList.height
                    videoTitle: model.title || ""
                    coverUrl: model.pic || ""
                    imageActive: homePage.popularImagesActive
                    preferOffscreenPlaceholder: controller && controller.videoCardOffscreenPlaceholderEnabled
                    upName: model.ownerName || ""
                    viewCount: model.views || ""
                    durationText: model.durationText || ""
                    bvid: model.bvid || ""
                    partCount: model.partCount || 1
                    onClicked: homePage.videoSelected(bvid)
                }

                onAtXEndChanged: {
                    if (!atXEnd || !controller) return
                    if (popularList.contentWidth <= popularList.width + 2) return
                    if (isLoading || homePage.popularLoadingMore || popularList.count <= 0) return
                    homePage.popularLoadingMore = true
                    controller.feed.fetchMorePopular()
                }

                Row {
                    visible: initialPopularRequested && popularList.count === 0 && isLoading
                    anchors.left: parent.left
                    anchors.leftMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Repeater {
                        model: 3
                        VideoCardCompact {
                            height: popularList.height
                            placeholder: true
                                }
                    }
                }

                // 空状态
                Text {
                    visible: initialPopularRequested && popularList.count === 0 && !isLoading
                    text: "暂无推荐视频"
                    color: Theme.textTertiary
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    anchors.centerIn: parent
                }
            }
        }

        // ──── Tab 1: 排行 ────
        Item {
            anchors.fill: parent
            visible: tabIndex === 1
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120 } }

            ListView {
                id: rankingList
                anchors.fill: parent
                anchors.margins: 4
                model: controller ? controller.feed.rankingModel() : null
                orientation: ListView.Horizontal
                spacing: 6
                clip: true

                cacheBuffer: 640
                displayMarginBeginning: 160
                displayMarginEnd: 160

                delegate: VideoCardCompact {
                    height: rankingList.height
                    videoTitle: model.title || ""
                    coverUrl: model.pic || ""
                    imageActive: homePage.rankingImagesActive
                    preferOffscreenPlaceholder: controller && controller.videoCardOffscreenPlaceholderEnabled
                    upName: model.ownerName || ""
                    viewCount: model.views || ""
                    durationText: model.durationText || ""
                    bvid: model.bvid || ""
                    partCount: model.partCount || 1
                    rankIndex: index + 1
                    showRank: true
                    onClicked: homePage.videoSelected(bvid)
                }

                Row {
                    visible: rankingList.count === 0 && isLoading
                    anchors.left: parent.left
                    anchors.leftMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Repeater {
                        model: 3
                        VideoCardCompact {
                            height: rankingList.height
                            placeholder: true
                                }
                    }
                }

                Text {
                    visible: rankingList.count === 0 && !isLoading
                    text: "排行榜加载中..."
                    color: Theme.textTertiary
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    anchors.centerIn: parent
                }
            }
        }

        // ──── Tab 3: 我的 ────
        Item {
            anchors.fill: parent
            visible: tabIndex === 3
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120 } }

            Row {
                anchors.centerIn: parent
                spacing: 20

                // 头像区
                Column {
                    spacing: 6
                    anchors.verticalCenter: parent.verticalCenter

                    Rectangle {
                        width: 56
                        height: 56
                        radius: 28
                        color: Theme.bgTertiary
                        anchors.horizontalCenter: parent.horizontalCenter
                        border.color: controller && controller.loggedIn
                        ? Theme.primary : Theme.borderLight
                        border.width: 2

                        Image {
                            id: avatarImg
                            anchors.fill: parent
                            anchors.margins: 2
                            visible: controller && controller.loggedIn && source != ""
                            source: controller && controller.userFace && homePage.profileImagesActive
                            ? "image://bili/" + encodeURIComponent(controller.userFace) : ""
                            sourceSize: Qt.size(112, 112)
                            cache: true
                            asynchronous: true
                            fillMode: Image.PreserveAspectCrop

                            layer.enabled: true
                            layer.smooth: true
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: !avatarImg.visible
                            text: controller && controller.loggedIn ? "👤" : "🔐"
                            font.pixelSize: 24
                        }

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -8
                            onClicked: {
                                if (controller && controller.loggedIn)
                                    homePage.loginRequested()
                            }
                        }
                    }

                    Text {
                        text: controller && controller.loggedIn
                        ? controller.userName : "点击登录"
                        color: controller && controller.loggedIn
                        ? Theme.textPrimary : Theme.primary
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                        font.bold: true
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }

                // 信息区（登录后显示）
                Column {
                    visible: controller && controller.loggedIn
                    spacing: 8
                    anchors.verticalCenter: parent.verticalCenter

                    Row {
                        spacing: 6
                        Rectangle {
                            width: 8; height: 8; radius: 4
                            color: Theme.success
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "已登录"
                            color: Theme.success
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                        }
                    }

                    Text {
                        text: "Lv" + (controller ? controller.userLevel : 0)
                        color: Theme.primary
                        font.family: Theme.fontFamily
                        font.pixelSize: 14
                        font.bold: true
                    }

                    Text {
                        text: "硬币: " + (controller ? controller.userCoins : 0)
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: 10
                    }
                }
            }
        }
    }

    // ── 更多菜单：从底部“更多”按钮淡入，后续功能继续纵向追加 ──
    Rectangle {
        id: moreMenu
        width: 68
        height: moreMenuColumn.implicitHeight + 8
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.bottom: tabBar.top
        anchors.bottomMargin: 4
        radius: 10
        z: 30
        opacity: moreMenuVisible ? 1 : 0
        visible: moreMenuVisible || opacity > 0.01
        scale: moreMenuVisible ? 1.0 : 0.96
        transformOrigin: Item.BottomRight
        color: Theme.withAlpha(Theme.bgSecondary, 0.96)
        border.color: Theme.withAlpha(Theme.primary, 0.22)
        border.width: 1

        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        Column {
            id: moreMenuColumn
            anchors.fill: parent
            anchors.margins: 4
            spacing: 4

            Rectangle {
                width: parent.width
                height: 20
                radius: 8
                color: dynamicMoreArea.pressed ? Theme.withAlpha(Theme.primary, 0.22) : "transparent"

                Text {
                    anchors.centerIn: parent
                    text: "动态"
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    font.bold: true
                }

                MouseArea {
                    id: dynamicMoreArea
                    anchors.fill: parent
                    anchors.margins: -3
                    onClicked: {
                        moreMenuVisible = false
                        dynamicRequested()
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 20
                radius: 8
                color: rankingMoreArea.pressed ? Theme.withAlpha(Theme.primary, 0.22) : "transparent"

                Text {
                    anchors.centerIn: parent
                    text: "排行"
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    font.bold: true
                }

                MouseArea {
                    id: rankingMoreArea
                    anchors.fill: parent
                    anchors.margins: -3
                    onClicked: {
                        moreMenuVisible = false
                        rankingRequested()
                    }
                }
            }
        }
    }

    // ── 底部标签栏 (含搜索) ──
    Rectangle {
        id: tabBar
        width: parent.width
        height: 26
        color: Theme.bgSecondary
        anchors.bottom: parent.bottom
        z: 10

        // 顶部边线
        Rectangle {
            width: parent.width
            height: 1
            anchors.top: parent.top
            color: Theme.borderLight
        }

        Row {
            width: parent.width - 16
            anchors.centerIn: parent
            spacing: 4

            readonly property real exitButtonWidth: 24
            readonly property real tabButtonWidth: (width - exitButtonWidth - spacing * 4) / 4

            Rectangle {
                width: parent.exitButtonWidth
                height: 20
                radius: 10
                color: exitMouseArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : "transparent"
                border.color: Theme.withAlpha(Theme.primary, 0.25)
                border.width: 1

                scale: exitMouseArea.pressed ? 0.92 : 1.0
                Behavior on scale { NumberAnimation { duration: 80 } }
                Behavior on color { ColorAnimation { duration: 100 } }

                Canvas {
                    anchors.centerIn: parent
                    width: 12
                    height: 12
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        ctx.strokeStyle = Theme.textSecondary
                        ctx.lineWidth = 1.4
                        ctx.lineCap = "round"
                        ctx.lineJoin = "round"

                        ctx.beginPath()
                        ctx.moveTo(7.5, 2)
                        ctx.lineTo(10, 2)
                        ctx.lineTo(10, 10)
                        ctx.lineTo(7.5, 10)
                        ctx.stroke()

                        ctx.beginPath()
                        ctx.moveTo(7, 6)
                        ctx.lineTo(2.5, 6)
                        ctx.moveTo(4.5, 4)
                        ctx.lineTo(2.5, 6)
                        ctx.lineTo(4.5, 8)
                        ctx.stroke()
                    }
                }

                MouseArea {
                    id: exitMouseArea
                    anchors.fill: parent
                    anchors.margins: -4
                    onClicked: homePage.backButtonClicked()
                }
            }

            Repeater {
                model: [
                    { label: "推荐", idx: 0 },
                    { label: "搜索", idx: 2 },
                    { label: "我的", idx: 3 },
                    { label: "更多", idx: 4 }
                ]

                Rectangle {
                    width: parent.tabButtonWidth
                    height: 20
                    radius: 10
                    color: {
                        if (tabMouseArea.pressed) return Theme.withAlpha(Theme.primary, 0.2)
                        if (modelData.idx === 2) return Theme.bgTertiary
                        if (modelData.idx === 4 && moreMenuVisible) return Theme.withAlpha(Theme.primary, 0.15)
                        return tabIndex === modelData.idx
                        ? Theme.withAlpha(Theme.primary, 0.15)
                        : "transparent"
                    }

                    scale: tabMouseArea.pressed ? 0.92 : 1.0
                    Behavior on scale { NumberAnimation { duration: 80 } }
                    Behavior on color { ColorAnimation { duration: 100 } }

                    Text {
                        text: modelData.label
                        color: {
                            if (modelData.idx === 2) return Theme.textSecondary
                            return (tabIndex === modelData.idx || (modelData.idx === 4 && moreMenuVisible))
                                ? Theme.primary
                                : Theme.textSecondary
                        }
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                        font.bold: (tabIndex === modelData.idx || (modelData.idx === 4 && moreMenuVisible)) && modelData.idx !== 2
                        anchors.centerIn: parent

                        Behavior on color { ColorAnimation { duration: 100 } }
                    }

                    MouseArea {
                        id: tabMouseArea
                        anchors.fill: parent
                        anchors.margins: -4
                        onClicked: switchTab(modelData.idx)
                    }
                }
            }
        }
    }

    // ── 加载指示器 ──
    Rectangle {
        visible: isLoading
        anchors.centerIn: contentArea
        width: loadingRow.width + 16
        height: 22
        radius: 11
        color: Theme.withAlpha(Theme.bgSecondary, 0.95)
        border.color: Theme.borderLight
        border.width: 1

        Row {
            id: loadingRow
            anchors.centerIn: parent
            spacing: 3

            Repeater {
                model: 3
                Item {
                    width: 6
                    height: 12

                    Rectangle {
                        width: 5
                        height: 5
                        radius: 2.5
                        color: Theme.primary
                        anchors.centerIn: parent

                        SequentialAnimation on opacity {
                            running: isLoading
                            loops: Animation.Infinite
                            PauseAnimation { duration: index * 120 }
                            NumberAnimation { to: 0.3; duration: 250 }
                            NumberAnimation { to: 1.0; duration: 250 }
                        }
                    }
                }
            }

            Item {
                width: childrenRect.width
                height: 12

                Text {
                    text: "加载中"
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: 9
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Rectangle {
                height: 16
                width: cancelTextItem.implicitWidth + 10
                radius: 8
                color: cancelArea.pressed
                       ? Theme.withAlpha(Theme.primary, 0.18)
                       : Theme.withAlpha(Theme.primary, 0.08)
                border.color: Theme.withAlpha(Theme.primary, 0.25)
                border.width: 1
                anchors.verticalCenter: parent.verticalCenter

                Text {
                    id: cancelTextItem
                    anchors.centerIn: parent
                    text: "取消"
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: 8
                }

                MouseArea {
                    id: cancelArea
                    anchors.fill: parent
                    onClicked: {
                        if (controller) controller.cancelAll();
                    }
                }
            }
        }
    }

    Connections {
        target: controller
        ignoreUnknownSignals: true
        function onIsLoadingChanged() {
            if (!controller || !controller.isLoading) homePage.popularLoadingMore = false
        }
    }

    // 首页首次加载由 main.qml 统一触发，避免返回时重复刷新
    function popularContentX() {
        return popularList ? popularList.contentX : 0
    }

    function rankingContentX() {
        return rankingList ? rankingList.contentX : 0
    }

    function restorePopularContentX(x) {
        if (popularList) {
            popularList.positionViewAtIndex(0, ListView.Beginning)
            popularList.contentX = x
        }
    }

    function restoreRankingContentX(x) {
        if (rankingList) {
            rankingList.positionViewAtIndex(0, ListView.Beginning)
            rankingList.contentX = x
        }
    }

    function tryRestoreHomePosition() {
        if (!rootRef) return
        if (rootRef.restoreHomePopularOnShow && tabIndex === 0) {
            Qt.callLater(function() {
                restorePopularContentX(rootRef.homePopularX)
                Qt.callLater(function() {
                    restorePopularContentX(rootRef.homePopularX)
                    rootRef.restoreHomePopularOnShow = false
                })
            })
        }
        if (rootRef.restoreHomeRankingOnShow && tabIndex === 1) {
            Qt.callLater(function() {
                restoreRankingContentX(rootRef.homeRankingX)
                Qt.callLater(function() {
                    restoreRankingContentX(rootRef.homeRankingX)
                    rootRef.restoreHomeRankingOnShow = false
                })
            })
        }
    }

    Component.onCompleted: {
        if (initialTabIndex >= 0) {
            tabIndex = initialTabIndex
        }
        if (rootRef) rootRef.homeTabIndex = tabIndex
        tryRestoreHomePosition()
        initialPopularTimer.restart()
    }

    onVisibleChanged: {
        if (visible) {
            tryRestoreHomePosition()
            if (!initialPopularRequested) initialPopularTimer.restart()
        }
    }
}
