import QtQuick 2.12
import QtGraphicalEffects 1.12
import "../components" as Components
import ".."

Rectangle {
    id: detailPage
    width: 320
    height: 170
    color: Theme.bgPrimary
    clip: true

    property var controller: null
    property var dynamicData: ({})
    property string fullscreenImageUrl: ""
    property bool imageFullscreenVisible: false

    signal backClicked()
    signal videoSelected(string bvid)
    signal upRequested(var mid)
    signal commentsRequested(var context)

    function value(key, fallback) {
        if (!dynamicData) return fallback
        var v = dynamicData[key]
        return (v === undefined || v === null) ? fallback : v
    }

    function asArray(value) {
        if (!value) return []
        if (value.length === undefined) return []
        var arr = []
        for (var i = 0; i < value.length; ++i) {
            if (value[i]) arr.push(value[i])
        }
        return arr
    }

    function cdnSizedUrl(url, suffix) {
        if (!url) return ""
        var s = String(url)
        if (s.indexOf("data:image/") === 0 || s.indexOf("image://") === 0) return s
        var queryIndex = s.indexOf("?")
        var base = queryIndex >= 0 ? s.slice(0, queryIndex) : s
        var query = queryIndex >= 0 ? s.slice(queryIndex) : ""
        var slash = base.lastIndexOf("/")
        var at = base.indexOf("@", slash + 1)
        if (at >= 0) base = base.slice(0, at)
        return base + suffix + query
    }

    function originalImageUrl(url) {
        if (!url) return ""
        var s = String(url)
        if (s.indexOf("image://") === 0 || s.indexOf("data:image/") === 0) return s
        var queryIndex = s.indexOf("?")
        var base = queryIndex >= 0 ? s.slice(0, queryIndex) : s
        var query = queryIndex >= 0 ? s.slice(queryIndex) : ""
        var slash = base.lastIndexOf("/")
        var at = base.indexOf("@", slash + 1)
        if (at >= 0) base = base.slice(0, at)
        return base + query
    }

    function cdnImageSource(url, suffix) {
        var s = cdnSizedUrl(url, suffix)
        if (!s) return ""
        if (s.indexOf("data:image/") === 0 || s.indexOf("image://") === 0) return s
        return "image://bili/" + encodeURIComponent(s)
    }

    function avatarImageSource(url) {
        return cdnImageSource(url, "@50w_50h")
    }

    function previewImageSource(url) {
        return cdnImageSource(url, "@320w_170h")
    }

    function fullImageSource(url) {
        var s = originalImageUrl(url)
        if (!s) return ""
        if (s.indexOf("data:image/") === 0 || s.indexOf("image://") === 0) return s
        return "image://bili/original/" + encodeURIComponent(s)
    }

    function commentContext() {
        var oid = String(value("commentOid", "") || "").trim()
        var type = Number(value("commentType", 0) || 0)
        if ((oid.length === 0 || oid === "0") && Number(value("majorAid", 0) || 0) > 0) {
            oid = String(value("majorAid", 0))
            type = 1
        }
        if ((oid.length === 0 || oid === "0") && Number(value("origAid", 0) || 0) > 0) {
            oid = String(value("origAid", 0))
            type = 1
        }
        return {
            oid: oid,
            type: type,
            key: oid.length > 0 && oid !== "0" && type > 0
                 ? "dynamic:" + value("idStr", "") + ":" + type + ":" + oid : "",
            title: titleText || bodyText || "动态评论",
            bvid: openBvid
        }
    }

    function openComments() {
        var ctx = commentContext()
        if (String(ctx.oid || "").length > 0 && ctx.oid !== "0" && ctx.type > 0) {
            detailPage.commentsRequested(ctx)
        } else if (controller) {
            controller.toastMessage("暂不支持查看该动态评论")
        }
    }

    function openPicture(url) {
        var original = originalImageUrl(url)
        if (!original) return
        if (controller) controller.toastMessage("正在打开图片...")
        if (controller && typeof imageViewer !== "undefined" && imageViewer) {
            controller.viewer.prepareImageForViewer(original)
            return
        }
        fullscreenImageUrl = original
        imageFullscreenVisible = !!fullscreenImageUrl
    }

    function openSystemImageViewer(localPath) {
        if (!localPath) return
        if (typeof imageViewer !== "undefined" && imageViewer) {
            imageViewer.open(localPath)
            id_pop_container.show("qrc:/qml/audiopages/FileManagerImageViewer.qml")
        } else {
            fullscreenImageUrl = localPath
            imageFullscreenVisible = true
        }
    }

    function displayPictures() {
        var pics = asArray(value("pictures", []))
        var cover = value("majorCover", "")
        if (pics.length === 0 && cover && !value("isVideo", false)) pics.push(cover)
        return pics
    }

    readonly property string titleText: value("majorTitle", "")
    readonly property string bodyText: value("text", "")
    readonly property string openBvid: value("majorBvid", "") || value("origBvid", "")
    readonly property var pictureItems: displayPictures()

    Components.TitleBar {
        id: titleBar
        title: value("isArticle", false) ? "文章详情" : "动态详情"
        showBack: true
        anchors.top: parent.top
        onBackClicked: detailPage.backClicked()
    }

    Flickable {
        id: flick
        anchors.top: titleBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        contentHeight: Math.max(height, contentColumn.childrenRect.height + Theme.spacingMedium)
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
            id: contentColumn
            width: flick.width - 12
            x: 6
            y: 6
            spacing: 6

            Row {
                width: parent.width
                height: 24
                spacing: 6

                Rectangle {
                    id: authorAvatar
                    width: 22
                    height: 22
                    radius: 11
                    color: Theme.bgTertiary
                    clip: true

                    Image {
                        id: authorAvatarImage
                        anchors.fill: parent
                        source: avatarImageSource(value("authorFace", ""))
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                        visible: false
                    }

                    OpacityMask {
                        anchors.fill: authorAvatarImage
                        source: authorAvatarImage
                        maskSource: Rectangle {
                            width: authorAvatarImage.width
                            height: authorAvatarImage.height
                            radius: Math.min(width, height) / 2
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        enabled: Number(value("authorMid", 0) || 0) > 0
                        onClicked: detailPage.upRequested(Number(value("authorMid", 0)))
                    }
                }

                Column {
                    width: parent.width - 28
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1

                    Text {
                        width: parent.width
                        text: value("authorName", "动态")
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontBody
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    Text {
                        width: parent.width
                        text: (value("pubAction", "") ? value("pubAction", "") + " · " : "") + value("pubTime", "")
                        color: Theme.textTertiary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSmall
                        elide: Text.ElideRight
                    }
                }
            }

            Text {
                visible: titleText.length > 0 && titleText !== bodyText
                width: parent.width
                text: titleText
                color: Theme.textPrimary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontLarge
                font.bold: true
                wrapMode: Text.Wrap
            }

            Text {
                width: parent.width
                text: bodyText.length > 0 ? bodyText : (titleText.length > 0 ? "" : "这条动态暂时没有文字内容")
                color: Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontMedium
                lineHeight: 1.16
                wrapMode: Text.Wrap
                visible: text.length > 0
            }

            Rectangle {
                visible: value("isForward", false) && (value("origTitle", "") || value("origSummary", ""))
                width: parent.width
                height: Math.max(30, forwardText.implicitHeight + 12)
                radius: Theme.radiusSmall
                color: Theme.bgSecondary
                border.width: 1
                border.color: Theme.border

                Text {
                    id: forwardText
                    anchors.fill: parent
                    anchors.margins: 6
                    text: value("origTitle", "") || value("origSummary", "")
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontBody
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
            }

            Repeater {
                model: pictureItems
                delegate: Rectangle {
                    width: contentColumn.width
                    height: 118
                    radius: Theme.radiusSmall
                    color: Theme.bgTertiary
                    clip: true

                    Image {
                        anchors.fill: parent
                        source: previewImageSource(modelData)
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: detailPage.openPicture(modelData)
                    }
                }
            }

            Rectangle {
                visible: openBvid.length > 0
                width: parent.width
                height: 28
                radius: Theme.radiusSmall
                color: openVideoArea.pressed ? Theme.withAlpha(Theme.primary, 0.28)
                                             : Theme.withAlpha(Theme.primary, 0.14)
                border.width: 1
                border.color: Theme.withAlpha(Theme.primary, 0.35)

                Text {
                    anchors.centerIn: parent
                    text: "打开视频"
                    color: Theme.primary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                    font.bold: true
                }

                MouseArea {
                    id: openVideoArea
                    anchors.fill: parent
                    onClicked: detailPage.videoSelected(openBvid)
                }
            }

            Rectangle {
                id: actionDock
                width: parent.width
                height: 30
                radius: Theme.radiusMedium
                color: Theme.withAlpha(Theme.bgSecondary, 0.92)
                border.width: 1
                border.color: Theme.withAlpha(Theme.borderLight, 0.72)

                Row {
                    anchors.fill: parent
                    anchors.margins: 3
                    spacing: 4

                    Item {
                        id: likeAction
                        width: (parent.width - parent.spacing) / 2
                        height: parent.height

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.radiusSmall
                            color: Theme.withAlpha(Theme.accent, 0.12)
                            border.width: 1
                            border.color: Theme.withAlpha(Theme.accent, 0.24)
                        }

                        Row {
                            anchors.centerIn: parent
                            spacing: 5

                            Canvas {
                                width: 14
                                height: 14
                                anchors.verticalCenter: parent.verticalCenter
                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.strokeStyle = Theme.accent
                                    ctx.fillStyle = Theme.withAlpha(Theme.accent, 0.18)
                                    ctx.lineWidth = 1.35
                                    ctx.lineCap = "round"
                                    ctx.lineJoin = "round"
                                    ctx.beginPath()
                                    ctx.moveTo(7, 12)
                                    ctx.bezierCurveTo(2.5, 8.8, 1.5, 6.7, 2.1, 4.5)
                                    ctx.bezierCurveTo(2.6, 2.6, 5.1, 2.1, 7, 4.2)
                                    ctx.bezierCurveTo(8.9, 2.1, 11.4, 2.6, 11.9, 4.5)
                                    ctx.bezierCurveTo(12.5, 6.7, 11.5, 8.8, 7, 12)
                                    ctx.closePath()
                                    ctx.fill()
                                    ctx.stroke()
                                }
                                Component.onCompleted: requestPaint()
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "点赞 " + value("likeCountText", "0")
                                color: Theme.accent
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                                font.bold: true
                                elide: Text.ElideRight
                                width: 88
                            }
                        }
                    }

                    Item {
                        id: commentAction
                        width: (parent.width - parent.spacing) / 2
                        height: parent.height

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.radiusSmall
                            color: commentActionArea.pressed
                                   ? Theme.withAlpha(Theme.primary, 0.24)
                                   : Theme.withAlpha(Theme.primary, 0.13)
                            border.width: 1
                            border.color: Theme.withAlpha(Theme.primary, 0.30)

                            Behavior on color { ColorAnimation { duration: Theme.animFast } }
                        }

                        Row {
                            anchors.centerIn: parent
                            spacing: 5

                            Canvas {
                                width: 15
                                height: 15
                                anchors.verticalCenter: parent.verticalCenter
                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.clearRect(0, 0, width, height)
                                    ctx.strokeStyle = Theme.primary
                                    ctx.lineWidth = 1.35
                                    ctx.lineCap = "round"
                                    ctx.lineJoin = "round"
                                    ctx.beginPath()
                                    ctx.moveTo(3.5, 4)
                                    ctx.quadraticCurveTo(3.5, 2.5, 5, 2.5)
                                    ctx.lineTo(10.5, 2.5)
                                    ctx.quadraticCurveTo(12, 2.5, 12, 4)
                                    ctx.lineTo(12, 8.4)
                                    ctx.quadraticCurveTo(12, 9.9, 10.5, 9.9)
                                    ctx.lineTo(7.4, 9.9)
                                    ctx.lineTo(4.8, 12.5)
                                    ctx.lineTo(5.4, 9.9)
                                    ctx.lineTo(5, 9.9)
                                    ctx.quadraticCurveTo(3.5, 9.9, 3.5, 8.4)
                                    ctx.closePath()
                                    ctx.stroke()
                                    ctx.beginPath()
                                    ctx.moveTo(6, 5.6)
                                    ctx.lineTo(9.7, 5.6)
                                    ctx.moveTo(6, 7.6)
                                    ctx.lineTo(8.8, 7.6)
                                    ctx.stroke()
                                }
                                Component.onCompleted: requestPaint()
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "评论 " + value("commentCountText", "0")
                                color: Theme.primary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                                font.bold: true
                                elide: Text.ElideRight
                                width: 88
                            }
                        }

                        MouseArea {
                            id: commentActionArea
                            anchors.fill: parent
                            onClicked: detailPage.openComments()
                        }
                    }
                }
            }
        }
    }

    Rectangle {
        visible: detailPage.imageFullscreenVisible
        anchors.fill: parent
        color: "#E6000000"
        z: 100

        MouseArea {
            anchors.fill: parent
            onClicked: {
                detailPage.imageFullscreenVisible = false
                detailPage.fullscreenImageUrl = ""
            }
        }

        Image {
            anchors.fill: parent
            anchors.margins: 8
            source: detailPage.fullImageSource(detailPage.fullscreenImageUrl)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
        }
    }

    Connections {
        target: controller
        ignoreUnknownSignals: true
        function onCommentImageReadyForViewer(localPath) {
            detailPage.openSystemImageViewer(localPath)
        }
    }

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
}
