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

    signal loadMoreRequested()

    readonly property bool _horizontal: orientation === ListView.Horizontal

    // 异常路径（请求失败且 loading/count 都无变化）时手动复位防抖
    function resetLoadMoreGuard() {
        loadingMore = false
    }

    function _maybeLoadMore() {
        if (_horizontal) {
            if (!atXEnd) return
            // 短列表保护：内容撑不满时 atXEnd 恒真
            if (contentWidth <= width + 2) return
        } else {
            if (!atYEnd) return
            if (contentHeight <= height + 2) return
        }
        if (count <= 0) return
        if (loadingMore || loading) return
        if (!hasMore) return
        loadingMore = true
        loadMoreRequested()
    }

    onAtXEndChanged: if (_horizontal && atXEnd) _maybeLoadMore()
    onAtYEndChanged: if (!_horizontal && atYEnd) _maybeLoadMore()

    // 防抖复位
    onCountChanged: loadingMore = false
    onLoadingChanged: if (!loading) loadingMore = false
    onModelChanged: loadingMore = false
}
