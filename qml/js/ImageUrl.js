.pragma library

// B 站 CDN 图片 URL 处理（.pragma library，components/pages 共享）。
// data:image/... 与 image://... 一律直通原样返回，不能再包进 provider。

function _isPassthrough(s) {
    return s.indexOf("data:image/") === 0 || s.indexOf("image://") === 0
}

// 把已有的 @尺寸后缀替换为 suffix（形如 "@50w_50h"），保留 query。
function cdnSizedUrl(url, suffix) {
    if (!url) return ""
    var s = String(url)
    if (_isPassthrough(s)) return s
    var queryIndex = s.indexOf("?")
    var base = queryIndex >= 0 ? s.slice(0, queryIndex) : s
    var query = queryIndex >= 0 ? s.slice(queryIndex) : ""
    var slash = base.lastIndexOf("/")
    var at = base.indexOf("@", slash + 1)
    if (at >= 0) base = base.slice(0, at)
    return base + suffix + query
}

// 去掉 @尺寸后缀，还原原图 URL。
function originalUrl(url) {
    if (!url) return ""
    var s = String(url)
    if (_isPassthrough(s)) return s
    var queryIndex = s.indexOf("?")
    var base = queryIndex >= 0 ? s.slice(0, queryIndex) : s
    var query = queryIndex >= 0 ? s.slice(queryIndex) : ""
    var slash = base.lastIndexOf("/")
    var at = base.indexOf("@", slash + 1)
    if (at >= 0) base = base.slice(0, at)
    return base + query
}

// cdnSizedUrl + image://bili/ 包装。
function cdnImageSource(url, suffix) {
    var s = cdnSizedUrl(url, suffix)
    if (!s) return ""
    if (_isPassthrough(s)) return s
    return "image://bili/" + encodeURIComponent(s)
}

// 头像 50x50（替换已有后缀）。
function avatarSource(url) {
    return cdnImageSource(url, "@50w_50h")
}

// 头像 50x50，但已有 @ 后缀则原样保留。
function avatarSourceKeepExisting(url) {
    if (!url) return ""
    var s = String(url)
    if (_isPassthrough(s)) return s
    var queryIndex = s.indexOf("?")
    var base = queryIndex >= 0 ? s.slice(0, queryIndex) : s
    var query = queryIndex >= 0 ? s.slice(queryIndex) : ""
    if (base.indexOf("@") < 0) s = base + "@50w_50h" + query
    return "image://bili/" + encodeURIComponent(s)
}

// 预览图 320x170。
function previewSource(url) {
    return cdnImageSource(url, "@320w_170h")
}

// 原图（走 image://bili/original/ 通道，先剥掉 @ 后缀）。
function originalImageSource(url) {
    var s = originalUrl(url)
    if (!s) return ""
    if (_isPassthrough(s)) return s
    return "image://bili/original/" + encodeURIComponent(s)
}

// 原样走 image://bili/ 通道，不改尺寸。
function rawImageSource(url) {
    if (!url) return ""
    var s = String(url)
    if (_isPassthrough(s)) return s
    return "image://bili/" + encodeURIComponent(s)
}

// 走 image://bili/size/WxH/ 缩放通道。
function sizedProviderSource(url, w, h) {
    if (!url) return ""
    var s = String(url)
    if (_isPassthrough(s)) return s
    return "image://bili/size/" + w + "x" + h + "/" + encodeURIComponent(s)
}
