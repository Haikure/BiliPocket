import QtQuick 2.12
import BiliPlugin 1.0
import "../components" as Components
import ".."

Rectangle {
    id: userPage
    width: 320
    height: 170
    color: Theme.bgPrimary

    property var controller: null
    signal backClicked()
    signal videoSelected(string bvid)
    signal watchLaterRequested()

    // 0=个人中心, 1=收藏夹列表, 2=收藏夹详情, 3=最近观看, 4=设置, 5=字幕设置, 6=偏好设置
    property int favView: 0
    property string currentFavTitle: ""
    property int currentFavId: 0
    property real recentHistoryContentX: 0
    property bool recentHistoryForceStart: false
    property bool recentHistorySearchMode: false
    property string recentHistoryKeyword: ""
    property bool loginPanelVisible: false
    property int previousFavView: 0
    property int lastAnimatedFavView: 0
    readonly property bool profileImagesActive: visible && isManagedViewCurrent(0)
    readonly property bool favoriteFolderImagesActive: visible && isManagedViewCurrent(1)
    readonly property bool favoriteItemImagesActive: visible && isManagedViewCurrent(2)
    readonly property bool recentHistoryImagesActive: visible && isManagedViewCurrent(3)
    readonly property bool loginImagesActive: visible && loginArea.visible

    function bumpFont(size) {
        return size + 1
    }

    function normalizedFavView(view) {
        return (view === 5 || view === 6) ? 4 : view
    }

    function isManagedViewCurrent(viewId) {
        return normalizedFavView(favView) === viewId
    }

    function shouldShowManagedView(viewId) {
        return normalizedFavView(favView) === viewId || previousFavView === viewId
    }

    function managedViewOffset(viewId) {
        var currentView = normalizedFavView(favView)
        if (currentView === viewId)
            return 0
        return viewId < currentView ? -10 : 10
    }

    function openFavorites() {
        favView = 1
        // 延后到下一帧触发，避免切换视图瞬间阻塞 UI
        if (controller) Qt.callLater(function() { controller.favorite.fetchFavoriteFolders() })
    }

    function openFavoriteDetail(fid, title) {
        currentFavId = fid
        currentFavTitle = title
        favView = 2
        // 延后到下一帧触发，避免进入详情时 UI 卡顿
        if (controller) Qt.callLater(function() { controller.favorite.fetchFavoriteItems(fid, 1, 20) })
    }

    function doHistorySearch(keyword) {
        var kw = keyword.trim()
        recentHistoryKeyword = kw
        recentHistorySearchMode = kw.length > 0
        recentHistoryContentX = 0
        recentHistoryForceStart = true
        if (!controller || !controller.history) return
        if (kw.length === 0) {
            controller.history.clearHistorySearch()
            controller.history.fetchRecentHistory()
        } else {
            controller.history.searchHistory(kw, 1)
        }
    }

    function clearHistorySearchMode() {
        recentHistoryKeyword = ""
        recentHistorySearchMode = false
        recentHistoryForceStart = true
        recentHistoryContentX = 0
        if (controller && controller.history) {
            controller.history.clearHistorySearch()
            controller.history.fetchRecentHistory()
        }
    }

    function openLoginPanel() {
        loginPanelVisible = true
        if (controller && controller.qrcodeUrl === "") {
            controller.auth.generateQrcode()
        }
    }

    function backInternal() {
        if (loginPanelVisible && (!controller || !controller.loggedIn)) {
            loginPanelVisible = false
            return
        }
        if (favView === 4 && (!controller || !controller.loggedIn)) {
            favView = 0
            return
        }
        if ((favView === 5 || favView === 6) && (!controller || !controller.loggedIn)) {
            favView = 4
            return
        }
        if (favView === 2) {
            favView = 1
            return
        }
        if (favView === 1) {
            favView = 0
            return
        }
        if (favView === 3) {
            if (recentHistorySearchMode) {
                clearHistorySearchMode()
                return
            }
            favView = 0
            return
        }
        if (favView === 4) {
            favView = 0
            return
        }
        if (favView === 5 || favView === 6) {
            favView = 4
            return
        }
        backClicked()
    }

    Component.onCompleted: {
        console.log("[UserPage] Created");
    }

    onVisibleChanged: {
        if (visible && controller && controller.loggedIn) {
            Qt.callLater(function() {
                if (visible && controller && controller.loggedIn) {
                    controller.auth.refreshUserInfoIfStale()
                }
                if (favView === 3 && recentLoader.item && recentLoader.item.restorePosition) {
                    recentLoader.item.restorePosition()
                }
            })
        }
    }

    onFavViewChanged: {
        var nextView = normalizedFavView(favView)
        if (nextView === lastAnimatedFavView)
            return
        previousFavView = lastAnimatedFavView
        lastAnimatedFavView = nextView
        favViewTransitionCleanup.restart()
    }

    Component.onDestruction: {
        console.log("[UserPage] Destroyed, cleaning up");
        // 页面销毁时清空图片源，防止后台线程继续访问
        if (qrcodeImg) qrcodeImg.source = "";
        // 取消轮询
        if (qrcodePollTimer) qrcodePollTimer.running = false;
        // 注意：如果已登录成功，不要取消 checkLoginStatus() 请求
        // 让用户信息能够正常加载并保存
    }

    Timer {
        id: favViewTransitionCleanup
        interval: Theme.animNormal
        repeat: false
        onTriggered: previousFavView = lastAnimatedFavView
    }

    Connections {
        target: controller
        function onLoginStateChanged() {
            if (controller && controller.loggedIn) {
                loginPanelVisible = false
            } else {
                favView = 0
            }
        }
    }

    Components.TitleBar {
        id: titleBar
        title: {
            if (!controller || !controller.loggedIn) return loginPanelVisible ? "扫码登录" : "个人中心"
            if (favView === 1) return "我的收藏夹"
            if (favView === 2) return currentFavTitle.length > 0 ? currentFavTitle : "收藏夹"
            if (favView === 3) return "最近观看"
            if (favView === 4) return "设置"
            if (favView === 5) return "字幕设置"
            if (favView === 6) return "偏好设置"
            return "个人中心"
        }
        showBack: true
        showSearch: controller && controller.loggedIn && favView === 3
        anchors.top: parent.top
        onBackClicked: userPage.backInternal()
        onSearchClicked: historySearchKeyboard.open(userPage.recentHistoryKeyword)
    }

    // ====== 未登录：个人中心占位 ======
    Item {
        id: loggedOutProfileArea
        visible: (!controller || !controller.loggedIn) && !loginPanelVisible
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right

        Flickable {
            anchors.fill: parent
            anchors.margins: Theme.spacingLarge
            contentHeight: loggedOutColumn.height
            clip: true

            Column {
                id: loggedOutColumn
                width: parent.width - Theme.spacingLarge * 2
                spacing: Theme.spacingLarge
                anchors.horizontalCenter: parent.horizontalCenter

                Row {
                    width: parent.width
                    spacing: Theme.spacingLarge

                    Rectangle {
                        width: 60
                        height: 60
                        radius: Theme.radiusRound
                        color: loginAvatarArea.pressed ? Theme.withAlpha(Theme.primary, 0.18) : Theme.bgTertiary
                        border.color: Theme.withAlpha(Theme.primary, 0.45)
                        border.width: 2

                        Canvas {
                            anchors.centerIn: parent
                            width: 28
                            height: 28
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.strokeStyle = Theme.primary
                                ctx.fillStyle = Theme.withAlpha(Theme.primary, 0.18)
                                ctx.lineWidth = 2
                                ctx.lineCap = "round"
                                ctx.lineJoin = "round"
                                ctx.beginPath()
                                ctx.moveTo(8, 12)
                                ctx.lineTo(8, 9)
                                ctx.bezierCurveTo(8, 4.5, 20, 4.5, 20, 9)
                                ctx.lineTo(20, 12)
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.moveTo(9, 12)
                                ctx.lineTo(19, 12)
                                ctx.quadraticCurveTo(23, 12, 23, 16)
                                ctx.lineTo(23, 20)
                                ctx.quadraticCurveTo(23, 24, 19, 24)
                                ctx.lineTo(9, 24)
                                ctx.quadraticCurveTo(5, 24, 5, 20)
                                ctx.lineTo(5, 16)
                                ctx.quadraticCurveTo(5, 12, 9, 12)
                                ctx.fill()
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.arc(14, 18, 1.6, 0, Math.PI * 2)
                                ctx.fillStyle = Theme.primary
                                ctx.fill()
                            }
                        }

                        MouseArea {
                            id: loginAvatarArea
                            anchors.fill: parent
                            onClicked: userPage.openLoginPanel()
                        }
                    }

                    Item {
                        width: 190
                        height: loginInfoColumn.height
                        anchors.verticalCenter: parent.verticalCenter

                        Column {
                            id: loginInfoColumn
                            width: parent.width
                            spacing: Theme.spacingSmall

                            Text {
                                text: "点击登录"
                                color: loginNameArea.pressed ? Theme.primaryDark : Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontMedium)
                                font.bold: true
                            }

                            Text {
                                width: 180
                                text: "登录后可查看收藏夹、稍后再看和观看历史"
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontBody)
                                wrapMode: Text.WordWrap
                            }
                        }

                        MouseArea {
                            id: loginNameArea
                            anchors.fill: parent
                            onClicked: userPage.openLoginPanel()
                        }
                    }
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingSmall
                    anchors.horizontalCenter: parent.horizontalCenter

                    readonly property real colW: (width - Theme.spacingSmall * 2) / 3

                    Column {
                        width: parent.colW
                        spacing: 4
                        Text { width: parent.width; text: "--"; color: Theme.textTertiary; font.family: Theme.fontFamily; font.pixelSize: userPage.bumpFont(Theme.fontMedium); font.bold: true; horizontalAlignment: Text.AlignHCenter }
                        Text { width: parent.width; text: "粉丝"; color: Theme.textSecondary; font.family: Theme.fontFamily; font.pixelSize: userPage.bumpFont(Theme.fontSmall); horizontalAlignment: Text.AlignHCenter }
                    }
                    Column {
                        width: parent.colW
                        spacing: 4
                        Text { width: parent.width; text: "--"; color: Theme.textTertiary; font.family: Theme.fontFamily; font.pixelSize: userPage.bumpFont(Theme.fontMedium); font.bold: true; horizontalAlignment: Text.AlignHCenter }
                        Text { width: parent.width; text: "关注"; color: Theme.textSecondary; font.family: Theme.fontFamily; font.pixelSize: userPage.bumpFont(Theme.fontSmall); horizontalAlignment: Text.AlignHCenter }
                    }
                    Column {
                        width: parent.colW
                        spacing: 4
                        Text { width: parent.width; text: "--"; color: Theme.textTertiary; font.family: Theme.fontFamily; font.pixelSize: userPage.bumpFont(Theme.fontMedium); font.bold: true; horizontalAlignment: Text.AlignHCenter }
                        Text { width: parent.width; text: "硬币"; color: Theme.textSecondary; font.family: Theme.fontFamily; font.pixelSize: userPage.bumpFont(Theme.fontSmall); horizontalAlignment: Text.AlignHCenter }
                    }
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Theme.spacingLarge

                    Repeater {
                        model: [
                            { label: "收藏夹", action: "login" },
                            { label: "最近观看", action: "login" },
                            { label: "稍后再看", action: "login" },
                            { label: "设置", action: "settings" }
                        ]
                        Column {
                            spacing: 6
                            Rectangle {
                                width: 36
                                height: 36
                                radius: 18
                                color: lockedEntryArea.pressed ? Theme.withAlpha(Theme.primary, 0.18) : Theme.withAlpha(Theme.primary, modelData.action === "settings" ? 0.12 : 0.08)
                                border.color: Theme.withAlpha(Theme.primary, modelData.action === "settings" ? 0.35 : 0.2)
                                border.width: 1
                                Canvas {
                                    anchors.centerIn: parent
                                    width: 16
                                    height: 16
                                    onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.clearRect(0, 0, width, height)
                                        ctx.strokeStyle = modelData.action === "settings" ? Theme.primary : Theme.textTertiary
                                        ctx.fillStyle = Theme.withAlpha(ctx.strokeStyle, modelData.action === "settings" ? 0.18 : 0.12)
                                        ctx.lineWidth = 1.4
                                        ctx.lineCap = "round"
                                        ctx.lineJoin = "round"
                                        if (modelData.action === "settings") {
                                            ctx.beginPath()
                                            ctx.arc(8, 8, 4.5, 0, Math.PI * 2)
                                            ctx.stroke()
                                            ctx.beginPath()
                                            ctx.arc(8, 8, 1.6, 0, Math.PI * 2)
                                            ctx.fill()
                                            ctx.beginPath()
                                            ctx.moveTo(8, 1.5)
                                            ctx.lineTo(8, 3.2)
                                            ctx.moveTo(8, 12.8)
                                            ctx.lineTo(8, 14.5)
                                            ctx.moveTo(1.5, 8)
                                            ctx.lineTo(3.2, 8)
                                            ctx.moveTo(12.8, 8)
                                            ctx.lineTo(14.5, 8)
                                            ctx.stroke()
                                        } else {
                                            ctx.beginPath()
                                            ctx.moveTo(5, 7)
                                            ctx.lineTo(5, 5.5)
                                            ctx.bezierCurveTo(5, 2.5, 11, 2.5, 11, 5.5)
                                            ctx.lineTo(11, 7)
                                            ctx.stroke()
                                            ctx.beginPath()
                                            ctx.moveTo(5.5, 7)
                                            ctx.lineTo(10.5, 7)
                                            ctx.quadraticCurveTo(12.5, 7, 12.5, 9)
                                            ctx.lineTo(12.5, 11.5)
                                            ctx.quadraticCurveTo(12.5, 13.5, 10.5, 13.5)
                                            ctx.lineTo(5.5, 13.5)
                                            ctx.quadraticCurveTo(3.5, 13.5, 3.5, 11.5)
                                            ctx.lineTo(3.5, 9)
                                            ctx.quadraticCurveTo(3.5, 7, 5.5, 7)
                                            ctx.fill()
                                            ctx.stroke()
                                        }
                                    }
                                }
                                MouseArea {
                                    id: lockedEntryArea
                                    anchors.fill: parent
                                    onClicked: {
                                        if (modelData.action === "settings") {
                                            favView = 4
                                        } else {
                                            userPage.openLoginPanel()
                                        }
                                    }
                                }
                            }
                            Text {
                                text: modelData.label
                                color: modelData.action === "settings" ? Theme.textPrimary : Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }
                }
            }
        }
    }

    // ====== 未登录：二维码登录 ======
    Item {
        id: loginArea
        visible: (!controller || !controller.loggedIn) && loginPanelVisible
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right

        Row {
            anchors.centerIn: parent
            spacing: Theme.spacingLarge

            // ── 二维码区域（放大！）──
            Rectangle {
                width: 110; height: 110
                radius: Theme.radiusLarge
                color: "#FFFFFF"
                anchors.verticalCenter: parent.verticalCenter

                // 内部二维码
                Rectangle {
                    id: qrContainer
                    anchors.fill: parent
                    anchors.margins: 6
                    radius: Theme.radiusMedium
                    color: "#FFFFFF"
                    clip: true

                    Image {
                        id: qrcodeImg
                        anchors.fill: parent
                        // base64 data URL 直接使用，普通 URL 通过 image://bili/ 协议
                        source: {
                            if (!userPage.loginImagesActive || !controller || !controller.qrcodeUrl) return ""
                            var url = controller.qrcodeUrl
                            // 如果是 base64 data URL，直接使用（添加时间戳防止缓存）
                            if (url.startsWith("data:image/")) {
                                return url + (controller.qrcodeKey ? ("&t=" + controller.qrcodeKey) : "")
                            }
                            // 普通图片 URL 通过 image://bili/ 协议
                            return "image://bili/" + encodeURIComponent(url)
                                + (controller.qrcodeKey ? ("?t=" + controller.qrcodeKey) : "")
                        }
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        cache: false  // 禁用 QML 缓存，让图片提供者完全控制
                        visible: controller ? controller.qrcodeUrl !== "" : false
                        opacity: visible ? 1 : 0

                        Behavior on opacity {
                            NumberAnimation { duration: Theme.animNormal }
                        }

                        onStatusChanged: {
                            if (status === Image.Error) {
                                console.log("[QRCode] Image load error, status:", status);
                            } else if (status === Image.Ready) {
                                console.log("[QRCode] Image loaded successfully");
                            }
                        }
                    }

                    // 未获取时的占位
                    Column {
                        anchors.centerIn: parent
                        spacing: Theme.spacingSmall
                        visible: !qrcodeImg.visible

                        Canvas {
                            width: 22
                            height: 22
                            anchors.horizontalCenter: parent.horizontalCenter
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.strokeStyle = "#555555"
                                ctx.lineWidth = 1.8
                                ctx.lineJoin = "round"
                                ctx.beginPath()
                                ctx.rect(6, 2, 10, 18)
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.arc(11, 17, 0.8, 0, Math.PI * 2)
                                ctx.fillStyle = "#555555"
                                ctx.fill()
                            }
                        }
                        Text {
                            text: "点击获取\n二维码"
                            color: "#555555"
                            font.family: Theme.fontFamily
                            font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (controller && !controller.qrcodeUrl) {
                                controller.auth.generateQrcode();
                            }
                        }
                    }
                }

                // 蓝色边框装饰
                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: "transparent"
                    border.color: Theme.withAlpha(Theme.primary, 0.5)
                    border.width: 2
                }

                // 角标
                Rectangle {
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.topMargin: -4
                    anchors.rightMargin: -4
                    width: 20; height: 20
                    radius: Theme.radiusRound
                    color: Theme.primary
                    z: 2

                    Text {
                        anchors.centerIn: parent
                        text: "B"
                        color: Theme.textOnPrimary
                        font.pixelSize: userPage.bumpFont(Theme.fontNormal)
                        font.bold: true
                    }
                }
            }

            // ── 说明文字 ──
            Column {
                width: 130
                spacing: Theme.spacingMedium
                anchors.verticalCenter: parent.verticalCenter

                Text {
                    text: "使用 B 站 APP"
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: userPage.bumpFont(Theme.fontMedium)
                    font.bold: true
                }

                Column {
                    spacing: Theme.spacingSmall

                    Row {
                        spacing: Theme.spacingSmall
                        Rectangle {
                            width: 16; height: 16
                            radius: Theme.radiusRound
                            color: Theme.withAlpha(Theme.primary, 0.2)
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                anchors.centerIn: parent
                                text: "1"
                                color: Theme.primary
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                font.bold: true
                            }
                        }
                        Text {
                            text: "打开 B 站 APP"
                            color: Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Row {
                        spacing: Theme.spacingSmall
                        Rectangle {
                            width: 16; height: 16
                            radius: Theme.radiusRound
                            color: Theme.withAlpha(Theme.primary, 0.2)
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                anchors.centerIn: parent
                                text: "2"
                                color: Theme.primary
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                font.bold: true
                            }
                        }
                        Text {
                            text: "点击左上角扫一扫"
                            color: Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Row {
                        spacing: Theme.spacingSmall
                        Rectangle {
                            width: 16; height: 16
                            radius: Theme.radiusRound
                            color: Theme.withAlpha(Theme.primary, 0.2)
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                anchors.centerIn: parent
                                text: "3"
                                color: Theme.primary
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                font.bold: true
                            }
                        }
                        Text {
                            text: "扫描左侧二维码"
                            color: Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Row {
                       spacing: Theme.spacingSmall

                        Rectangle {
                            width: 16
                            height: 16
                            radius: Theme.radiusRound
                            color: Theme.withAlpha(Theme.primary, 0.2)
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                anchors.centerIn: parent
                                text: "4"
                                color: Theme.primary
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                font.bold: true
                            }
                        }

                        Text {
                            text: "或进行短信登录"
                            color: Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                }

                // 刷新按钮
                Rectangle {
                    width: 80; height: Theme.buttonHeight
                    radius: Theme.radiusRound
                    color: refreshArea.pressed ? Theme.primaryDark : Theme.primary
                    visible: controller ? controller.qrcodeUrl !== "" : false

                    Behavior on color { ColorAnimation { duration: Theme.animFast } }
                    scale: refreshArea.pressed ? 0.93 : 1.0
                    Behavior on scale { NumberAnimation { duration: Theme.animFast } }

                    Text {
                        anchors.centerIn: parent
                        text: "刷新二维码"
                        color: Theme.textOnPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                        font.bold: true
                    }

                    MouseArea {
                        id: refreshArea
                        anchors.fill: parent
                        onClicked: {
                            if (controller) controller.auth.generateQrcode();
                        }
                    }
                }
            }
        }

        // 轮询定时器
        Timer {
            id: qrcodePollTimer
            interval: 3000
            repeat: true
            running: controller
            ? (loginArea.visible && controller.qrcodeUrl !== "" && !controller.loggedIn) : false
            onTriggered: {
                if (controller) controller.auth.pollQrcode();
            }
        }
    }

    // ====== 个人资料和子页面 ======
    Item {
        visible: (controller && controller.loggedIn) || favView === 4 || favView === 5 || favView === 6
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right

        // ── 个人中心 ──
        Item {
            id: profileView
            anchors.fill: parent
            visible: controller && controller.loggedIn && userPage.shouldShowManagedView(0)
            enabled: controller && controller.loggedIn && userPage.isManagedViewCurrent(0)
            opacity: controller && controller.loggedIn && userPage.isManagedViewCurrent(0) ? 1 : 0
            z: controller && controller.loggedIn && userPage.isManagedViewCurrent(0) ? 1 : 0
            transform: Translate {
                x: userPage.managedViewOffset(0)
                Behavior on x { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic } }
            }
            Behavior on opacity { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutQuad } }

            Flickable {
                anchors.fill: parent
                anchors.margins: Theme.spacingLarge
                contentHeight: contentColumn.height
                clip: true

                Column {
                    id: contentColumn
                    width: parent.width - Theme.spacingLarge * 2
                    spacing: Theme.spacingLarge
                    anchors.horizontalCenter: parent.horizontalCenter

                    // 头像和用户名
                    Row {
                        width: parent.width
                        spacing: Theme.spacingLarge
                        anchors.horizontalCenter: parent.horizontalCenter

                        // 头像
                        Rectangle {
                            width: 60; height: 60
                            radius: Theme.radiusRound
                            color: Theme.bgTertiary
                            border.color: Theme.primary
                            border.width: 2

                            // 圆形裁剪由 image provider 的 round/ 前缀完成，无需 OpacityMask
                            Image {
                                id: userAvatarImage
                                anchors.fill: parent
                                anchors.margins: 2
                                sourceSize: Qt.size(112, 112)
                                source: controller && controller.userFace && userPage.profileImagesActive
                                ? "image://bili/round/size/112x112/" + encodeURIComponent(controller.userFace) : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }
                        }

                        Column {
                            spacing: Theme.spacingSmall
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                text: controller ? controller.userName : ""
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontMedium)
                                font.bold: true
                            }

                            Row {
                                spacing: Theme.spacingSmall

                                Rectangle {
                                    width: 10; height: 10
                                    radius: 5
                                    color: Theme.success
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: "已登录"
                                    color: Theme.success
                                    font.family: Theme.fontFamily
                                    font.pixelSize: userPage.bumpFont(Theme.fontBody)
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            // 等级和经验
                            Row {
                                spacing: Theme.spacingSmall

                                Rectangle {
                                    width: 40; height: 20
                                    radius: Theme.radiusRound
                                    color: Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter

                                    Text {
                                        anchors.centerIn: parent
                                        text: "LV" + (controller ? controller.userLevel : 0)
                                        color: Theme.textOnPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                        font.bold: true
                                    }
                                }

                                Item {
                                    width: 108; height: 20
                                    anchors.verticalCenter: parent.verticalCenter

                                    Rectangle {
                                        width: parent.width
                                        height: 5
                                        radius: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: Theme.withAlpha(Theme.bgTertiary, 0.9)
                                        clip: true

                                        Rectangle {
                                            width: parent.width * (controller ? controller.userExpProgress : 0)
                                            height: parent.height
                                            radius: parent.radius
                                            color: Theme.primary
                                        }
                                    }

                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.top
                                        anchors.bottomMargin: 2
                                        text: controller ? (String(controller.userExp) + "/" + String(controller.userExpNext)) : "0/0"
                                        color: Theme.textSecondary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: userPage.bumpFont(Theme.fontTiny)
                                        font.bold: true
                                    }
                                }
                            }

                            // VIP 标签
                            Rectangle {
                                width: 60; height: 20
                                radius: Theme.radiusRound
                                color: controller && controller.userIsVip ? "#FB7299" : Theme.bgTertiary
                                visible: controller && (controller.userIsVip || controller.userVipLabel !== "")

                                Text {
                                    anchors.centerIn: parent
                                    text: controller && controller.userVipLabel !== "" ? controller.userVipLabel : "大会员"
                                    color: controller && controller.userIsVip ? Theme.textOnPrimary : Theme.textSecondary
                                    font.family: Theme.fontFamily
                                    font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                }
                            }
                        }
                    }

                    // 签名
                    Text {
                        text: controller && controller.userSign !== "" ? controller.userSign : "这个人很懒，什么都没写~"
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: userPage.bumpFont(Theme.fontBody)
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }

                    // 统计数据
                    Row {
                        width: parent.width
                        spacing: Theme.spacingSmall
                        anchors.horizontalCenter: parent.horizontalCenter

                        readonly property real colW: (width - Theme.spacingSmall * 2) / 3

                        // 粉丝
                        Column {
                            width: parent.colW
                            spacing: 4

                            Text {
                                width: parent.width
                                text: controller ? String(controller.userFans) : "0"
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontMedium)
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                text: "粉丝"
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }

                        // 关注
                        Column {
                            width: parent.colW
                            spacing: 4

                            Text {
                                width: parent.width
                                text: controller ? String(controller.userFollowing) : "0"
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontMedium)
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                text: "关注"
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }

                        // 硬币
                        Column {
                            width: parent.colW
                            spacing: 4

                            Text {
                                width: parent.width
                                text: controller ? String(controller.userCoins) : "0"
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontMedium)
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                text: "硬币"
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }

                    // 快捷入口：收藏夹 / 稍后再看 / 最近观看 / 设置
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Theme.spacingLarge

                        Column {
                            spacing: 6

                            Rectangle {
                                width: 36
                                height: 36
                                radius: 18
                                color: favEntryArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.withAlpha(Theme.primary, 0.12)
                                border.color: Theme.withAlpha(Theme.primary, 0.35)
                                border.width: 1
                                anchors.horizontalCenter: parent.horizontalCenter

                                Canvas {
                                    anchors.centerIn: parent
                                    width: 16
                                    height: 16
                                    onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.clearRect(0, 0, width, height)
                                        ctx.fillStyle = Theme.primary
                                        var cx = width / 2
                                        var cy = height / 2
                                        var outerR = 8
                                        var innerR = 3.4
                                        ctx.beginPath()
                                        for (var i = 0; i < 5; i++) {
                                            var outerAngle = (i * 72 - 90) * Math.PI / 180
                                            var innerAngle = ((i * 72) + 36 - 90) * Math.PI / 180
                                            var ox = cx + outerR * Math.cos(outerAngle)
                                            var oy = cy + outerR * Math.sin(outerAngle)
                                            var ix = cx + innerR * Math.cos(innerAngle)
                                            var iy = cy + innerR * Math.sin(innerAngle)
                                            if (i === 0) ctx.moveTo(ox, oy)
                                            else ctx.lineTo(ox, oy)
                                            ctx.lineTo(ix, iy)
                                        }
                                        ctx.closePath()
                                        ctx.fill()
                                    }
                                }

                                MouseArea {
                                    id: favEntryArea
                                    anchors.fill: parent
                                    onClicked: userPage.openFavorites()
                                }
                            }

                            Text {
                                text: "收藏夹"
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }

                        Column {
                            spacing: 6

                            Rectangle {
                                width: 36
                                height: 36
                                radius: 18
                                color: historyEntryArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.withAlpha(Theme.primary, 0.12)
                                border.color: Theme.withAlpha(Theme.primary, 0.35)
                                border.width: 1
                                anchors.horizontalCenter: parent.horizontalCenter

                                Canvas {
                                    anchors.centerIn: parent
                                    width: 16
                                    height: 16
                                    onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.clearRect(0, 0, width, height)
                                        ctx.strokeStyle = Theme.primary
                                        ctx.lineWidth = 1.8
                                        ctx.lineCap = "round"
                                        ctx.beginPath()
                                        ctx.arc(9, 9, 6.5, 0, Math.PI * 2)
                                        ctx.stroke()
                                        ctx.beginPath()
                                        ctx.moveTo(9, 9)
                                        ctx.lineTo(9, 5.5)
                                        ctx.moveTo(9, 9)
                                        ctx.lineTo(12, 10.5)
                                        ctx.stroke()
                                    }
                                }

                                MouseArea {
                                    id: historyEntryArea
                                    anchors.fill: parent
                                    onClicked: {
                                        recentHistoryContentX = 0
                                        recentHistoryForceStart = true
                                        recentHistorySearchMode = false
                                        recentHistoryKeyword = ""
                                        if (controller && controller.history) controller.history.clearHistorySearch()
                                        if (recentLoader.item && recentLoader.item.resetPosition) {
                                            recentLoader.item.resetPosition()
                                        }
                                        favView = 3
                                        if (controller) Qt.callLater(function() { controller.history.fetchRecentHistory() })
                                    }
                                }
                            }

                            Text {
                                text: "最近观看"
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }

                        Column {
                            spacing: 6

                            Rectangle {
                                width: 36
                                height: 36
                                radius: 18
                                color: watchLaterEntryArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.withAlpha(Theme.primary, 0.12)
                                border.color: Theme.withAlpha(Theme.primary, 0.35)
                                border.width: 1
                                anchors.horizontalCenter: parent.horizontalCenter

                                Canvas {
                                    anchors.centerIn: parent
                                    width: 16
                                    height: 16
                                    onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.clearRect(0, 0, width, height)
                                        ctx.strokeStyle = Theme.primary
                                        ctx.lineWidth = 1.6
                                        ctx.lineCap = "round"
                                        ctx.beginPath()
                                        ctx.arc(8, 8, 6, 0, Math.PI * 2)
                                        ctx.stroke()
                                        ctx.beginPath()
                                        ctx.moveTo(8, 8)
                                        ctx.lineTo(8, 4.5)
                                        ctx.moveTo(8, 8)
                                        ctx.lineTo(11.2, 9.4)
                                        ctx.stroke()
                                        ctx.beginPath()
                                        ctx.moveTo(12.5, 3.5)
                                        ctx.lineTo(14.5, 3.5)
                                        ctx.moveTo(13.5, 2.2)
                                        ctx.lineTo(13.5, 4.8)
                                        ctx.stroke()
                                    }
                                }

                                MouseArea {
                                    id: watchLaterEntryArea
                                    anchors.fill: parent
                                    onClicked: userPage.watchLaterRequested()
                                }
                            }

                            Text {
                                text: "稍后再看"
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }

                        Column {
                            spacing: 6

                            Rectangle {
                                width: 36
                                height: 36
                                radius: 18
                                color: settingsEntryArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.withAlpha(Theme.primary, 0.12)
                                border.color: Theme.withAlpha(Theme.primary, 0.35)
                                border.width: 1
                                anchors.horizontalCenter: parent.horizontalCenter

                                Canvas {
                                    anchors.centerIn: parent
                                    width: 16
                                    height: 16
                                    onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.clearRect(0, 0, width, height)
                                        ctx.strokeStyle = Theme.primary
                                        ctx.lineWidth = 1.6
                                        ctx.lineCap = "round"
                                        ctx.beginPath()
                                        ctx.arc(8, 8, 2.2, 0, Math.PI * 2)
                                        ctx.stroke()
                                        for (var i = 0; i < 8; i++) {
                                            var a = i * Math.PI / 4
                                            var x1 = 8 + Math.cos(a) * 4.2
                                            var y1 = 8 + Math.sin(a) * 4.2
                                            var x2 = 8 + Math.cos(a) * 6.8
                                            var y2 = 8 + Math.sin(a) * 6.8
                                            ctx.beginPath()
                                            ctx.moveTo(x1, y1)
                                            ctx.lineTo(x2, y2)
                                            ctx.stroke()
                                        }
                                    }
                                }

                                MouseArea {
                                    id: settingsEntryArea
                                    anchors.fill: parent
                                    onClicked: favView = 4
                                }
                            }

                            Text {
                                text: "设置"
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }

                    // 退出登录按钮
                    Rectangle {
                        width: 120; height: Theme.buttonHeight
                        radius: Theme.radiusRound
                        color: "transparent"
                        border.color: Theme.withAlpha(Theme.error, 0.5)
                        border.width: 1
                        anchors.horizontalCenter: parent.horizontalCenter

                        Behavior on color { ColorAnimation { duration: Theme.animFast } }

                        Text {
                            anchors.centerIn: parent
                            text: "退出登录"
                            color: Theme.withAlpha(Theme.error, 0.8)
                            font.family: Theme.fontFamily
                            font.pixelSize: userPage.bumpFont(Theme.fontBody)
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (controller) controller.auth.logout();
                            }
                            onPressed: parent.color = Theme.withAlpha(Theme.error, 0.1)
                            onReleased: parent.color = "transparent"
                        }
                    }
                }
            }
        }

        // ── 收藏夹列表 ──
        Item {
            id: favListView
            anchors.fill: parent
            visible: userPage.shouldShowManagedView(1)
            enabled: userPage.isManagedViewCurrent(1)
            opacity: userPage.isManagedViewCurrent(1) ? 1 : 0
            z: userPage.isManagedViewCurrent(1) ? 1 : 0
            transform: Translate {
                x: userPage.managedViewOffset(1)
                Behavior on x { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic } }
            }
            Behavior on opacity { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutQuad } }

            ListView {
                id: favList
                anchors.fill: parent
                anchors.margins: Theme.spacingSmall
                model: controller ? controller.favorite.favoriteFolderModel() : null
                spacing: Theme.spacingSmall
                clip: true

                delegate: Rectangle {
                    width: parent.width
                    height: 54
                    radius: Theme.radiusMedium
                    color: Theme.bgSecondary
                    border.color: Theme.withAlpha(Theme.primary, 0.15)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8

                        Rectangle {
                            width: 72
                            height: parent.height - 2
                            radius: Theme.radiusSmall
                            color: Theme.bgTertiary
                            clip: true

                            Image {
                                anchors.fill: parent
                                sourceSize: Qt.size(144, 104)
                                source: model.cover && userPage.favoriteFolderImagesActive ? "image://bili/" + encodeURIComponent(model.cover) : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }
                        }

                        Column {
                            width: parent.width - 90
                            spacing: 4
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                text: model.title || ""
                                color: Theme.textPrimary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontBody)
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            Text {
                                text: "共" + (model.mediaCount || 0) + "个视频"
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: userPage.bumpFont(Theme.fontSmall)
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: userPage.openFavoriteDetail(model.id, model.title)
                    }
                }
            }

            Text {
                visible: favList.count === 0 && controller && !controller.isLoading
                text: "暂无收藏夹"
                color: Theme.textTertiary
                anchors.centerIn: parent
            }

            Components.LoadingIndicator {
                anchors.centerIn: parent
                running: controller ? controller.isLoading : false
                onCancelRequested: {
                    if (controller) controller.cancelAll();
                }
            }
        }

        // ── 最近观看 ──
        Item {
            id: recentHistoryView
            anchors.fill: parent
            visible: userPage.shouldShowManagedView(3)
            enabled: userPage.isManagedViewCurrent(3)
            opacity: userPage.isManagedViewCurrent(3) ? 1 : 0
            z: userPage.isManagedViewCurrent(3) ? 1 : 0
            transform: Translate {
                x: userPage.managedViewOffset(3)
                Behavior on x { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic } }
            }
            Behavior on opacity { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutQuad } }

            // 用 Loader 延迟创建 ListView，避免 UserPage 被加载时就构建大量 delegate 导致卡顿
            Loader {
                id: recentLoader
                anchors.fill: parent
                active: recentHistoryView.visible
                asynchronous: true
                sourceComponent: Component {
                    Item {
                        anchors.fill: parent
                        property int pendingDeleteIndex: -1
                        property string pendingDeleteTitle: ""
                        property string pendingDeleteBusiness: "archive"
                        property var pendingDeleteKid: 0
                        property bool deleteConfirmVisible: false

                        function resetPosition() {
                            recentList.contentX = 0
                            Qt.callLater(function() {
                                recentList.contentX = 0
                                Qt.callLater(function() { recentList.contentX = 0 })
                            })
                        }

                        function restorePosition() {
                            if (userPage.recentHistoryForceStart) {
                                resetPosition()
                                return
                            }
                            if (recentHistoryView.visible && userPage.recentHistoryContentX > 0) {
                                recentList.contentX = userPage.recentHistoryContentX
                            } else {
                                resetPosition()
                            }
                        }

                        Components.LoadMoreListView {
                            id: recentList
                            anchors.fill: parent
                            anchors.margins: Theme.spacingSmall
                            model: controller ? controller.history.recentHistoryModel() : null
                            spacing: Theme.spacingMedium
                            onContentWidthChanged: {
                                if (userPage.recentHistoryForceStart) contentX = 0
                            }
                            onCountChanged: {
                                if (!userPage.recentHistoryForceStart) return
                                contentX = 0
                                if (count > 0) {
                                    Qt.callLater(function() {
                                        contentX = 0
                                        userPage.recentHistoryForceStart = false
                                    })
                                }
                            }

                            onLoadMoreRequested: {
                                if (!controller || !controller.history) return
                                if (userPage.recentHistorySearchMode)
                                    controller.history.searchMoreHistory()
                                else
                                    controller.history.fetchMoreRecentHistory()
                            }

                            delegate: Item {
                                width: Theme.cardWidth
                                height: recentList.height

                                Components.VideoCardCompact {
                                    id: recentCard
                                    anchors.fill: parent
                                    videoTitle: model.title || ""
                                    // 与 HomePage 保持一致：直接使用 model.pic，避免重复 encode 带来额外开销/错误
                                    coverUrl: model.pic || ""
                                    imageActive: userPage.recentHistoryImagesActive
                                    preferOffscreenPlaceholder: controller && controller.videoCardOffscreenPlaceholderEnabled
                                    upName: model.ownerName || ""
                                    viewCount: ""
                                    durationText: model.durationText || ""
                                    bvid: model.bvid || ""
                                    partCount: model.partCount || 1
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    pressAndHoldInterval: 550
                                    onClicked: {
                                        userPage.recentHistoryContentX = recentList.contentX
                                        userPage.recentHistoryForceStart = false
                                        userPage.videoSelected(model.bvid || "")
                                    }
                                    onPressAndHold: {
                                        pendingDeleteIndex = index
                                        pendingDeleteTitle = model.title || ""
                                        pendingDeleteBusiness = model.historyBusiness || "archive"
                                        pendingDeleteKid = model.historyKid || model.aid || 0
                                        deleteConfirmVisible = true
                                    }
                                }
                            }

                            Row {
                                visible: recentList.count === 0 && controller && recentList.model && recentList.model.loading
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingSmall
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingMedium
                                Repeater {
                                    model: 3
                                    Components.VideoCardCompact {
                                        height: recentList.height
                                        placeholder: true
                                    }
                                }
                            }
                        }

                        Text {
                            visible: recentList.count === 0
                            text: userPage.recentHistorySearchMode ? "未找到相关历史" : "暂无最近观看"
                            color: Theme.textTertiary
                            anchors.centerIn: parent
                        }

                        Rectangle {
                            visible: userPage.recentHistorySearchMode
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.topMargin: 4
                            anchors.rightMargin: 6
                            width: Math.min(parent.width - 12, searchLabel.implicitWidth + 42)
                            height: 22
                            radius: 11
                            color: Theme.withAlpha(Theme.primary, 0.16)
                            border.color: Theme.withAlpha(Theme.primary, 0.45)
                            z: 20

                            Text {
                                id: searchLabel
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                text: "搜索：" + userPage.recentHistoryKeyword
                                color: Theme.primary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                                elide: Text.ElideRight
                                width: parent.width - 32
                            }

                            Canvas {
                                anchors.right: parent.right
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                width: 10
                                height: 10
                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.strokeStyle = Theme.primary
                                    ctx.lineWidth = 1.6
                                    ctx.lineCap = "round"
                                    ctx.beginPath()
                                    ctx.moveTo(1, 1)
                                    ctx.lineTo(9, 9)
                                    ctx.moveTo(9, 1)
                                    ctx.lineTo(1, 9)
                                    ctx.stroke()
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: userPage.clearHistorySearchMode()
                            }
                        }

                        Rectangle {
                            visible: opacity > 0
                            opacity: deleteConfirmVisible ? 1 : 0
                            scale: deleteConfirmVisible ? 1 : 0.92
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
                                    text: "删除这条历史？"
                                    color: Theme.textPrimary
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontMedium
                                    font.bold: true
                                    horizontalAlignment: Text.AlignHCenter
                                }

                                Text {
                                    width: parent.width
                                    text: pendingDeleteTitle
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
                                        MouseArea { id: cancelDeleteArea; anchors.fill: parent; onClicked: deleteConfirmVisible = false }
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
                                                deleteConfirmVisible = false
                                                if (controller && controller.history) {
                                                    controller.history.deleteRecentHistoryItem(pendingDeleteIndex, pendingDeleteBusiness, Number(pendingDeleteKid))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Component.onCompleted: {
                            Qt.callLater(function() { restorePosition() })
                        }
                    }
                }
            }
        }

        // ── 设置页 ──
        SettingsPage {
            id: settingsPage
            anchors.fill: parent
            visible: userPage.shouldShowManagedView(4)
            enabled: userPage.isManagedViewCurrent(4)
            opacity: userPage.isManagedViewCurrent(4) ? 1 : 0
            z: userPage.isManagedViewCurrent(4) ? 1 : 0
            transform: Translate {
                x: userPage.managedViewOffset(4)
                Behavior on x { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic } }
            }
            Behavior on opacity { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutQuad } }
            controller: userPage.controller
            viewMode: favView
            onRequestSubtitleSettings: userPage.favView = 5
            onRequestPreferenceSettings: userPage.favView = 6
        }

        // ── 收藏夹详情 ──
        Item {
            id: favDetailView
            anchors.fill: parent
            visible: userPage.shouldShowManagedView(2)
            enabled: userPage.isManagedViewCurrent(2)
            opacity: userPage.isManagedViewCurrent(2) ? 1 : 0
            z: userPage.isManagedViewCurrent(2) ? 1 : 0
            transform: Translate {
                x: userPage.managedViewOffset(2)
                Behavior on x { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic } }
            }
            Behavior on opacity { NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutQuad } }

            Loader {
                id: favDetailLoader
                anchors.fill: parent
                active: favDetailView.visible
                asynchronous: true
                sourceComponent: Component {
                    Item {
                        anchors.fill: parent

                        Components.LoadMoreListView {
                            id: favItems
                            anchors.fill: parent
                            anchors.margins: Theme.spacingSmall
                            model: controller ? controller.favorite.favoriteItemModel() : null
                            spacing: Theme.spacingMedium

                            onLoadMoreRequested: {
                                if (controller && controller.favorite) controller.favorite.fetchMoreFavoriteItems()
                            }

                            delegate: Components.VideoCardCompact {
                                height: favItems.height
                                videoTitle: model.title || ""
                                coverUrl: model.pic || ""
                                imageActive: userPage.favoriteItemImagesActive
                                preferOffscreenPlaceholder: controller && controller.videoCardOffscreenPlaceholderEnabled
                                upName: model.ownerName || ""
                                viewCount: model.views || ""
                                durationText: model.durationText || ""
                                bvid: model.bvid || ""
                                partCount: model.partCount || 1
                                onClicked: userPage.videoSelected(bvid)
                            }

                            Row {
                                visible: favItems.count === 0 && controller && favItems.model && favItems.model.loading
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingSmall
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingMedium
                                Repeater {
                                    model: 3
                                    Components.VideoCardCompact {
                                        height: favItems.height
                                        placeholder: true
                                    }
                                }
                            }
                        }

                        Text {
                            visible: favItems.count === 0 && controller && !controller.isLoading
                            text: "收藏夹为空"
                            color: Theme.textTertiary
                            anchors.centerIn: parent
                        }

                        Components.LoadingIndicator {
                            anchors.centerIn: parent
                            running: controller ? controller.isLoading : false
                            onCancelRequested: {
                                if (controller) controller.cancelAll();
                            }
                        }
                    }
                }
            }
        }
    }

    Components.VirtualKeyboardInput {
        id: historySearchKeyboard
        objectName: "from_UserPage_history_search"
        // 空串也有效（用于清空搜索），故不做 trim/空判断
        onAccepted: userPage.doHistorySearch(content)
    }

}
