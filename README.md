# 听歌小窝（songbox）

给家里那位用的安卓音乐 App：界面照网易云，全程不登录任何账号。网易云、QQ、B 站、酷我四个曲库都走端内匿名直连，另外兼容 lx-music v2.0.0 的音源脚本。

## 曲库现状（2026-10 实测）

| 源 | 匿名能给的 | 备注 |
| --- | --- | --- |
| 网易云 `wy` | 整首，最高 320k | `fee=1` 撞会员墙 |
| QQ `tx` | 整首，只有 128k | 游客身份只开 M500 |
| B 站 `bl` | 整首，上限 192k | 会员墙后面唯一还肯匿名出整首的；直链必须带 Referer |
| 酷我 `kw` | 歌词可用 | 音频接口现在只回 11 秒试听 |
| 音源脚本 | 不稳定 | `assets/js/sources` 里内置 8 个第三方脚本，还能出链的没几个 |

放不出时先降一档音质，再去四个源里找同一首歌（`lib/ui/pages/builtin_library.dart`）。「确认没有免费版」这个判定只在接口明确答「没有」时才落盘；断网、被风控一律算「这次问得不凑巧」，不会把一首好歌跳过一周。

## 功能

搜索（单曲/歌手/专辑/歌单，分页 + 历史）、首页推荐与榜单、自建歌单与收藏、播放页黑胶 + 滚动歌词（含翻译行）、后台播放（通知栏/锁屏/线控）、下载、均衡器、定时停止、断网等一等再重试、音源自检。

## 构建

工具链装在 `~/dev`（免管理员）：Flutter 3.47 / JDK 21 / Android SDK。

```bash
bash build.sh
```

它会按 `pubspec.yaml` 的版本号同步「关于」页那行，`flutter build apk --release --split-per-abi`，再把 arm64 包命名成 `听歌小窝-<version>.apk` 拷到桌面。手动构建：

```bash
export JAVA_HOME="$HOME/dev/jdk21" ANDROID_HOME="$HOME/dev/android-sdk"
~/dev/flutter/bin/flutter pub get
~/dev/flutter/bin/flutter build apk --release --split-per-abi
```

## 测试

```bash
~/dev/flutter/bin/flutter analyze   # 只剩 lx_engine.dart 里一条已知的 protected member 警告
~/dev/flutter/bin/flutter test      # 80 条，全离线
```

联网探测脚本放在 `tool/`，按需单独跑；`research/` 是抓下来的第三方脚本和逐条回包，不进仓库。

## 目录

- `lib/music_sdk/` —— 四个曲库的匿名接口（网易云的 weapi 签名在本机算，不落任何凭证）
- `lib/engine/` —— FlutterJS 沙箱，跑 lx-music 音源脚本
- `lib/player/` —— just_audio + 后台服务，队列、换源、断网重试都在这儿
- `lib/download/` —— 下载与均衡器
- `lib/ui/` —— 页面、组件、色板
- `assets/js/sources/` —— 内置音源脚本（第三方）
