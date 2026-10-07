# FFmpegPlayer 预编译模块

此目录附带供 BiliPocket 设备包使用的 ARM64 / AArch64 Linux、Qt 5.15 播放器，模块名为 `FFmpegPlayer 1.0`。`package.sh` 默认将 `qml/FFmpegPlayer/` 原样复制到安装包的同名 QML 目录。主机测试继续使用 x86_64 测试构建。

来源：相邻 `ffmpeg_mod` 项目的 `build/dist-static/qml/FFmpegPlayer/libffmpegplayerplugin.so`，2026-10-07 导入。FFmpeg、OpenSSL 和字幕依赖静态链接，Qt、ALSA、MPP、DRM 使用设备库。

此版本包含 `0007-tls-system-trust.patch`：HTTPS 默认使用 OpenSSL 信任路径及设备 `/etc/ssl/certs` 哈希证书目录，不再要求 `ca-certificates.crt` 合集文件。可通过 `SSL_CERT_FILE` / `SSL_CERT_DIR` 显式配置；证书链和主机名校验保持开启。

附带库的 SHA-256：

```text
0c81a21c83883d65c4d1befaef94d3b9a507ffefecdd7cf3fe34b1397a3b06f0  qml/FFmpegPlayer/libffmpegplayerplugin.so
```

更新时在 `ffmpeg_mod` 中按其 README 构建 ARM64 插件并安装，然后从 BiliPocket 根目录执行：

```sh
cp ../ffmpeg_mod/build/dist-static/qml/FFmpegPlayer/libffmpegplayerplugin.so qml/FFmpegPlayer/
cp ../ffmpeg_mod/build/dist-static/qml/FFmpegPlayer/qmldir qml/FFmpegPlayer/
sha256sum qml/FFmpegPlayer/libffmpegplayerplugin.so
./package.sh
```

同步更新本文件中的来源与校验值。临时使用其他构建可设置 `FFMPEGPLAYER_QML_DIR`，无需覆盖附带版本。
