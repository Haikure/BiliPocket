import QtQuick 2.12
import BiliPlugin 1.0
import "../components" as Components
import ".."

Rectangle {
    id: dynamicPage
    width: 320
    height: 170
    color: Theme.bgPrimary
    clip: true

    property var controller: null
    property var rootRef: null
    property var dynamicModel: controller ? controller.feed.dynamicModel() : null
    property bool initialRequested: false
    property bool revealReady: false
    readonly property bool imagesActive: visible

    signal backClicked()
    signal videoSelected(string bvid)
    signal dynamicSelected(var dynamicData)

    function contentYValue() {
        return dynamicList ? dynamicList.contentY : 0
    }

    function restoreContentY(y) {
        if (!dynamicList) return
        Qt.callLater(function() {
            dynamicList.contentY = Math.max(0, y)
            Qt.callLater(function() { dynamicList.contentY = Math.max(0, y) })
        })
    }

    function requestInitial(force) {
        if (!controller || (!force && initialRequested)) return
        initialRequested = true
        revealReady = true
        controller.feed.fetchDynamic("all")
    }

    function dynamicDataFromModel(m) {
        return {
            idStr: m.idStr || "",
            type: m.type || "",
            authorName: m.authorName || "",
            authorFace: m.authorFace || "",
            authorMid: m.authorMid || 0,
            pubAction: m.pubAction || "",
            pubTime: m.pubTime || "",
            pubTs: m.pubTs || 0,
            text: m.text || "",
            majorTitle: m.majorTitle || "",
            majorCover: m.majorCover || "",
            majorBvid: m.majorBvid || "",
            majorAid: m.majorAid || 0,
            majorDurationText: m.majorDurationText || "",
            pictures: m.pictures || [],
            origSummary: m.origSummary || "",
            origTitle: m.origTitle || "",
            origCover: m.origCover || "",
            origBvid: m.origBvid || "",
            origAid: m.origAid || 0,
            repostCountText: m.repostCountText || "0",
            commentCountText: m.commentCountText || "0",
            likeCountText: m.likeCountText || "0",
            commentOid: m.commentOid || "",
            commentType: m.commentType || 0,
            isVideo: m.isVideo || false,
            isImage: m.isImage || false,
            isArticle: m.isArticle || false,
            isLive: m.isLive || false,
            isForward: m.isForward || false
        }
    }

    Components.LoadMoreListView {
        id: dynamicList
        anchors.fill: parent
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        anchors.topMargin: 4
        anchors.bottomMargin: 4
        model: dynamicModel
        orientation: ListView.Vertical
        spacing: 5
        // 纵向流：cacheBuffer/displayMargin 需覆盖横向默认值
        cacheBuffer: 360
        displayMarginBeginning: 120
        displayMarginEnd: Theme.listDisplayMargin

        header: Item {
            width: dynamicList.width
            height: 32

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 30
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                Text {
                    id: dynamicTitleText
                    text: "动态"
                    color: titleRefreshArea.pressed ? Theme.primary : Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontTitle
                    font.bold: true

                    // 点击标题强制刷新；加载中禁用防止重复触发
                    MouseArea {
                        id: titleRefreshArea
                        anchors.fill: parent
                        anchors.margins: -6
                        enabled: !(dynamicModel && dynamicModel.loading)
                        onClicked: dynamicPage.requestInitial(true)
                    }
                }

                Rectangle {
                    height: 15
                    width: statusText.implicitWidth + 10
                    radius: 8
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.withAlpha(Theme.primary, 0.12)
                    border.width: 1
                    border.color: Theme.withAlpha(Theme.primary, 0.2)
                    Text {
                        id: statusText
                        anchors.centerIn: parent
                        text: dynamicModel && dynamicModel.loading ? "加载中" : "关注更新"
                        color: Theme.primary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSmall
                        font.bold: true
                    }
                }
            }
        }

        delegate: Components.DynamicFeedCard {
            width: dynamicList.width
            authorName: model.authorName || ""
            authorFace: model.authorFace || ""
            pubAction: model.pubAction || ""
            pubTime: model.pubTime || ""
            text: model.text || ""
            majorTitle: model.majorTitle || ""
            majorCover: model.majorCover || ""
            majorBvid: model.majorBvid || ""
            majorDurationText: model.majorDurationText || ""
            pictures: model.pictures || []
            origSummary: model.origSummary || ""
            origTitle: model.origTitle || ""
            origCover: model.origCover || ""
            repostCountText: model.repostCountText || "0"
            commentCountText: model.commentCountText || "0"
            likeCountText: model.likeCountText || "0"
            isVideo: model.isVideo || false
            isImage: model.isImage || false
            isArticle: model.isArticle || false
            isLive: model.isLive || false
            isForward: model.isForward || false
            imageActive: dynamicPage.imagesActive
            onClicked: {
                if (bvid && bvid.length > 0) {
                    dynamicPage.videoSelected(bvid)
                } else {
                    dynamicPage.dynamicSelected(dynamicPage.dynamicDataFromModel(model))
                }
            }
        }

        footer: Item {
            width: dynamicList.width
            height: (dynamicModel && dynamicModel.count > 0) ? 22 : 2
            Text {
                anchors.centerIn: parent
                visible: dynamicModel && dynamicModel.count > 0
                text: dynamicModel && dynamicModel.loading ? "正在加载更多" : (dynamicModel && dynamicModel.hasMore ? "继续上滑加载" : "没有更多了")
                color: Theme.textTertiary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSmall
            }
        }

        onLoadMoreRequested: {
            if (controller && controller.feed) controller.feed.fetchMoreDynamic()
        }
    }

    Rectangle {
        id: backPill
        width: 24
        height: 18
        x: 5
        y: 5
        radius: 9
        z: 20
        color: backArea.pressed ? Theme.withAlpha(Theme.primary, 0.32) : Theme.withAlpha(Theme.bgSecondary, 0.88)
        border.width: 1
        border.color: Theme.withAlpha(Theme.primary, 0.28)

        Canvas {
            anchors.centerIn: parent
            width: 10
            height: 10
            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                ctx.strokeStyle = Theme.textPrimary
                ctx.lineWidth = 1.5
                ctx.lineCap = "round"
                ctx.lineJoin = "round"
                ctx.beginPath()
                ctx.moveTo(6.5, 2)
                ctx.lineTo(3, 5)
                ctx.lineTo(6.5, 8)
                ctx.stroke()
            }
        }

        MouseArea {
            id: backArea
            anchors.fill: parent
            anchors.margins: -5
            onClicked: dynamicPage.backClicked()
        }

        scale: backArea.pressed ? 0.92 : 1.0
        Behavior on scale { NumberAnimation { duration: 80 } }
        Behavior on color { ColorAnimation { duration: Theme.animFast } }
    }

    Column {
        visible: dynamicModel && dynamicModel.count === 0 && !dynamicModel.loading && initialRequested
        anchors.centerIn: parent
        spacing: 6
        z: 8

        Text {
            text: dynamicModel && dynamicModel.errorMessage.length > 0 ? dynamicModel.errorMessage : "暂无动态"
            color: Theme.textTertiary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontBody
            anchors.horizontalCenter: parent.horizontalCenter
            width: 230
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            maximumLineCount: 2
        }

        Rectangle {
            width: 48
            height: 18
            radius: 9
            color: retryArea.pressed ? Theme.withAlpha(Theme.primary, 0.28) : Theme.withAlpha(Theme.primary, 0.14)
            border.width: 1
            border.color: Theme.withAlpha(Theme.primary, 0.35)
            anchors.horizontalCenter: parent.horizontalCenter
            Text {
                anchors.centerIn: parent
                text: "重试"
                color: Theme.primary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSmall
                font.bold: true
            }
            MouseArea {
                id: retryArea
                anchors.fill: parent
                anchors.margins: -4
                onClicked: dynamicPage.requestInitial(true)
            }
        }
    }

    Components.LoadingIndicator {
        anchors.centerIn: parent
        running: dynamicModel && dynamicModel.loading && (!dynamicModel || dynamicModel.count === 0)
        onCancelRequested: {
            if (controller) controller.cancelAll()
        }
    }

    Component.onCompleted: {
        Qt.callLater(function() { dynamicPage.requestInitial(false) })
    }

    onVisibleChanged: {
        if (visible) {
            if (!initialRequested) Qt.callLater(function() { dynamicPage.requestInitial(false) })
            if (rootRef && rootRef.restoreDynamicPageOnShow) {
                restoreContentY(rootRef.dynamicPageY)
                rootRef.restoreDynamicPageOnShow = false
            }
        }
    }
}
