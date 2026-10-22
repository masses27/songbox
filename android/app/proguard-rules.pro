# 播放卡「按键接回来」那处修复要靠反射找 audio_service 里的类和成员
# （MainActivity.reattachMediaListener）。R8 只在 release 开，而这两个嵌套类型
# 没有任何字节码按名字引用它们：ServiceListener 是 AudioService 的接口，
# AudioHandlerInterface 是插件里那个私有的静态字段类型。名字被改就一切回到
# 「原生答 missing」，所以整包保住，别只靠清单里那一条隐式 keep。
-keep class com.ryanheise.audioservice.** { *; }
