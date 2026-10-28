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

搜索（单曲/歌手/专辑/歌单，分页 + 历史 + 模糊）、首页推荐与榜单、按本机听歌数据挑的每日推荐、自建歌单与收藏、播放页黑胶 + 滚动歌词（含翻译行）、播放历史与统计、后台播放（通知栏/锁屏/线控/下拉播放卡，卡上「上一首/下一首」走的就是应用里那同一对方法）、下载、均衡器、定时停止、断网等一等再重试（打不开的地址先重取一条、本机那份放不出就自动改走在线的，等满几轮才报错跳下一首；换歌、连着播出够久、她自己按过重试，这三种才重新发满额度）、进度兜底（播完没回话、半路停住不往前，都有一只自己的表盯着接着放）、音源自检、播放卡自检与一键修复、日志导出。

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

同一套 Dart 代码也能在桌面上跑，产物有形态两份：一个 zip（解压双击 `lyric_music.exe`）和一颗自解压的单文件 exe（下面两节各说一种），都不用装任何东西（VC++ 运行库那三颗 DLL 一并抄进包里）。

构建走 GitHub Actions：仓库的 Actions 页 → `windows-portable` → Run workflow（`.github/workflows/windows-portable.yml`，只有 `workflow_dispatch`，一次出两份产物：`songbox-<version>-windows-x64-portable.zip` 和 `songbox-<version>-windows-x64-single.exe`）。

必须在 Actions 上编，本机编不了：`flutter build windows` 要能建符号链接，而这台机的账号既没有 `SeCreateSymbolicLinkPrivilege`，开发者模式也开不了（要写 `HKLM\...\AppModelUnlock`，得管理员）。runner 上这两条现成。

几个决定记在这儿，免得下次照安卓那套去猜：

- 仓库里不提交 `windows/` 那套 C++ 壳子，workflow 里 `flutter create --platforms=windows` 现造。日后 `flutter upgrade` 改壳子文件不会来来回回产生噪声 diff；窗口标题（`L"听歌小窝"`，写成 `\u` 转义让 main.cpp 保持纯 ASCII）也只能在这一步改。
- 声音换了后端：`just_audio` 官方只有 `android/` 和 `darwin/` 两条实现，桌面上每次播放调用都是 `MissingPluginException` —— 界面起得来、就是放不出。所以加了 `just_audio_media_kit`（libmpv），`main.dart` 里只在 `Platform.isWindows` 那一支注册，原来那句 `JustAudioBackground.init` 原样挪进 `else`；`player_service.dart` 的音频管道同理，安卓走的还是原来那条。libmpv 由 `media_kit_libs_windows_audio` 在构建时拉下来拷到 exe 旁边，构建那步会验它在不在包里。
- 数据落在 exe 旁边的 `data/`（`lib/util/app_paths.dart`）。桌面版 `getApplicationDocumentsDirectory()` 返回的是用户的「文档」根目录，不收敛就会把 `settings.json`、`library/`、`logs/`、`sources/` 全撒进她的文档里；`data/` 跟着包走，U 盘拷一份就是完整一套。旁边写不动时才退回应用支持目录。安卓落点不变。注意这个 `data/` 跟 Flutter 自己那个 `data/`（`app.so`、`flutter_assets`、`icudtl.dat`）是同一个目录，我们的 `logs/`、`library/` 就并排躺在引擎资源旁边——能用，但不体面，日后想分开就改 `AppPaths._desktopRoot()` 那一个名字。
- 安卓专属那几样在桌面上直接绕开，不去试：系统均衡器（`AndroidEqualizer` 走 MethodChannel）、下拉菜单那张播放卡的整条自检与接桥。均衡器那一页里「这台设备没有提供系统均衡器」那句就是给桌面版的。
- 已知短处：lx-music 音源脚本在桌面上激活会超时（QuickJS 那条桥，日志里那句「音源脚本激活失败」就是它），能出声的是四个端内直连；桌面上也没有媒体会话，切歌只能回应用里点。
- 验到哪一步了：0.8.35 那个包在本机起得来、界面和封面都正常，`libmpv-2.dll` 确实加载进了进程，旧版那句 `MissingPluginException(… just_audio.methods)` 不再出现，数据也确实落在 `data/` 而没碰「文档」。播放也真点过了：`data/logs/play-2026-10-27.log` 里三行 `[播]`（一首 B 站 192k、两首提前备好的 320k），队列自己往下走，`library/play_stats.json` 记到「阿刁」听到 371 秒（全长 374）并算完播、「米店」336 秒算完播——那是播放位置一路推进出来的数，不是点一下就能伪造的。`[崩]` 一条没有。剩最后一格没勾：耳机里到底有没有声，只有她耳朵能判。

## Windows 单文件版

zip 那份要用，就得一直留着那个文件夹：她桌面要么堆一层目录，要么放个快捷方式指进去。单文件那份把这些都省了——桌面永远只有 `听歌小窝.exe` 一颗（0.8.36 实测 20.8MB），双击就完事。

做法是启动器 + 尾巴：`tool/win_single/launcher.cs` 用 runner 上现成的 `csc.exe`（.NET Framework 4.8 自带，不额外装东西）编成一颗 211KB 的 exe，再把 zip 那一份整个接在它尾巴上。PE 只看头部那些节，尾巴上的字节当资源多余的部分忽略，所以这文件既是能跑的程序又是一份完整 zip；启动器按 zip 自己的 EOCD 往回算出尾巴起点（`blobStart = eocd绝对位置 - 中央目录长度 - 中央目录起始偏移`），把 blob 切出来解到 `%LOCALAPPDATA%\听歌小窝\`，再从那儿拉起 `lyric_music.exe`。payload 是 38 个条目（31 个文件 + 7 个目录项，压缩 20.6MB、解出来 47.2MB），第一次解压实测一秒左右；之后版本号和 `songbox-version.txt` 那枚戳记一致就直接跳过解压。

几条写死了的理由：

- 落点选 `%LOCALAPPDATA%\听歌小窝\` 而不是临时目录：数据是 `AppPaths` 按「exe 旁边的 `data/`」放的，跟着 exe 走，所以程序文件解在哪儿数据就在哪儿，固定落点 = 她的收藏和日志有个稳定的家。代价是不再「跟着文件走」——把这颗 exe 拷去别的机器，第一次会在对方机器上重新解一套空的。zip 那份还留着，要带走数据就拷整个文件夹。反过来也一样：哪天不想要了，删桌面那颗 exe 删不掉数据，`%LOCALAPPDATA%\听歌小窝\` 得整个删（收藏、播放统计、日志都在里面，别顺手清掉）。
- 升级只重写程序文件，她的东西一个字不碰：payload 里带 `data/` 开头的只有引擎自己那三样（`app.so`、`icudtl.dat`、`flutter_assets/**`），38 个条目里没有一个 `data/library`、`data/logs`、`data/sources` 或 `settings.json`；`CopyOut` 又逐条按 zip 里的路径写、先落 `.new` 再换（半截 dll 是中断的更新把整套变成起不来的来路），够不着她的收藏、播放统计、日志和她自己导入的音源脚本。换新版 = 覆盖桌面那颗 exe，下次双击版本号对不上就重解一遍。
- 已经开着的时候不硬来：戳记是最新但进程在跑，就把那个窗口拉回前台，不再开第二个；戳记是旧的而进程在跑，直接提示「先把它关掉再点一次」退出——半覆盖正在运行的程序文件是版本混着用的来路。
- 图标走 `-win32icon:`，用和安卓同源那张 `mipmap-xxxhdpi/ic_launcher.png` 现拼的 ICO（16/24/32/48/64/96/128/192 八帧，202149 字节），编进启动器的资源里，桌面那颗 exe、任务栏、资源管理器预览都是它。为什么不提交现成的 `.ico`：logo 在 0.8.32-0.8.34 连着换了三次，二进制文件正是下次换标会忘记重生的那种。zip 那份里 `lyric_music.exe` 带的还是 Flutter 模板那颗图标（runner 是 `flutter create` 现造的，没往里塞图标），要它好看就照以前那样在外面配快捷方式 —— 这也是单文件版顺手解决掉的一件事。
- 三份都实测 `Get-AuthenticodeSignature = NotSigned`（runner 上没有证书），第一次运行 Windows 拦一下属正常：弹的那张「已保护你的电脑」要按「更多信息」才露出「仍要运行」。这跟单文件版没关系，zip 里那颗 exe 一样。
- 单文件这份本机验到的是：桌面双击 → 进程起在 `%LOCALAPPDATA%\听歌小窝\lyric_music.exe`（不是桌面那颗），窗口标题 `[听歌小窝]`，`libmpv-2.dll` 确实加载，日志接着往 `data\logs\` 里写 `[起]`；已经在跑的时候再点一次，进程数不变，只把窗口拉回前台，也不重解。尾巴接的就是那份 zip 本体：run 6 的产物 21,839,569 = 启动器 215,552 + 免安装包 21,624,017，启动器自己算出来的 `blobStart` 也正好是 215,552，解出来的 31 个文件跟 zip 里逐个 SHA256 对上、0 处不一致。上面「播放也真点过了」那三行 `[播]` 是 0.8.35 那份点出来的；两份 0.8.36 产物（zip 与单文件）payload 同一串哈希，所以「这一份能不能出声」在两份上是同一个答案，但 0.8.36 比 0.8.35 多了两轮界面改动，到底有没有声只有她在现在这颗上再听一次才算数。
- 启动器补了版本资源（五条 assembly attribute，两个版本号都取那句被 workflow 改写的 `Version`）：属性→详细信息里 `FileVersion=0.8.36`、产品名和说明都是「听歌小窝」，不再是一颗 20MB 的无名 blob。里面那颗 `lyric_music.exe` 带的还是 Flutter 模板那套（`FileDescription=lyric_music`、`FileVersion=0.8.36+49`），那个壳子是 `flutter create` 现造的，不去动它。

启动器源码里那三行 `\u` 转义的汉字不是凑字数：`csc` 读没 BOM 的文件按各机 ANSI 代码页解码，源码里塞汉字哪天就编成乱码——和 `main.cpp` 的窗口标题同一个理由。调试开关 `/dir:<路径>`（解到别处）和 `/check`（只解压不启动）、`/log:<路径>`（winexe 没控制台，话只能写文件）留给 CI 和本机复现用，她双击时一个都不会碰到。

## 测试

```bash
~/dev/flutter/bin/flutter analyze   # 只剩 lx_engine.dart 里一条已知的 protected member 警告
~/dev/flutter/bin/flutter test      # 188 条，全离线
```

联网探测脚本放在 `tool/`，按需单独跑；`research/` 是抓下来的第三方脚本和逐条回包，不进仓库。

## 目录

- `lib/music_sdk/` —— 各家曲库的匿名接口（网易云的 weapi 签名在本机算，不落任何凭证）
- `lib/engine/` —— FlutterJS 沙箱，跑 lx-music 音源脚本
- `lib/source/` —— 音源脚本的装载、更新与自检
- `lib/player/` —— just_audio + 后台服务，队列、换源、断网重试、播完/停住的进度兜底、播放卡取证与接桥都在这儿
- `lib/library/` —— 本机数据：收藏、自建歌单、播放历史、口味画像（推荐吃这个，不联网）
- `lib/download/` —— 下载与均衡器
- `lib/util/` —— 日志、封面地址与本地封面文件、人话化错误、原生通道、数据落点（`app_paths.dart`，安卓与桌面各归各处）
- `lib/ui/` —— 页面、组件、色板
- `assets/js/sources/` —— 内置音源脚本（第三方）
- `third_party/songbox_audio_background/` —— just_audio_background 0.0.1-beta.17 的副本，只为把卡上「上一首/下一首」接到应用自己的切歌（上游接的是它自己的 `skipToQueueItem`，而本项目一首一首装 AudioSource，队列里永远只有一项）。改动只有三处：两个静态钩子、`skipToNext/Previous` 先走钩子、控件表在钩子装着时放行那两个键。升上游版本时这三处要重新对齐，`test/card_skip_seam_test.dart` 会先响。
