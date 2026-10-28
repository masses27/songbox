import 'dart:io';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<ProcessResult> run(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    executable,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  check(
    result.exitCode == 0,
    '$executable failed (${result.exitCode})\n${result.stdout}\n${result.stderr}',
  );
  return result;
}

Future<void> main(List<String> args) async {
  if (args.length < 2 ||
      args.length > 3 ||
      (args.length == 3 && args.last != '--native')) {
    stderr.writeln(
      'Usage: dart tool/windows/patch_windows_test.dart '
      '<flutter-sdk> <scratch-parent> [--native] (MSVC developer shell)',
    );
    exitCode = 64;
    return;
  }
  final sdk = Directory(args[0]).absolute;
  final scratch = Directory(args[1]).absolute;
  check(scratch.existsSync(), 'Scratch parent must already exist');
  final root = scratch.createTempSync('songbox windows-');
  stdout.writeln('Test tree: ${root.path}');
  final templates = sdk.uri.resolve(
    'packages/flutter_tools/templates/app/windows.tmpl/runner/',
  );
  final patch = File.fromUri(Platform.script.resolve('../patch_windows.dart'));
  final originals = <String, String>{};
  for (final name in [
    'main.cpp',
    'win32_window.cpp',
    'win32_window.h',
    'resource.h',
    'flutter_window.h',
    'utils.h',
  ]) {
    final templateName = name == 'main.cpp' ? '$name.tmpl' : name;
    originals[name] = File.fromUri(templates.resolve(templateName))
        .readAsStringSync()
        .replaceAll('\r\n', '\n')
        .replaceAll('{{projectName}}', 'lyric_music');
  }
  Directory fixture(String name, {bool crlf = false}) {
    final project = Directory.fromUri(root.uri.resolve('$name/'));
    final runner = Directory.fromUri(project.uri.resolve('windows/runner/'));
    runner.createSync(recursive: true);
    for (final entry in originals.entries) {
      File.fromUri(runner.uri.resolve(entry.key)).writeAsStringSync(
        crlf ? entry.value.replaceAll('\n', '\r\n') : entry.value,
      );
    }
    return project;
  }

  Future<ProcessResult> apply(Directory project) =>
      Process.run(Platform.resolvedExecutable, [patch.path, project.path]);
  Future<void> rejectsUnchanged(Directory project, String label) async {
    final runner = Directory.fromUri(project.uri.resolve('windows/runner/'));
    final before = <String, String>{
      for (final file in runner.listSync().whereType<File>())
        file.path: file.readAsStringSync(),
    };
    final result = await apply(project);
    check(
      result.exitCode != 0 &&
          result.stderr.toString().contains('Windows runner patch failed:'),
      '$label must explicitly fail',
    );
    for (final entry in before.entries) {
      check(
        File(entry.key).readAsStringSync() == entry.value,
        '$label partially patched ${entry.key}',
      );
    }
    check(
      runner.listSync().length == before.length,
      '$label unexpectedly wrote files',
    );
  }

  final good = fixture('native');
  for (final project in [good, fixture('crlf', crlf: true)]) {
    final result = await apply(project);
    check(result.exitCode == 0, 'Patch failed: ${result.stderr}');
    final runner = project.uri.resolve('windows/runner/');
    final main = File.fromUri(runner.resolve('main.cpp')).readAsStringSync();
    check(
      main.contains(r'L"\u542c\u6b4c\u5c0f\u7a9d"') &&
          main.codeUnits.every((c) => c < 128),
      'Title must use ASCII escapes',
    );
    check(
      File.fromUri(runner.resolve('window_geometry.h')).readAsStringSync() ==
          File.fromUri(Platform.script.resolve('window_geometry.h'))
              .readAsStringSync(),
      'Generated runner must share the tested geometry',
    );
    await rejectsUnchanged(project, 'Already patched');
  }
  final mutations = [
    ('main.cpp', 'L"lyric_music"'),
    ('main.cpp', 'size(1280, 720)'),
    ('win32_window.cpp', '#include "resource.h"'),
    ('win32_window.cpp', 'int Scale(int source, double scale_factor)'),
    ('win32_window.cpp', 'double scale_factor = dpi / 96.0;'),
    ('win32_window.cpp', 'case WM_DPICHANGED:'),
    ('win32_window.h', 'bool quit_on_close_ = false;'),
  ];
  for (var i = 0; i < mutations.length; ++i) {
    final project = fixture('missing-$i');
    final (name, anchor) = mutations[i];
    final file = File.fromUri(project.uri.resolve('windows/runner/$name'));
    check(
      file.readAsStringSync().contains(anchor),
      'Invalid test anchor $anchor',
    );
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst(anchor, 'changed'),
    );
    await rejectsUnchanged(project, 'Missing $anchor');
  }
  for (final name in ['main.cpp', 'win32_window.cpp', 'win32_window.h']) {
    final project = fixture('duplicate-${name.replaceAll('.', '-')}');
    File.fromUri(project.uri.resolve('windows/runner/$name'))
        .writeAsStringSync('${originals[name]}${originals[name]}');
    await rejectsUnchanged(project, 'Duplicate anchors in $name');
  }
  stdout.writeln(
    'Patch: LF/CRLF, ASCII title, shared header, repeat refusal, '
    '7 missing and 3 duplicate anchor cases passed',
  );
  if (args.length != 3) {
    stdout.writeln(
      'Native tests not requested; use --native in an MSVC shell.',
    );
    return;
  }
  check(Platform.isWindows, 'Native tests require Windows');
  final engine = Directory.fromUri(
    sdk.uri.resolve('bin/cache/artifacts/engine/windows-x64/'),
  );
  final runner = Directory.fromUri(good.uri.resolve('windows/runner/'));
  final flags = [
    '/nologo',
    '/std:c++17',
    '/EHsc',
    '/W4',
    '/WX',
    '/wd4100',
    '/MD',
    '/DUNICODE',
    '/D_UNICODE',
    '/D_HAS_EXCEPTIONS=0',
    '/UNDEBUG',
    '/I${runner.path}',
    '/I${engine.path}',
    '/I${Directory.fromUri(engine.uri.resolve('cpp_client_wrapper/include/')).path}',
  ];
  await run('cl.exe', [
    ...flags,
    '/c',
    File.fromUri(runner.uri.resolve('main.cpp')).path,
    '/Fo${File.fromUri(root.uri.resolve('main.obj')).path}',
  ], workingDirectory: root.path);
  final binary = File.fromUri(root.uri.resolve('window_geometry_test.exe'));
  final build = await run('cl.exe', [
    ...flags,
    File.fromUri(runner.uri.resolve('win32_window.cpp')).path,
    File.fromUri(Platform.script.resolve('window_geometry_test.cpp')).path,
    '/Fe${binary.path}',
    '/link',
    File.fromUri(engine.uri.resolve('flutter_windows.dll.lib')).path,
    'user32.lib',
    'advapi32.lib',
    'dwmapi.lib',
  ], workingDirectory: root.path);
  stdout.write(build.stdout);
  final result = await run(
    binary.path,
    [],
    workingDirectory: root.path,
    environment: {
      'PATH': '${engine.path};${Platform.environment['PATH'] ?? ''}',
    },
  );
  stdout.write(result.stdout);
  check(
    result.stdout.toString().contains('maximize/minimize and restore passed'),
    'Native test did not finish all assertions',
  );
}
