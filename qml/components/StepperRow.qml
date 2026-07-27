import QtQuick 2.12
import ".."

// 设置页“label − value ＋”步进行。数值格式化与步进/边界逻辑由页面负责：
// valueText 原样显示，± 按钮只发 decreased()/increased() 信号。
Rectangle {
    id: stepperRow

    property string label: ""
    property string valueText: ""
    // 数值文本宽度：整数值 30，百分比/小数 40
    property int valueWidth: 30
    signal decreased()
    signal increased()

    height: 30
    radius: Theme.radiusMedium
    color: Theme.bgSecondary
    border.color: Theme.withAlpha(Theme.primary, 0.12)
    border.width: 1

    Row {
        anchors.fill: parent
        anchors.margins: 6
        spacing: 8

        Text { text: stepperRow.label; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: 64 }

        Rectangle {
            width: 24; height: 24; radius: 6
            color: minusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
            Text { anchors.centerIn: parent; text: "-"; color: Theme.textPrimary; font.pixelSize: 14 }
            MouseArea {
                id: minusArea
                anchors.fill: parent
                onClicked: stepperRow.decreased()
            }
        }

        Text { text: stepperRow.valueText; color: Theme.textPrimary; font.family: Theme.fontFamily; font.pixelSize: 11; width: stepperRow.valueWidth; horizontalAlignment: Text.AlignHCenter }

        Rectangle {
            width: 24; height: 24; radius: 6
            color: plusArea.pressed ? Theme.withAlpha(Theme.primary, 0.2) : Theme.bgTertiary
            Text { anchors.centerIn: parent; text: "+"; color: Theme.textPrimary; font.pixelSize: 14 }
            MouseArea {
                id: plusArea
                anchors.fill: parent
                onClicked: stepperRow.increased()
            }
        }
    }
}
