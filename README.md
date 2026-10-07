# 笔里哔哩（BiliPocket）

适用于 **有道词典笔 2 代（YDP02x）** + PenMods

面向 `320×170` 触摸屏设计，以插件形式运行在 PenMods 插件系统中。

| 项目 | 说明 |
|------|------|
| 插件 ID | `com.bilipocket.player` |
| 当前版本 | `1.7.3` |
| 作者 | BiliPocket |
| 安装路径 | `/userdisk/PenMods/plugins/bili_plugin/` |

---

## 功能

- **推荐 / 热门**：首页推荐流，支持刷新
- **搜索**：关键词搜索视频
- **排行榜**：热门排行浏览
- **视频详情**：封面、简介、分 P、合集跳转
- **播放**：本地播放链路，支持清晰度 / 字幕相关能力；可在偏好设置中启用嵌入播放器
- **评论**：一级评论、回复查看与点赞
- **动态**：动态流与动态详情（含 opus / 合集导航）
- **UP 主页**：投稿列表、合作视频、上次观看定位
- **个人中心**：历史、收藏、稍后再看
- **登录**：扫码登录 / 短信登录辅助流程
- **个性化**：目前支持个性化调整字幕、预加载、字体（字体需要在Theme.qml中修改）

---

## 安装 / 更新

1. 从 Release 或自行打包得到 `bili_plugin.zip`
2. 解压到词典笔：

```text
/userdisk/PenMods/plugins/bili_plugin/
```

3. 目录中应包含：

```text
bili_plugin/
├── libbili_plugin.so   # Qt/C++ 插件
├── qml/                # QML 界面
│   └── FFmpegPlayer/ # 上游嵌入播放器模块
│       ├── qmldir
│       └── libffmpegplayerplugin.so
├── metadata.json       # 插件入口元数据
├── icon.png
├── server              # 本地 Go API 服务
└── bili-sms            # 短信登录辅助
```

4. 在 PenMods 插件管理中启用 **笔里哔哩**，进入插件 / 重启设备完成更新。

> 插件会自行拉起本地 Go 服务（默认 `127.0.0.1:8000`）。短信登录辅助监听 `0.0.0.0:8666`。
> 向本地 Go 请求失败时，插件会按需检查进程锁：确认 Go 已结束后询问是否重启，只有点击“重启”才会执行；不会定时检测或自动重启。取消后可在设置页手动重启，恢复后请重新操作，失败请求不会自动重放。
> 此功能要求插件与 `server` 成套更新。Go 运行期间持有 `/tmp/bilipocket-server-8000.lock`（其他端口使用对应编号），退出后锁自动释放，但文件会保留，请勿手动删除；旧版服务没有锁文件时仍显示原网络错误。
> 若希望查看 Go 服务日志，可 `pkill -f server` 杀死服务后以 `DEBUG=true server` 启动查看详细日志，同时会监听在 `0.0.0.0:8000` 上
---

## 架构概览

```text
  QML UI
    ↓ 调用
BiliController / modules (Qt/C++)
    ↓ HTTP
本地 Go server (127.0.0.1:8000)
    ↓
上游 API
```

| 层级 | 路径 | 职责 |
|------|------|------|
| UI | `qml/` | 页面路由、交互、绑定展示 |
| 插件运行时 | `src/` | QML 类型注册、网络、模型、业务模块 |
| 本地 API | `go_server/main` | Cookie / 登录态、接口代理与归一化 |
| 短信辅助 | `go_server/sms` | 短信登录页与轮询接口 |

入口契约见 `metadata.json`：

- `main_qml`: `qml/main.qml`
- `main_so`: `libbili_plugin.so`

---

## 开发构建

> 交叉编译目标为 `arm64-v8a` / `aarch64-linux-gnu`。

### 环境

- Linux 主机
- [xmake](https://xmake.io/) `v3.0.9`
- [Qt（aarch64）开发框架](https://github.com/Redbeanw44602/aarch64-linux-qt-5.15.2)与 zig 交叉工具链
- Go 1.20+（构建 sidecars）

### 配置并编译插件

按本机 Qt 路径调整：

```bash
xmake f -c \
  --qt="/path/to/qt" \
  --arch=arm64-v8a \
  --toolchain=zigcc \
  --cross=aarch64-linux-gnu.2.27 \
  -m release -vD

xmake
```

产物：

```text
build/linux/arm64-v8a/release/libbili_plugin.so
```

### 编译 Go 服务

```bash
./go_server/build.sh
```

或分别：

```bash
cd go_server/main && OOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -trimpath -o ../server
cd go_server/sms  && OOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -trimpath -o ../bili-sms
```

### 一键打包

项目已附带来自 `ffmpeg_mod` 的 **ARM64 / Qt 5.15** 播放器模块，位于 `qml/FFmpegPlayer`。默认随整个 `qml` 目录原样打包到 `bili_plugin/qml/FFmpegPlayer`，无需相邻的 `ffmpeg_mod` 项目。播放器来源、校验值及更新方法见 `qml/FFmpegPlayer/README.md`。也可通过环境变量指定其他模块目录：

```bash
./package.sh

# 路径应直接包含 qmldir 与 libffmpegplayerplugin.so
FFMPEGPLAYER_QML_DIR=/path/to/ffmpeg_mod/build/dist-static/qml/FFmpegPlayer ./package.sh
```

打包脚本会先检查模块文件是否完整、是否为 AArch64，并验证 `qmldir` 中的模块名和插件名。会生成根目录下的 `bili_plugin.zip`，内含 so、QML、播放器模块、metadata、icon 与两个 Go 二进制。（压缩包包含插件根目录）

播放器原样打包上游 `FFmpegPlayer 1.0` 模块，保留 `qmldir` 和 `libffmpegplayerplugin.so`，无需私有重命名。PenMods 共用 QML 引擎，应统一使用满足字幕等接口要求的播放器版本；后续可由主程序统一提供该模块。

使用 `ffmpeg_mod` 的静态依赖构建，无需额外附带 FFmpeg、OpenSSL、libass 等库；Qt、ALSA、Rockchip MPP 和 DRM 库由设备提供。

### 嵌入播放器

在设置页开启「使用嵌入播放器」后，新发起的播放在插件内显示；默认关闭，沿用原播放方式。`EmbeddedPlayer.qml` 使用 `ffmpeg_mod/examples/Player.qml`（2026-10-07）的完整控制界面，将独立窗口适配为页面内组件，保留分离音轨、字幕、续播和进度上报，关闭按钮返回项目页面。组件随项目打包，运行时不依赖上游源码目录。

支持点击画面暂停/继续、横向滑动定位、长按临时倍速、纵向滑动显示/隐藏控制栏、缩放及拖动画面，以及进度条、前后跳转、字幕开关和 0.5–2 倍速切换。播放时控制栏自动隐藏。播放器随页面退出释放资源。更新时同时替换 QML 和 `qml/FFmpegPlayer` 目录，再重启 PenMods；只替换 QML 无法更新原生播放器。

嵌入播放器的音频输出、MPP 硬解和 Wayland 显示需要在词典笔实机验证；主机构建或界面检查不能替代这些检查。

### 本地调试服务

```bash
# 主 API
cd go_server/main && PORT=8000 DEBUG=true go run .

# 短信登录辅助
cd go_server/sms && go run .
```

---

## 目录结构

```text
bili_plugin/
├── qml/                 # QML 页面与组件
│   ├── main.qml         # 路由 / 返回栈 / 页面保活
│   ├── pages/           # 业务页面
│   └── components/      # 可复用组件
├── src/                 # Qt/C++ 插件
│   ├── BiliController.* # QML 边界与启动逻辑
│   ├── BiliModels.*     # 列表模型与解析
│   ├── BiliNetwork.*    # 本地 API 客户端
│   └── modules/         # feed / search / playback / login …
├── go_server/
│   ├── main/            # 本地 API 服务
│   └── sms/             # 短信登录辅助
├── metadata.json
├── icon.png
├── xmake.lua
└── package.sh
```

---

## 注意事项 / 声明

- 本插件依赖 PenMods 插件机制，**不是**独立桌面客户端。
- 登录 Cookie 与本地服务仅在设备本地使用；请妥善保管设备与账号。
- 使用第三方客户端访问 B 站接口可能违反平台规则，风险自负。
- 仅用于学习和测试，请于下载后24小时内删除，所用API皆从官方网站收集，不提供任何破解内容。

---

## 致谢

- [Lyrecoul](https://github.com/Lyrecoul) — 提供初始框架
- [SocialSisterYi / bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [bggRGjQaUbCoE / PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) — 部分接口与交互参考
