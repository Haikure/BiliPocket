import QtQuick 2.12
import QtGraphicalEffects 1.12
import BiliPlugin 1.0
import "../components" as Components
import ".."

Rectangle {
    id: commentsPage
    width: 320
    height: 170
    color: Theme.bgPrimary

    // 字体清晰度：在小字号+深色背景下，NativeRendering+强 Hinting 容易出现横竖笔画粗细不一致。
    // 这里统一改为 QtRendering 并关闭 Hinting，让抗锯齿更均匀。
    readonly property int _textRenderType: Text.QtRendering
    readonly property int _hinting: Font.PreferNoHinting
    readonly property bool _textAA: true
    readonly property int _commentBodyFontSize: Theme.fontBody + 2
    readonly property color _pageTopGlow: "#18283b"
    readonly property color _pageBottomGlow: "#1a1320"
    readonly property color _panelFill: "#171b22"
    readonly property color _panelBorder: "#2a313d"
    readonly property color _cardFill: "#1b212a"
    readonly property color _cardFillStrong: "#202734"
    readonly property color _chipFill: "#222b37"
    readonly property color _mutedText: "#7f8a9a"
    readonly property int _headerHeight: 30
    readonly property int _metaStripHeight: 22
    readonly property int _commentPictureWidth: 96
    readonly property int _commentPictureHeight: 51

    property var controller: null
    property string contextBvid: ""
    property var contextOid: 0
    property int contextType: 1
    property string contextKey: ""
    property string contextTitle: ""
    property string loadedCommentsBvid: ""
    property int viewMode: 0 // 0=主评论列表,1=子评论详情
    property real mainCommentContentY: 0
    property var selectedComment: null
    property bool imageFullscreenVisible: false
    property string fullscreenImageUrl: ""
    property bool autoLoadingComments: false
    property bool autoLoadingReplies: false
    property bool commentLoadMoreCooling: false
    property bool replyLoadMoreCooling: false
    property bool initialCommentsRequested: false
    property bool commentsModelAttached: false
    property bool commentImagesDeferred: false
    property bool commentLoadingMaskVisible: false
    signal backClicked()

    function deferCommentImages() {
        commentImageResumeTimer.stop()
        commentImagesDeferred = true
    }

    function resumeCommentImagesSoon() {
        commentImageResumeTimer.restart()
    }

    Timer {
        id: commentImageResumeTimer
        interval: 120
        repeat: false
        onTriggered: commentsPage.commentImagesDeferred = false
    }

    Timer {
        id: commentLoadingMaskTimer
        interval: 320
        repeat: false
        onTriggered: commentsPage.commentLoadingMaskVisible = false
    }

    Timer {
        id: commentLoadMoreCooldownTimer
        interval: 650
        repeat: false
        onTriggered: commentsPage.commentLoadMoreCooling = false
    }

    Timer {
        id: replyLoadMoreCooldownTimer
        interval: 650
        repeat: false
        onTriggered: commentsPage.replyLoadMoreCooling = false
    }

    function showCommentLoadingMask() {
        commentLoadingMaskTimer.stop()
        commentLoadingMaskVisible = true
    }

    function hideCommentLoadingMaskSoon() {
        Qt.callLater(function() {
            Qt.callLater(function() {
                Qt.callLater(function() {
                    commentLoadingMaskTimer.restart()
                })
            })
        })
    }

    function currentContextBvid() {
        if (contextBvid && contextBvid.length > 0) return contextBvid
        return controller ? (controller.videoBvid || "") : ""
    }

    function currentCommentOid() {
        var oid = String(contextOid || "").trim()
        if (oid.length > 0 && oid !== "0") return oid
        return controller ? String(controller.videoAid || 0) : ""
    }

    function currentCommentType() {
        var typ = Number(contextType || 0)
        return typ > 0 ? typ : 1
    }

    function currentCommentKey() {
        if (contextKey && contextKey.length > 0) return contextKey
        var bvid = currentContextBvid()
        if (bvid && bvid.length > 0) return bvid
        var oid = currentCommentOid()
        var typ = currentCommentType()
        return hasValidCommentOid(oid) ? "comment:" + typ + ":" + oid : ""
    }

    function hasValidCommentOid(oid) {
        return oid && oid.length > 0 && oid !== "0"
    }

    function syncCommentContext() {
        var key = currentCommentKey()
        if (!key || key.length === 0) return false
        if (loadedCommentsBvid === key) return true

        viewMode = 0
        selectedComment = null
        mainCommentContentY = 0
        autoLoadingComments = false
        autoLoadingReplies = false
        commentLoadMoreCooling = false
        replyLoadMoreCooling = false
        initialCommentsRequested = false
        commentsModelAttached = false
        commentLoadingMaskVisible = false
        loadedCommentsBvid = key
        return true
    }

    function queueInitialCommentsIfNeeded() {
        if (!syncCommentContext()) return
        if (initialCommentsRequested && controller && !hasReusableCurrentComments()) {
            var cm = controller.comments.commentModel()
            if (!cm || (!cm.loading && cm.count === 0)) {
                initialCommentsRequested = false
                commentsModelAttached = false
            }
        }
        if (initialCommentsRequested) return
        showInitialCommentLoadingIfNeeded()
        initialCommentsTimer.restart()
    }

    function hasReusableCurrentComments() {
        if (!controller || !controller.comments) return false
        if (controller.comments.commentsReadyForContext) {
            return controller.comments.commentsReadyForContext(currentCommentKey())
        }
        return !!controller.comments.commentsReady
    }

    function showInitialCommentLoadingIfNeeded() {
        if (!controller || viewMode !== 0 || initialCommentsRequested) return
        if (!hasValidCommentOid(currentCommentOid()) || currentCommentType() <= 0) return
        if (controller.videoDetailPreloadEnabled || hasReusableCurrentComments()) return
        showCommentLoadingMask()
    }

    function updateCommentLoadingMask() {
        if (viewMode !== 0) {
            commentLoadingMaskVisible = false
            return
        }
        if (hasReusableCurrentComments()) {
            commentLoadingMaskVisible = false
            return
        }
        var cm = controller ? controller.comments.commentModel() : null
        if ((!initialCommentsRequested && controller && !controller.videoDetailPreloadEnabled) ||
                (cm && cm.loading && commentList.count === 0)) {
            showCommentLoadingMask()
        } else {
            hideCommentLoadingMaskSoon()
        }
    }

    onViewModeChanged: updateCommentLoadingMask()
    onControllerChanged: queueInitialCommentsIfNeeded()
    onContextBvidChanged: {
        if (visible) queueInitialCommentsIfNeeded()
    }
    onContextOidChanged: {
        if (visible) queueInitialCommentsIfNeeded()
    }
    onContextTypeChanged: {
        if (visible) queueInitialCommentsIfNeeded()
    }
    onContextKeyChanged: {
        if (visible) queueInitialCommentsIfNeeded()
    }

    function requestInitialComments() {
        if (!controller || initialCommentsRequested) return
        var oid = currentCommentOid()
        var typ = currentCommentType()
        var key = currentCommentKey()
        if (!hasValidCommentOid(oid) || typ <= 0 || key.length === 0) return
        initialCommentsRequested = true
        commentsModelAttached = true
        if (hasReusableCurrentComments()) {
            commentLoadingMaskVisible = false
            return
        }
        showCommentLoadingMask()
        if (controller.comments.fetchCommentsForContext) {
            controller.comments.fetchCommentsForContext(oid, typ, key, 1, false)
        } else {
            controller.comments.fetchComments()
        }
        updateCommentLoadingMask()
    }

    Timer {
        id: initialCommentsTimer
        interval: 50
        repeat: false
        onTriggered: commentsPage.requestInitialComments()
    }

    function openCommentDetail(commentObj) {
        selectedComment = commentObj
        mainCommentContentY = commentList.contentY
        viewMode = 1
        if (controller && controller.comments.fetchCommentRepliesForContext) {
            controller.comments.fetchCommentRepliesForContext(currentCommentOid(), currentCommentType(),
                                                              currentCommentKey(), commentObj.rpid)
        } else if (controller) {
            controller.comments.fetchCommentReplies(commentObj.rpid)
        }
    }

    function toggleCommentLike(rpid, liked) {
        if (!controller || !controller.comments || !controller.comments.toggleCommentLike) return
        controller.comments.toggleCommentLike(currentCommentOid(), currentCommentType(),
                                              Number(rpid || 0), !!liked)
    }

    function commentImageSource(url) {
        if (!url) return ""
        if (url.indexOf("data:image/") === 0) return url
        return "image://bili/original/" + encodeURIComponent(url)
    }

    function commentThumbSource(url) {
        if (!url) return ""
        if (url.indexOf("data:image/") === 0) return url
        return "image://bili/" + encodeURIComponent(url)
    }

    function avatarImageSource(url) {
        if (!url) return ""
        if (url.indexOf("data:image/") === 0) return url
        var s = String(url)
        var queryIndex = s.indexOf("?")
        var base = queryIndex >= 0 ? s.slice(0, queryIndex) : s
        var query = queryIndex >= 0 ? s.slice(queryIndex) : ""
        if (base.indexOf("@") < 0) s = base + "@50w_50h" + query
        return "image://bili/" + encodeURIComponent(s)
    }

    function escapeCommentRichText(text) {
        if (!text) return ""
        var s = String(text)
        s = s.replace(/&/g, "&amp;")
        s = s.replace(/</g, "&lt;")
        s = s.replace(/>/g, "&gt;")
        return s
    }

    function escapeHtmlAttribute(text) {
        if (!text) return ""
        var s = String(text)
        s = s.replace(/&/g, "&amp;")
        s = s.replace(/"/g, "&quot;")
        s = s.replace(/</g, "&lt;")
        s = s.replace(/>/g, "&gt;")
        return s
    }

    function videoLinkAnchor(token) {
        return "<a href=\"" + escapeHtmlAttribute(token) + "\" style=\"color:#60a5fa;text-decoration:none;\">" +
                escapeCommentRichText(token) + "</a>"
    }

    function isCommentVideoLinkToken(token) {
        if (!token) return false
        return /^(?:https?:\/\/)?(?:[Ww][Ww][Ww]\.)?[Bb]23\.[Tt][Vv]\/[0-9A-Za-z]+$/.test(token) ||
                /^[Bb][Vv]1[1-9A-HJ-NP-Za-km-z]{9}$/.test(token)
    }

    function openVideoLink(link) {
        if (!link || !controller || !controller.video || !controller.video.resolveVideoLink) return
        controller.video.resolveVideoLink(link)
    }

    function normalizeCommentEmoteUrl(url) {
        if (!url) return ""
        var s = String(url)
        if (s.indexOf("//") === 0) {
            s = "https:" + s
        } else if (s.indexOf("http://") === 0) {
            s = "https://" + s.slice(7)
        }

        if (s.indexOf("/bfs/emote/") < 0) return s

        var queryIndex = s.indexOf("?")
        var base = queryIndex >= 0 ? s.slice(0, queryIndex) : s
        var query = queryIndex >= 0 ? s.slice(queryIndex) : ""
        if (base.indexOf("@") >= 0) return s
        return base + "@80w_80h" + query
    }

    function findCommentEmote(emotes, token) {
        if (!emotes || !token) return null
        if (emotes[token]) return emotes[token]
        if (token.length > 2 && token.charAt(0) === "[" && token.charAt(token.length - 1) === "]") {
            var bare = token.slice(1, -1)
            if (emotes[bare]) return emotes[bare]
        }
        return null
    }

    function commentEmoteDisplaySize(emote) {
        var base = Number(commentsPage._commentBodyFontSize || Theme.fontBody)
        var metaSize = Number(emote && emote.size ? emote.size : 1)
        var scale = metaSize >= 2 ? 1.35 : 1.15
        var size = Math.round(base * scale)
        var minSize = base
        var maxSize = base + 5
        return Math.max(minSize, Math.min(size, maxSize))
    }

    function commentRichText(content, emotes) {
        var raw = content && content.length > 0 ? String(content) : ""
        if (!raw) return ""

        raw = raw.replace(/\r\n/g, "\n").replace(/\r/g, "\n")
        var tokenPattern = /(?:https?:\/\/)?(?:[Ww][Ww][Ww]\.)?[Bb]23\.[Tt][Vv]\/[0-9A-Za-z]+|[Bb][Vv]1[1-9A-HJ-NP-Za-km-z]{9}|\[[^\[\]\r\n]{1,40}\]/g
        var rich = ""
        var lastIndex = 0
        var match

        while ((match = tokenPattern.exec(raw)) !== null) {
            var start = match.index
            var token = match[0]
            rich += escapeCommentRichText(raw.slice(lastIndex, start))

            if (commentsPage.isCommentVideoLinkToken(token)) {
                rich += commentsPage.videoLinkAnchor(token)
            } else {
                var emote = commentsPage.findCommentEmote(emotes, token)
                if (!emote || !emote.url) {
                    rich += escapeCommentRichText(token)
                } else {
                    var size = commentsPage.commentEmoteDisplaySize(emote)
                    var src = commentsPage.escapeHtmlAttribute(commentsPage.normalizeCommentEmoteUrl(emote.url))
                    var alt = commentsPage.escapeHtmlAttribute(token)
                    rich += "<img src=\"" + src + "\" width=\"" + size + "\" height=\"" + size + "\" alt=\"" + alt + "\" />"
                }
            }

            lastIndex = start + token.length
        }

        rich += escapeCommentRichText(raw.slice(lastIndex))
        return rich.replace(/\n/g, "<br>")
    }

    function firstPicture(pictures) {
        if (!pictures || pictures.length === 0) return ""
        return pictures[0] || ""
    }

    function compactCount(value) {
        var n = Number(value || 0)
        if (n <= 0) return ""
        if (n >= 10000) return (n / 10000.0).toFixed(n >= 100000 ? 0 : 1) + "w"
        if (n >= 1000) return (n / 1000.0).toFixed(n >= 10000 ? 0 : 1) + "k"
        return n.toString()
    }

    function levelAccent(level) {
        switch (Number(level || 0)) {
        case 1: return "#60a5fa"
        case 2: return "#34d399"
        case 3: return "#f59e0b"
        case 4: return "#fb7185"
        case 5: return "#a78bfa"
        case 6: return "#f472b6"
        default: return Theme.primary
        }
    }

    function isOwner(mid) {
        return controller && mid && controller.videoOwnerMid > 0 && (Number(mid) === Number(controller.videoOwnerMid))
    }

    function openCommentImage(url) {
        if (!url) return
        if (controller) controller.toastMessage("正在打开图片...")
        // 系统 FileManagerImageViewer 只能打开本地文件；让 C++ 先下载到 /tmp 后发回本地路径。
        if (controller && typeof imageViewer !== "undefined" && imageViewer) {
            controller.viewer.prepareImageForViewer(url)
            return
        }
        // 兜底：宿主未注入 imageViewer 时使用旧预览。
        commentsPage.fullscreenImageUrl = url
        commentsPage.imageFullscreenVisible = !!commentsPage.fullscreenImageUrl
    }

    function openSystemImageViewer(localPath) {
        if (!localPath) return
        if (typeof imageViewer !== "undefined" && imageViewer) {
            imageViewer.open(localPath)
            id_pop_container.show("qrc:/qml/audiopages/FileManagerImageViewer.qml")
        } else {
            commentsPage.fullscreenImageUrl = localPath
            commentsPage.imageFullscreenVisible = true
        }
    }

    function internalBack() {
        if (imageFullscreenVisible) {
            imageFullscreenVisible = false
            fullscreenImageUrl = ""
            return
        }
        if (viewMode === 1) {
            viewMode = 0
            Qt.callLater(function() {
                commentList.contentY = mainCommentContentY
            })
            return
        }
        commentsPage.backClicked()
    }

    function requestMoreCommentsIfNeeded() {
        if (!controller || viewMode !== 0) return
        var cm = controller.comments.commentModel()
        if (!cm || cm.loading || autoLoadingComments || commentLoadMoreCooling || commentList.count <= 0) return
        if (commentList.contentHeight <= commentList.height) return
        autoLoadingComments = true
        commentLoadMoreCooling = true
        commentLoadMoreCooldownTimer.restart()
        if (controller.comments.fetchMoreCommentsForContext) {
            controller.comments.fetchMoreCommentsForContext(currentCommentOid(), currentCommentType(),
                                                            currentCommentKey())
        } else {
            controller.comments.fetchMoreComments()
        }
    }

    function requestMoreRepliesIfNeeded() {
        if (!controller || viewMode !== 1 || !controller.comments.replyHasMore) return
        var rm = controller.comments.commentReplyModel()
        if (!rm || rm.loading || autoLoadingReplies || replyLoadMoreCooling || rm.count <= 0) return
        // 内容未撑满视口时无法滚动触底，仍应继续拉取下一页。
        autoLoadingReplies = true
        replyLoadMoreCooling = true
        replyLoadMoreCooldownTimer.restart()
        if (controller.comments.fetchMoreCommentRepliesForContext) {
            controller.comments.fetchMoreCommentRepliesForContext(currentCommentOid(), currentCommentType(),
                                                                  currentCommentKey())
        } else {
            controller.comments.fetchMoreCommentReplies()
        }
    }

    function maybeAutoLoadMoreReplies() {
        if (viewMode !== 1) return
        if (!controller || !controller.comments.replyHasMore) return
        var rm = controller.comments.commentReplyModel()
        if (!rm || rm.loading || rm.count <= 0) return
        if (replyDetailFlick.contentHeight <= replyDetailFlick.height + 2
                || replyDetailFlick.contentY + replyDetailFlick.height >= replyDetailFlick.contentHeight - 18) {
            requestMoreRepliesIfNeeded()
        }
    }

    function isAnyCommentLoading() {
        if (!controller) return false
        var cm = controller.comments.commentModel()
        var rm = controller.comments.commentReplyModel()
        return (cm && cm.loading) || (rm && rm.loading)
    }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#0b1017" }
            GradientStop { position: 0.55; color: "#0f151d" }
            GradientStop { position: 1.0; color: "#0c1118" }
        }
    }

    Rectangle {
        width: 110
        height: 60
        radius: 30
        anchors.right: parent.right
        anchors.rightMargin: -28
        anchors.bottom: parent.bottom
        anchors.bottomMargin: -18
        color: Theme.withAlpha(_pageBottomGlow, 0.55)
    }

    Item {
        id: headerWrap
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 28
        z: 20

        Rectangle {
            id: backButton
            width: 20
            height: 20
            radius: 10
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.top: parent.top
            anchors.topMargin: 4
            color: backButtonArea.pressed ? Theme.withAlpha(Theme.primary, 0.26) : Theme.withAlpha(_panelFill, 0.88)
            border.color: Theme.withAlpha(Theme.primary, backButtonArea.pressed ? 0.32 : 0.16)
            border.width: 1

            Text {
                anchors.centerIn: parent
                text: "‹"
                color: Theme.primary
                font.pixelSize: Theme.fontLarge
                font.bold: true
            }

            MouseArea {
                id: backButtonArea
                anchors.fill: parent
                anchors.margins: -8
                onClicked: commentsPage.internalBack()
            }
        }

        Rectangle {
            id: titleChip
            anchors.left: backButton.right
            anchors.leftMargin: 6
            anchors.top: parent.top
            anchors.topMargin: 4
            height: 20
            width: titleText.implicitWidth + 12
            radius: 10
            color: Theme.withAlpha(_panelFill, 0.9)
            border.color: Theme.withAlpha(_panelBorder, 0.82)
            border.width: 1

            Text {
                id: titleText
                anchors.centerIn: parent
                text: viewMode === 1 ? "评论详情" : "评论区"
                color: Theme.textPrimary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontMedium
                font.bold: true
                renderType: commentsPage._textRenderType
                font.hintingPreference: commentsPage._hinting
                antialiasing: commentsPage._textAA
            }
        }

        Rectangle {
            id: headerCountChip
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.top: parent.top
            anchors.topMargin: 6
            width: headerCountText.implicitWidth + 12
            height: 15
            radius: 8
            color: Theme.withAlpha(Theme.primary, 0.14)
            border.color: Theme.withAlpha(Theme.primary, 0.22)
            border.width: 1

            Text {
                id: headerCountText
                anchors.centerIn: parent
                text: {
                    if (viewMode === 1) {
                        var totalReplies = selectedComment ? Number(selectedComment.rcount || 0) : 0
                        var rm = controller ? controller.comments.commentReplyModel() : null
                        var apiTotal = rm && rm.totalCount ? Number(rm.totalCount) : 0
                        var loaded = rm ? rm.count : 0
                        // 主评论 rcount > 接口 totalCount > 已加载数
                        var n = totalReplies > 0 ? totalReplies : (apiTotal > 0 ? apiTotal : loaded)
                        return n + " 条回复"
                    }
                    var cm = controller ? controller.comments.commentModel() : null
                    var total = cm ? cm.totalCount : 0
                    return (total > 0 ? total : 0) + " 条评论"
                }
                color: Theme.primaryLight
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontTiny
                font.bold: true
                renderType: commentsPage._textRenderType
                font.hintingPreference: commentsPage._hinting
                antialiasing: commentsPage._textAA
            }
        }

        Rectangle {
            id: metaStrip
            anchors.top: backButton.bottom
            anchors.topMargin: Theme.spacingSmall
            anchors.left: titleChip.left
            anchors.right: parent.right
            anchors.rightMargin: 8
            height: 0
            radius: 11
            color: "transparent"
            border.width: 0
            visible: false
        }
    }

    ListView {
        id: commentList
        anchors.top: headerWrap.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        anchors.bottomMargin: 4
        model: controller && commentsPage.commentsModelAttached ? controller.comments.commentModel() : null
        spacing: 5
        clip: true
        cacheBuffer: 360
        displayMarginBeginning: 120
        displayMarginEnd: 240
        visible: viewMode === 0
        onMovementStarted: commentsPage.deferCommentImages()
        onFlickStarted: commentsPage.deferCommentImages()
        onFlickEnded: commentsPage.resumeCommentImagesSoon()
        onMovementEnded: {
            commentsPage.resumeCommentImagesSoon()
            if (contentY + height >= contentHeight - 18) {
                commentsPage.requestMoreCommentsIfNeeded()
            }
        }
        onCountChanged: commentsPage.updateCommentLoadingMask()

        delegate: Rectangle {
            id: commentDelegate
            property bool pinned: (typeof isTop !== "undefined" && !!isTop)
                                  || (typeof is_top !== "undefined" && !!is_top)
                                  || (!!model && !!model.isTop)
                                  || (!!model && !!model.is_top)
            property bool maybeHasPicture: !!(model.pictures && model.pictures.length > 0)
            property string cachedAvatarSource: model.avatar ? commentsPage.avatarImageSource(model.avatar) : ""
            property bool bodyExpanded: false
            property string cachedPictureUrl: commentsPage.firstPicture(model.pictures)
            property string cachedPictureSource: cachedPictureUrl ? commentsPage.commentThumbSource(cachedPictureUrl) : ""
            property bool liked: !!model.liked

            width: commentList.width
            height: realContentLoader.item ? realContentLoader.item.height + 7 : 69
            radius: 12
            color: pinned ? Theme.withAlpha(_cardFillStrong, 0.98) : Theme.withAlpha(_cardFill, 0.98)
            border.color: pinned ? Theme.withAlpha(Theme.primary, 0.34) : Theme.withAlpha(_panelBorder, 0.9)
            border.width: 1

            Loader {
                id: realContentLoader
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: 6
                anchors.rightMargin: 6
                anchors.topMargin: 6
                asynchronous: false
                active: true
                sourceComponent: realCommentComponent
            }

            Component {
                id: realCommentComponent

                Item {
                    width: realContentLoader.width
                    height: realRow.height

                    Row {
                        id: realRow
                        width: parent.width
                        spacing: 6

                        Rectangle {
                            width: 22
                            height: 22
                            radius: 11
                            color: Theme.bgTertiary


                            Image {
                                id: commentAvatarImage
                                anchors.fill: parent
                                source: commentDelegate.cachedAvatarSource
                                sourceSize: Qt.size(44, 44)
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                smooth: true
                                mipmap: true
                                visible: false
                            }

                            OpacityMask {
                                anchors.fill: commentAvatarImage
                                source: commentAvatarImage
                                opacity: commentAvatarImage.status === Image.Ready ? 1 : 0
                                maskSource: Rectangle {
                                    width: commentAvatarImage.width
                                    height: commentAvatarImage.height
                                    radius: Math.min(width, height) / 2
                                    visible: false
                                }
                            }
                        }

                        Column {
                            id: commentBodyColumn
                            width: parent.width - 28
                            spacing: 4

                            Row {
                                width: parent.width
                                spacing: 4

                                Text {
                                    width: Math.min(90, implicitWidth)
                                    text: model.userName || ""
                                    color: model.isVip ? Theme.accent : Theme.textPrimary
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontBody
                                    font.bold: true
                                    elide: Text.ElideRight
                                    renderType: commentsPage._textRenderType
                                    font.hintingPreference: commentsPage._hinting
                                    antialiasing: commentsPage._textAA
                                }

                                Rectangle {
                                    visible: commentsPage.isOwner(model.mid)
                                    width: ownerTagText.implicitWidth + 8
                                    height: 12
                                    radius: 6
                                    color: Theme.withAlpha(Theme.accent, 0.18)
                                    border.color: Theme.withAlpha(Theme.accent, 0.28)
                                    border.width: 1

                                    Text {
                                        id: ownerTagText
                                        anchors.centerIn: parent
                                        text: "UP"
                                        color: Theme.accent
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 7
                                        font.bold: true
                                    }
                                }

                                Rectangle {
                                    visible: (model.level || 0) > 0
                                    width: levelText.implicitWidth + 8
                                    height: 12
                                    radius: 6
                                    color: Theme.withAlpha(commentsPage.levelAccent(model.level || 0), 0.16)
                                    border.color: Theme.withAlpha(commentsPage.levelAccent(model.level || 0), 0.30)
                                    border.width: 1

                                    Text {
                                        id: levelText
                                        anchors.centerIn: parent
                                        text: "Lv" + (model.level || 0)
                                        color: commentsPage.levelAccent(model.level || 0)
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 7
                                        font.bold: true
                                    }
                                }

                                Rectangle {
                                    visible: commentDelegate.pinned
                                    width: topTagText.implicitWidth + 10
                                    height: 13
                                    radius: 6
                                    color: Qt.rgba(0.23, 0.51, 0.96, 0.18)
                                    border.color: Qt.rgba(0.38, 0.70, 1.0, 0.36)
                                    border.width: 1

                                    Text {
                                        id: topTagText
                                        anchors.centerIn: parent
                                        text: "TOP"
                                        color: "#93c5fd"
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 7
                                        font.bold: true
                                    }
                                }
                            }

                            Text {
                                width: parent.width
                                text: model.ctimeText || ""
                                color: _mutedText
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontTiny
                                elide: Text.ElideRight
                                renderType: commentsPage._textRenderType
                                font.hintingPreference: commentsPage._hinting
                                antialiasing: commentsPage._textAA
                            }

                            Column {
                                id: commentBodyPreview
                                property string richContent: commentsPage.commentRichText(model.content || "", model.emotes || ({}))
                                property real previewHeight: Math.ceil(commentsPage._commentBodyFontSize * 1.22 * 5 + 2)
                                property bool hasMore: commentBodyMeasure.paintedHeight > previewHeight + 1
                                width: parent.width
                                spacing: 2

                                Text {
                                    id: commentBodyMeasure
                                    width: parent.width
                                    height: 0
                                    visible: false
                                    text: commentBodyPreview.richContent
                                    textFormat: Text.RichText
                                    font.family: Theme.fontFamily
                                    font.pixelSize: commentsPage._commentBodyFontSize
                                    wrapMode: Text.Wrap
                                    lineHeight: 1.22
                                    renderType: commentsPage._textRenderType
                                    font.hintingPreference: commentsPage._hinting
                                    antialiasing: commentsPage._textAA
                                }

                                Item {
                                    width: parent.width
                                    height: commentDelegate.bodyExpanded || !commentBodyPreview.hasMore
                                            ? commentBodyText.paintedHeight
                                            : commentBodyPreview.previewHeight
                                    clip: !commentDelegate.bodyExpanded && commentBodyPreview.hasMore

                                    Text {
                                        id: commentBodyText
                                        width: parent.width
                                        text: commentBodyPreview.richContent
                                        textFormat: Text.RichText
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: commentsPage._commentBodyFontSize
                                        wrapMode: Text.Wrap
                                        elide: Text.ElideNone
                                        lineHeight: 1.22
                                        linkColor: "#60a5fa"
                                        renderType: commentsPage._textRenderType
                                        font.hintingPreference: commentsPage._hinting
                                        antialiasing: commentsPage._textAA
                                        onLinkActivated: commentsPage.openVideoLink(link)
                                    }
                                }

                                Text {
                                    visible: commentBodyPreview.hasMore
                                    text: commentDelegate.bodyExpanded ? "收起" : "展开更多..."
                                    color: Theme.primaryLight
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontTiny
                                    font.bold: true
                                    renderType: commentsPage._textRenderType
                                    font.hintingPreference: commentsPage._hinting
                                    antialiasing: commentsPage._textAA

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -4
                                        onClicked: commentDelegate.bodyExpanded = !commentDelegate.bodyExpanded
                                    }
                                }
                            }

                            Row {
                                width: parent.width
                                spacing: 6

                                Rectangle {
                                    visible: !!commentDelegate.cachedPictureUrl
                                    width: commentsPage._commentPictureWidth
                                    height: commentsPage._commentPictureHeight
                                    radius: 8
                                    color: Theme.bgTertiary
                                    border.color: Theme.withAlpha(_panelBorder, 0.95)
                                    border.width: 1
                                    clip: true


                                    Image {
                                        id: commentPictureImage
                                        anchors.fill: parent
                                        source: commentDelegate.cachedPictureSource
                                        sourceSize: Qt.size(commentsPage._commentPictureWidth * 2, commentsPage._commentPictureHeight * 2)
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        smooth: false
                                        mipmap: false
                                        opacity: status === Image.Ready ? 1 : 0
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: commentsPage.openCommentImage(commentDelegate.cachedPictureUrl)
                                    }
                                }

                                Item {
                                    width: Math.max(0, parent.width - (commentDelegate.cachedPictureUrl ? commentsPage._commentPictureWidth + 6 : 0) - actionButtons.width)
                                    height: 1
                                }

                                Row {
                                    id: actionButtons
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    Rectangle {
                                        width: 30
                                        height: Theme.touchMinSize
                                        radius: Theme.radiusMedium
                                        color: likeArea.pressed ? Theme.withAlpha(Theme.primary, 0.15) : "transparent"

                                        Row {
                                            anchors.centerIn: parent
                                            spacing: 3

                                            Canvas {
                                                id: commentLikeIcon
                                                width: 11
                                                height: 11
                                                anchors.verticalCenter: parent.verticalCenter
                                                onPaint: {
                                                    var ctx = getContext("2d")
                                                    ctx.clearRect(0, 0, width, height)
                                                    ctx.strokeStyle = commentDelegate.liked ? Theme.primary : Theme.textTertiary
                                                    ctx.fillStyle = commentDelegate.liked ? Theme.primary : "transparent"
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
                                                    if (commentDelegate.liked) ctx.fill()
                                                    ctx.stroke()
                                                }
                                            }

                                            Connections {
                                                target: commentDelegate
                                                function onLikedChanged() { commentLikeIcon.requestPaint() }
                                            }

                                            Text {
                                                text: commentsPage.compactCount(model.likes || 0)
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontTiny
                                                color: commentDelegate.liked ? Theme.primary : Theme.textSecondary
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: text.length > 0
                                            }
                                        }

                                        MouseArea {
                                            id: likeArea
                                            anchors.fill: parent
                                            anchors.margins: -2
                                            onClicked: commentsPage.toggleCommentLike(model.rpid, model.liked)
                                        }
                                    }

                                    Rectangle {
                                        width: 32
                                        height: Theme.touchMinSize
                                        radius: Theme.radiusMedium
                                        color: replyArea.pressed ? Theme.withAlpha(Theme.primary, 0.15) : "transparent"

                                        Row {
                                            anchors.centerIn: parent
                                            spacing: 3

                                            Canvas {
                                                width: 11
                                                height: 11
                                                anchors.verticalCenter: parent.verticalCenter
                                                onPaint: {
                                                    var ctx = getContext("2d")
                                                    ctx.clearRect(0, 0, width, height)
                                                    ctx.strokeStyle = Theme.textTertiary
                                                    ctx.lineWidth = 1.3
                                                    ctx.lineCap = "round"
                                                    ctx.lineJoin = "round"
                                                    ctx.beginPath()
                                                    ctx.moveTo(2.5, 2.0)
                                                    ctx.lineTo(8.5, 2.0)
                                                    ctx.quadraticCurveTo(9.8, 2.0, 9.8, 3.3)
                                                    ctx.lineTo(9.8, 6.7)
                                                    ctx.quadraticCurveTo(9.8, 8.0, 8.5, 8.0)
                                                    ctx.lineTo(5.2, 8.0)
                                                    ctx.lineTo(3.2, 9.7)
                                                    ctx.lineTo(3.6, 8.0)
                                                    ctx.lineTo(2.5, 8.0)
                                                    ctx.quadraticCurveTo(1.2, 8.0, 1.2, 6.7)
                                                    ctx.lineTo(1.2, 3.3)
                                                    ctx.quadraticCurveTo(1.2, 2.0, 2.5, 2.0)
                                                    ctx.stroke()
                                                }
                                            }

                                            Text {
                                                text: commentsPage.compactCount(model.rcount || 0)
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontTiny
                                                color: Theme.textSecondary
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: text.length > 0
                                            }
                                        }

                                        MouseArea {
                                            id: replyArea
                                            anchors.fill: parent
                                            anchors.margins: -2
                                            onClicked: {
                                                commentsPage.openCommentDetail({
                                                    rpid: model.rpid || 0,
                                                    userName: model.userName || "",
                                                    avatar: model.avatar || "",
                                                    level: model.level || 0,
                                                    content: model.content || "",
                                                    emotes: model.emotes || ({}),
                                                    pictures: model.pictures || [],
                                                    likes: model.likes || 0,
                                                    liked: model.liked || false,
                                                    rcount: model.rcount || 0,
                                                    ctimeText: model.ctimeText || "",
                                                    isVip: model.isVip || false,
                                                    pinned: commentDelegate.pinned
                                                })
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        Column {
            visible: commentsPage.initialCommentsRequested && commentList.count === 0 && controller && !commentsPage.isAnyCommentLoading()
            anchors.centerIn: parent
            spacing: 2

            Text {
                text: "评论还没刷出来"
                color: Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontBody
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
                text: "稍后再试"
                color: Theme.textTertiary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontTiny
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    Item {
        anchors.top: headerWrap.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        anchors.bottomMargin: 4
        visible: viewMode === 1

        ListView {
            id: replyDetailFlick
            anchors.fill: parent
            clip: true
            boundsBehavior: Flickable.DragOverBounds
            cacheBuffer: 60
            spacing: 5
            model: controller ? controller.comments.commentReplyModel() : null

            onMovementStarted: commentsPage.deferCommentImages()
            onFlickStarted: commentsPage.deferCommentImages()
            onFlickEnded: {
                commentsPage.resumeCommentImagesSoon()
                if (atYEnd || contentY + height >= contentHeight - 18) {
                    commentsPage.requestMoreRepliesIfNeeded()
                }
            }
            onMovementEnded: {
                commentsPage.resumeCommentImagesSoon()
                if (atYEnd || contentY + height >= contentHeight - 18) {
                    commentsPage.requestMoreRepliesIfNeeded()
                }
            }
            onAtYEndChanged: {
                if (atYEnd) commentsPage.requestMoreRepliesIfNeeded()
            }
            onContentHeightChanged: {
                if (viewMode === 1) Qt.callLater(commentsPage.maybeAutoLoadMoreReplies)
            }
            onCountChanged: {
                if (viewMode === 1) Qt.callLater(commentsPage.maybeAutoLoadMoreReplies)
            }

            header: Column {
                width: replyDetailFlick.width
                spacing: 5

                Rectangle {
                    width: parent.width
                    height: detailHeaderColumn.height + 12
                    radius: 12
                    color: Theme.withAlpha(_cardFillStrong, 0.98)
                    border.color: Theme.withAlpha(Theme.primary, 0.24)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 6

                        Rectangle {
                            width: 24
                            height: 24
                            radius: 12
                            color: Theme.bgTertiary

                            Image {
                                id: detailAvatarImage
                                anchors.fill: parent
                                source: selectedComment && selectedComment.avatar
                                        ? commentsPage.avatarImageSource(selectedComment.avatar) : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                smooth: true
                                mipmap: true
                                visible: false
                            }

                            OpacityMask {
                                anchors.fill: detailAvatarImage
                                source: detailAvatarImage
                                maskSource: Rectangle {
                                    width: detailAvatarImage.width
                                    height: detailAvatarImage.height
                                    radius: Math.min(width, height) / 2
                                    visible: false
                                }
                            }
                        }

                        Column {
                            id: detailHeaderColumn
                            width: parent.width - 30
                            spacing: 4

                            Row {
                                width: parent.width
                                spacing: 4

                                Text {
                                    id: detailUserNameText
                                    width: Math.min(88, implicitWidth)
                                    text: selectedComment ? selectedComment.userName : ""
                                    color: selectedComment && selectedComment.isVip ? Theme.accent : Theme.textPrimary
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontBody
                                    font.bold: true
                                    elide: Text.ElideRight
                                    renderType: commentsPage._textRenderType
                                    font.hintingPreference: commentsPage._hinting
                                    antialiasing: commentsPage._textAA
                                }

                                Rectangle {
                                    id: detailTopTag
                                    visible: selectedComment && selectedComment.pinned
                                    width: detailTopTagText.implicitWidth + 10
                                    height: 13
                                    radius: 6
                                    color: Qt.rgba(0.23, 0.51, 0.96, 0.18)
                                    border.color: Qt.rgba(0.38, 0.70, 1.0, 0.36)
                                    border.width: 1

                                    Text {
                                        id: detailTopTagText
                                        anchors.centerIn: parent
                                        text: "TOP"
                                        color: "#93c5fd"
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 7
                                        font.bold: true
                                    }
                                }

                                Text {
                                    id: detailTimeText
                                    width: 50
                                    horizontalAlignment: Text.AlignRight
                                    text: selectedComment ? selectedComment.ctimeText : ""
                                    color: _mutedText
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontTiny
                                    renderType: commentsPage._textRenderType
                                    font.hintingPreference: commentsPage._hinting
                                    antialiasing: commentsPage._textAA
                                }

                                Item {
                                    width: Math.max(0, parent.width
                                                    - detailUserNameText.width
                                                    - (detailTopTag.visible ? detailTopTag.width : 0)
                                                    - detailTimeText.width
                                                    - detailLikeBadge.width
                                                    - (detailTopTag.visible ? 20 : 16))
                                    height: 1
                                }

                                Rectangle {
                                    id: detailLikeBadge
                                    width: detailLikeText.implicitWidth + 10
                                    height: 14
                                    radius: 7
                                    color: selectedComment && selectedComment.liked
                                           ? Theme.withAlpha(Theme.primary, 0.25)
                                           : Theme.withAlpha(Theme.primary, 0.12)
                                    border.color: Theme.withAlpha(Theme.primary, 0.2)
                                    border.width: 1

                                    Text {
                                        id: detailLikeText
                                        anchors.centerIn: parent
                                        text: "赞 " + commentsPage.compactCount(selectedComment ? selectedComment.likes : 0)
                                        color: selectedComment && selectedComment.liked ? Theme.primary : Theme.primaryLight
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 7
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -2
                                        onClicked: {
                                            if (selectedComment)
                                                commentsPage.toggleCommentLike(selectedComment.rpid, selectedComment.liked)
                                        }
                                    }
                                }
                            }

                            Text {
                                width: parent.width
                                text: selectedComment ? commentsPage.commentRichText(selectedComment.content || "", selectedComment.emotes || ({})) : ""
                                textFormat: Text.RichText
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: commentsPage._commentBodyFontSize
                                wrapMode: Text.Wrap
                                lineHeight: 1.24
                                linkColor: "#60a5fa"
                                renderType: commentsPage._textRenderType
                                font.hintingPreference: commentsPage._hinting
                                antialiasing: commentsPage._textAA
                                onLinkActivated: commentsPage.openVideoLink(link)
                            }

                            Rectangle {
                                visible: selectedComment && !!commentsPage.firstPicture(selectedComment.pictures)
                                width: commentsPage._commentPictureWidth
                                height: commentsPage._commentPictureHeight
                                radius: 8
                                color: Theme.bgTertiary
                                border.color: Theme.withAlpha(_panelBorder, 0.95)
                                border.width: 1
                                clip: true

                                Image {
                                    anchors.fill: parent
                                    source: commentsPage.commentThumbSource(commentsPage.firstPicture(selectedComment.pictures))
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    mipmap: true
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: commentsPage.openCommentImage(commentsPage.firstPicture(selectedComment.pictures))
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 18
                    radius: 9
                    color: Theme.withAlpha(_chipFill, 0.92)
                    border.color: Theme.withAlpha(_panelBorder, 0.8)
                    border.width: 1

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        Text {
                            text: "回复列表"
                            color: Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontTiny
                        }

                        Text {
                            text: {
                                var totalReplies = selectedComment ? Number(selectedComment.rcount || 0) : 0
                                var rm = controller ? controller.comments.commentReplyModel() : null
                                var apiTotal = rm && rm.totalCount ? Number(rm.totalCount) : 0
                                var loaded = rm ? rm.count : 0
                                return (totalReplies > 0 ? totalReplies : (apiTotal > 0 ? apiTotal : loaded)) + " 条"
                            }
                            color: _mutedText
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontTiny
                        }
                    }
                }
            }

            delegate: Rectangle {
                width: replyDetailFlick.width
                height: replyContent.height + 7
                radius: 12
                color: Theme.withAlpha(_cardFill, 0.98)
                border.color: Theme.withAlpha(_panelBorder, 0.9)
                border.width: 1
                property string replyAvatarSource: ""
                property string replyPictureSource: ""

                function loadReplyImages() {
                    if (commentsPage.commentImagesDeferred) return
                    if (!replyAvatarSource && model.avatar) {
                        replyAvatarSource = commentsPage.avatarImageSource(model.avatar)
                    }
                    if (!replyPictureSource) {
                        var pic = commentsPage.firstPicture(model.pictures)
                        if (pic) replyPictureSource = commentsPage.commentThumbSource(pic)
                    }
                }

                Component.onCompleted: Qt.callLater(loadReplyImages)

                Connections {
                    target: commentsPage
                    function onCommentImagesDeferredChanged() {
                        if (!commentsPage.commentImagesDeferred) Qt.callLater(loadReplyImages)
                    }
                }

                Row {
                    anchors.fill: parent
                    anchors.margins: 6
                    spacing: 6

                    Rectangle {
                        width: 20
                        height: 20
                        radius: 10
                        color: Theme.bgTertiary

                        Image {
                            id: replyAvatarImage
                            anchors.fill: parent
                            source: replyAvatarSource
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            smooth: true
                            mipmap: true
                            visible: false
                        }

                        OpacityMask {
                            anchors.fill: replyAvatarImage
                            source: replyAvatarImage
                            maskSource: Rectangle {
                                width: replyAvatarImage.width
                                height: replyAvatarImage.height
                                radius: Math.min(width, height) / 2
                                visible: false
                            }
                        }
                    }

                    Column {
                        id: replyContent
                        width: parent.width - 26
                        spacing: 4

                        Row {
                            width: parent.width
                            spacing: 4

                            Text {
                                width: Math.min(84, implicitWidth)
                                text: model.userName || ""
                                color: model.isVip ? Theme.accent : Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                                font.bold: true
                                elide: Text.ElideRight
                                renderType: commentsPage._textRenderType
                                font.hintingPreference: commentsPage._hinting
                                antialiasing: commentsPage._textAA
                            }

                            Rectangle {
                                visible: commentsPage.isOwner(model.mid)
                                width: replyUpTagText.implicitWidth + 8
                                height: 12
                                radius: 6
                                color: Theme.withAlpha(Theme.accent, 0.18)
                                border.color: Theme.withAlpha(Theme.accent, 0.28)
                                border.width: 1

                                Text {
                                    id: replyUpTagText
                                    anchors.centerIn: parent
                                    text: "UP"
                                    color: Theme.accent
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 7
                                    font.bold: true
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            text: model.ctimeText || ""
                            color: _mutedText
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontTiny
                            elide: Text.ElideRight
                            renderType: commentsPage._textRenderType
                            font.hintingPreference: commentsPage._hinting
                            antialiasing: commentsPage._textAA
                        }

                        Text {
                            width: parent.width
                            text: commentsPage.commentRichText(model.content || "", model.emotes || ({}))
                            textFormat: Text.RichText
                            color: Theme.textPrimary
                            font.family: Theme.fontFamily
                            font.pixelSize: commentsPage._commentBodyFontSize
                            wrapMode: Text.Wrap
                            lineHeight: 1.22
                            linkColor: "#60a5fa"
                            renderType: commentsPage._textRenderType
                            font.hintingPreference: commentsPage._hinting
                            antialiasing: commentsPage._textAA
                            onLinkActivated: commentsPage.openVideoLink(link)
                        }

                        Row {
                            width: parent.width
                            spacing: 6

                            Rectangle {
                                visible: !!commentsPage.firstPicture(model.pictures)
                                width: commentsPage._commentPictureWidth
                                height: commentsPage._commentPictureHeight
                                radius: 8
                                color: Theme.bgTertiary
                                border.color: Theme.withAlpha(_panelBorder, 0.95)
                                border.width: 1
                                clip: true

                                Image {
                                    anchors.fill: parent
                                    source: replyPictureSource
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    mipmap: true
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: commentsPage.openCommentImage(commentsPage.firstPicture(model.pictures))
                                }
                            }

                            Components.IconButton {
                                icon: "👍"
                                value: commentsPage.compactCount(model.likes || 0)
                                active: !!model.liked
                                width: 34
                                anchors.verticalCenter: parent.verticalCenter
                                onClicked: commentsPage.toggleCommentLike(model.rpid, model.liked)
                            }
                        }
                    }
                }
            }

            footer: Column {
                width: replyDetailFlick.width
                spacing: 5

                Text {
                    visible: controller && controller.comments.commentReplyModel() && controller.comments.commentReplyModel().count === 0 && !commentsPage.isAnyCommentLoading()
                    text: "这条评论还没有回复"
                    color: Theme.textTertiary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontBody
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    visible: controller && controller.comments.replyHasMore
                             && controller.comments.commentReplyModel()
                             && controller.comments.commentReplyModel().count > 0
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: (controller && controller.comments.commentReplyModel() && controller.comments.commentReplyModel().loading)
                          ? "正在加载更多回复..."
                          : "上滑加载更多回复"
                    color: Theme.textTertiary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                    topPadding: 2
                    bottomPadding: 4
                }
            }
        }
    }

    // ── 图片全屏查看：仅全屏预览（移除缩放/拖动/手势） ──
    Rectangle {
        id: fullscreenOverlay
        anchors.fill: parent
        visible: commentsPage.imageFullscreenVisible
        z: 1000
        color: "#E6000000"

        function close() {
            commentsPage.imageFullscreenVisible = false
            commentsPage.fullscreenImageUrl = ""
        }

        // 进入时不做任何缩放状态恢复（因为已移除缩放）

        // 背景拦截（不点击关闭，避免误触；需要可改成点击背景关闭）
        MouseArea {
            anchors.fill: parent
            z: 1
            onClicked: {
                // noop
            }
        }

        // 全屏图片：自适应显示
        Image {
            id: fullImage
            anchors.fill: parent
            anchors.margins: 0
            z: 2
            source: commentsPage.commentImageSource(commentsPage.fullscreenImageUrl)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            mipmap: true
            smooth: true
        }

        // 顶部仅保留关闭按钮
        Rectangle {
            id: topBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 34
            color: "transparent"
            z: 20

            Row {
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    width: 38
                    height: 24
                    radius: 10
                    color: closeArea.pressed
                           ? Theme.withAlpha(Theme.primary, 0.22)
                           : Theme.withAlpha(Theme.bgTertiary, 0.55)
                    border.color: Theme.withAlpha(Theme.primary, 0.25)
                    border.width: 1

                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontNormal
                        renderType: commentsPage._textRenderType
                        font.hintingPreference: commentsPage._hinting
                        antialiasing: commentsPage._textAA
                    }

                    MouseArea {
                        id: closeArea
                        anchors.fill: parent
                        onClicked: fullscreenOverlay.close()
                    }
                }
            }
        }
    }

    // ── 初始加载遮罩：先让下层卡片完成创建，再淡出遮罩 ──
    Rectangle {
        visible: opacity > 0
        opacity: commentsPage.commentLoadingMaskVisible ? 1 : 0
        anchors.top: headerWrap.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        color: Theme.bgPrimary
        z: 200
        Behavior on opacity { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic } }

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
                            running: commentsPage.visible && commentsPage.commentLoadingMaskVisible
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
                        if (controller) controller.cancelAll()
                        commentsPage.hideCommentLoadingMaskSoon()
                    }
                }
            }
        }
    }

    Connections {
        target: controller ? controller.comments : null
        function onCommentsReadyChanged() {
            commentsPage.updateCommentLoadingMask()
        }
        function onCommentLikeChanged(rpid, liked, likes) {
            if (!commentsPage.selectedComment ||
                    Number(commentsPage.selectedComment.rpid) !== Number(rpid)) return
            var updated = {}
            for (var key in commentsPage.selectedComment)
                updated[key] = commentsPage.selectedComment[key]
            updated.liked = liked
            updated.likes = likes
            commentsPage.selectedComment = updated
        }
    }

    Connections {
        target: controller ? controller.comments.commentModel() : null
        function onLoadingChanged() {
            if (!target || !target.loading) commentsPage.autoLoadingComments = false
            commentsPage.updateCommentLoadingMask()
        }
        function onCountChanged() {
            commentsPage.updateCommentLoadingMask()
        }
    }

    Connections {
        target: controller ? controller.comments.commentReplyModel() : null
        function onLoadingChanged() {
            if (!target || !target.loading) {
                commentsPage.autoLoadingReplies = false
                if (commentsPage.viewMode === 1)
                    Qt.callLater(commentsPage.maybeAutoLoadMoreReplies)
            }
            commentsPage.updateCommentLoadingMask()
        }
        function onCountChanged() {
            commentsPage.updateCommentLoadingMask()
            if (commentsPage.viewMode === 1)
                Qt.callLater(commentsPage.maybeAutoLoadMoreReplies)
        }
    }

    Connections {
        target: controller ? controller.comments : null
        ignoreUnknownSignals: true
        function onReplyHasMoreChanged() {
            if (commentsPage.viewMode === 1)
                Qt.callLater(commentsPage.maybeAutoLoadMoreReplies)
        }
    }

    // 系统图片查看器弹出容器
    Item {
        id: id_pop_container
        anchors.fill: parent
        z: 3000
        visible: popItemObject !== null
        property var popItemObject: null
        signal closeSameItem(string popStackId)

        function updateStackInfo() {
            if (id_pop_container.children.length > 1) {
                popItemObject = id_pop_container.children[id_pop_container.children.length - 2]
            } else {
                popItemObject = null
            }
        }

        function show(componentPath) {
            function initObj(obj) {
                if (!obj) return
                Object.defineProperty(obj, "popStackId", {
                    enumerable: false,
                    configurable: false,
                    writable: false,
                    value: componentPath
                })
                popItemObject = obj
                if (obj.backButtonClicked) {
                    obj.backButtonClicked.connect(function() {
                        closeSameItem(obj.popStackId)
                        updateStackInfo()
                        obj.destroy(1)
                    })
                }
                id_pop_container.closeSameItem.connect(function(popStackId) {
                    if (popStackId === obj.popStackId) obj.destroy(1)
                })
                if (obj.show) obj.show()
            }

            closeSameItem(componentPath)
            var comp = Qt.createComponent(componentPath)
            if (comp.status === Component.Ready) {
                var incubator = comp.incubateObject(id_pop_container)
                if (incubator.status !== Component.Ready) {
                    incubator.onStatusChanged = function(s) {
                        if (s === Component.Ready) initObj(incubator.object)
                    }
                } else {
                    initObj(incubator.object)
                }
            } else {
                console.error("Image viewer component error: " + comp.errorString())
            }
        }
    }

    Connections {
        target: controller
        ignoreUnknownSignals: true
        function onCommentImageReadyForViewer(localPath) {
            commentsPage.openSystemImageViewer(localPath)
        }
    }

    Component.onCompleted: {
        queueInitialCommentsIfNeeded()
    }

    onVisibleChanged: {
        if (visible) {
            queueInitialCommentsIfNeeded()
        }
    }
}
