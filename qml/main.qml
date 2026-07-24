import QtQuick 2.12
import BiliPlugin 1.0
import "pages" as Pages
import "components" as Components

Rectangle {
    id: root
    width: 320
    height: 170
    color: Theme.bgPrimary
    clip: true

    signal backButtonClicked()

    BiliController {
        id: controller
    }

    property var rootController: controller

    // ── 页面管理 ──
    property string currentPage: "home"
    property var pageStack: []
    property string detailBvid: ""
    property string commentsBvid: ""
    property string commentsOid: ""
    property int commentsType: 1
    property string commentsKey: ""
    property string commentsTitle: ""
    property int detailSessionId: 0
    property int nextDetailSessionId: 1
    property var reportedDetailSessions: ({})
    property var detailCacheBvids: ({})
    property string lastPage: "home"
    property var upUserMid: 0
    property var upFromViewAid: 0
    property var dynamicDetailData: ({})
    property var seasonMid: 0
    property var seasonId: 0
    property string seasonTitle: ""
    property string seasonCover: ""
    property int seasonTotal: 0
    property string seasonCurrentBvid: ""
    property bool _animating: false
    property real rankingPageX: 0
    property bool restoreRankingPageOnShow: false
    property real dynamicPageY: 0
    property bool restoreDynamicPageOnShow: false

    // 播放清晰度（由详情页选择）
    property int playQualitySelected: 16

    // 首页列表滚动位置缓存（仅从详情页返回时恢复）
    property real homePopularX: 0
    property real homeRankingX: 0
    property bool restoreHomePopularOnShow: false
    property bool restoreHomeRankingOnShow: false

    // SearchPage 搜索结果横向滚动位置（用于跨页面/跨销毁恢复）
    property real searchSavedResultX: 0

    // 详情页分P列表滚动位置缓存：key=bvid, value=contentX
    property var detailPartListXCache: ({})

    // 首页 Tab 记录（0=推荐,1=排行,3=我的）
    property int homeTabIndex: 0

    function stackContains(page) {
        for (var i = 0; i < pageStack.length; ++i) {
            var entry = pageStack[i]
            if (entry && entry.page === page) return true
        }
        return false
    }

    function capturePageProps(page) {
        if (page === "detail") {
            captureCurrentDetailSnapshot()
            return { bvid: detailBvid, sessionId: detailSessionId }
        }
        if (page === "comments") {
            return {
                bvid: commentsBvid || controller.videoBvid || detailBvid,
                oid: commentsOid,
                type: commentsType,
                key: commentsKey,
                title: commentsTitle
            }
        }
        if (page === "up") {
            return { mid: upUserMid, fromViewAid: upFromViewAid }
        }
        if (page === "dynamicDetail") {
            return { item: dynamicDetailData }
        }
        if (page === "season") {
            return {
                mid: seasonMid,
                seasonId: seasonId,
                title: seasonTitle,
                cover: seasonCover,
                total: seasonTotal,
                currentBvid: seasonCurrentBvid
            }
        }
        return {}
    }

    function applyPageProps(page, props) {
        if (!props) return
        if (page === "detail" && props.bvid) {
            detailSessionId = props.sessionId || nextDetailSessionId++
            detailBvid = props.bvid
        }
        if (page === "comments") {
            commentsBvid = (props && props.bvid) ? props.bvid : (controller.videoBvid || detailBvid)
            commentsOid = (props && props.oid) ? String(props.oid) : ""
            commentsType = (props && props.type) ? props.type : 1
            commentsKey = (props && props.key) ? props.key : ""
            commentsTitle = (props && props.title) ? props.title : ""
            if (commentsBvid && !commentsOid && controller && controller.video && controller.videoBvid !== commentsBvid) {
                controller.video.restoreCachedVideoDetail(commentsBvid)
            }
        }
        if (page === "up") {
            upUserMid = props.mid || 0
            upFromViewAid = props.fromViewAid || 0
        }
        if (page === "dynamicDetail") {
            dynamicDetailData = (props && props.item) ? props.item : ({})
        }
        if (page === "season") {
            seasonMid = props.mid || 0
            seasonId = props.seasonId || 0
            seasonTitle = props.title || ""
            seasonCover = props.cover || ""
            seasonTotal = props.total || 0
            seasonCurrentBvid = props.currentBvid || ""
        }
    }

    function pruneReportedDetailSessions() {
        var keep = ({})
        if (currentPage === "detail" && detailSessionId > 0) keep[detailSessionId] = true
        for (var i = 0; i < pageStack.length; ++i) {
            var entry = pageStack[i]
            if (entry && entry.page === "detail" && entry.props && entry.props.sessionId > 0) {
                keep[entry.props.sessionId] = true
            }
        }

        var nextReported = ({})
        var reported = reportedDetailSessions || ({})
        for (var id in reported) {
            if (keep[id]) nextReported[id] = reported[id]
        }
        reportedDetailSessions = nextReported
    }

    function captureCurrentDetailSnapshot() {
        if (currentPage !== "detail") return
        if (!controller || !controller.video || !controller.video.captureCurrentVideoDetail) return
        controller.video.captureCurrentVideoDetail()
    }

    function collectActiveDetailBvids() {
        var keep = ({})
        if (currentPage === "detail" && detailBvid && detailBvid.length > 0) {
            keep[detailBvid] = true
        }
        for (var i = 0; i < pageStack.length; ++i) {
            var entry = pageStack[i]
            if (entry && entry.page === "detail" && entry.props && entry.props.bvid) {
                keep[entry.props.bvid] = true
            }
        }
        return keep
    }

    function syncDetailCacheWithPageStack() {
        if (!controller || !controller.video) return
        var keep = collectActiveDetailBvids()
        var known = detailCacheBvids || ({})
        for (var bvid in known) {
            if (!keep[bvid] && controller.video.dropCachedVideoDetail) {
                controller.video.dropCachedVideoDetail(bvid)
            }
        }
        detailCacheBvids = keep
    }

    function navigateTo(page, props) {
        if (_animating) return;
        var newStack = pageStack.slice(0); // Create a copy
        newStack.push({
            page: currentPage,
            props: capturePageProps(currentPage)
        });
        console.log("[navigateTo] from=", currentPage, "to=", page, "stack=", JSON.stringify(newStack));
        pageStack = newStack; // Assign the new array
        lastPage = currentPage;
        applyPageProps(page, props || {})
        _animating = true;
        currentPage = page;
        pruneReportedDetailSessions()
        syncDetailCacheWithPageStack()
        pageTransition.restart();
    }

    function goBack() {
        if (_animating) return;
        captureCurrentDetailSnapshot()

        console.log("[goBack] currentPage=", currentPage,
                    "stack=", JSON.stringify(pageStack),
                    "lastPage=", lastPage,
                    "animating=", _animating);

        if (pageStack.length > 0) {
            var newStack = pageStack.slice(0); // Create a copy
            var prevEntry = newStack.pop();
            var prev = (prevEntry && prevEntry.page) ? prevEntry.page : prevEntry;
            var fromPage = currentPage;
            console.log("[goBack] pop prev=", prev, "newStack=", JSON.stringify(newStack));
            if (prevEntry && prevEntry.props) {
                applyPageProps(prev, prevEntry.props)
            }
            _animating = true;
            // 先切回目标页，再更新栈，避免依赖 stackContains(prev) 的 Loader
            // 在 currentPage 仍是旧页时被短暂销毁，导致子页面状态丢失。
            currentPage = prev;
            pageStack = newStack; // Assign the new array
            pruneReportedDetailSessions()
            syncDetailCacheWithPageStack()

            // 从详情页返回时恢复对应页面滚动位置
            if (fromPage === "detail" || fromPage === "dynamicDetail") {
                if (prev === "home") {
                    if (root.homeTabIndex === 0) {
                        restoreHomePopularOnShow = true;
                    } else if (root.homeTabIndex === 1) {
                        restoreHomeRankingOnShow = true;
                    }
                } else if (prev === "ranking") {
                    restoreRankingPageOnShow = true;
                } else if (prev === "dynamic") {
                    restoreDynamicPageOnShow = true;
                }
            }

            pageTransitionBack.restart();
        } else {
            console.log("[goBack] stack empty, currentPage=", currentPage);
            if (currentPage !== "home") {
                _animating = true;
                var fromPage2 = currentPage;
                currentPage = "home";
                lastPage = fromPage2;
                pruneReportedDetailSessions()
                syncDetailCacheWithPageStack()
                pageTransitionBack.restart();
                return;
            }
            // 只有在首页且没有任何弹层/页面跳转上下文时才允许退出插件
            if (currentPage === "home") {
                console.log("[goBack] triggering plugin exit");
                backButtonClicked();
            }
        }
    }

    // ── 页面切换动画容器 ──
    Item {
        id: pageContainer
        anchors.fill: parent
        opacity: 1
        transform: Translate { id: pageTranslate; x: 0 }

        SequentialAnimation {
            id: pageTransition
            ScriptAction {
                script: {
                    pageContainer.opacity = 1
                    pageTranslate.x = 12
                }
            }
            ParallelAnimation {
                NumberAnimation {
                    target: pageContainer; property: "opacity"
                    from: 0.96; to: 1; duration: Theme.animNormal
                    easing.type: Easing.OutQuad
                }
                NumberAnimation {
                    target: pageTranslate; property: "x"
                    from: 12; to: 0; duration: Theme.animNormal
                    easing.type: Easing.OutCubic
                }
            }
            onFinished: root._animating = false
        }

        SequentialAnimation {
            id: pageTransitionBack
            ScriptAction {
                script: {
                    pageContainer.opacity = 1
                    pageTranslate.x = -12
                }
            }
            ParallelAnimation {
                NumberAnimation {
                    target: pageContainer; property: "opacity"
                    from: 0.96; to: 1; duration: Theme.animNormal
                    easing.type: Easing.OutQuad
                }
                NumberAnimation {
                    target: pageTranslate; property: "x"
                    from: -12; to: 0; duration: Theme.animNormal
                    easing.type: Easing.OutCubic
                }
            }
            onFinished: root._animating = false
        }

        // ── 页面加载器 ──
        Loader {
            id: homeLoader
            asynchronous: true
            active: true
            visible: currentPage === "home"
            enabled: visible
            anchors.fill: parent
            sourceComponent: Component {
                Pages.HomePage {
                    id: homePage
                    controller: root.rootController
                    rootRef: root
                    initialTabIndex: root.homeTabIndex
                    onVideoSelected: {
                        if (!bvid || bvid.length < 2) return;
                        if (homeLoader.item) {
                            root.homePopularX = homeLoader.item.popularContentX();
                            root.homeRankingX = homeLoader.item.rankingContentX();
                            root.homeTabIndex = homeLoader.item.tabIndex;
                        }
                        Qt.callLater(function() {
                            root.navigateTo("detail", { bvid: bvid })
                        });
                    }
                    onSearchRequested: root.navigateTo("search")
                    onLoginRequested: root.navigateTo("user")
                    onRankingRequested: root.navigateTo("ranking")
                    onDynamicRequested: root.navigateTo("dynamic")
                    onBackButtonClicked: root.backButtonClicked()
                }
            }
        }

        Loader {
            id: searchLoader
            // 仅在“搜索页自身”或“从搜索页进入的下级页面(栈内仍包含 search)”时保持实例
            // 这样只有在真正退出搜索页（search 出栈）时才会销毁 SearchPage
            active: currentPage === "search" || root.stackContains("search")
            visible: currentPage === "search"
            enabled: visible
            anchors.fill: parent
            sourceComponent: Component {
                Pages.SearchPage {
                    controller: root.rootController
                    rootRef: root
                    onBackClicked: {
                        // 退出搜索页：清空结果，并清掉缓存的滚动位置
                        root.searchSavedResultX = 0
                        if (root.rootController && root.rootController.search) {
                            var model = root.rootController.search.searchModel()
                            if (model && model.clear) model.clear()
                        }
                        root.goBack();
                    }
                    onVideoSelected: {
                        if (!bvid || bvid.length < 2) return;
                        Qt.callLater(function() {
                            root.navigateTo("detail", { bvid: bvid })
                        });
                    }
                }
            }
        }

        Loader {
            id: detailLoader
            // 仅在“详情页自身”或“从详情页进入的下级页面(栈内仍包含detail)”时保持实例
            // 这样只有在从详情页返回(goBack 导致 detail 出栈)时才会销毁
            active: currentPage === "detail" || root.stackContains("detail")
            visible: currentPage === "detail"
            enabled: visible
            anchors.fill: parent
            sourceComponent: Component {
                Pages.VideoDetailPage {
                    controller: root.rootController
                    bvid: root.detailBvid
                    detailSessionId: root.detailSessionId
                    rootRef: root
                    onBackClicked: root.goBack()
                    onPlayRequested: {
                        root.playQualitySelected = quality;
                        root.navigateTo("player")
                    }
                    onCommentsRequested: root.navigateTo("comments", { bvid: root.detailBvid || controller.videoBvid })
                    onUpRequested: {
                        if (mid > 0) root.navigateTo("up", { mid: mid, fromViewAid: aid });
                    }
                    onSeasonRequested: {
                        if (props && props.seasonId > 0) root.navigateTo("season", props)
                    }
                    onVideoSelected: {
                        if (bvid) root.navigateTo("detail", { bvid: bvid })
                    }
                }
            }
        }

        Loader {
            active: currentPage === "player"
            visible: currentPage === "player"
            enabled: visible
            anchors.fill: parent
            sourceComponent: Component {
                Pages.PlayerPage {
                    controller: root.rootController
                    playQuality: root.playQualitySelected
                    onBackClicked: root.goBack()
                }
            }
        }

        Loader {
            active: currentPage === "comments" || root.stackContains("comments")
            visible: currentPage === "comments"
            enabled: visible
            anchors.fill: parent
            sourceComponent: Component {
                Pages.CommentsPage {
                    controller: root.rootController
                    contextBvid: root.commentsBvid
                    contextOid: root.commentsOid
                    contextType: root.commentsType
                    contextKey: root.commentsKey
                    contextTitle: root.commentsTitle
                    onBackClicked: root.goBack()
                }
            }
        }

        Loader {
            id: rankingLoader
            // 在排行榜页或从排行榜进入详情页时保持实例
            active: currentPage === "ranking" || root.stackContains("ranking")
            visible: currentPage === "ranking"
            enabled: visible
            anchors.fill: parent
            sourceComponent: Component {
                Pages.RankingPage {
                    controller: root.rootController
                    rootRef: root
                    onBackClicked: root.goBack()
                    onVideoSelected: {
                        if (!bvid || bvid.length < 2) return;
                        if (rankingLoader.item) {
                            root.rankingPageX = rankingLoader.item.contentXValue();
                        }
                        Qt.callLater(function() {
                            root.navigateTo("detail", { bvid: bvid })
                        });
                    }
                }
            }
        }

        Loader {
            id: dynamicLoader
            active: currentPage === "dynamic" || root.stackContains("dynamic")
            visible: currentPage === "dynamic"
            enabled: visible
            anchors.fill: parent
            sourceComponent: Component {
                Pages.DynamicPage {
                    controller: root.rootController
                    rootRef: root
                    onBackClicked: root.goBack()
                    onVideoSelected: {
                        if (!bvid || bvid.length < 2) return;
                        if (dynamicLoader.item) {
                            root.dynamicPageY = dynamicLoader.item.contentYValue();
                        }
                        Qt.callLater(function() {
                            root.navigateTo("detail", { bvid: bvid })
                        });
                    }
                    onDynamicSelected: {
                        if (dynamicLoader.item) {
                            root.dynamicPageY = dynamicLoader.item.contentYValue();
                        }
                        Qt.callLater(function() {
                            root.navigateTo("dynamicDetail", { item: dynamicData || ({}) })
                        });
                    }
                }
            }
        }

        Loader {
            id: dynamicDetailLoader
            active: currentPage === "dynamicDetail" || root.stackContains("dynamicDetail")
            visible: currentPage === "dynamicDetail"
            enabled: visible
            anchors.fill: parent
            sourceComponent: Component {
                Pages.DynamicDetailPage {
                    controller: root.rootController
                    dynamicData: root.dynamicDetailData
                    onBackClicked: root.goBack()
                    onVideoSelected: {
                        if (!bvid || bvid.length < 2) return
                        root.navigateTo("detail", { bvid: bvid })
                    }
                    onUpRequested: {
                        if (mid > 0) root.navigateTo("up", { mid: mid, fromViewAid: 0 })
                    }
                    onCommentsRequested: {
                        if (context && String(context.oid || "").length > 0
                                && context.oid !== "0" && context.type > 0) {
                            root.navigateTo("comments", context)
                        } else {
                            controller.toastMessage("暂不支持查看该动态评论")
                        }
                    }
                }
            }
        }

        Loader {
            // 仅在用户页或从用户页进入详情时保持实例
            active: currentPage === "user" || root.stackContains("user")
            visible: currentPage === "user"
            enabled: visible
            anchors.fill: parent
            sourceComponent: Component {
                Pages.UserPage {
                    controller: root.rootController
                    onBackClicked: root.goBack()
                    onVideoSelected: {
                        if (!bvid || bvid.length < 2) return;
                        Qt.callLater(function() {
                            root.navigateTo("detail", { bvid: bvid })
                        });
                    }
                    onWatchLaterRequested: root.navigateTo("watchLater")
                }
            }
        }

        Loader {
            active: currentPage === "watchLater" || root.stackContains("watchLater")
            visible: currentPage === "watchLater"
            enabled: visible
            anchors.fill: parent
            sourceComponent: Component {
                Pages.WatchLaterPage {
                    controller: root.rootController
                    rootRef: root
                    onBackClicked: root.goBack()
                    onVideoSelected: {
                        if (!bvid || bvid.length < 2) return;
                        Qt.callLater(function() {
                            root.navigateTo("detail", { bvid: bvid })
                        });
                    }
                }
            }
        }

        Loader {
            active: currentPage === "up" || root.stackContains("up")
            visible: currentPage === "up"
            enabled: visible
            anchors.fill: parent
            sourceComponent: Component {
                Pages.UpUserPage {
                    controller: root.rootController
                    rootRef: root
                    upMid: root.upUserMid
                    upFromViewAid: root.upFromViewAid
                    onBackClicked: root.goBack()
                    onVideoSelected: {
                        if (!bvid || bvid.length < 2) return;
                        Qt.callLater(function() {
                            root.navigateTo("detail", { bvid: bvid })
                        });
                    }
                }
            }
        }

        Loader {
            id: seasonPageLoader
            active: currentPage === "season" || root.stackContains("season")
            visible: currentPage === "season"
            enabled: visible
            anchors.fill: parent
            sourceComponent: Component {
                Pages.VideoSeasonPage {
                    controller: root.rootController
                    seasonMid: root.seasonMid
                    seasonId: root.seasonId
                    seasonTitle: root.seasonTitle
                    seasonCover: root.seasonCover
                    seasonTotal: root.seasonTotal
                    currentBvid: root.seasonCurrentBvid
                    onBackClicked: root.goBack()
                    onVideoSelected: {
                        if (!bvid || bvid.length < 2) return;
                        Qt.callLater(function() {
                            root.navigateTo("detail", { bvid: bvid })
                        });
                    }
                }
            }
        }
    }

    // ── 全局错误遮罩 ──
    Components.ErrorOverlay {
        anchors.fill: parent
        errorMessage: controller.globalError
        onRetryClicked: {
            controller.clearError();
            if (currentPage === "home") controller.feed.fetchPopular();
            else if (currentPage === "dynamic") controller.feed.fetchDynamic("all");
            else if (currentPage === "detail") controller.video.fetchVideoDetail(root.detailBvid);
            else if (currentPage === "season") controller.season.fetchSeasonVideos(
                root.seasonMid, root.seasonId, 1, 30,
                seasonPageLoader.item ? seasonPageLoader.item.seasonSortOldestFirst : false);
        }
        onDismissed: controller.clearError()
    }

    // ── Toast ──
    Components.Toast {
        id: globalToast
    }

    Timer {
        id: loginSuccessTimer
        interval: 3000  // 等待 3 秒，让用户信息完全加载并保存
        running: false
        onTriggered: {
            if (controller && controller.loggedIn && root.currentPage === "user") {
                console.log("[UserPage] Timer expired, going back to home");
                root.goBack();
            }
        }
    }

    Connections {
        target: controller
        function onToastMessage(message) { globalToast.show(message); }
        function onQrcodeLoginSuccess() {
            console.log("[UserPage] QR login success, waiting for user info...");
            globalToast.show("登录成功！🎉", 3000);
            // 延迟返回，等待 checkLoginStatus() 回调更新用户信息
            loginSuccessTimer.start();
        }
        function onQrcodeNeedRefresh() {
            globalToast.show("二维码已过期，请重新获取", 2500);
        }
        function onLoginStateChanged() {
            console.log("[UserPage] loginStateChanged:", controller.loggedIn, "userName:", controller.userName);
        }
    }

    Connections {
        target: controller && controller.video ? controller.video : null
        function onVideoLinkResolved(bvid) {
            if (!bvid || bvid.length < 2) return
            if (root.currentPage === "detail" && bvid === root.detailBvid) return
            if (root.currentPage === "comments" && bvid === root.detailBvid) {
                root.goBack()
                return
            }
            root.navigateTo("detail", { bvid: bvid })
        }
    }

    Component.onCompleted: {
        console.log("=== BiliPlugin Loaded ===", width, "x", height);
    }
}
