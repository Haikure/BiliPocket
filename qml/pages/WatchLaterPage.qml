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

    // 长按删除
    property int pendingDeleteIndex: -1
    property string pendingDeleteTitle: ""
    property var pendingDeleteAid: 0
    property bool deleteConfirmVisible: false

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

        Components.LoadMoreListView {
            id: watchLaterList
            anchors.fill: parent
            anchors.margins: Theme.spacingSmall
            model: watchLaterModel
            spacing: Theme.spacingMedium
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

            onLoadMoreRequested: if (controller) controller.history.fetchMoreWatchLater()

            // MouseArea 作为卡片子项覆盖在最上层，保持 VideoCardCompact 仍是 delegate 根
            // （reuseItems 的 ListView.onPooled/onReused 只在 delegate 根上生效）
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

                MouseArea {
                    anchors.fill: parent
                    pressAndHoldInterval: 550
                    onClicked: {
                        watchLaterPage.watchLaterContentX = watchLaterList.contentX
                        watchLaterPage.restoreWatchLaterOnShow = true
                        watchLaterPage.watchLaterForceStart = false
                        watchLaterPage.videoSelected(model.bvid || "")
                    }
                    onPressAndHold: {
                        watchLaterPage.pendingDeleteIndex = index
                        watchLaterPage.pendingDeleteTitle = model.title || ""
                        watchLaterPage.pendingDeleteAid = model.aid || 0
                        watchLaterPage.deleteConfirmVisible = true
                    }
                }
            }
        }

        Text {
            visible: watchLaterContentReady && watchLaterList.count === 0 && watchLaterModel && !watchLaterModel.loading
            text: "暂无稍后再看"
            color: Theme.textTertiary
            anchors.centerIn: parent
        }

        // 长按删除确认框
        Rectangle {
            visible: opacity > 0
            opacity: watchLaterPage.deleteConfirmVisible ? 1 : 0
            scale: watchLaterPage.deleteConfirmVisible ? 1 : 0.92
            anchors.centerIn: parent
            width: 210
            height: 96
            radius: Theme.radiusLarge
            color: Theme.bgSecondary
            border.color: Theme.withAlpha(Theme.error, 0.55)
            z: 40
            Behavior on opacity { NumberAnimation { duration: Theme.animFast; easing.type: Easing.OutQuad } }
            Behavior on scale { NumberAnimation { duration: Theme.animFast; easing.type: Easing.OutBack } }

            Column {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 7

                Text {
                    width: parent.width
                    text: "从稍后再看移除？"
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontMedium
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    width: parent.width
                    text: watchLaterPage.pendingDeleteTitle
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 10
                    Rectangle {
                        width: 70
                        height: 24
                        radius: 12
                        color: cancelDeleteArea.pressed ? Theme.bgTertiary : Theme.withAlpha(Theme.textSecondary, 0.12)
                        Text { anchors.centerIn: parent; text: "取消"; color: Theme.textSecondary; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall }
                        MouseArea { id: cancelDeleteArea; anchors.fill: parent; onClicked: watchLaterPage.deleteConfirmVisible = false }
                    }
                    Rectangle {
                        width: 70
                        height: 24
                        radius: 12
                        color: confirmDeleteArea.pressed ? Theme.withAlpha(Theme.error, 0.35) : Theme.withAlpha(Theme.error, 0.2)
                        Text { anchors.centerIn: parent; text: "删除"; color: Theme.error; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall; font.bold: true }
                        MouseArea {
                            id: confirmDeleteArea
                            anchors.fill: parent
                            onClicked: {
                                watchLaterPage.deleteConfirmVisible = false
                                if (controller && controller.history) {
                                    controller.history.deleteWatchLaterItem(watchLaterPage.pendingDeleteIndex, Number(watchLaterPage.pendingDeleteAid))
                                }
                            }
                        }
                    }
                }
            }
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
