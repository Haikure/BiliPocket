import QtQuick 2.12
import BiliPlugin 1.0
import "../components" as Components
import ".."

Rectangle {
    id: searchPage
    width: 320
    height: 170
    color: Theme.bgPrimary

    property var controller: null
    // 由 main.qml 传入，用于跨页面（即使 SearchPage 被销毁重建也能恢复滚动位置）
    property var rootRef: null

    signal backClicked()
    signal videoSelected(string bvid)

    // 虚拟键盘弹层
    Components.VirtualKeyboardInput {
        id: searchKeyboard
        objectName: "from_SearchPage.qml"
        onAccepted: {
            searchInput.text = content.trim()
            if (searchInput.text.length > 0) doSearch()
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 搜索栏
    // ═══════════════════════════════════════════════════════════
    Rectangle {
        id: searchBar
        width: parent.width
        height: 38
        color: Theme.bgSecondary
        z: 10

        Row {
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            spacing: 6

            // ── 返回按钮 ──
            Item {
                width: 36
                height: 36
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    anchors.centerIn: parent
                    width: 30
                    height: 30
                    radius: 8
                    color: backBtnArea.pressed
                    ? Qt.rgba(0.15, 0.56, 0.94, 0.15)
                    : "transparent"

                    Behavior on color {
                        ColorAnimation { duration: 100 }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: "‹"
                        color: Theme.primary
                        font.family: Theme.fontFamily
                        font.pixelSize: 22
                        font.weight: Font.Bold
                    }
                }

                MouseArea {
                    id: backBtnArea
                    anchors.fill: parent
                    onClicked: searchPage.backClicked()
                }
            }

            // ── 搜索输入框 ──
            Rectangle {
                id: searchInputBox
                width: parent.width - 36 - 52 - 18
                height: 30
                radius: 15
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.bgInput
                border.width: 1.5
                border.color: searchInputArea.pressed
                ? Theme.primary
                : Qt.rgba(0, 0, 0, 0.06)

                Behavior on border.color {
                    ColorAnimation { duration: 150 }
                }

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 10
                    spacing: 8

                    // 搜索图标
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "🔍"
                        font.pixelSize: 11
                        opacity: 0.4
                    }

                    // 显示文本
                    Text {
                        id: displayText
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 30
                        text: searchInput.text.length > 0
                        ? searchInput.text
                        : "搜索视频、UP主..."
                        color: searchInput.text.length > 0
                        ? Theme.textPrimary
                        : Theme.textTertiary
                        font.family: Theme.fontFamily
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                }

                // 清除按钮
                Rectangle {
                    visible: searchInput.text.length > 0
                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: 18
                    height: 18
                    radius: 9
                    color: clearBtnArea.pressed
                    ? Qt.rgba(0, 0, 0, 0.15)
                    : Qt.rgba(0, 0, 0, 0.08)

                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: 13
                        font.weight: Font.Bold
                    }

                    MouseArea {
                        id: clearBtnArea
                        anchors.fill: parent
                        onClicked: {
                            searchInput.text = "";
                            showResults = false;
                        }
                    }
                }

                // 隐藏的 TextInput 用于存储
                TextInput {
                    id: searchInput
                    visible: false
                }

                // 点击触发键盘
                MouseArea {
                    id: searchInputArea
                    anchors.fill: parent
                    anchors.leftMargin: -4
                    // 文字为空时原值 0-4 为负外边距，改为非负
                    anchors.rightMargin: searchInput.text.length > 0 ? 22 : 0
                    anchors.topMargin: -6
                    anchors.bottomMargin: -6
                    onClicked: searchKeyboard.open(searchInput.text)
                }
            }

            // ── 搜索按钮 ──
            Rectangle {
                width: 52
                height: 30
                radius: 15
                anchors.verticalCenter: parent.verticalCenter
                color: searchBtnArea.pressed
                ? Theme.primaryDark
                : Theme.primary

                Behavior on color {
                    ColorAnimation { duration: 80 }
                }

                scale: searchBtnArea.pressed ? 0.95 : 1.0
                Behavior on scale {
                    NumberAnimation { duration: 80 }
                }

                Text {
                    anchors.centerIn: parent
                    text: "搜索"
                    color: "#FFFFFF"
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    font.weight: Font.Bold
                }

                MouseArea {
                    id: searchBtnArea
                    anchors.fill: parent
                    onClicked: doSearch()
                }
            }
        }

        // 底部分隔线
        Rectangle {
            width: parent.width
            height: 1
            anchors.bottom: parent.bottom
            color: Theme.divider
            opacity: 0.6
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 搜索逻辑
    // ═══════════════════════════════════════════════════════════
    property bool showResults: false
    readonly property bool resultImagesActive: visible && showResults
    property real savedResultContentX: (rootRef && rootRef.searchSavedResultX > 0) ? rootRef.searchSavedResultX : 0

    onSavedResultContentXChanged: {
        if (rootRef) rootRef.searchSavedResultX = savedResultContentX
    }

    // 上一次 count 变化前的条目数：用于区分“新搜索首批结果”与“加载更多追加”
    property int lastResultCountForRestore: 0

    function restoreSearchPosition() {
        if (!showResults) return;
        if (searchResultList.count <= 0) return;
        if (savedResultContentX <= 0) return;
        // 恢复滚动位置：双重延后，防止 visible/size/model 变化触发布局后覆盖 contentX
        Qt.callLater(function() {
            searchResultList.contentX = savedResultContentX;
            Qt.callLater(function() {
                searchResultList.contentX = savedResultContentX;
            });
        });
    }

    function doSearch() {
        var kw = searchInput.text.trim();
        if (kw.length === 0) return;
        var searchModel = controller ? controller.search.searchModel() : null;
        if (searchModel && searchModel.keyword === kw && searchModel.count > 0) {
            showResults = true;
            restoreSearchPosition();
            return;
        }
        savedResultContentX = 0;
        searchResultList.contentX = 0;
        if (controller) controller.search.search(kw);
        showResults = true;
    }

    // ═══════════════════════════════════════════════════════════
    // 热搜列表
    // ═══════════════════════════════════════════════════════════
    Flickable {
        id: hotSearchArea
        visible: !showResults
        anchors {
            top: searchBar.bottom
            bottom: parent.bottom
            left: parent.left
            right: parent.right
            topMargin: 4
            leftMargin: 8
            rightMargin: 8
            bottomMargin: 4
        }
        contentHeight: hotSearchCol.height
        clip: true
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: hotSearchCol
            width: parent.width
            spacing: 2

            // ─────────────────────────────────────
            // 搜索历史
            // ─────────────────────────────────────
            Column {
                id: historyColumn
                width: parent.width
                spacing: 2
                visible: searchInput.text.length === 0 && historyRepeater.count > 0

                // 历史记录标题
                Item {
                    width: parent.width
                    height: 24
                
                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                
                        Text {
                            text: "⏳"
                            font.pixelSize: 11
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "搜索历史"
                            color: Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                
                    Rectangle {
                        id: clearHistoryBtn
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        height: 18
                        width: clearHistoryText.implicitWidth + 10
                        radius: 9
                        visible: historyRepeater.count > 0
                        color: clearHistoryArea.pressed
                               ? Qt.rgba(0, 0, 0, 0.14)
                               : Qt.rgba(0, 0, 0, 0.08)
                
                        Text {
                            id: clearHistoryText
                            anchors.centerIn: parent
                            text: "🗑清空"
                            color: Theme.textSecondary
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                        }
                
                        MouseArea {
                            id: clearHistoryArea
                            anchors.fill: parent
                            anchors.margins: -4
                            onClicked: {
                                if (controller) controller.search.clearSearchHistory()
                            }
                        }
                    }
                }

                // 历史记录项 (横向流动布局)
                Flow {
                    width: parent.width
                    spacing: 6
                    
                    Repeater {
                        id: historyRepeater
                        model: controller ? controller.search.searchHistoryModel() : null

                        Rectangle {
                            height: 24
                            width: historyText.implicitWidth + 22 + (historyItemArea.pressed ? 12 : 0)
                            radius: 12
                            color: historyItemArea.deleteArmed
                                   ? Qt.rgba(1.0, 0.25, 0.25, 0.13)
                                   : (historyItemArea.pressed ? Qt.rgba(0,0,0,0.10) : Qt.rgba(0,0,0,0.05))
                            border.width: 1
                            border.color: historyItemArea.deleteArmed ? Qt.rgba(1.0, 0.25, 0.25, 0.35) : Qt.rgba(0,0,0,0.08)
                            scale: historyItemArea.pressed ? 0.96 : 1.0

                            Behavior on width { NumberAnimation { duration: 100 } }
                            Behavior on scale { NumberAnimation { duration: 80 } }
                            Behavior on color { ColorAnimation { duration: 80 } }
                            Behavior on border.color { ColorAnimation { duration: 80 } }

                            Row {
                                anchors.centerIn: parent
                                spacing: 4

                                Text {
                                    id: historyText
                                    text: model.display
                                    color: Theme.textSecondary
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 12
                                }

                                Text {
                                    visible: historyItemArea.deleteArmed
                                    text: "🗑"
                                    font.pixelSize: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: historyItemArea
                                anchors.fill: parent
                                pressAndHoldInterval: 550
                                property bool longPressed: false
                                property bool deleteArmed: false
                                onPressed: {
                                    longPressed = false;
                                    deleteArmed = false;
                                }
                                onReleased: {
                                    var inside = mouse.x >= 0 && mouse.x <= width && mouse.y >= 0 && mouse.y <= height;
                                    if (deleteArmed && inside && controller) {
                                        controller.search.removeSearchHistory(model.display);
                                    }
                                    deleteArmed = false;
                                }
                                onCanceled: deleteArmed = false
                                onClicked: {
                                    if (longPressed) return;
                                    searchInput.text = model.display;
                                    doSearch();
                                }
                                onPressAndHold: {
                                    longPressed = true;
                                    deleteArmed = true;
                                }
                            }
                        }
                    }
                }
            }

            // ─────────────────────────────────────
            // 热搜榜
            // ─────────────────────────────────────
            // 标题
            Row {
                spacing: 4
                leftPadding: 4
                bottomPadding: 2

                Text {
                    text: "🔥"
                    font.pixelSize: 11
                }
                Text {
                    text: "热搜榜"
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                }
            }

            // 热搜项目
            Repeater {
                model: controller ? controller.search.hotSearchModel() : null

                Rectangle {
                    width: hotSearchCol.width
                    height: 26
                    radius: 6
                    color: hotItemArea.pressed
                    ? Qt.rgba(0.15, 0.56, 0.94, 0.1)
                    : "transparent"

                    Behavior on color {
                        ColorAnimation { duration: 80 }
                    }

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 6
                        spacing: 10

                        // 排名标签
                        Rectangle {
                            width: 18
                            height: 18
                            radius: 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: {
                                if (index === 0) return "#FF6B6B";
                                if (index === 1) return "#FFA94D";
                                if (index === 2) return "#FFD43B";
                                return Qt.rgba(0, 0, 0, 0.05);
                            }

                            Text {
                                anchors.centerIn: parent
                                text: (index + 1).toString()
                                color: index < 3 ? "#FFFFFF" : Theme.textTertiary
                                font.family: Theme.fontFamily
                                font.pixelSize: 10
                                font.weight: Font.Bold
                            }
                        }

                        // 关键词
                        Text {
                            text: model.keyword || ""
                            color: Theme.textPrimary
                            font.family: Theme.fontFamily
                            font.pixelSize: 13
                            elide: Text.ElideRight
                            width: hotSearchCol.width - 44
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: hotItemArea
                        anchors.fill: parent
                        onClicked: {
                            searchInput.text = model.keyword;
                            doSearch();
                        }
                    }
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 搜索结果
    // ═══════════════════════════════════════════════════════════
    Components.LoadMoreListView {
        id: searchResultList
        visible: showResults
        anchors {
            top: searchBar.bottom
            bottom: parent.bottom
            left: parent.left
            right: parent.right
            margins: 6
        }
        model: controller ? controller.search.searchModel() : null
        spacing: 10
        boundsBehavior: Flickable.StopAtBounds
        // 守卫用 controller.isLoading，而非 model.loading
        loading: controller ? controller.isLoading : false

        delegate: Components.VideoCardCompact {
            height: searchResultList.height
            videoTitle: model.title || ""
            coverUrl: model.pic || ""
            imageActive: searchPage.resultImagesActive
            preferOffscreenPlaceholder: controller && controller.videoCardOffscreenPlaceholderEnabled
            upName: model.ownerName || ""
            viewCount: model.views || ""
            durationText: model.durationText || ""
            bvid: model.bvid || ""
            partCount: model.partCount || 1

            // 标题稍微更小 + 标题与 UP 信息间距更小
            titleScale: 0.95
            infoSpacing: 0.5

            onClicked: {
                searchPage.savedResultContentX = searchResultList.contentX
                searchPage.videoSelected(bvid)
            }
        }

        Row {
            visible: showResults
                     && controller
                     && controller.search.searchModel()
                     && controller.search.searchModel().loading
                     && searchResultList.count === 0
            anchors.left: parent.left
            anchors.leftMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            Repeater {
                model: 3
                Components.VideoCardCompact {
                    height: searchResultList.height
                    placeholder: true
                            titleScale: 0.95
                    infoSpacing: 0.5
                }
            }
        }

        onLoadMoreRequested: if (controller) controller.search.searchMore()

        onCountChanged: {
            // 仅当“新搜索首批结果”到达（上一次 count 为 0）时才恢复滚动位置；
            // 加载更多是向后追加，恢复会把 contentX 强制拉回旧值
            if (searchPage.showResults
                    && searchResultList.count > 0
                    && searchPage.lastResultCountForRestore <= 0) {
                searchPage.restoreSearchPosition();
            }
            searchPage.lastResultCountForRestore = searchResultList.count;
        }

        // ── 空状态提示 ──
        Column {
            visible: searchResultList.count === 0
            && showResults
            && controller
            && !controller.isLoading
            anchors.centerIn: parent
            spacing: 6

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "📭"
                font.pixelSize: 24
                opacity: 0.4
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    var sm = controller ? controller.search.searchModel() : null;
                    if (sm && sm.errorMessage) return sm.errorMessage;
                    return "未找到相关视频";
                }
                color: Theme.textTertiary
                font.family: Theme.fontFamily
                font.pixelSize: 12
            }

            // 返回热搜按钮
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 80
                height: 26
                radius: 13
                color: retryBtnArea.pressed
                ? Qt.rgba(0, 0, 0, 0.08)
                : Qt.rgba(0, 0, 0, 0.04)
                border.width: 1
                border.color: Qt.rgba(0, 0, 0, 0.1)

                Text {
                    anchors.centerIn: parent
                    text: "返回热搜"
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                }

                MouseArea {
                    id: retryBtnArea
                    anchors.fill: parent
                    onClicked: {
                        searchInput.text = "";
                        showResults = false;
                    }
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 加载指示器
    // ═══════════════════════════════════════════════════════════
    Components.LoadingIndicator {
        anchors.centerIn: parent
        running: controller ? controller.isLoading : false
        onCancelRequested: {
            if (controller) controller.cancelAll();
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 初始化
    // ═══════════════════════════════════════════════════════════
    Component.onCompleted: {
        if (controller) {
            // 返回搜索页时，如果已有结果就直接恢复，不再触发新的请求
            var searchModel = controller.search.searchModel();
            if (searchModel && searchModel.keyword && searchModel.count > 0) {
                searchInput.text = searchModel.keyword;
                showResults = true;
                restoreSearchPosition();
            } else {
                controller.search.fetchHotSearch();
            }
        }
    }

    onVisibleChanged: {
        if (visible) restoreSearchPosition();
    }

    onShowResultsChanged: {
        if (showResults) restoreSearchPosition();
    }
}
