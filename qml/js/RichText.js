.pragma library

// 富文本工具库（.pragma library）：HTML 转义 + b23.tv/BV 号链接化 + 评论表情。
// 两个入口：linkifyVideoLinks() 只链接化，emoteRichText() 额外渲染表情。
// 库内取不到 Theme，linkColor / baseFontSize 需由调用方传入。

var DEFAULT_LINK_COLOR = "#60a5fa"
var DEFAULT_BASE_FONT_SIZE = 9

// 正文转义（& < >）。
function escapeRichText(text) {
    if (!text) return ""
    var s = String(text)
    s = s.replace(/&/g, "&amp;")
    s = s.replace(/</g, "&lt;")
    s = s.replace(/>/g, "&gt;")
    return s
}

// HTML 属性转义（& " < >）。
function escapeHtmlAttribute(text) {
    if (!text) return ""
    var s = String(text)
    s = s.replace(/&/g, "&amp;")
    s = s.replace(/"/g, "&quot;")
    s = s.replace(/</g, "&lt;")
    s = s.replace(/>/g, "&gt;")
    return s
}

// token 是否为 b23.tv 短链或 BV 号（整串匹配）。
function isVideoLinkToken(token) {
    if (!token) return false
    return /^(?:https?:\/\/)?(?:[Ww][Ww][Ww]\.)?[Bb]23\.[Tt][Vv]\/[0-9A-Za-z]+$/.test(token) ||
            /^[Bb][Vv]1[1-9A-HJ-NP-Za-km-z]{9}$/.test(token)
}

// 链接锚点（配合 Text.onLinkActivated → controller.video.resolveVideoLink）。
function videoLinkAnchor(token, linkColor) {
    var color = linkColor || DEFAULT_LINK_COLOR
    return "<a href=\"" + escapeHtmlAttribute(token) + "\" style=\"color:" + color +
            ";text-decoration:none;\">" + escapeRichText(token) + "</a>"
}

// 转义 + 链接化（不处理表情）；text 为空时用 fallbackText。
function linkifyVideoLinks(text, fallbackText, linkColor) {
    var raw = text && text.length > 0 ? String(text) : (fallbackText || "")
    var pattern = /(?:https?:\/\/)?(?:[Ww][Ww][Ww]\.)?[Bb]23\.[Tt][Vv]\/[0-9A-Za-z]+|[Bb][Vv]1[1-9A-HJ-NP-Za-km-z]{9}/g
    var lastIndex = 0
    var result = ""
    var match

    while ((match = pattern.exec(raw)) !== null) {
        var start = match.index
        var token = match[0]
        result += escapeRichText(raw.slice(lastIndex, start))
        result += videoLinkAnchor(token, linkColor)
        lastIndex = start + token.length
    }

    result += escapeRichText(raw.slice(lastIndex))
    return result.replace(/\r\n/g, "<br>").replace(/\n/g, "<br>").replace(/\r/g, "<br>")
}

// 表情 URL 归一：协议补全 https + /bfs/emote/ 图追加 @80w_80h。
function normalizeEmoteUrl(url) {
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

// 在表情表里查 token（兼容带/不带方括号的 key）。
function findEmote(emotes, token) {
    if (!emotes || !token) return null
    if (emotes[token]) return emotes[token]
    if (token.length > 2 && token.charAt(0) === "[" && token.charAt(token.length - 1) === "]") {
        var bare = token.slice(1, -1)
        if (emotes[bare]) return emotes[bare]
    }
    return null
}

// 表情显示尺寸（随正文字号缩放并夹紧）。
function emoteDisplaySize(emote, baseSize) {
    var base = Number(baseSize || DEFAULT_BASE_FONT_SIZE)
    var metaSize = Number(emote && emote.size ? emote.size : 1)
    var scale = metaSize >= 2 ? 1.35 : 1.15
    var size = Math.round(base * scale)
    var minSize = base
    var maxSize = base + 5
    return Math.max(minSize, Math.min(size, maxSize))
}

// 转义 + 链接化 + 表情图片。emotes: { "[表情名]": { url, size }, ... }，可为空。
function emoteRichText(content, emotes, baseFontSize, linkColor) {
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
        rich += escapeRichText(raw.slice(lastIndex, start))

        if (isVideoLinkToken(token)) {
            rich += videoLinkAnchor(token, linkColor)
        } else {
            var emote = findEmote(emotes, token)
            if (!emote || !emote.url) {
                rich += escapeRichText(token)
            } else {
                var size = emoteDisplaySize(emote, baseFontSize)
                var src = escapeHtmlAttribute(normalizeEmoteUrl(emote.url))
                var alt = escapeHtmlAttribute(token)
                rich += "<img src=\"" + src + "\" width=\"" + size + "\" height=\"" + size + "\" alt=\"" + alt + "\" />"
            }
        }

        lastIndex = start + token.length
    }

    rich += escapeRichText(raw.slice(lastIndex))
    return rich.replace(/\n/g, "<br>")
}
