import QtQuick 2.12
import QtGraphicalEffects 1.12
import BiliPlugin 1.0
import "qrc:/qml/commons"
import "../components" as Components
import ".."

Rectangle {
    id: upPage
    width: 320
    height: 170
    color: Theme.bgPrimary

    property var controller: null
    property var rootRef: null
    property var upMid: 0
    property var upFromViewAid: 0
    property bool upVideosRequested: false
    property bool upSeasonsRequested: false
    property bool upInfoRequested: false
    property bool upInfoReady: false
    property bool requestScheduled: false
    property int skeletonPaintToken: 0
    property bool locatingLastWatched: false
    property int locatingLastWatchedFetches: 0
    property bool locatingLastWatchedAroundRequested: false
    property int locatedLastWatchedIndex: -1
    property bool upSearchMode: false
    property string upSearchKeyword: ""
    property bool upSearchLoadingMore: false
    property bool upDynamicLoadingMore: false
    property real savedUpSearchContentX: 0
    property int upVideoPreloadWindow: 5
    property bool instantReadyTransition: false
    readonly property bool upContentReady: upInfoReady && controller && controller.upUserMid === Number(upMid) && controller.upUserName.length > 0
    readonly property bool upDynamicMode: controller && controller.upSelectedDynamic

    signal backClicked()
    signal videoSelected(string bvid)
    signal dynamicSelected(var dynamicData)

    function clampScrollState() {
        Qt.callLater(function() {
            var maxY = Math.max(0, mainFlick.contentHeight - mainFlick.height)
            if (mainFlick.contentY > maxY) mainFlick.contentY = maxY
            if (mainFlick.contentY < 0) mainFlick.contentY = 0
        })
    }

    function resetScrollState() {
        Qt.callLater(function() {
            mainFlick.contentY = 0
            filterFlick.contentX = 0
            upVideoList.contentX = 0
            clampScrollState()
        })
    }

    function resetListState() {
        locatingLastWatched = false
        locatingLastWatchedFetches = 0
        locatingLastWatchedAroundRequested = false
        locatedLastWatchedIndex = -1
        Qt.callLater(function() {
            upVideoList.contentX = 0
            clampScrollState()
        })
    }

    function scrollToVideoSection() {
        Qt.callLater(function() {
            mainFlick.contentY = Math.max(0, contentColumn.y + videoSection.y - Theme.spacingSmall)
            clampScrollState()
        })
    }

    function restoreUpSearchPosition() {
        if (!upSearchMode || savedUpSearchContentX <= 0) return
        Qt.callLater(function() {
            upSearchResultList.contentX = savedUpSearchContentX
            Qt.callLater(function() {
                upSearchResultList.contentX = savedUpSearchContentX
            })
        })
    }

    function requestUpSearchKeyboard() {
        let component = qmlCreateComponent("YInputPage")
        if (Component.Ready === component.status) {
            var incubator = component.incubateObject(up_search_pop_helper.containerItem)
            if (incubator.status !== Component.Ready) {
                incubator.onStatusChanged = function(status) {
                    if (status === Component.Ready)
                        up_search_pop_helper.inputPageCreated(incubator.object)
                }
            } else {
                up_search_pop_helper.inputPageCreated(incubator.object)
            }
        }
    }

    function upFansMedalLabel() {
        if (!controller || !controller.upFansMedalName) return ""
        var levelText = controller.upFansMedalLevel > 0 ? " Lv" + controller.upFansMedalLevel : ""
        return controller.upFansMedalName + levelText
    }

    function hasUpBadges() {
        return !!(controller && (controller.upOfficialLabel || controller.upVipLabel || upFansMedalLabel()))
    }

    function doUpSearch() {
        var kw = upSearchKeyword.trim()
        if (kw.length === 0) return
        var model = controller && controller.up ? controller.up.upSearchVideoModel() : null
        if (model && model.keyword === kw && model.count > 0) {
            upSearchMode = true
            scrollToVideoSection()
            restoreUpSearchPosition()
            return
        }
        savedUpSearchContentX = 0
        if (upSearchResultList) upSearchResultList.contentX = 0
        upSearchKeyword = kw
        upSearchMode = true
        scrollToVideoSection()
        if (controller && controller.up) controller.up.searchUpVideos(Number(upMid), kw, 1, 20)
    }

    function resetUpSearchState() {
        upSearchMode = false
        upSearchKeyword = ""
        upSearchLoadingMore = false
        upDynamicLoadingMore = false
        savedUpSearchContentX = 0
        if (controller && controller.up && controller.up.clearUpSearch) controller.up.clearUpSearch()
    }

    function scheduleUpVideoPreload() {
        if (!visible || !controller || !controller.videoDetailPreloadEnabled) return
        if (!controller.video || !controller.video.preloadVideoDetail) return
        if (upDynamicMode) return
        upVideoPreloadTimer.restart()
    }

    function firstVisibleVideoIndex(listView) {
        if (!listView || listView.count <= 0) return 0
        listView.forceLayout()
        var idx = listView.indexAt(Math.max(0, listView.contentX + 8), Math.max(1, listView.height / 2))
        if (idx < 0) {
            idx = Math.floor(Math.max(0, listView.contentX) / Math.max(1, 105 + listView.spacing))
        }
        return Math.max(0, Math.min(idx, listView.count - 1))
    }

    function preloadVideosFromList(listView) {
        if (!listView || !listView.visible || listView.count <= 0) return
        if (!controller || !controller.video || !controller.video.preloadVideoDetail) return
        var modelObj = listView.model
        if (!modelObj || !modelObj.bvidAt) return
        var first = firstVisibleVideoIndex(listView)
        var start = Math.max(0, first - 1)
        var end = Math.min(listView.count, first + upVideoPreloadWindow)
        for (var i = start; i < end; ++i) {
            var bvid = modelObj.bvidAt(i)
            if (bvid && bvid.length > 0) controller.video.preloadVideoDetail(bvid)
        }
    }

    function runUpVideoPreload() {
        if (!visible || !controller || !controller.videoDetailPreloadEnabled) return
        if (upSearchMode) {
            preloadVideosFromList(upSearchResultList)
        } else {
            preloadVideosFromList(upVideoList)
        }
    }

    function hasPreloadedUpInfo(midVal) {
        return !!(controller && midVal > 0 &&
                  controller.upUserMid === midVal &&
                  controller.upUserName && controller.upUserName.length > 0)
    }

    function requestUpDependentData(midVal) {
        if (!controller || !controller.up || !midVal || midVal <= 0) return

        var videoModel = controller.up.upVideoModel()
        if (!upVideosRequested && controller.upSelectedSeasonId === 0) {
            upVideosRequested = true
            if (!videoModel || (videoModel.count <= 0 && !videoModel.loading)) {
                controller.up.fetchUpVideos(midVal, 1, 20)
            }
        }

        var seasonModel = controller.up.upSeasonModel()
        if (!upSeasonsRequested) {
            upSeasonsRequested = true
            if (!seasonModel || (seasonModel.count <= 0 && !seasonModel.loading)) {
                controller.up.fetchUpSeasons(midVal)
            }
        }
    }

    function syncPreloadedUpState() {
        var midVal = Number(upMid)
        if (!hasPreloadedUpInfo(midVal)) return false
        var wasReady = upContentReady
        if (!wasReady) instantReadyTransition = true
        upInfoReady = true
        upInfoRequested = true
        requestScheduled = false
        initialFetchTimer.stop()
        requestUpDependentData(midVal)
        if (!wasReady) {
            Qt.callLater(function() {
                instantReadyTransition = false
            })
        }
        return true
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

    function positionLastWatchedIndex(idx) {
        if (idx < 0 || idx >= upVideoList.count) return
        upVideoList.forceLayout()
        upVideoList.positionViewAtIndex(idx, ListView.Center)
        Qt.callLater(function() {
            if (idx <= 1 && upVideoList.maybeFetchPrevious) {
                upVideoList.maybeFetchPrevious(true)
            }
        })
    }

    function tryScrollToLastWatched() {
        if (!locatingLastWatched || !controller || !controller.up) return
        var model = controller.up.upVideoModel()
        if (!model) return

        var targetAid = Number(upFromViewAid || 0)
        var idx = -1
        if (targetAid > 0 && model.indexOfAid) {
            idx = model.indexOfAid(targetAid)
        }
        if (targetAid <= 0 && model.indexOfLastWatched) {
            idx = model.indexOfLastWatched()
            if (idx < 0 && controller.upLastWatchedRank > 0 && model.indexOfLastWatchedRank) {
                idx = model.indexOfLastWatchedRank(controller.upLastWatchedRank)
            }
            if (idx < 0 && controller.upLastWatchedRank > 0 && model.count >= controller.upLastWatchedRank) {
                idx = controller.upLastWatchedRank - 1
            }
        }
        if (idx >= 0) {
            locatedLastWatchedIndex = idx
            scrollToVideoSection()
            Qt.callLater(function() {
                Qt.callLater(function() {
                    upPage.positionLastWatchedIndex(idx)
                })
            })
            locatingLastWatched = false
            return
        }
        if (model.loading) return
        if (targetAid > 0) {
            if (!locatingLastWatchedAroundRequested && controller.up.fetchUpVideosAroundAid) {
                locatingLastWatchedAroundRequested = true
                locatingLastWatchedFetches += 1
                controller.up.fetchUpVideosAroundAid(Number(upMid), targetAid, 20)
            } else {
                locatingLastWatched = false
            }
            return
        }
        if (model.hasMore && locatingLastWatchedFetches < 12) {
            locatingLastWatchedFetches += 1
            controller.up.fetchMoreUpVideos()
        } else {
            locatingLastWatched = false
        }
    }

    function locateLastWatched() {
        if (!controller || !controller.up) return
        locatingLastWatched = true
        locatingLastWatchedFetches = 0
        locatingLastWatchedAroundRequested = false
        if (controller.upSelectedSeasonId !== 0 || controller.upSelectedDynamic) {
            controller.up.selectUpSeason(0, "", false, 0)
        }
        Qt.callLater(tryScrollToLastWatched)
    }

    function scheduleInitialFetch() {
        var midVal = Number(upMid)
        if (!visible || !controller || !midVal || midVal <= 0) return
        if (rootRef && rootRef.currentPage !== "up") return
        if (syncPreloadedUpState()) return
        if (upInfoRequested || requestScheduled) return
        requestScheduled = true
        initialFetchTimer.restart()
    }

    function performInitialFetch() {
        var midVal = Number(upMid)
        requestScheduled = false
        if (!visible || !controller || !midVal || midVal <= 0) return
        if (rootRef && rootRef.currentPage !== "up") return
        if (syncPreloadedUpState()) return
        if (upInfoRequested) return
        upInfoRequested = true
        controller.up.fetchUpInfo(midVal)
    }

    function formatFanCount(value) {
        var n = Number(value || 0)
        if (n < 10000) return String(Math.floor(n))

        var wan = n / 10000.0
        var s = wan.toFixed(2)
        s = s.replace(/\.?0+$/, "")
        return s + "万"
    }

    onUpMidChanged: {
        initialFetchTimer.stop()
        var midVal = Number(upMid)
        upVideosRequested = false
        upSeasonsRequested = false
        upInfoRequested = false
        upInfoReady = false
        requestScheduled = false
        locatingLastWatched = false
        locatingLastWatchedFetches = 0
        locatingLastWatchedAroundRequested = false
        locatedLastWatchedIndex = -1
        upSearchMode = false
        upSearchKeyword = ""
        upSearchLoadingMore = false
        savedUpSearchContentX = 0
        skeletonPaintToken += 1
        var hasPreloadedInfo = hasPreloadedUpInfo(midVal)
        if (controller && controller.up && !hasPreloadedInfo) {
            if (controller.up.clearUpSearch) controller.up.clearUpSearch()
            var videoModel = controller.up.upVideoModel()
            if (videoModel && videoModel.clear) videoModel.clear()
            var seasonModel = controller.up.upSeasonModel()
            if (seasonModel && seasonModel.clear) seasonModel.clear()
            var dynamicModel = controller.feed ? controller.feed.upDynamicModel() : null
            if (dynamicModel && dynamicModel.clear) dynamicModel.clear()
        }
        if (controller && controller.upUserMid === midVal &&
                (controller.upSelectedSeasonId !== 0 || controller.upSelectedDynamic)) {
            controller.up.selectUpSeason(0, "", false, 0)
            upVideosRequested = true
        }
        syncPreloadedUpState()
        resetScrollState()
        scheduleInitialFetch()
    }

    onUpFromViewAidChanged: {
        locatingLastWatched = false
        locatingLastWatchedFetches = 0
        locatingLastWatchedAroundRequested = false
        locatedLastWatchedIndex = -1
    }

    onVisibleChanged: {
        if (visible) {
            var midVal = Number(upMid)
            if (controller && controller.upUserMid !== midVal && controller.up) {
                upInfoReady = false
                var videoModel = controller.up.upVideoModel()
                if (videoModel && videoModel.clear) videoModel.clear()
                var seasonModel = controller.up.upSeasonModel()
                if (seasonModel && seasonModel.clear) seasonModel.clear()
                var dynamicModel = controller.feed ? controller.feed.upDynamicModel() : null
                if (dynamicModel && dynamicModel.clear) dynamicModel.clear()
                upPage.resetUpSearchState()
            }
            syncPreloadedUpState()
            resetScrollState()
            scheduleInitialFetch()
            scheduleUpVideoPreload()
        }
    }

    onUpSearchModeChanged: scheduleUpVideoPreload()
    onUpDynamicModeChanged: scheduleUpVideoPreload()

    Timer {
        id: initialFetchTimer
        interval: Theme.animNormal + 16
        repeat: false
        onTriggered: upPage.performInitialFetch()
    }

    Timer {
        id: upVideoPreloadTimer
        interval: 180
        repeat: false
        onTriggered: upPage.runUpVideoPreload()
    }

    Component.onCompleted: {
        var midVal = Number(upMid)
        if (controller && controller.upUserMid !== midVal && controller.up) {
            var videoModel = controller.up.upVideoModel()
            if (videoModel && videoModel.clear) videoModel.clear()
            var seasonModel = controller.up.upSeasonModel()
            if (seasonModel && seasonModel.clear) seasonModel.clear()
            var dynamicModel = controller.feed ? controller.feed.upDynamicModel() : null
            if (dynamicModel && dynamicModel.clear) dynamicModel.clear()
            upInfoReady = false
        }
        syncPreloadedUpState()
        scheduleInitialFetch()
        scheduleUpVideoPreload()
    }

    Connections {
        target: controller
        function onUpUserChanged() {
            var midVal = Number(upMid)
            if (!controller || !midVal || controller.upUserMid !== midVal) return
            upInfoReady = true
            if (!upVideosRequested) {
                upVideosRequested = true
                Qt.callLater(function() {
                    if (!controller || controller.upUserMid !== midVal) return
                    if (controller.upSelectedSeasonId === 0) {
                        controller.up.fetchUpVideos(midVal, 1, 20)
                    }
                })
            }
            if (!upSeasonsRequested) {
                upSeasonsRequested = true
                Qt.callLater(function() {
                    if (!controller || controller.upUserMid !== midVal) return
                    controller.up.fetchUpSeasons(midVal)
                })
            }
        }
    }

    Components.TitleBar {
        id: titleBar
        title: "UP 主页"
        showBack: true
        anchors.top: parent.top
        onBackClicked: upPage.backClicked()
    }

    Flickable {
        id: mainFlick
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        contentHeight: Math.max(height, contentColumn.childrenRect.height + Theme.spacingLarge + Theme.spacingMedium)
        onContentHeightChanged: upPage.clampScrollState()
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        visible: opacity > 0
        opacity: upPage.upContentReady ? 1 : 0
        enabled: upPage.upContentReady
        Behavior on opacity {
            enabled: !upPage.instantReadyTransition
            NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic }
        }

        Column {
            id: contentColumn
            width: parent.width
            height: childrenRect.height
            spacing: Theme.spacingLarge
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Theme.spacingLarge

            // 头像 + 信息
            Row {
                id: headerRow
                width: parent.width - Theme.spacingLarge * 2
                height: 64
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingLarge

                Rectangle {
                    id: avatarWrap
                    width: 64
                    height: 64
                    radius: 32
                    color: Theme.bgTertiary
                    border.color: Theme.primary
                    border.width: 2

                    Image {
                        id: avatarImage
                        anchors.fill: parent
                        anchors.margins: 2
                        source: controller && controller.upUserFace
                            ? "image://bili/" + encodeURIComponent(controller.upUserFace)
                            : ""
                        fillMode: Image.PreserveAspectCrop
                        smooth: true
                        mipmap: true
                        asynchronous: true
                        visible: false
                    }

                    OpacityMask {
                        anchors.fill: avatarImage
                        source: avatarImage
                        maskSource: Rectangle {
                            width: avatarImage.width
                            height: avatarImage.height
                            radius: Math.min(width, height) / 2
                        }
                    }
                }

                Column {
                    id: infoColumn
                    width: parent.width - 96
                    spacing: Theme.spacingSmall
                    anchors.verticalCenter: parent.verticalCenter

                    Row {
                        width: parent.width
                        spacing: Theme.spacingSmall

                        Text {
                            id: upNameText
                            width: parent.width - uidBadge.width - Theme.spacingSmall
                            text: controller ? controller.upUserName : ""
                            color: Theme.textPrimary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontMedium
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        // UID 徽标
                        Rectangle {
                            id: uidBadge
                            height: 18
                            radius: Theme.radiusRound
                            color: Theme.withAlpha(Theme.primary, 0.12)
                            border.color: Theme.withAlpha(Theme.primary, 0.35)
                            border.width: 1
                            width: uidText.implicitWidth + 14

                            Text {
                                id: uidText
                                anchors.centerIn: parent
                                text: "UID " + (controller ? String(controller.upUserMid) : "0")
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                                font.bold: true
                            }
                        }
                    }

                    Row {
                        spacing: Theme.spacingSmall

                        Rectangle {
                            width: 40
                            height: 18
                            radius: Theme.radiusRound
                            color: Theme.primary

                            Text {
                                anchors.centerIn: parent
                                text: "LV" + (controller ? controller.upUserLevel : 0)
                                color: Theme.textOnPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                                font.bold: true
                            }
                        }

                        Rectangle {
                            height: 18
                            radius: Theme.radiusRound
                            color: controller && controller.upIsFollowing
                                   ? (followArea.pressed ? Theme.bgTertiary : Theme.bgSecondary)
                                   : (followArea.pressed ? Theme.primaryDark : Theme.primary)
                            border.width: controller && controller.upIsFollowing ? 1 : 0
                            border.color: controller && controller.upIsFollowing
                                          ? Theme.withAlpha(Theme.primary, 0.35)
                                          : "transparent"
                            width: followText.implicitWidth + 16

                            Text {
                                id: followText
                                anchors.centerIn: parent
                                text: controller && controller.upIsFollowing ? "已关注" : "关注"
                                color: controller && controller.upIsFollowing ? Theme.textSecondary : Theme.textOnPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                                font.bold: true
                            }

                            MouseArea {
                                id: followArea
                                anchors.fill: parent
                                onClicked: {
                                    if (controller) controller.up.toggleUpFollow()
                                }
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        height: visible ? 16 : 0
                        spacing: 4
                        visible: upPage.hasUpBadges()
                        clip: true

                        Rectangle {
                            visible: controller && controller.upOfficialLabel !== ""
                            height: 16
                            radius: Theme.radiusRound
                            color: Theme.withAlpha(Theme.primary, 0.16)
                            border.color: Theme.withAlpha(Theme.primary, 0.36)
                            border.width: 1
                            width: Math.min(84, officialBadgeText.implicitWidth + 12)

                            Text {
                                id: officialBadgeText
                                anchors.centerIn: parent
                                width: parent.width - 8
                                text: controller ? controller.upOfficialLabel : ""
                                color: Theme.primaryLight
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontTiny
                                font.bold: true
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }

                        Rectangle {
                            visible: controller && controller.upVipLabel !== ""
                            height: 16
                            radius: Theme.radiusRound
                            color: Theme.withAlpha(Theme.accent, 0.18)
                            border.color: Theme.withAlpha(Theme.accent, 0.38)
                            border.width: 1
                            width: Math.min(64, vipBadgeText.implicitWidth + 12)

                            Text {
                                id: vipBadgeText
                                anchors.centerIn: parent
                                width: parent.width - 8
                                text: controller ? controller.upVipLabel : ""
                                color: "#FB7299"
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontTiny
                                font.bold: true
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }

                        Rectangle {
                            visible: upPage.upFansMedalLabel() !== ""
                            height: 16
                            radius: Theme.radiusRound
                            color: Theme.withAlpha(Theme.warning, 0.16)
                            border.color: Theme.withAlpha(Theme.warning, 0.36)
                            border.width: 1
                            width: Math.min(70, medalBadgeText.implicitWidth + 12)

                            Text {
                                id: medalBadgeText
                                anchors.centerIn: parent
                                width: parent.width - 8
                                text: upPage.upFansMedalLabel()
                                color: Theme.warning
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontTiny
                                font.bold: true
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }
                }
            }

            // 个人签名（放在头像下面）
            Rectangle {
                width: parent.width - Theme.spacingLarge * 2
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Theme.radiusLarge
                color: Theme.bgSecondary
                border.color: Theme.withAlpha(Theme.primary, 0.15)
                border.width: 1
                height: signText.implicitHeight + Theme.spacingMedium * 2

                Text {
                    id: signText
                    anchors.fill: parent
                    anchors.margins: Theme.spacingMedium
                    text: controller && controller.upUserSign !== "" ? controller.upUserSign : "这个人很懒，什么都没写~"
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontBody
                    wrapMode: Text.WordWrap
                }
            }

            // 粉丝/关注
            Row {
                width: parent.width - Theme.spacingLarge * 2
                height: 28
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingSmall

                readonly property real colW: (width - Theme.spacingSmall) / 2

                Column {
                    width: parent.colW
                    spacing: 4

                    Text {
                        width: parent.width
                        text: controller ? upPage.formatFanCount(controller.upUserFans) : "0"
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontMedium
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Text {
                        width: parent.width
                        text: "粉丝"
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSmall
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                Column {
                    width: parent.colW
                    spacing: 4

                    Text {
                        width: parent.width
                        text: controller ? String(controller.upUserFollowing) : "0"
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontMedium
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Text {
                        width: parent.width
                        text: "关注"
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSmall
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }

            // 投稿视频 / 合集筛选
            Item {
                id: videoSection
                width: parent.width
                height: videoHeader.height + Theme.spacingSmall + filterStrip.height + Theme.spacingNormal + upVideoList.height

                // 标题行：当前筛选名 + 视频数量提示
                Item {
                    id: videoHeader
                    width: parent.width
                    height: 24
                    anchors.top: parent.top

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingLarge
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - Theme.spacingLarge * 2 - lastWatchedButton.width - searchButton.width - 12
                        spacing: Theme.spacingSmall

                        // 装饰条
                        Rectangle {
                            width: 3
                            height: titleHeaderText.implicitHeight - 2
                            radius: 1.5
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            id: titleHeaderText
                            text: upPage.upSearchMode
                                  ? "搜索：" + upPage.upSearchKeyword
                                  : (upPage.upDynamicMode
                                     ? "图文动态"
                                  : (controller && controller.upSelectedSeasonId !== 0
                                     ? (controller.upSelectedSeasonName || "合集")
                                     : "视频列表"))
                            color: Theme.textPrimary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontMedium
                            font.bold: true
                            elide: Text.ElideRight
                            width: Math.min(implicitWidth, upPage.width - 176)
                        }

                        Text {
                            id: listCountText
                            anchors.verticalCenter: parent.verticalCenter
                            visible: controller && (upPage.upSearchMode
                                                     ? (!!upSearchResultList.model && upSearchResultList.count > 0)
                                                     : (upPage.upDynamicMode
                                                        ? (!!upDynamicList.model && upDynamicList.count > 0)
                                                        : (controller.upVideoTotal > 0 || (!!upVideoList.model && upVideoList.count > 0))))
                            text: " · " + (upPage.upSearchMode
                                           ? upSearchResultList.count + " 个视频"
                                           : (upPage.upDynamicMode
                                              ? upDynamicList.count + " 条动态"
                                              : (controller.upVideoTotal > 0 ? controller.upVideoTotal : upVideoList.count) + " 个视频"))
                            color: Theme.textTertiary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSmall
                        }
                    }

                    Rectangle {
                        id: searchButton
                        anchors.right: lastWatchedButton.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !upPage.upDynamicMode
                        width: visible ? 34 : 0
                        height: 20
                        radius: 10
                        color: searchArea.pressed ? Theme.withAlpha(Theme.primary, 0.22)
                                                  : Theme.withAlpha(Theme.primary, 0.10)
                        border.color: Theme.withAlpha(Theme.primary, 0.32)
                        border.width: 1

                        Canvas {
                            anchors.centerIn: parent
                            width: 13
                            height: 13
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.strokeStyle = Theme.textSecondary
                                ctx.lineWidth = 1.6
                                ctx.beginPath()
                                ctx.arc(5.5, 5.5, 4, 0, Math.PI * 2, false)
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.moveTo(8.7, 8.7)
                                ctx.lineTo(12, 12)
                                ctx.stroke()
                            }
                        }

                        MouseArea {
                            id: searchArea
                            anchors.fill: parent
                            onClicked: upPage.requestUpSearchKeyboard()
                        }
                    }

                    Rectangle {
                        id: lastWatchedButton
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingLarge
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !upPage.upDynamicMode
                        width: visible ? 58 : 0
                        height: 20
                        radius: 10
                        color: lastWatchedArea.pressed ? Theme.withAlpha(Theme.primary, 0.22)
                                                        : Theme.withAlpha(Theme.primary, 0.10)
                        border.color: Theme.withAlpha(Theme.primary, 0.32)
                        border.width: 1
                        opacity: upPage.upSearchMode || (controller && controller.loggedIn) ? 1 : 0.55

                        Text {
                            anchors.centerIn: parent
                            text: upPage.upSearchMode ? "返回列表" : "上次观看"
                            color: Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSmall
                            font.bold: true
                        }

                        MouseArea {
                            id: lastWatchedArea
                            anchors.fill: parent
                            onClicked: {
                                if (upPage.upSearchMode) {
                                    upPage.upSearchMode = false
                                } else {
                                    upPage.locateLastWatched()
                                }
                            }
                        }
                    }
                }

                Item { width: parent.width; height: 2 }

                // 合集筛选条：水平滚动 chip 列表
                Item {
                    id: filterStrip
                    width: parent.width
                    height: 24
                    visible: !upPage.upSearchMode
                    anchors.top: videoHeader.bottom
                    anchors.topMargin: Theme.spacingSmall

                    Flickable {
                        id: filterFlick
                        anchors.fill: parent
                        contentWidth: filterRow.width + Theme.spacingLarge * 2
                        contentHeight: filterStrip.height
                        flickableDirection: Flickable.HorizontalFlick
                        boundsBehavior: Flickable.StopAtBounds
                        clip: true

                        Row {
                            id: filterRow
                            x: Theme.spacingLarge
                            spacing: 6
                            anchors.verticalCenter: parent.verticalCenter

                            // “视频”全部 chip
                            Rectangle {
                                id: allChip
                                height: filterStrip.height
                                width: allChipText.implicitWidth + 26
                                radius: height / 2
                                property bool selected: !controller || (!controller.upSelectedDynamic && controller.upSelectedSeasonId === 0)
                                color: selected ? Theme.primary
                                                : (allChipArea.pressed ? Theme.bgTertiary : Theme.bgSecondary)
                                border.color: selected ? "transparent"
                                                       : Theme.withAlpha(Theme.primary, 0.25)
                                border.width: selected ? 0 : 1

                                Behavior on color { ColorAnimation { duration: Theme.animFast } }

                                Text {
                                    id: allChipText
                                    anchors.centerIn: parent
                                    text: "视频"
                                    color: parent.selected ? Theme.textOnPrimary : Theme.textSecondary
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSmall
                                    font.bold: parent.selected
                                }

                                MouseArea {
                                    id: allChipArea
                                    anchors.fill: parent
                                    onClicked: {
                                        if (!controller) return
                                        if (controller.upSelectedSeasonId !== 0 || controller.upSelectedDynamic) {
                                            controller.up.selectUpSeason(0, "", false, 0)
                                            upPage.resetListState()
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                id: dynamicChip
                                height: filterStrip.height
                                width: dynamicChipText.implicitWidth + 26
                                radius: height / 2
                                property bool selected: controller && controller.upSelectedDynamic
                                color: selected ? Theme.primary
                                                : (dynamicChipArea.pressed ? Theme.bgTertiary : Theme.bgSecondary)
                                border.color: selected ? "transparent"
                                                       : Theme.withAlpha(Theme.primary, 0.25)
                                border.width: selected ? 0 : 1

                                Behavior on color { ColorAnimation { duration: Theme.animFast } }

                                Row {
                                    anchors.centerIn: parent
                                    spacing: 4

                                    Canvas {
                                        id: dynamicChipIcon
                                        width: 10
                                        height: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        property bool selected: dynamicChip.selected
                                        onSelectedChanged: requestPaint()
                                        onPaint: {
                                            var ctx = getContext("2d")
                                            ctx.clearRect(0, 0, width, height)
                                            var c = dynamicChip.selected ? Theme.textOnPrimary : Theme.textSecondary
                                            ctx.strokeStyle = c
                                            ctx.fillStyle = c
                                            ctx.lineWidth = 1.1
                                            ctx.lineCap = "round"
                                            ctx.lineJoin = "round"

                                            ctx.beginPath()
                                            ctx.moveTo(1.2, 2)
                                            ctx.lineTo(8.8, 2)
                                            ctx.quadraticCurveTo(9.4, 2, 9.4, 2.6)
                                            ctx.lineTo(9.4, 7.8)
                                            ctx.quadraticCurveTo(9.4, 8.4, 8.8, 8.4)
                                            ctx.lineTo(1.2, 8.4)
                                            ctx.quadraticCurveTo(0.6, 8.4, 0.6, 7.8)
                                            ctx.lineTo(0.6, 2.6)
                                            ctx.quadraticCurveTo(0.6, 2, 1.2, 2)
                                            ctx.closePath()
                                            ctx.stroke()

                                            ctx.beginPath()
                                            ctx.arc(3, 4, 0.9, 0, Math.PI * 2, false)
                                            ctx.fill()

                                            ctx.beginPath()
                                            ctx.moveTo(1.2, 7.6)
                                            ctx.lineTo(3.5, 5.6)
                                            ctx.lineTo(5.1, 6.9)
                                            ctx.lineTo(6.8, 5.1)
                                            ctx.lineTo(8.8, 7.6)
                                            ctx.stroke()
                                        }
                                        Component.onCompleted: requestPaint()
                                    }

                                    Text {
                                        id: dynamicChipText
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "图文"
                                        color: dynamicChip.selected ? Theme.textOnPrimary : Theme.textSecondary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSmall
                                        font.bold: dynamicChip.selected
                                    }
                                }

                                MouseArea {
                                    id: dynamicChipArea
                                    anchors.fill: parent
                                    onClicked: {
                                        if (!controller || !controller.up) return
                                        if (!dynamicChip.selected) {
                                            upPage.resetUpSearchState()
                                            controller.up.selectUpDynamic()
                                            upPage.resetListState()
                                        }
                                    }
                                }
                            }

                            Repeater {
                                model: controller ? controller.up.upSeasonModel() : null

                                delegate: Rectangle {
                                    id: seasonChip
                                    height: filterStrip.height
                                    width: Math.min(seasonChipText.implicitWidth + 26, 172)
                                    radius: height / 2
                                    property bool selected: controller && !controller.upSelectedDynamic && controller.upSelectedSeasonId === model.seasonId
                                    color: selected ? Theme.primary
                                                    : (seasonChipArea.pressed ? Theme.bgTertiary : Theme.bgSecondary)
                                    border.color: selected ? "transparent"
                                                           : Theme.withAlpha(Theme.primary, 0.25)
                                    border.width: selected ? 0 : 1

                                    Behavior on color { ColorAnimation { duration: Theme.animFast } }

                                    Row {
                                        anchors.centerIn: parent
                                        spacing: 4

                                        // 合集小图标：两层错位的小方块，暗示叠放/合集
                                        Item {
                                            width: 10; height: 10
                                            anchors.verticalCenter: parent.verticalCenter

                                            Rectangle {
                                                width: 7; height: 7
                                                radius: 1.5
                                                color: "transparent"
                                                border.color: seasonChip.selected ? Theme.textOnPrimary : Theme.textSecondary
                                                border.width: 1
                                                x: 0; y: 3
                                            }
                                            Rectangle {
                                                width: 7; height: 7
                                                radius: 1.5
                                                color: seasonChip.selected ? Theme.textOnPrimary : Theme.textSecondary
                                                x: 3; y: 0
                                            }
                                        }

                                        Text {
                                            id: seasonChipText
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: (model.name || "合集")
                                                  + (model.total > 0 ? "·" + model.total : "")
                                            color: seasonChip.selected ? Theme.textOnPrimary : Theme.textSecondary
                                            font.family: Theme.fontFamily
                                            font.pixelSize: Theme.fontSmall
                                            font.bold: seasonChip.selected
                                            elide: Text.ElideRight
                                            // chip 总宽 max 172，扣掉左右内边距与图标和间距 ≈ 140
                                            width: Math.min(implicitWidth, 140)
                                        }
                                    }

                                    MouseArea {
                                        id: seasonChipArea
                                        anchors.fill: parent
                                        onClicked: {
                                            if (!controller) return
                                            if (!seasonChip.selected) {
                                                controller.up.selectUpSeason(model.seasonId,
                                                                          model.name || "",
                                                                          model.isSeries === true,
                                                                          model.total || 0)
                                                upPage.resetListState()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                }

                Connections {
                    target: controller ? controller.up.upSeasonModel() : null
                    function onLoadingChanged() {
                        if (!target || target.loading) return
                        upPage.clampScrollState()
                    }
                }

                ListView {
                    id: upVideoList
                    visible: !upPage.upSearchMode && !upPage.upDynamicMode
                    width: parent.width
                    height: 135
                    anchors.top: filterStrip.bottom
                    anchors.topMargin: Theme.spacingNormal
                    orientation: ListView.Horizontal
                    spacing: 6
                    clip: true
                    cacheBuffer: 640
                    displayMarginBeginning: 160
                    displayMarginEnd: 160
                    model: controller ? controller.up.upVideoModel() : null
                    leftMargin: 4
                    rightMargin: 4
                    property bool _loadingMore: false
                    property bool _loadingPrevious: false
                    property int _previousCountBeforeLoad: 0

                    function maybeFetchPrevious(force) {
                        if (!controller || !controller.up) return
                        if (!force && !atXBeginning) return
                        if (upVideoList.contentWidth <= upVideoList.width + 2) return
                        if (upVideoList._loadingPrevious || upVideoList._loadingMore) return
                        if (upVideoList.model && upVideoList.model.loading) return
                        if (!controller.up.canFetchPreviousUpVideos || !controller.up.canFetchPreviousUpVideos()) return
                        upVideoList._loadingPrevious = true
                        upVideoList._previousCountBeforeLoad = upVideoList.count
                        controller.up.fetchPreviousUpVideos()
                    }

                    onAtXBeginningChanged: if (atXBeginning) maybeFetchPrevious()
                    onMovementEnded: {
                        maybeFetchPrevious()
                        upPage.scheduleUpVideoPreload()
                    }
                    onDraggingChanged: if (!dragging) {
                        maybeFetchPrevious()
                        upPage.scheduleUpVideoPreload()
                    }
                    onContentXChanged: upPage.scheduleUpVideoPreload()

                    // 注意：当列表内容不足以撑满宽度时，atXEnd 会一直为 true，
                    // 可能导致无限触发“加载更多”并表现为“循环同一列表”。
                    // 这里增加防抖/条件：仅当确实可横向滚动且未在加载时才触发。
                    onAtXEndChanged: {
                        if (!controller) return
                        if (!atXEnd) return
                        if (upVideoList.contentWidth <= upVideoList.width + 2) return
                        if (upVideoList._loadingMore) return
                        if (upVideoList.model && upVideoList.model.loading) return
                        if (upVideoList.model && upVideoList.model.hasMore === false) return
                        upVideoList._loadingMore = true
                        controller.up.fetchMoreUpVideos()
                    }

                    delegate: Components.VideoCardCompact {
                        height: upVideoList.height
                        videoTitle: model.title || ""
                        coverUrl: model.pic || ""
                        imageActive: upPage.visible
                        preferOffscreenPlaceholder: controller && controller.videoCardOffscreenPlaceholderEnabled
                        upName: model.ownerName || ""
                        viewCount: model.views || ""
                        durationText: model.durationText || ""
                        bvid: model.bvid || ""
                        isLastWatched: (Number(upPage.upFromViewAid || 0) > 0 && Number(model.aid || 0) === Number(upPage.upFromViewAid))
                                       || model.isLastWatchedArc === true
                                       || index === upPage.locatedLastWatchedIndex
                        partCount: model.partCount || 1
                        titleScale: 0.9
                        subScale: 0.85
                        onClicked: upPage.videoSelected(bvid)
                    }

                    Row {
                        visible: upVideoList.count === 0 && controller && controller.isLoading
                        anchors.left: parent.left
                        anchors.leftMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6
                        Repeater {
                            model: 3
                            Components.VideoCardCompact {
                                height: upVideoList.height
                                placeholder: true
                                        titleScale: 0.9
                                subScale: 0.85
                            }
                        }
                    }
                }

                ListView {
                    id: upDynamicList
                    visible: !upPage.upSearchMode && upPage.upDynamicMode
                    width: parent.width
                    height: 135
                    anchors.top: filterStrip.bottom
                    anchors.topMargin: Theme.spacingNormal
                    orientation: ListView.Vertical
                    spacing: 5
                    clip: true
                    cacheBuffer: 360
                    displayMarginBeginning: 120
                    displayMarginEnd: 160
                    model: controller && controller.feed ? controller.feed.upDynamicModel() : null
                    leftMargin: 6
                    rightMargin: 6
                    topMargin: 1
                    bottomMargin: 1

                    delegate: Components.DynamicFeedCard {
                        width: upDynamicList.width - 12
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
                        imageActive: upPage.visible && upPage.upDynamicMode
                        onClicked: {
                            if (bvid && bvid.length > 0) {
                                upPage.videoSelected(bvid)
                            } else {
                                upPage.dynamicSelected(upPage.dynamicDataFromModel(model))
                            }
                        }
                    }

                    onAtYEndChanged: {
                        if (!atYEnd || !controller || !controller.feed) return
                        if (upDynamicList.contentHeight <= upDynamicList.height + 2) return
                        if (upPage.upDynamicLoadingMore) return
                        if (upDynamicList.model && upDynamicList.model.loading) return
                        if (upDynamicList.model && upDynamicList.model.hasMore === false) return
                        upPage.upDynamicLoadingMore = true
                        controller.feed.fetchMoreUpDynamics()
                    }

                    onCountChanged: upPage.upDynamicLoadingMore = false
                }

                ListView {
                    id: upSearchResultList
                    visible: upPage.upSearchMode
                    width: parent.width
                    height: 135
                    anchors.top: videoHeader.bottom
                    anchors.topMargin: Theme.spacingSmall
                    orientation: ListView.Horizontal
                    spacing: 6
                    clip: true
                    cacheBuffer: 640
                    displayMarginBeginning: 160
                    displayMarginEnd: 160
                    model: controller && controller.up ? controller.up.upSearchVideoModel() : null
                    leftMargin: 4
                    rightMargin: 4

                    delegate: Components.VideoCardCompact {
                        height: upSearchResultList.height
                        videoTitle: model.title || ""
                        coverUrl: model.pic || ""
                        imageActive: upPage.visible && upPage.upSearchMode
                        preferOffscreenPlaceholder: controller && controller.videoCardOffscreenPlaceholderEnabled
                        upName: model.ownerName || ""
                        viewCount: model.views || ""
                        durationText: model.durationText || ""
                        bvid: model.bvid || ""
                        partCount: model.partCount || 1
                        titleScale: 0.9
                        subScale: 0.85
                        onClicked: {
                            upPage.savedUpSearchContentX = upSearchResultList.contentX
                            upPage.videoSelected(bvid)
                        }
                    }

                    Row {
                        visible: upPage.upSearchMode
                                 && upSearchResultList.model
                                 && upSearchResultList.model.loading
                                 && upSearchResultList.count === 0
                        anchors.left: parent.left
                        anchors.leftMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6
                        Repeater {
                            model: 3
                            Components.VideoCardCompact {
                                height: upSearchResultList.height
                                placeholder: true
                                        titleScale: 0.9
                                subScale: 0.85
                            }
                        }
                    }

                    onAtXEndChanged: {
                        if (!atXEnd || !controller || !controller.up) return
                        if (upSearchResultList.contentWidth <= upSearchResultList.width + 2) return
                        if (upPage.upSearchLoadingMore) return
                        if (upSearchResultList.model && upSearchResultList.model.loading) return
                        if (upSearchResultList.model && upSearchResultList.model.hasMore === false) return
                        upPage.upSearchLoadingMore = true
                        controller.up.searchMoreUpVideos()
                    }

                    onCountChanged: {
                        upPage.upSearchLoadingMore = false
                        upPage.restoreUpSearchPosition()
                        upPage.scheduleUpVideoPreload()
                    }

                    onContentXChanged: upPage.scheduleUpVideoPreload()
                    onMovementEnded: upPage.scheduleUpVideoPreload()
                    onDraggingChanged: if (!dragging) upPage.scheduleUpVideoPreload()
                }

                Connections {
                    target: upVideoList.model
                    function onLoadingChanged() {
                        if (!target || target.loading) return
                        upVideoList._loadingMore = false
                        upVideoList._loadingPrevious = false
                        upPage.clampScrollState()
                        upPage.tryScrollToLastWatched()
                        upPage.scheduleUpVideoPreload()
                    }
                    function onCountChanged() {
                        if (upVideoList._loadingPrevious) {
                            var added = Math.max(0, upVideoList.count - upVideoList._previousCountBeforeLoad)
                            if (added > 0) {
                                upVideoList.contentX += added * (105 + upVideoList.spacing)
                            }
                        }
                        upVideoList._loadingMore = false
                        upPage.tryScrollToLastWatched()
                        upPage.scheduleUpVideoPreload()
                    }
                }

                Connections {
                    target: upDynamicList.model
                    function onLoadingChanged() {
                        if (!target || target.loading) return
                        upPage.upDynamicLoadingMore = false
                        upPage.clampScrollState()
                    }
                    function onCountChanged() {
                        upPage.upDynamicLoadingMore = false
                    }
                }

                Connections {
                    target: upSearchResultList.model
                    function onLoadingChanged() {
                        if (!target || target.loading) return
                        upPage.upSearchLoadingMore = false
                        upPage.restoreUpSearchPosition()
                        upPage.scheduleUpVideoPreload()
                    }
                }

                Text {
                    visible: !upPage.upSearchMode && !upPage.upDynamicMode
                             && upVideoList.count === 0 && controller && !controller.isLoading
                    text: controller && controller.upSelectedSeasonId !== 0 ? "该合集暂无视频" : "暂无投稿"
                    color: Theme.textTertiary
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: upVideoList.bottom
                    anchors.topMargin: 6
                }

                Text {
                    visible: !upPage.upSearchMode && upPage.upDynamicMode
                             && upDynamicList.count === 0
                             && upDynamicList.model
                             && !upDynamicList.model.loading
                    text: upDynamicList.model && upDynamicList.model.errorMessage
                          ? upDynamicList.model.errorMessage
                          : "暂无图文动态"
                    color: Theme.textTertiary
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: upDynamicList.bottom
                    anchors.topMargin: 6
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                }

                Text {
                    visible: upPage.upSearchMode
                             && upSearchResultList.count === 0
                             && upSearchResultList.model
                             && !upSearchResultList.model.loading
                    text: upSearchResultList.model && upSearchResultList.model.errorMessage
                          ? upSearchResultList.model.errorMessage
                          : "未找到相关视频"
                    color: Theme.textTertiary
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: upSearchResultList.bottom
                    anchors.topMargin: 6
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                }
            }
        }
    }

    YPagePopHelper {
        id: up_search_pop_helper
        z: 99

        function inputPageCreated(keyboardPage) {
            keyboardPage.backButtonClicked.connect(function() {
                qmlGlobal.inputPageShowing = false
                keyboardPage.todoDestroy()
                keyboardPage = null
            })

            keyboardPage.inputFinished.connect(function(content) {
                upPage.upSearchKeyword = content.trim()
                qmlGlobal.inputPageShowing = false
                keyboardPage.todoDestroy()
                if (upPage.upSearchKeyword.length > 0) {
                    upPage.doUpSearch()
                }
            })

            keyboardPage.enterText(upPage.upSearchKeyword)
            keyboardPage.show()
            qmlGlobal.inputPageShowing = true
        }

        isShowing: qmlGlobal.inputPageShowing
        objectName: "from_UpUserPage.qml"
    }

    Item {
        id: upSkeletonLayer
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: opacity > 0
        opacity: upPage.upContentReady ? 0 : 1
        z: 20
        clip: true
        Behavior on opacity {
            enabled: !upPage.instantReadyTransition
            NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic }
        }

        Column {
            width: parent.width
            spacing: Theme.spacingLarge
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Theme.spacingLarge

            Row {
                width: parent.width - Theme.spacingLarge * 2
                height: 64
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingLarge

                Canvas {
                    width: 64
                    height: 64
                    property int paintToken: upPage.skeletonPaintToken
                    Component.onCompleted: requestPaint()
                    onPaintTokenChanged: requestPaint()
                    onVisibleChanged: if (visible) requestPaint()
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        ctx.fillStyle = Theme.bgTertiary
                        ctx.beginPath()
                        ctx.arc(width / 2, height / 2, 31, 0, Math.PI * 2, false)
                        ctx.fill()
                        ctx.strokeStyle = Theme.withAlpha(Theme.primary, 0.38)
                        ctx.lineWidth = 2
                        ctx.stroke()
                        ctx.strokeStyle = Theme.withAlpha(Theme.textSecondary, 0.22)
                        ctx.lineWidth = 2
                        ctx.beginPath()
                        ctx.arc(32, 25, 8, 0, Math.PI * 2, false)
                        ctx.stroke()
                        ctx.beginPath()
                        ctx.arc(32, 47, 15, Math.PI * 1.05, Math.PI * 1.95, false)
                        ctx.stroke()
                    }
                }

                Canvas {
                    width: parent.width - 96
                    height: 58
                    anchors.verticalCenter: parent.verticalCenter
                    property int paintToken: upPage.skeletonPaintToken
                    Component.onCompleted: requestPaint()
                    onPaintTokenChanged: requestPaint()
                    onVisibleChanged: if (visible) requestPaint()
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        function pill(x, y, w, h, color) {
                            ctx.fillStyle = color
                            ctx.beginPath()
                            ctx.moveTo(x + h / 2, y)
                            ctx.lineTo(x + w - h / 2, y)
                            ctx.quadraticCurveTo(x + w, y, x + w, y + h / 2)
                            ctx.quadraticCurveTo(x + w, y + h, x + w - h / 2, y + h)
                            ctx.lineTo(x + h / 2, y + h)
                            ctx.quadraticCurveTo(x, y + h, x, y + h / 2)
                            ctx.quadraticCurveTo(x, y, x + h / 2, y)
                            ctx.fill()
                        }
                        pill(0, 4, width * 0.72, 12, Theme.withAlpha(Theme.textSecondary, 0.22))
                        pill(width * 0.76, 4, width * 0.22, 12, Theme.withAlpha(Theme.primary, 0.16))
                        pill(0, 30, 40, 18, Theme.withAlpha(Theme.primary, 0.20))
                        pill(48, 30, 58, 18, Theme.withAlpha(Theme.textSecondary, 0.16))
                    }
                }
            }

            Canvas {
                width: parent.width - Theme.spacingLarge * 2
                height: 44
                anchors.horizontalCenter: parent.horizontalCenter
                property int paintToken: upPage.skeletonPaintToken
                Component.onCompleted: requestPaint()
                onPaintTokenChanged: requestPaint()
                onVisibleChanged: if (visible) requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    function pill(x, y, w, h, color) {
                        ctx.fillStyle = color
                        ctx.beginPath()
                        ctx.moveTo(x + h / 2, y)
                        ctx.lineTo(x + w - h / 2, y)
                        ctx.quadraticCurveTo(x + w, y, x + w, y + h / 2)
                        ctx.quadraticCurveTo(x + w, y + h, x + w - h / 2, y + h)
                        ctx.lineTo(x + h / 2, y + h)
                        ctx.quadraticCurveTo(x, y + h, x, y + h / 2)
                        ctx.quadraticCurveTo(x, y, x + h / 2, y)
                        ctx.fill()
                    }
                    ctx.fillStyle = Theme.bgSecondary
                    ctx.beginPath()
                    ctx.moveTo(10, 0)
                    ctx.lineTo(width - 10, 0)
                    ctx.quadraticCurveTo(width, 0, width, 10)
                    ctx.lineTo(width, height - 10)
                    ctx.quadraticCurveTo(width, height, width - 10, height)
                    ctx.lineTo(10, height)
                    ctx.quadraticCurveTo(0, height, 0, height - 10)
                    ctx.lineTo(0, 10)
                    ctx.quadraticCurveTo(0, 0, 10, 0)
                    ctx.fill()
                    pill(12, 11, width * 0.78, 8, Theme.withAlpha(Theme.textSecondary, 0.18))
                    pill(12, 26, width * 0.46, 8, Theme.withAlpha(Theme.textSecondary, 0.13))
                }
            }

            Canvas {
                width: parent.width - Theme.spacingLarge * 2
                height: 32
                anchors.horizontalCenter: parent.horizontalCenter
                property int paintToken: upPage.skeletonPaintToken
                Component.onCompleted: requestPaint()
                onPaintTokenChanged: requestPaint()
                onVisibleChanged: if (visible) requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    function pill(x, y, w, h, color) {
                        ctx.fillStyle = color
                        ctx.beginPath()
                        ctx.moveTo(x + h / 2, y)
                        ctx.lineTo(x + w - h / 2, y)
                        ctx.quadraticCurveTo(x + w, y, x + w, y + h / 2)
                        ctx.quadraticCurveTo(x + w, y + h, x + w - h / 2, y + h)
                        ctx.lineTo(x + h / 2, y + h)
                        ctx.quadraticCurveTo(x, y + h, x, y + h / 2)
                        ctx.quadraticCurveTo(x, y, x + h / 2, y)
                        ctx.fill()
                    }
                    pill(0, 0, width * 0.26, 10, Theme.withAlpha(Theme.textPrimary, 0.18))
                    pill(0, 18, 52, 14, Theme.withAlpha(Theme.primary, 0.20))
                    pill(60, 18, 78, 14, Theme.withAlpha(Theme.textSecondary, 0.14))
                    pill(146, 18, 68, 14, Theme.withAlpha(Theme.textSecondary, 0.12))
                }
            }

            Row {
                width: parent.width
                height: 135
                spacing: 6
                anchors.horizontalCenter: parent.horizontalCenter
                Repeater {
                    model: 3
                    Components.VideoCardCompact {
                        height: 135
                        placeholder: true
                        titleScale: 0.9
                        subScale: 0.85
                    }
                }
            }
        }
    }
}
