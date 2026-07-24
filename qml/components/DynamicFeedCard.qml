import QtQuick 2.12
import QtGraphicalEffects 1.12
import ".."

Item {
    id: card
    width: 304
    height: Math.max(76, Math.min(108, contentColumn.implicitHeight + 14))

    property string authorName: ""
    property string authorFace: ""
    property string pubAction: ""
    property string pubTime: ""
    property string text: ""
    property string majorTitle: ""
    property string majorCover: ""
    property string majorBvid: ""
    property string majorDurationText: ""
    property var pictures: []
    property string origSummary: ""
    property string origTitle: ""
    property string origCover: ""
    property string repostCountText: "0"
    property string commentCountText: "0"
    property string likeCountText: "0"
    property bool isVideo: false
    property bool isImage: false
    property bool isArticle: false
    property bool isLive: false
    property bool isForward: false
    property bool imageActive: true
    readonly property bool clickable: (isVideo && majorBvid.length > 0)
                                      || isImage || isArticle || isForward
                                      || text.length > 0 || majorTitle.length > 0
    readonly property string typeLabel: isLive ? "直播"
                                               : (isArticle ? "文章"
                                                            : (isImage ? "图文" : "动态"))
    property string avatarSource: cdnImageSource(authorFace, "@50w_50h")
    property string coverSource: cdnImageSource(majorCover, "@320w_170h")
    property string origCoverSource: cdnImageSource(origCover, "@320w_170h")

    signal clicked(string bvid)

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

    function cdnImageSource(url, suffix) {
        var s = cdnSizedUrl(url, suffix)
        if (!s) return ""
        if (s.indexOf("data:image/") === 0 || s.indexOf("image://") === 0) return s
        return "image://bili/" + encodeURIComponent(s)
    }

    function pictureAt(i) {
        if (!pictures || pictures.length <= i) return ""
        return pictures[i]
    }

    Rectangle {
        id: bg
        anchors.fill: parent
        radius: Theme.radiusMedium
        color: cardArea.pressed && card.clickable ? Theme.withAlpha(Theme.primary, 0.13) : Theme.bgCard
        border.width: 1
        border.color: card.clickable ? Theme.withAlpha(Theme.primary, 0.18) : Theme.border

        Behavior on color { ColorAnimation { duration: Theme.animFast } }
        Behavior on border.color { ColorAnimation { duration: Theme.animFast } }

        Column {
            id: contentColumn
            anchors.fill: parent
            anchors.margins: 6
            spacing: 3

            Row {
                width: parent.width
                height: 15
                spacing: 4

                Rectangle {
                    width: 14
                    height: 14
                    radius: 7
                    color: Theme.bgTertiary
                    clip: true
                    Image {
                        id: avatarImage
                        anchors.fill: parent
                        source: card.imageActive ? card.avatarSource : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
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

                Text {
                    width: Math.max(50, parent.width - 112)
                    anchors.verticalCenter: parent.verticalCenter
                    text: card.authorName || "动态"
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontBody
                    font.bold: true
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                Text {
                    width: 88
                    anchors.verticalCenter: parent.verticalCenter
                    text: (card.pubAction ? card.pubAction + " · " : "") + card.pubTime
                    color: Theme.textTertiary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignRight
                    maximumLineCount: 1
                }
            }

            Row {
                width: parent.width
                spacing: 5

                Column {
                    width: parent.width - (mediaBox.visible ? mediaBox.width + parent.spacing : 0)
                    spacing: 3

                    Text {
                        width: parent.width
                        text: card.text || card.majorTitle || card.origSummary || "这条动态暂时没有文字内容"
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontNormal
                        lineHeight: 1.0
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        visible: card.isForward && (card.origSummary.length > 0 || card.origTitle.length > 0)
                        width: parent.width
                        height: 18
                        radius: Theme.radiusSmall
                        color: Theme.withAlpha(Theme.bgTertiary, 0.72)
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.borderLight, 0.45)

                        Row {
                            anchors.fill: parent
                            anchors.margins: 3
                            spacing: 4
                            Rectangle {
                                visible: card.origCover.length > 0
                                width: 12
                                height: 12
                                radius: 3
                                color: Theme.bgSecondary
                                clip: true
                                Image {
                                    anchors.fill: parent
                                    source: card.imageActive ? card.origCoverSource : ""
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }
                            }
                            Text {
                                width: parent.width - (card.origCover.length > 0 ? 18 : 0)
                                anchors.verticalCenter: parent.verticalCenter
                                text: card.origTitle || card.origSummary
                                color: Theme.textSecondary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSmall
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        height: 12
                        spacing: 8
                        Text { text: "转 " + card.repostCountText; color: Theme.textTertiary; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall }
                        Text { text: "评 " + card.commentCountText; color: Theme.textTertiary; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall }
                        Text { text: "赞 " + card.likeCountText; color: Theme.textTertiary; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSmall }
                    }
                }

                Rectangle {
                    id: mediaBox
                    visible: card.majorCover.length > 0 || (card.pictures && card.pictures.length > 0)
                    width: card.isVideo ? 72 : 58
                    height: card.isVideo ? 42 : 38
                    radius: Theme.radiusSmall
                    color: Theme.bgTertiary
                    clip: true

                    Image {
                        visible: card.majorCover.length > 0 || card.isVideo
                        anchors.fill: parent
                        source: card.imageActive ? card.coverSource : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                    }

                    Row {
                        visible: !card.isVideo && card.pictures && card.pictures.length > 1
                        anchors.fill: parent
                        spacing: 1
                        Repeater {
                            model: Math.min(3, card.pictures ? card.pictures.length : 0)
                            Rectangle {
                                width: (mediaBox.width - 2) / Math.min(3, card.pictures ? card.pictures.length : 1)
                                height: mediaBox.height
                                color: Theme.bgSecondary
                                clip: true
                                Image {
                                    anchors.fill: parent
                                    source: card.imageActive ? card.cdnImageSource(card.pictureAt(index), "@320w_170h") : ""
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    smooth: true
                                }
                            }
                        }
                    }

                    Rectangle {
                        visible: card.isVideo && card.majorDurationText.length > 0
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 2
                        width: durationText.implicitWidth + 6
                        height: 12
                        radius: 3
                        color: "#CC000000"
                        Text {
                            id: durationText
                            anchors.centerIn: parent
                            text: card.majorDurationText
                            color: "#FFFFFF"
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontTiny
                            font.bold: true
                        }
                    }

                    Rectangle {
                        visible: !card.isVideo && card.typeLabel.length > 0
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.margins: 2
                        width: typeText.implicitWidth + 6
                        height: 12
                        radius: 3
                        color: Theme.withAlpha(card.isLive ? Theme.accent : Theme.primary, 0.88)
                        Text {
                            id: typeText
                            anchors.centerIn: parent
                            text: card.typeLabel
                            color: Theme.textOnPrimary
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontTiny
                            font.bold: true
                        }
                    }
                }
            }
        }
    }

    MouseArea {
        id: cardArea
        anchors.fill: parent
        anchors.margins: -2
        onClicked: {
            if (!card.clickable) return
            card.clicked(card.isVideo ? card.majorBvid : "")
        }
    }

    scale: cardArea.pressed && card.clickable ? 0.985 : 1.0
    Behavior on scale { NumberAnimation { duration: 80 } }
}
