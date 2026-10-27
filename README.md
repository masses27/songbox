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

界面这一层有两条规矩：能自动办的不留按钮，非要她出手时动作就放在提示条上（「换版本」「重试」「接着放」「撤销」），不指路设置页；本机数据没落盘、某一页没拉到、歌中途停了，都要当场在屏幕上说出来，不靠她去猜。循环模式跟音质、主题一样存进设置，重启不回列表循环。

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

### 桌面图标故意不做自适应图标，但整张必须铺满

`res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` 五张整幅铺满的方形 PNG（48/72/96/144/192）：圆盘画满整个宽度，四角用画面自己的夜色做一层虚化底补上，一个透明像素都不留。仓库里没有 `mipmap-anydpi-v26/ic_launcher.xml` 是被删掉的，别照安卓文档里的「最佳实践」补回来：

- 自适应图标是 108dp 画布只露中间 72dp，遮罩和缩放都由桌面说了算。华为/鸿蒙桌面会强制套圆角壳、还把图层放大到填满遮罩，一枚圆盘放进去出来就是方块，边上照样啃掉一块——前景层缩到多少都没用。
- 回落到 legacy 位图之后桌面按原样画，但它会先给普通位图垫一层白底再套圆角：四角留透明就是四个白角，跟旁边一格格的图标一比特别难看。所以「铺满」这件事得图自己做。
- 兼容别家桌面本该留 `mipmap-anydpi-v26`，可那正好把她的机器推回套壳那条路，两个要求互斥，所以按装机那台来。

## Windows 免安装版

同一套 Dart 代码也能在桌面上跑，产物是一个 zip，解压双击 `lyric_music.exe` 就行，不用装任何东西（VC++ 运行库那三颗 DLL 一并抄进包里）。

构建走 GitHub Actions：仓库的 Actions 页 → `windows-portable` → Run workflow（`.github/workflows/windows-portable.yml`，只有 `workflow_dispatch`，产物是 `songbox-<version>-windows-x64-portable.zip`）。

必须在 Actions 上编，本机编不了：`flutter build windows` 要能建符号链接，而这台机的账号既没有 `SeCreateSymbolicLinkPrivilege`，开发者模式也开不了（要写 `HKLM\...\AppModelUnlock`，得管理员）。runner 上这两条现成。

几个决定记在这儿，免得下次照安卓那套去猜：

- 仓库里不提交 `windows/` 那套 C++ 壳子，workflow 里 `flutter create --platforms=windows` 现造。日后 `flutter upgrade` 改壳子文件不会来来回回产生噪声 diff；窗口标题（`L"听歌小窝"`，写成 `\u` 转义让 main.cpp 保持纯 ASCII）也只能在这一步改。
- 声音换了后端：`just_audio` 官方只有 `android/` 和 `darwin/` 两条实现，桌面上每次播放调用都是 `MissingPluginException` —— 界面起得来、就是放不出。所以加了 `just_audio_media_kit`（libmpv），`main.dart` 里只在 `Platform.isWindows` 那一支注册，原来那句 `JustAudioBackground.init` 原样挪进 `else`；`player_service.dart` 的音频管道同理，安卓走的还是原来那条。libmpv 由 `media_kit_libs_windows_audio` 在构建时拉下来拷到 exe 旁边，构建那步会验它在不在包里。
- 数据落在 exe 旁边的 `data/`（`lib/util/app_paths.dart`）。桌面版 `getApplicationDocumentsDirectory()` 返回的是用户的「文档」根目录，不收敛就会把 `settings.json`、`library/`、`logs/`、`sources/` 全撒进她的文档里；`data/` 跟着包走，U 盘拷一份就是完整一套。旁边写不动时才退回应用支持目录。安卓落点不变。注意这个 `data/` 跟 Flutter 自己那个 `data/`（`app.so`、`flutter_assets`、`icudtl.dat`）是同一个目录，我们的 `logs/`、`library/` 就并排躺在引擎资源旁边——能用，但不体面，日后想分开就改 `AppPaths._desktopRoot()` 那一个名字。
- 安卓专属那几样在桌面上直接绕开，不去试：系统均衡器（`AndroidEqualizer` 走 MethodChannel）、下拉菜单那张播放卡的整条自检与接桥。均衡器那一页里「这台设备没有提供系统均衡器」那句就是给桌面版的。
- 已知短处：lx-music 音源脚本在桌面上激活会超时（QuickJS 那条桥，日志里那句「音源脚本激活失败」就是它），能出声的是四个端内直连；桌面上也没有媒体会话，切歌只能回应用里点。
- 验到哪一步了：0.8.35 那个包在本机起得来、界面和封面都正常，`libmpv-2.dll` 确实加载进了进程，旧版那句 `MissingPluginException(… just_audio.methods)` 不再出现，数据也确实落在 `data/` 而没碰「文档」。**但还没真的点过一次播放**——出声与否要看的证据是 `data/logs/play-<日期>.log` 里那句 `[播]`（旧版在那一步只会留 `[崩]`）。在那之前，「桌面版能放整首」只能算推断，不算实测。

## 测试

```bash
~/dev/flutter/bin/flutter analyze   # 只剩 lx_engine.dart 里一条已知的 protected member 警告
~/dev/flutter/bin/flutter test      # 169 条，全离线
```

联网探测脚本放在 `tool/`，按需单独跑；`research/` 是抓下来的第三方脚本和逐条回包，不进仓库。

## 目录

- `lib/music_sdk/` —— 各家曲库的匿名接口（网易云的 weapi 签名在本机算，不落任何凭证）
- `lib/engine/` —— FlutterJS 沙箱，跑 lx-music 音源脚本
- `lib/source/` —— 音源脚本的装载、更新与自检
- `lib/player/` —— just_audio + 后台服务，队列、换源、断网重试、播放卡取证与接桥都在这儿
- `lib/library/` —— 本机数据：收藏、自建歌单、播放历史、口味画像（推荐吃这个，不联网）
- `lib/download/` —— 下载与均衡器
- `lib/util/` —— 日志、封面地址与本地封面文件、人话化错误、原生通道、数据落点（`app_paths.dart`，安卓与桌面各归各处）
- `lib/ui/` —— 页面、组件、色板
- `assets/js/sources/` —— 内置音源脚本（第三方）
- `third_party/songbox_audio_background/` —— just_audio_background 0.0.1-beta.17 的副本，只为把卡上「上一首/下一首」接到应用自己的切歌（上游接的是它自己的 `skipToQueueItem`，而本项目一首一首装 AudioSource，队列里永远只有一项）。改动只有三处：两个静态钩子、`skipToNext/Previous` 先走钩子、控件表在钩子装着时放行那两个键。升上游版本时这三处要重新对齐，`test/card_skip_seam_test.dart` 会先响。
