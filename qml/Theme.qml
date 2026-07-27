pragma Singleton
import QtQuick 2.12

Item {
    FontLoader {
        id: appFont
        source: "LXGWWenKai-Regular.ttf"
    }

    // ── 主题色 ──
    readonly property color primary: "#00A1D6"
    readonly property color primaryLight: "#23ADE5"
    readonly property color primaryDark: "#0078A8"
    readonly property color primaryGlow: "#1A00A1D6"
    readonly property color accent: "#FB7299"
    readonly property color accentDark: "#E85D82"

    // ── 背景色（深色主题）──
    readonly property color bgPrimary: "#0D0D0D"
    readonly property color bgSecondary: "#181818"
    readonly property color bgTertiary: "#242424"
    readonly property color bgCard: "#1E1E1E"
    readonly property color bgCardHover: "#2A2A2A"
    readonly property color bgInput: "#2C2C2C"
    readonly property color bgOverlay: "#CC000000"

    // ── 文字颜色 ──
    readonly property color textPrimary: "#F0F0F0"
    readonly property color textSecondary: "#A0A0A0"
    readonly property color textTertiary: "#666666"
    readonly property color textOnPrimary: "#FFFFFF"
    readonly property color textLink: "#23ADE5"

    // ── 边框/分割线 ──
    readonly property color border: "#2E2E2E"
    readonly property color borderLight: "#3A3A3A"
    readonly property color divider: "#1F1F1F"

    // ── 状态色 ──
    readonly property color error: "#FF5252"
    readonly property color success: "#66BB6A"
    readonly property color warning: "#FFA726"

    // ── 详情页配色 ──
    readonly property color detailAccent: "#3b82f6"
    readonly property color detailAccentLight: "#60a5fa"
    readonly property color detailAccentDark: "#2563eb"
    readonly property color detailBg: "#0d1117"
    readonly property color detailSurface: "#1e293b"
    readonly property color detailTextBright: "#e2e8f0"
    readonly property color detailTextSecondary: "#94a3b8"
    // 与 RichText.js 的 DEFAULT_LINK_COLOR 保持一致
    readonly property string richTextLinkColor: "#60a5fa"

    // ── 字体尺寸（320x170 优化）──
    readonly property int fontTiny: 7
    readonly property int fontSmall: 8
    readonly property int fontBody: 9
    readonly property int fontNormal: 10
    readonly property int fontMedium: 11
    readonly property int fontLarge: 13
    readonly property int fontTitle: 14
    readonly property int fontHuge: 18

    // ── 间距 ──
    readonly property int spacingTiny: 2
    readonly property int spacingSmall: 4
    readonly property int spacingNormal: 6
    readonly property int spacingMedium: 8
    readonly property int spacingLarge: 12
    readonly property int spacingXL: 16

    // ── 圆角体系 ──
    readonly property int radiusTiny: 2
    readonly property int radiusSmall: 4
    readonly property int radiusMedium: 6
    readonly property int radiusLarge: 10
    readonly property int radiusXL: 14
    readonly property int radiusRound: 999

    // ── 列表/卡片布局 ──
    readonly property int cardWidth: 105
    readonly property int listCacheBuffer: 640
    readonly property int listDisplayMargin: 160

    // ── 触摸最小点击区域 ──
    readonly property int touchMinSize: 28
    readonly property int buttonHeight: 24
    readonly property int buttonHeightLarge: 30

    // ── 标题栏 ──
    readonly property int titleBarHeight: 28

    // ── 动画时长 ──
    readonly property int animFast: 120
    readonly property int animNormal: 200
    readonly property int animSlow: 350
    readonly property int animPage: 300

    // ── 字体族 ──
    readonly property string fontFamily: appFont.name !== "" ? appFont.name : "Microsoft YaHei"

    // ── 工具函数 ──
    function withAlpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    function lighten(c, factor) {
        return Qt.lighter(c, 1.0 + factor);
    }

    function darken(c, factor) {
        return Qt.darker(c, 1.0 + factor);
    }
}
