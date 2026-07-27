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
        if (popupStack.children.length > 1) {
            popItemObject = popupStack.children[popupStack.children.length - 2]
        } else {
            popItemObject = null
        }
    }

    // 销毁所有 popStackId 匹配的弹层
    function closeSameItem(popStackId) {
        for (var i = popupStack.children.length - 1; i >= 0; --i) {
            var child = popupStack.children[i]
            if (child && child.popStackId === popStackId) child.destroy(1)
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
            popupStack.popItemObject = obj
            if (obj.backButtonClicked) {
                // 连在弹层对象自身信号上，对象销毁即断开
                obj.backButtonClicked.connect(function() {
                    popupStack.closeSameItem(obj.popStackId)
                    popupStack.updateStackInfo()
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
