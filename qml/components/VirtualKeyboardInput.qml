import QtQuick 2.12
import "qrc:/qml/commons"

// 虚拟键盘输入弹层：封装 YInputPage 的 incubate + YPagePopHelper 样板。
// 依赖宿主注入的 qmlCreateComponent() 与 qmlGlobal.inputPageShowing；
// accepted 的 content 是原始文本，是否 trim/空串处理由页面决定。
YPagePopHelper {
    id: helper
    z: 99

    property string initialText: ""

    signal accepted(string content)
    signal dismissed()

    isShowing: qmlGlobal.inputPageShowing

    function open(prefill) {
        if (prefill !== undefined && prefill !== null) initialText = String(prefill)
        var component = qmlCreateComponent("YInputPage")
        if (Component.Ready === component.status) {
            var incubator = component.incubateObject(helper.containerItem)
            if (incubator.status !== Component.Ready) {
                incubator.onStatusChanged = function(status) {
                    if (status === Component.Ready)
                        helper.inputPageCreated(incubator.object)
                }
            } else {
                helper.inputPageCreated(incubator.object)
            }
        }
    }

    function inputPageCreated(keyboardPage) {
        keyboardPage.backButtonClicked.connect(function() {
            qmlGlobal.inputPageShowing = false
            keyboardPage.todoDestroy()
            keyboardPage = null
            helper.dismissed()
        })

        keyboardPage.inputFinished.connect(function(content) {
            qmlGlobal.inputPageShowing = false
            keyboardPage.todoDestroy()
            helper.accepted(content)
        })

        keyboardPage.enterText(helper.initialText)
        keyboardPage.show()
        qmlGlobal.inputPageShowing = true
    }
}
