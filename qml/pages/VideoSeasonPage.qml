import QtQuick 2.12
import BiliPlugin 1.0
import "../components" as Components
import ".."

Rectangle {
    id: seasonPage
    width: 320
    height: 170
    color: Theme.bgPrimary

    property var controller: null
    property var seasonMid: 0
    property var seasonId: 0
    property string seasonTitle: ""
    property string seasonCover: ""
    property int seasonTotal: 0
    property string currentBvid: ""
    property string loadedKey: ""
    property bool seasonLoadingMore: false
    property bool seasonSortOldestFirst: false
    property bool locatingLastWatched: false
    property int locatingLastWatchedFetches: 0
    property int locatedLastWatchedIndex: -1
    readonly property bool locateAvailable: currentBvid.length > 0
    property var seasonModel: controller ? controller.season.seasonVideoModel() : null
    readonly property bool sortBusy: seasonModel ? seasonModel.loading : false

    signal backClicked()
    signal videoSelected(string bvid)

    function totalText() {
        var total = controller && controller.seasonVideoTotal > 0
            ? controller.seasonVideoTotal
            : seasonTotal
        return total > 0 ? "共 " + total + " 个视频" : ""
    }

    function refresh() {
        var midVal = Number(seasonMid)
        var sidVal = Number(seasonId)
        if (!controller || !midVal || !sidVal || midVal <= 0 || sidVal <= 0) return
        if (seasonModel && seasonModel.loading) return
        var key = midVal + "#" + sidVal + "#" + (seasonSortOldestFirst ? "old" : "new")
        if (loadedKey === key) return
        loadedKey = key
        controller.season.fetchSeasonVideos(midVal, sidVal, 1, 30, seasonSortOldestFirst)
    }

    function selectSort(oldestFirst) {
        if (sortBusy || seasonSortOldestFirst === oldestFirst) return
        seasonSortOldestFirst = oldestFirst
        loadedKey = ""
        seasonLoadingMore = false
        seasonVideoList.contentX = 0
    }

    function toggleSort() {
        selectSort(!seasonSortOldestFirst)
    }

    function resetLocateState() {
        locatingLastWatched = false
        locatingLastWatchedFetches = 0
        locatedLastWatchedIndex = -1
    }

    function positionLastWatchedIndex(idx) {
        if (idx < 0 || idx >= seasonVideoList.count) return
        seasonVideoList.forceLayout()
        seasonVideoList.positionViewAtIndex(idx, ListView.Center)
        locatedLastWatchedIndex = idx
    }

    function tryScrollToLastWatched() {
        if (!locatingLastWatched || !controller || !controller.season) return
        if (!currentBvid || currentBvid.length === 0) {
            locatingLastWatched = false
            return
        }
        var modelObj = seasonPage.seasonModel
        if (!modelObj) return

        var idx = modelObj.indexOfBvid ? modelObj.indexOfBvid(currentBvid) : -1
        if (idx >= 0) {
            Qt.callLater(function() {
                seasonPage.positionLastWatchedIndex(idx)
            })
            locatingLastWatched = false
            return
        }

        if (modelObj.loading) return
        if (modelObj.hasMore && locatingLastWatchedFetches < 20) {
            locatingLastWatchedFetches += 1
            seasonLoadingMore = true
            controller.season.fetchMoreSeasonVideos()
        } else {
            locatingLastWatched = false
            if (controller) controller.toastMessage("未找到上次观看")
        }
    }

    function locateLastWatched() {
        if (!currentBvid || currentBvid.length === 0) {
            if (controller) controller.toastMessage("暂无上次观看记录")
            return
        }
        locatingLastWatched = true
        locatingLastWatchedFetches = 0
        Qt.callLater(tryScrollToLastWatched)
    }

    onSeasonMidChanged: {
        loadedKey = ""
        resetLocateState()
        Qt.callLater(refresh)
    }

    onSeasonIdChanged: {
        loadedKey = ""
        resetLocateState()
        Qt.callLater(refresh)
    }

    onCurrentBvidChanged: resetLocateState()

    onSeasonSortOldestFirstChanged: {
        loadedKey = ""
        resetLocateState()
        Qt.callLater(refresh)
    }

    onVisibleChanged: {
        if (visible) Qt.callLater(refresh)
    }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.bgPrimary }
            GradientStop { position: 1.0; color: "#0f172a" }
        }
    }

    Components.TitleBar {
        id: titleBar
        title: seasonTitle.length > 0 ? seasonTitle : "合集"
        titleSuffix: seasonPage.totalText()
        showBack: true
        titleSideReserve: 90
        anchors.top: parent.top
        onBackClicked: seasonPage.backClicked()
    }

    Rectangle {
        id: sortTitleButton
        width: 42
        height: titleBar.height
        anchors.top: titleBar.top
        anchors.right: titleBar.right
        anchors.rightMargin: 6
        color: "transparent"
        z: titleBar.z + 1
        opacity: seasonPage.sortBusy ? 0.55 : 1.0

        Rectangle {
            id: sortTitleButtonCore
            anchors.centerIn: parent
            width: 30
            height: 24
            radius: Theme.radiusMedium
            color: sortTitleButtonArea.pressed && !seasonPage.sortBusy
                   ? Theme.withAlpha(Theme.primary, 0.22) : "transparent"

            Behavior on color { ColorAnimation { duration: Theme.animFast } }

            Canvas {
                id: sortTitleIcon
                anchors.centerIn: parent
                width: 18
                height: 18
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.lineWidth = 1.7
                    ctx.lineCap = "round"
                    ctx.lineJoin = "round"
                    ctx.strokeStyle = Theme.primary
                    ctx.fillStyle = Theme.primary

                    ctx.beginPath()
                    ctx.moveTo(2.5, 4.5)
                    ctx.lineTo(10.5, 4.5)
                    ctx.moveTo(2.5, 9)
                    ctx.lineTo(8.5, 9)
                    ctx.moveTo(2.5, 13.5)
                    ctx.lineTo(6.5, 13.5)
                    ctx.stroke()

                    ctx.beginPath()
                    if (seasonPage.seasonSortOldestFirst) {
                        ctx.moveTo(14, 4)
                        ctx.lineTo(14, 14)
                        ctx.moveTo(10.5, 10.5)
                        ctx.lineTo(14, 14)
                        ctx.lineTo(17.5, 10.5)
                    } else {
                        ctx.moveTo(14, 14)
                        ctx.lineTo(14, 4)
                        ctx.moveTo(10.5, 7.5)
                        ctx.lineTo(14, 4)
                        ctx.lineTo(17.5, 7.5)
                    }
                    ctx.stroke()
                }

                Component.onCompleted: requestPaint()
            }
        }

        MouseArea {
            id: sortTitleButtonArea
            anchors.fill: parent
            enabled: !seasonPage.sortBusy
            onClicked: seasonPage.toggleSort()
        }
    }

    Rectangle {
        id: locateTitleButton
        width: 42
        height: titleBar.height
        anchors.top: titleBar.top
        anchors.right: sortTitleButton.left
        anchors.rightMargin: 0
        color: "transparent"
        z: titleBar.z + 1
        opacity: seasonPage.locateAvailable ? (seasonPage.locatingLastWatched ? 0.65 : 1.0) : 0.45

        Canvas {
            id: locateTitleCanvas
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: 5
            width: 30
            height: 24

            function roundedRect(ctx, x, y, w, h, r) {
                ctx.beginPath()
                ctx.moveTo(x + r, y)
                ctx.lineTo(x + w - r, y)
                ctx.quadraticCurveTo(x + w, y, x + w, y + r)
                ctx.lineTo(x + w, y + h - r)
                ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h)
                ctx.lineTo(x + r, y + h)
                ctx.quadraticCurveTo(x, y + h, x, y + h - r)
                ctx.lineTo(x, y + r)
                ctx.quadraticCurveTo(x, y, x + r, y)
                ctx.closePath()
            }

            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)

                var active = seasonPage.locateAvailable
                var pressed = locateTitleButtonArea.pressed && active
                var bg = pressed
                    ? Theme.withAlpha(Theme.accent, 0.22)
                    : (seasonPage.locatingLastWatched && active
                       ? Theme.withAlpha(Theme.accent, 0.12)
                       : "transparent")
                var stroke = active
                    ? Theme.withAlpha(Theme.accent, seasonPage.locatingLastWatched ? 0.55 : 0.34)
                    : Theme.withAlpha(Theme.textTertiary, 0.28)
                var icon = active ? Theme.accent : Theme.textTertiary

                roundedRect(ctx, 0.75, 0.75, width - 1.5, height - 1.5, Theme.radiusMedium)
                ctx.fillStyle = bg
                ctx.fill()
                ctx.lineWidth = 1
                ctx.strokeStyle = stroke
                ctx.stroke()

                ctx.save()
                ctx.translate(6, 3)
                ctx.lineWidth = 1.7
                ctx.lineCap = "round"
                ctx.lineJoin = "round"
                ctx.strokeStyle = icon
                ctx.fillStyle = icon

                ctx.beginPath()
                ctx.arc(9, 9, 5.4, 0, Math.PI * 2, false)
                ctx.stroke()

                ctx.beginPath()
                ctx.moveTo(9, 1.8)
                ctx.lineTo(9, 4.2)
                ctx.moveTo(9, 13.8)
                ctx.lineTo(9, 16.2)
                ctx.moveTo(1.8, 9)
                ctx.lineTo(4.2, 9)
                ctx.moveTo(13.8, 9)
                ctx.lineTo(16.2, 9)
                ctx.stroke()

                ctx.beginPath()
                ctx.arc(9, 9, 2.1, 0, Math.PI * 2, false)
                ctx.fill()
                ctx.restore()
            }

            Component.onCompleted: requestPaint()
        }

        MouseArea {
            id: locateTitleButtonArea
            anchors.fill: parent
            enabled: seasonPage.locateAvailable
            onPressedChanged: locateTitleCanvas.requestPaint()
            onClicked: seasonPage.locateLastWatched()
        }
    }

    Connections {
        target: seasonPage
        function onSeasonSortOldestFirstChanged() {
            sortTitleIcon.requestPaint()
        }
        function onCurrentBvidChanged() {
            locateTitleCanvas.requestPaint()
        }
        function onLocatingLastWatchedChanged() {
            locateTitleCanvas.requestPaint()
        }
    }

    Components.LoadMoreListView {
        id: seasonVideoList
        anchors.top: titleBar.bottom
        anchors.topMargin: 4
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        spacing: 6
        leftMargin: 8
        rightMargin: 8
        model: seasonPage.seasonModel
        // 页面级 seasonLoadingMore 兼作"定位上次观看"连拉链路的守卫，需并入 loading
        loading: !!(seasonPage.seasonModel && seasonPage.seasonModel.loading === true)
                 || seasonPage.seasonLoadingMore

        onLoadMoreRequested: {
            if (!controller) return
            seasonPage.seasonLoadingMore = true
            controller.season.fetchMoreSeasonVideos()
        }

        delegate: Item {
            width: Theme.cardWidth
            height: seasonVideoList.height
            property bool current: (model.bvid || "") === seasonPage.currentBvid
            property bool located: index === seasonPage.locatedLastWatchedIndex

            Components.VideoCardCompact {
                anchors.fill: parent
                videoTitle: model.title || ""
                coverUrl: model.pic || ""
                imageActive: seasonPage.visible
                preferOffscreenPlaceholder: controller && controller.videoCardOffscreenPlaceholderEnabled
                upName: model.ownerName || ""
                viewCount: model.views || ""
                durationText: model.durationText || ""
                bvid: model.bvid || ""
                isLastWatched: parent.located
                partCount: model.partCount || 1
                titleScale: 0.9
                subScale: 0.85
                onClicked: {
                    if (!bvid || bvid === seasonPage.currentBvid) return
                    seasonPage.videoSelected(bvid)
                }
            }

            Rectangle {
                anchors.fill: parent
                visible: parent.current
                radius: Theme.radiusMedium
                color: "transparent"
                border.color: Theme.primary
                border.width: 2
                z: 2
            }

            Rectangle {
                visible: parent.current
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 4
                anchors.rightMargin: 4
                width: currentText.implicitWidth + 10
                height: 16
                radius: 8
                color: Theme.primary
                z: 3

                Text {
                    id: currentText
                    anchors.centerIn: parent
                    text: "当前"
                    color: Theme.textOnPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                    font.bold: true
                }
            }
        }

        Row {
            visible: seasonVideoList.count === 0 && controller && controller.isLoading
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Repeater {
                model: 3
                Components.VideoCardCompact {
                    height: seasonVideoList.height
                    placeholder: true
                    titleScale: 0.9
                    subScale: 0.85
                }
            }
        }
    }

    Connections {
        target: seasonPage.seasonModel
        function onLoadingChanged() {
            if (!target || !target.loading) seasonPage.seasonLoadingMore = false
            if (target && !target.loading) {
                Qt.callLater(seasonPage.refresh)
                Qt.callLater(seasonPage.tryScrollToLastWatched)
            }
        }
        function onCountChanged() {
            seasonPage.seasonLoadingMore = false
            seasonPage.tryScrollToLastWatched()
        }
    }

    Text {
        anchors.centerIn: seasonVideoList
        visible: seasonVideoList.count === 0 && controller && !controller.isLoading
        text: "该合集暂无视频"
        color: Theme.textTertiary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontBody
    }

    Rectangle {
        visible: controller && controller.isLoading && seasonVideoList.count === 0
        anchors.centerIn: seasonVideoList
        width: loadingText.implicitWidth + 18
        height: 22
        radius: 11
        color: Theme.withAlpha(Theme.bgSecondary, 0.95)
        border.color: Theme.borderLight
        border.width: 1

        Text {
            id: loadingText
            anchors.centerIn: parent
            text: "加载中"
            color: Theme.textSecondary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSmall
        }
    }
}
