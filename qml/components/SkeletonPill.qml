import QtQuick 2.12
import ".."

// 骨架屏“药丸”占位 Canvas：pills 为空时画满整个组件，否则按数组逐条画。
// 坐标约定：x/w 落在 (0,1] 时按组件宽度取比例，>1 为绝对像素；y/h 恒为像素。
Canvas {
    id: skeleton

    property var pills: []
    property color pillColor: Theme.withAlpha(Theme.textTertiary, 0.16)
    property int paintToken: 0

    Component.onCompleted: requestPaint()
    onPillsChanged: requestPaint()
    onPillColorChanged: requestPaint()
    onPaintTokenChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    function _resolveX(v) {
        var n = Number(v || 0)
        return (n > 0 && n <= 1) ? n * width : n
    }

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

        var list = skeleton.pills
        if (!list || list.length === 0) {
            pill(0, 0, width, height, skeleton.pillColor)
            return
        }
        for (var i = 0; i < list.length; ++i) {
            var p = list[i]
            if (!p) continue
            pill(skeleton._resolveX(p.x), Number(p.y || 0),
                 skeleton._resolveX(p.w), Number(p.h || 0),
                 p.color !== undefined ? p.color : skeleton.pillColor)
        }
    }
}
