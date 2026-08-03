import QtQuick 2.12

// 系统弹层容器（图片查看器等 qrc 页面）。closeSameItem 用普通函数而非 signal，
// 避免旧实现每次 show() 都 connect 闭包、累积后对已销毁对象调 destroy()。
Item {
    id: popupStack
    anchors.fill: parent
    z: 3000
    visible: popItemObject !== null

    property var popItemObject: null

    function updateStackInfo() {
        // 跳过当前正在关闭的弹层，从后往前找第一个可见弹层作为新的栈顶，
        // 避免用 children[length-2] 这类索引假设（destroy 延迟一帧生效时索引会错位）。
        var found = null
        for (var i = popupStack.children.length - 1; i >= 0; --i) {
            var child = popupStack.children[i]
            if (!child || child === popItemObject) continue
            if (child.visible !== false) {
                found = child
                break
            }
        }
        popItemObject = found
    }

    // 销毁所有 popStackId 匹配的弹层
    function closeSameItem(popStackId) {
        for (var i = popupStack.children.length - 1; i >= 0; --i) {
            var child = popupStack.children[i]
            if (child && child.popStackId === popStackId) child.destroy(1)
        }
        // destroy(1) 延迟一帧才真正移除子项：延后到下一事件循环再更新栈顶，
        // 此时被销毁对象已从 children 移除，索引不再错位。
        Qt.callLater(function() { popupStack.updateStackInfo() })
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
            popupStack.popItemObject = obj
            if (obj.backButtonClicked) {
                // 连在弹层对象自身信号上，对象销毁即断开
                obj.backButtonClicked.connect(function() {
                    popupStack.closeSameItem(obj.popStackId)
                    // 栈顶更新由 closeSameItem 延迟到 destroy 生效后执行
                })
            }
            if (obj.show) obj.show()
        }

        closeSameItem(componentPath)
        var comp = Qt.createComponent(componentPath)
        if (comp.status === Component.Ready) {
            var incubator = comp.incubateObject(popupStack)
            if (incubator.status !== Component.Ready) {
                incubator.onStatusChanged = function(s) {
                    if (s === Component.Ready) initObj(incubator.object)
                }
            } else {
                initObj(incubator.object)
            }
        } else {
            console.error("PopupStack component error: " + comp.errorString())
        }
    }
}
