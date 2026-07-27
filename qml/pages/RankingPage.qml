// reuseItems 需要 QtQuick 2.15（Qt 5.15）
import QtQuick 2.15
import BiliPlugin 1.0
import "../components" as Components
import ".."

Rectangle {
    id: rankingPage
    width: 320
    height: 170
    color: Theme.bgPrimary

    property var controller: null
    property var rootRef: null
    property bool initialRankingRequested: false
    property bool rankingModelAttached: false

    signal backClicked()
    signal videoSelected(string bvid)

    function contentXValue() {
        return rankList ? rankList.contentX : 0
    }

    function restoreContentX(x) {
        if (rankList) {
            Qt.callLater(function() { rankList.contentX = x; })
        }
    }

    function requestInitialRanking() {
        if (!controller || initialRankingRequested) return
        initialRankingRequested = true
        controller.feed.fetchRanking(categoryBar.selectedRid)
        rankingModelAttached = true
    }

    Timer {
        id: initialRankingTimer
        interval: 50
        repeat: false
        onTriggered: rankingPage.requestInitialRanking()
    }

    Components.TitleBar {
        id: titleBar
        title: "排行榜"
        showBack: true
        anchors.top: parent.top
        onBackClicked: rankingPage.backClicked()
    }

    // ── 分区标签 ──
    Rectangle {
        id: categoryBar
        width: parent.width
        height: 24
        anchors.top: titleBar.bottom
        color: Theme.bgSecondary

        property int selectedRid: 0

        ListView {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingSmall
            anchors.rightMargin: Theme.spacingSmall
            orientation: ListView.Horizontal
            spacing: Theme.spacingSmall
            clip: true

            model: ListModel {
                ListElement { name: "全站"; rid: 0 }
                ListElement { name: "动画"; rid: 1 }
                ListElement { name: "音乐"; rid: 3 }
                ListElement { name: "游戏"; rid: 4 }
                ListElement { name: "娱乐"; rid: 5 }
                ListElement { name: "鬼畜"; rid: 119 }
                ListElement { name: "国创"; rid: 168 }
                ListElement { name: "科技"; rid: 188 }
                ListElement { name: "知识"; rid: 36 }
                ListElement { name: "生活"; rid: 160 }
                ListElement { name: "美食"; rid: 211 }
                ListElement { name: "运动"; rid: 234 }
                ListElement { name: "影视"; rid: 181 }
            }

            delegate: Rectangle {
                width: 42; height: 18
                radius: Theme.radiusRound
                anchors.verticalCenter: parent.verticalCenter
                color: categoryBar.selectedRid === rid
                ? Theme.primary
                : (catArea.pressed ? Theme.withAlpha(Theme.primary, 0.1) : "transparent")

                Behavior on color { ColorAnimation { duration: Theme.animNormal } }

                Text {
                    anchors.centerIn: parent
                    text: name
                    color: categoryBar.selectedRid === rid
                    ? Theme.textOnPrimary : Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                    font.bold: categoryBar.selectedRid === rid
                }

                MouseArea {
                    id: catArea
                    anchors.fill: parent
                    anchors.margins: -2
                    onClicked: {
                        categoryBar.selectedRid = rid;
                        initialRankingTimer.stop();
                        initialRankingRequested = true;
                        if (controller) {
                            controller.feed.fetchRanking(rid);
                            rankingModelAttached = true;
                        }
                    }
                }
            }
        }

        Rectangle {
            width: parent.width; height: 1
            anchors.bottom: parent.bottom
            color: Theme.divider
        }
    }

    ListView {
        id: rankList
        anchors.top: categoryBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.spacingSmall
        anchors.rightMargin: Theme.spacingSmall
        anchors.topMargin: Theme.spacingSmall
        anchors.bottomMargin: Math.max(0, Theme.spacingSmall - 3)
        model: controller && rankingPage.rankingModelAttached ? controller.feed.rankingModel() : null
        orientation: ListView.Horizontal
        spacing: Theme.spacingMedium
        clip: true
        reuseItems: true
        cacheBuffer: Theme.listCacheBuffer
        displayMarginBeginning: Theme.listDisplayMargin
        displayMarginEnd: Theme.listDisplayMargin

        delegate: Components.VideoCardCompact {
            height: rankList.height
            titleScale: 0.9
            titleBold: true
            subScale: 0.86
            // 减少标题与UP信息的空隙 3px（默认 infoSpacing=2）
            infoSpacing: -1
            subYOffset: -10
            videoTitle: model.title || ""
            coverUrl: model.pic || ""
            imageActive: rankingPage.visible
            preferOffscreenPlaceholder: controller && controller.videoCardOffscreenPlaceholderEnabled
            upName: model.ownerName || ""
            viewCount: model.views || ""
            durationText: model.durationText || ""
            bvid: model.bvid || ""
            partCount: model.partCount || 1
            onClicked: rankingPage.videoSelected(bvid)
        }

        Row {
            visible: initialRankingRequested && rankList.count === 0 && controller && controller.isLoading
            anchors.left: parent.left
            anchors.leftMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingMedium
            Repeater {
                model: 3
                Components.VideoCardCompact {
                    height: rankList.height
                    placeholder: true
                    titleScale: 0.9
                    titleBold: true
                    subScale: 0.86
                    infoSpacing: -1
                    subYOffset: -10
                }
            }
        }

        Column {
            visible: initialRankingRequested && rankList.count === 0 && controller && !controller.isLoading
            anchors.centerIn: parent
            spacing: Theme.spacingSmall

            Text {
                text: "🏆"
                font.pixelSize: 18
                anchors.horizontalCenter: parent.horizontalCenter
                opacity: 0.4
            }
            Text {
                text: "暂无数据"
                color: Theme.textTertiary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontBody
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    Components.LoadingIndicator {
        anchors.centerIn: parent
        running: controller ? controller.isLoading : false
        onCancelRequested: {
            if (controller) controller.cancelAll();
        }
    }

    Component.onCompleted: {
        initialRankingTimer.restart()
        if (rootRef && rootRef.restoreRankingPageOnShow) {
            restoreContentX(rootRef.rankingPageX)
            rootRef.restoreRankingPageOnShow = false
        }
    }

    onVisibleChanged: {
        if (visible) {
            if (!initialRankingRequested) initialRankingTimer.restart()
            if (rootRef && rootRef.restoreRankingPageOnShow) {
                restoreContentX(rootRef.rankingPageX)
                rootRef.restoreRankingPageOnShow = false
            }
        }
    }
}
