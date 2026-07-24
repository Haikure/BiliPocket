import QtQuick 2.12
import BiliPlugin 1.0
import "../components" as Components
import ".."

Rectangle {
    id: watchLaterPage
    width: 320
    height: 170
    color: Theme.bgPrimary

    property var controller: null
    property var rootRef: null
    property var watchLaterModel: controller ? controller.history.watchLaterModel() : null
    property real watchLaterContentX: 0
    property bool restoreWatchLaterOnShow: false
    property bool watchLaterForceStart: false
    property bool watchLaterInitialLoadPending: true
    property bool watchLaterContentReady: false
    property bool watchLaterRevealPlayed: false
    readonly property bool watchLaterImagesActive: visible

    signal backClicked()
    signal videoSelected(string bvid)

    function resetPosition() {
        watchLaterList.contentX = 0
        Qt.callLater(function() {
            watchLaterList.contentX = 0
            Qt.callLater(function() { watchLaterList.contentX = 0 })
        })
    }

    function restorePosition() {
        if (watchLaterForceStart) {
            resetPosition()
            return
        }
        if (visible && restoreWatchLaterOnShow && watchLaterContentX > 0) {
            watchLaterList.contentX = watchLaterContentX
        } else {
            resetPosition()
        }
    }

    function finishInitialLoad() {
        if (!watchLaterInitialLoadPending) return
        watchLaterInitialLoadPending = false
        watchLaterContentReady = true
        if (!watchLaterRevealPlayed) watchLaterRevealPlayed = true
        Qt.callLater(function() { restorePosition() })
    }

    Components.TitleBar {
        id: titleBar
        title: "稍后再看"
        showBack: true
        anchors.top: parent.top
        onBackClicked: watchLaterPage.backClicked()
    }

    Connections {
        target: watchLaterModel
        function onLoadingChanged() {
            if (!target) return
            if (watchLaterPage.watchLaterInitialLoadPending) {
                if (target.loading) {
                    watchLaterPage.watchLaterForceStart = true
                    resetPosition()
                } else {
                    finishInitialLoad()
                }
            }
        }
        function onCountChanged() {
            if (watchLaterPage.watchLaterInitialLoadPending && watchLaterPage.watchLaterForceStart) {
                resetPosition()
            }
        }
    }

    Item {
        id: contentLayer
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        opacity: watchLaterContentReady ? 1 : 0
        x: watchLaterContentReady ? 0 : 12
        enabled: watchLaterContentReady

        Behavior on opacity { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutQuad } }
        Behavior on x { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutQuad } }

        ListView {
            id: watchLaterList
            anchors.fill: parent
            anchors.margins: Theme.spacingSmall
            model: watchLaterModel
            orientation: ListView.Horizontal
            spacing: Theme.spacingMedium
            clip: true
            interactive: watchLaterContentReady
            onContentWidthChanged: {
                if (watchLaterInitialLoadPending && !watchLaterPage.restoreWatchLaterOnShow && watchLaterPage.watchLaterForceStart) contentX = 0
            }
            onCountChanged: {
                if (watchLaterInitialLoadPending && !watchLaterPage.restoreWatchLaterOnShow && watchLaterPage.watchLaterForceStart) {
                    contentX = 0
                    if (count > 0) {
                        Qt.callLater(function() {
                            contentX = 0
                            watchLaterPage.watchLaterForceStart = false
                        })
                    }
                }
            }

            cacheBuffer: 640
            displayMarginBeginning: 160
            displayMarginEnd: 160

            property bool _loadingMore: false
            onAtXEndChanged: {
                if (!atXEnd || !controller || _loadingMore) return
                _loadingMore = true
                Qt.callLater(function() {
                    controller.history.fetchMoreWatchLater()
                    _loadingMore = false
                })
            }

            delegate: Components.VideoCardCompact {
                height: watchLaterList.height
                videoTitle: model.title || ""
                coverUrl: model.pic || ""
                imageActive: watchLaterPage.watchLaterImagesActive
                preferOffscreenPlaceholder: controller && controller.videoCardOffscreenPlaceholderEnabled
                upName: model.ownerName || ""
                viewCount: ""
                durationText: model.durationText || ""
                bvid: model.bvid || ""
                partCount: model.partCount || 1
                onClicked: {
                    watchLaterPage.watchLaterContentX = watchLaterList.contentX
                    watchLaterPage.restoreWatchLaterOnShow = true
                    watchLaterPage.watchLaterForceStart = false
                    watchLaterPage.videoSelected(bvid)
                }
            }
        }

        Text {
            visible: watchLaterContentReady && watchLaterList.count === 0 && watchLaterModel && !watchLaterModel.loading
            text: "暂无稍后再看"
            color: Theme.textTertiary
            anchors.centerIn: parent
        }
    }

    Components.LoadingIndicator {
        anchors.centerIn: parent
        running: watchLaterInitialLoadPending
        onCancelRequested: {
            if (controller) controller.cancelAll();
        }
    }

    Component.onCompleted: {
        watchLaterInitialLoadPending = true
        watchLaterContentReady = false
        watchLaterRevealPlayed = false
        watchLaterForceStart = true
        restoreWatchLaterOnShow = false
        if (controller) Qt.callLater(function() { controller.history.fetchWatchLater(1, 20) })
    }

    onVisibleChanged: {
        if (visible && watchLaterContentReady) {
            Qt.callLater(function() { restorePosition() })
        }
    }
}
