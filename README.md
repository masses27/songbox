# 听歌小窝（songbox）

给家里那位用的安卓音乐 App：界面照网易云，全程不登录任何账号。网易云、QQ、B 站、酷狗四个曲库都走端内匿名直连、能出整首，酷我如今只剩歌词和搜索，另外兼容 lx-music v2.0.0 的音源脚本。

## 曲库现状（2026-10 实测）

| 源 | 匿名能给的 | 备注 |
| --- | --- | --- |
| 网易云 `wy` | 整首，最高 320k | `fee=1` 撞会员墙；weapi 签名在本机算 |
| QQ `tx` | 整首，只有 128k | 游客身份只开 M500；`payplay` 先判这首歌放不放得出来 |
| B 站 `bl` | 整首，上限 192k | 会员墙后面第一条还肯匿名出整首的路；直链必须带 Referer |
| 酷狗 `kg` | 整首，只有 128k | `i/v2` 匿名直链，会员墙后面的第二条路；老的 `v5/url` 要 sso-code，接不了 |
| 酷我 `kw` | 歌词、搜索 | 音频接口现在只回 11 秒试听 |
| 音源脚本 | 不稳定 | `assets/js/sources` 里内置 8 个第三方脚本，还能出链的没几个 |

放不出时先降一档音质，再去四个源里找同一首歌（`lib/ui/pages/builtin_library.dart`，端内可取的四个源写死在 `inAppSources`）。「确认没有免费版」这个判定只在接口明确答「没有」时才落盘；断网、被风控一律算「这次问得不凑巧」，不会把一首好歌跳过一周。

## 功能

搜索（单曲/歌手/专辑/歌单，分页 + 历史 + 模糊）、首页推荐与榜单、按本机听歌数据挑的每日推荐、自建歌单与收藏、播放页黑胶 + 滚动歌词（含翻译行）、播放历史与统计、后台播放（通知栏/锁屏/线控/下拉播放卡，卡上「上一首/下一首」走的就是应用里那同一对方法）、下载、均衡器、定时停止、断网等一等再重试、音源自检、播放卡自检与一键修复、日志导出。

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

### release 才踩得到的两处

debug 版不收缩代码也不收缩资源，所以这两种坏只在装进手机的版本里出现，而且坏得一点征兆都没有。

- `android/app/src/main/res/raw/keep.xml` —— audio_service 是运行时按名字查它那七枚控制图标的（`getResourceId → getIdentifier`），字节码里一次 `R.drawable` 引用都没有，资源收缩就把它们当没用的删干净了。图标 id 变成 0，推播放状态那一步直接抛「You must specify an icon resource id」：前台服务没起来、通知通道也没建，下拉里永远没有播放卡。
- `android/app/proguard-rules.pro` —— 桥被 idle 拆掉之后是靠反射把原生那半截 listener 装回去的（`MainActivity.reattachMediaListener`），对象是 `com.ryanheise.audioservice.**` 里那个类和它的嵌套接口，一个字节码引用都没有；R8 把名字改掉，这条修复就退回「原生答 missing」。

打完包核这两眼：`aapt2 dump resources` 里 `drawable/audio_service_*` 该有七枚，`build/app/outputs/mapping/release/mapping.txt` 里 `AudioService`、`AudioService$ServiceListener`、`AudioServicePlugin` 都该映射到自己。

## 测试

```bash
~/dev/flutter/bin/flutter analyze   # 只剩 lx_engine.dart 里一条已知的 protected member 警告
~/dev/flutter/bin/flutter test      # 163 条，全离线
```

联网探测脚本放在 `tool/`，按需单独跑；`research/` 是抓下来的第三方脚本和逐条回包，不进仓库。

## 目录

- `lib/music_sdk/` —— 各家曲库的匿名接口（网易云的 weapi 签名在本机算，不落任何凭证）
- `lib/engine/` —— FlutterJS 沙箱，跑 lx-music 音源脚本
- `lib/source/` —— 音源脚本的装载、更新与自检
- `lib/player/` —— just_audio + 后台服务，队列、换源、断网重试、播放卡取证与接桥都在这儿
- `lib/library/` —— 本机数据：收藏、自建歌单、播放历史、口味画像（推荐吃这个，不联网）
- `lib/download/` —— 下载与均衡器
- `lib/util/` —— 日志、封面地址与本地封面文件、人话化错误、原生通道
- `lib/ui/` —— 页面、组件、色板
- `assets/js/sources/` —— 内置音源脚本（第三方）
- `third_party/songbox_audio_background/` —— just_audio_background 0.0.1-beta.17 的副本，只为把卡上「上一首/下一首」接到应用自己的切歌（上游接的是它自己的 `skipToQueueItem`，而本项目一首一首装 AudioSource，队列里永远只有一项）。改动只有三处：两个静态钩子、`skipToNext/Previous` 先走钩子、控件表在钩子装着时放行那两个键。升上游版本时这三处要重新对齐，`test/card_skip_seam_test.dart` 会先响。
