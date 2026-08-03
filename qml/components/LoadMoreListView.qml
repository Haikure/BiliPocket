// reuseItems 需要 QtQuick 2.15（Qt 5.15）
import QtQuick 2.15
import ".."

// 滚到尾部自动“加载更多”的 ListView（横向按 atXEnd，Vertical 按 atYEnd）。
// hasMore/loading 默认读 model 的同名属性，页面可绑定覆盖。
// 默认开 reuseItems，自定义 delegate 需保证状态由属性驱动、可正确重置。
ListView {
    id: listView

    orientation: ListView.Horizontal
    clip: true
    reuseItems: true
    cacheBuffer: Theme.listCacheBuffer
    displayMarginBeginning: Theme.listDisplayMargin
    displayMarginEnd: Theme.listDisplayMargin

    property bool hasMore: !model || model.hasMore === undefined || model.hasMore !== false
    property bool loading: !!(model && model.loading === true)
    property bool loadingMore: false
    // 短列表内容不满一屏时同一条目数只尝试一次加载，防止死循环
    property int lastShortCount: -1

    signal loadMoreRequested()

    readonly property bool _horizontal: orientation === ListView.Horizontal

    // 异常路径（请求失败且 loading/count 都无变化）时手动复位防抖
    function resetLoadMoreGuard() {
        loadingMore = false
    }

    function _maybeLoadMore() {
        if (count <= 0) return
        if (loadingMore || loading) return
        if (!hasMore) return
        if (_horizontal) {
            if (contentWidth > width + 2) {
                // 正常（撑满）列表：滚到尾部才加载
                if (!atXEnd) return
            } else {
                // 内容撑不满时 atXEnd 恒真，改由 count 变化驱动，同一条目数只试一次
                if (count === lastShortCount) return
            }
        } else {
            if (contentHeight > height + 2) {
                if (!atYEnd) return
            } else {
                if (count === lastShortCount) return
            }
        }
        lastShortCount = count
        loadingMore = true
        // watchdog：请求未进入 loading 且无人复位时超时自行解锁
        loadMoreWatchdog.restart()
        loadMoreRequested()
    }

    onAtXEndChanged: if (_horizontal && atXEnd) _maybeLoadMore()
    onAtYEndChanged: if (!_horizontal && atYEnd) _maybeLoadMore()

    // 防抖复位；短列表靠 count 变化驱动下一次加载尝试
    onCountChanged: {
        loadingMore = false
        if (_horizontal && atXEnd) _maybeLoadMore()
        else if (!_horizontal && atYEnd) _maybeLoadMore()
    }
    onLoadingChanged: if (!loading) loadingMore = false
    onModelChanged: {
        loadingMore = false
        lastShortCount = -1
    }

    // watchdog：800ms 内未进入 loading（请求失败等）则复位，避免加载更多卡死
    Timer {
        id: loadMoreWatchdog
        interval: 800
        repeat: false
        onTriggered: {
            if (loadingMore && !loading) loadingMore = false
        }
    }
}
