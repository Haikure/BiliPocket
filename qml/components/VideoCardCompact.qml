// ListView.onPooled/onReused 需要 QtQuick 2.15（Qt 5.15）
import QtQuick 2.15
import ".."
import "../js/ImageUrl.js" as ImageUrl

Item {
    id: card
    width: Theme.cardWidth
    height: parent.height

    property string videoTitle: ""
    property string coverUrl: ""
    property string upName: ""
    property string viewCount: ""
    property string durationText: ""
    property string bvid: ""
    property int rankIndex: 0
    // 多P视频选集角标：可直接传 partCount，也兼容外部显式 showCollection
    property int partCount: 1
    property bool showCollection: partCount > 1
    property bool showRank: false
    property bool isLastWatched: false
    property real fontScale: 1.0
    property real titleScale: 1.0
    property real subScale: 1.0
    property bool titleBold: true
    property bool imageActive: true
    property bool placeholder: false
    property bool preferOffscreenPlaceholder: false
    // 离屏占位不用绑定（绑 view.contentX 会在滚动时每帧重估），改为低频时机主动更新
    property bool offscreenPlaceholderActive: false
    readonly property bool effectivePlaceholder: placeholder || offscreenPlaceholderActive
    // 池化标记：入池后暂停加载与状态更新
    property bool _pooled: false
    // 标题与UP信息之间的垂直间距（默认 2）
    property real infoSpacing: 2
    // 注意：该组件的文本在 Column 中布局，直接改子项 y 通常不会生效
    property real subYOffset: 0
    property string coverImageSource: ""
    property string _loadedCoverUrl: ""

    signal clicked()

    function normalizedCoverSource(url) {
        return ImageUrl.sizedProviderSource(url, 320, 170)
    }

    function isNearViewport() {
        var view = ListView.view
        if (!view) return true
        if (!visible) return false
        if (view.orientation === ListView.Vertical) {
            return y + height >= view.contentY && y <= view.contentY + view.height
        }
        return x + width >= view.contentX && x <= view.contentX + view.width
    }

    function scheduleCoverLoad() {
        var requested = coverUrl
        var shouldLoad = imageActive && !effectivePlaceholder && !_pooled
        if (!requested) {
            coverImageSource = ""
            _loadedCoverUrl = ""
            return
        }
        if (_loadedCoverUrl.length > 0 && _loadedCoverUrl !== requested) {
            coverImageSource = ""
            _loadedCoverUrl = ""
        }
        if (!shouldLoad) return
        Qt.callLater(function() {
            if (imageActive && !effectivePlaceholder && !card._pooled && coverUrl === requested) {
                coverImageSource = normalizedCoverSource(requested)
                _loadedCoverUrl = requested
            }
        })
    }

    function updateOffscreenPlaceholder() {
        if (_pooled) return
        var next = preferOffscreenPlaceholder && !placeholder && !isNearViewport()
        if (offscreenPlaceholderActive !== next) offscreenPlaceholderActive = next
    }

    Component.onCompleted: {
        updateOffscreenPlaceholder()
        scheduleCoverLoad()
    }
    onCoverUrlChanged: scheduleCoverLoad()
    onImageActiveChanged: scheduleCoverLoad()
    onPreferOffscreenPlaceholderChanged: updateOffscreenPlaceholder()
    onPlaceholderChanged: updateOffscreenPlaceholder()
    onVisibleChanged: updateOffscreenPlaceholder()
    onEffectivePlaceholderChanged: {
        scheduleCoverLoad()
        if (effectivePlaceholder) {
            Qt.callLater(function() {
                if (card.effectivePlaceholder) effectivePlaceholderTextCanvas.requestPaint()
            })
        }
    }

    // 复用时要重估占位并重新调度封面：model 角色未变不会触发 onCoverUrlChanged
    ListView.onPooled: card._pooled = true
    ListView.onReused: {
        card._pooled = false
        card.updateOffscreenPlaceholder()
        card.scheduleCoverLoad()
    }

    // 也监听 contentX/Y：恢复滚动位置等程序化跳转不会发 movementEnded
    Connections {
        target: (card.preferOffscreenPlaceholder && card.ListView.view) ? card.ListView.view : null
        function onMovementEnded() { card.updateOffscreenPlaceholder() }
        function onFlickEnded() { card.updateOffscreenPlaceholder() }
        function onContentXChanged() { if (target && !target.moving) card.updateOffscreenPlaceholder() }
        function onContentYChanged() { if (target && !target.moving) card.updateOffscreenPlaceholder() }
    }

    Rectangle {
        id: cardBg
        anchors.fill: parent
        radius: 6
        color: Theme.bgSecondary
        border.color: card.isLastWatched ? Theme.accent : (mouseArea.pressed ? Theme.primary : "transparent")
        border.width: card.isLastWatched ? 2 : 1

        Behavior on border.color { ColorAnimation { duration: 80 } }

        // 封面区 (高度约 65%)
        Rectangle {
            id: coverContainer
            width: parent.width - 4
            height: parent.height * 0.58
            anchors.top: parent.top
            anchors.topMargin: 2
            anchors.horizontalCenter: parent.horizontalCenter
            radius: 4
            color: Theme.bgTertiary
            clip: true

            Image {
                id: coverImage
                anchors.fill: parent
                source: coverImageSource
                sourceSize: Qt.size(210, 140)
                cache: true
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                smooth: true
                mipmap: true

                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 150 } }
            }

            // 占位
            Text {
                visible: coverImage.status !== Image.Ready
                text: "📺"
                font.pixelSize: 18
                opacity: 0.3
                anchors.centerIn: parent
            }

            // 时长
            Rectangle {
                visible: !effectivePlaceholder && durationText.length > 0
                anchors { right: parent.right; bottom: parent.bottom; margins: 3 }
                width: durationLabel.width + 8
                height: 14
                radius: 3
                color: "#CC000000"

                Text {
                    id: durationLabel
                    text: durationText
                    color: "#FFFFFF"
                    font.family: Theme.fontFamily
                    font.pixelSize: 9 * card.fontScale
                    font.bold: true
                    anchors.centerIn: parent
                }
            }

            // 选集角标（多P视频）
            Rectangle {
                visible: !effectivePlaceholder && showCollection
                anchors { left: parent.left; bottom: parent.bottom; leftMargin: 4; bottomMargin: 4 }
                width: collectionText.implicitWidth + 10
                height: 14
                radius: 6
                color: Qt.rgba(0, 0, 0, 0.58)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.18)
                z: 2

                Text {
                    id: collectionText
                    text: "选集"
                    color: "#F8FAFC"
                    font.family: Theme.fontFamily
                    font.pixelSize: 8
                    font.bold: true
                    anchors.centerIn: parent
                }
            }

            // 上次观看标记
            Rectangle {
                visible: !effectivePlaceholder && card.isLastWatched
                anchors { left: parent.left; top: parent.top; margins: 3 }
                width: lastWatchedLabel.implicitWidth + 8
                height: 14
                radius: 7
                color: Theme.withAlpha(Theme.accent, 0.92)
                border.width: 1
                border.color: Theme.withAlpha(Theme.textOnPrimary, 0.28)
                z: 3

                Text {
                    id: lastWatchedLabel
                    anchors.centerIn: parent
                    text: "上次"
                    color: Theme.textOnPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: 8
                    font.bold: true
                }
            }

            // 排名
            Rectangle {
                visible: !effectivePlaceholder && showRank && rankIndex > 0
                anchors { left: parent.left; top: parent.top; margins: 3 }
                width: 16; height: 14
                radius: 3
                color: rankIndex <= 3 ? Theme.error : "#CC000000"

                Text {
                    text: rankIndex
                    color: "#FFFFFF"
                    font.family: Theme.fontFamily
                    font.pixelSize: 9
                    font.bold: true
                    anchors.centerIn: parent
                }
            }
        }

        // 信息区（骨架占位）
        SkeletonPill {
            id: effectivePlaceholderTextCanvas
            visible: effectivePlaceholder
            anchors {
                top: coverContainer.bottom
                topMargin: 4
                left: parent.left
                right: parent.right
                leftMargin: 5
                rightMargin: 5
                bottom: parent.bottom
                bottomMargin: 3
            }
            pills: [
                { x: 0, y: 0, w: 0.92, h: 8, color: Theme.withAlpha(Theme.textTertiary, 0.16) },
                { x: 0, y: 11, w: 0.78, h: 8, color: Theme.withAlpha(Theme.textTertiary, 0.12) },
                { x: 0, y: 25, w: 0.56, h: 7, color: Theme.withAlpha(Theme.textTertiary, 0.10) }
            ]
        }

        Column {
            visible: !effectivePlaceholder
            anchors {
                top: coverContainer.bottom
                topMargin: 4
                left: parent.left
                right: parent.right
                leftMargin: 5
                rightMargin: 5
                bottom: parent.bottom
                bottomMargin: 3
            }
            spacing: infoSpacing

            // 标题
            Text {
                width: parent.width
                text: videoTitle
                color: Theme.textPrimary
                font.family: Theme.fontFamily
                font.pixelSize: 10 * card.fontScale * card.titleScale
                font.bold: titleBold
                maximumLineCount: 2
                wrapMode: Text.Wrap
                elide: Text.ElideRight
                lineHeight: 1.15
            }

            // UP主 + 播放量
            Text {
                width: parent.width
                // 处于 Column 布局中，y 可能会被布局覆盖，保留该属性以兼容需要时的手动布局
                y: subYOffset
                text: upName + (viewCount ? " · " + viewCount : "")
                color: "#7A7A7A"
                font.family: Theme.fontFamily
                font.pixelSize: 8 * card.fontScale * card.subScale
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: mouseArea
            anchors.fill: parent
            enabled: !effectivePlaceholder
            onClicked: card.clicked()
        }
    }
}
