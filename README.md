# 笔里哔哩（BiliPocket）

适用于 **有道词典笔 2 代（YDP02x）** + PenMods

面向 `320×170` 触摸屏设计，以插件形式运行在 PenMods 插件系统中。

| 项目 | 说明 |
|------|------|
| 插件 ID | `com.bilipocket.player` |
| 当前版本 | `1.7.6` |
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
- **个人中心**：历史、收藏、稍后再看、缓存队列
- **下载**：一次处理一个视频，大文件最多四路分段下载；支持暂停、断点续传和左滑移出队列
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
├── metadata.json       # 插件入口元数据
├── icon.png
├── server              # 本地 Go API 服务
└── bili-sms            # 短信登录辅助
```

4. 在 PenMods 插件管理中启用 **笔里哔哩**，进入插件 / 重启设备完成更新。

> 插件会自行拉起本地 Go 服务（默认 `127.0.0.1:8000`）。短信登录辅助监听 `0.0.0.0:8666`。
> 首次启动在后台异步进行，插件可立即打开；API 请求等服务就绪后发送。
> 向本地 Go 请求失败时，插件会按需检查进程锁：确认 Go 已结束后询问是否重启，只有点击“重启”才会执行；不会定时检测或自动重启。取消后可在设置页手动重启，恢复后请重新操作，失败请求不会自动重放。
> 此功能要求插件与 `server` 成套更新。Go 运行期间持有 `/tmp/bilipocket-server-8000.lock`（其他端口使用对应编号），退出后锁自动释放，但文件会保留，请勿手动删除；旧版服务没有锁文件时仍显示原网络错误。
> 若希望查看 Go 服务日志，可 `pkill -f server` 杀死服务后以 `DEBUG=true server` 启动查看详细日志，同时会监听在 `0.0.0.0:8000` 上
---

## 架构概览

“我的”快捷图标行中，收藏夹左侧的“缓存”可查看任务，点击条目可单独暂停/继续，失败项可点击重试。全部暂停后继续点击下载只会排队，此时单独继续一条只会放行该任务；全部开始会按顺序下载，并重试失败项。删除最后一个未完成任务会复位此前的全部暂停状态，重新下载不会继承已删除任务的暂停状态；空队列仍可主动点击全部暂停来开启仅排队。退出页面不会停止下载。同一视频分 P 和清晰度会去重，移出队列后成品仍在 bili 文件夹时也不会重复下载。速度显示最近约 8 秒的滑动平均，每秒更新。
已完成的缓存条目可点击直接播放本地视频或音频，沿用嵌入/外部播放器偏好，并加载同名 ASS 字幕；文件被移动、删除或无法读取时会提示。缓存页的“清除完成”会批量移出已完成记录，保留 bili 文件夹里的成品和所有未完成任务。搜索、详情、评论、个人中心（含缓存/设置）、UP 主页、合集等页面右上角的房屋图标可直接回到首页，并清空中间页面的返回栈。
未完成的媒体、分段断点及队列索引保存在插件目录的 `.downloads/` 中，重启后恢复；每条媒体连接连续 30 秒未收到字节才超时，没有总时长限制。支持 HTTP Range 的大文件使用最多四路并发，不支持 Range 时自动单路下载，重新开始该文件。
成品及同名 ASS 字幕保存到 `/userdisk/Music/bili/`，文件名带任务标识以区分分 P 和清晰度。移出队列会清理对应断点，已经保存的成品会保留。DASH 视频和音频分两阶段显示进度，合并时显示蓝色动画。

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
- Go 1.27.3（构建 sidecars，与 CI 一致）

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

```bash
./package.sh
```

打包脚本会生成根目录下的 `bili_plugin.zip`，内含 so、QML、metadata、icon 与两个 Go 二进制。（压缩包包含插件根目录）

### 嵌入播放器

嵌入播放器使用 PenMods 提供的 `FFmpegPlayer 1.0`。在设置页开启「使用嵌入播放器」后，新发起的播放在插件内显示；默认关闭。

支持分离音轨、字幕、续播和进度上报，以及点击暂停、滑动定位、长按倍速、缩放等控制。

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
