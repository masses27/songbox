import 'dart:io';

String replaceOnce(
  String source,
  String anchor,
  String replacement,
  String label,
) {
  final count = anchor.allMatches(source).length;
  if (count != 1) {
    throw StateError(
      '$label: expected one Flutter template anchor, found $count',
    );
  }
  return source.replaceFirst(anchor, replacement);
}

void patchWindows(Directory project) {
  final runner = Directory.fromUri(project.uri.resolve('windows/runner/'));
  final main = File.fromUri(runner.uri.resolve('main.cpp'));
  final window = File.fromUri(runner.uri.resolve('win32_window.cpp'));
  final declaration = File.fromUri(runner.uri.resolve('win32_window.h'));
  final geometry = File.fromUri(runner.uri.resolve('window_geometry.h'));
  if (geometry.existsSync()) {
    throw StateError(
      'window_geometry.h already exists; regenerate the runner first',
    );
  }
  String read(File file) => file.readAsStringSync().replaceAll('\r\n', '\n');
  // 标题只写一处：kTitle 由单实例那段声明，窗口名和「把先开的那一个叫到眼前」
  // 用的 FindWindow 必须是同一个串，所以守卫先垫进去，再换 Create() 的实参。
  final mainText = replaceOnce(
    replaceOnce(
      read(main),
      '''  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);''',
      r'''  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Universal-character-name spelling, not raw Chinese: the runner compiles
  // without /utf-8, so multi-byte literals in this file would land as mojibake.
  const wchar_t kTitle[] = L"\u542c\u6b4c\u5c0f\u7a9d";
  // One instance per install directory: two windows from the same folder each
  // write their own data/*.json, and whichever quits last overwrites the
  // other. The mutex is named after this exe's directory, so a copy installed
  // somewhere else still starts on its own.
  wchar_t exe_path[MAX_PATH] = {};
  const DWORD exe_len = ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (exe_len > 0 && exe_len < MAX_PATH) {
    // Hand-written scan for the last separator: <cwchar> is not among the
    // runner's includes, so wcsrchr would be a build-time surprise.
    wchar_t* cut = nullptr;
    for (wchar_t* p = exe_path; *p != L'\0'; ++p) {
      if (*p == L'\\') {
        cut = p;
      }
    }
    if (cut != nullptr) {
      *cut = L'\0';
      wchar_t mutex_name[3 * MAX_PATH] = {};
      ::wsprintfW(mutex_name, L"Local\\songbox-%s", exe_path);
      const HANDLE held = ::CreateMutexW(nullptr, FALSE, mutex_name);
      if (held != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
        // The second copy draws no window of its own: it calls the first one
        // to the front, else a double click looks like a failed start.
        const HWND front = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_CLASS", kTitle);
        if (front != nullptr) {
          if (::IsIconic(front)) {
            ::ShowWindow(front, SW_RESTORE);
          }
          ::SetForegroundWindow(front);
        }
        ::CloseHandle(held);
        return EXIT_SUCCESS;
      }
    }
  }''',
      'main.cpp single instance guard',
    ),
    '''  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"lyric_music", origin, size)) {''',
    '''  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kTitle, origin, size)) {''',
    'main.cpp title and startup size',
  );
  var windowText = replaceOnce(
    read(window),
    '#include "resource.h"',
    '#include "resource.h"\n#include "window_geometry.h"',
    'win32_window.cpp includes',
  );
  windowText = replaceOnce(
    windowText,
    '''// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

''',
    '',
    'win32_window.cpp scale helper',
  );
  windowText = replaceOnce(
    windowText,
    '''  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);''',
    '''  RECT work;
  if (!window_geometry::GetWorkArea(monitor, &work)) {
    return false;
  }
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  if (dpi == 0) {
    dpi = 96;
  }
  const RECT bounds = window_geometry::StartupBounds(
      work, dpi, {static_cast<LONG>(size.width), static_cast<LONG>(size.height)});

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      bounds.left, bounds.top, window_geometry::Width(bounds),
      window_geometry::Height(bounds),
      nullptr, nullptr, GetModuleHandle(nullptr), this);''',
    'win32_window.cpp startup bounds',
  );
  windowText = replaceOnce(
    windowText,
    '''    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();''',
    '''    case WM_GETMINMAXINFO:
      DefWindowProc(hwnd, message, wparam, lparam);
      window_geometry::SetMinimumTrackSize(
          hwnd, reinterpret_cast<MINMAXINFO*>(lparam));
      return 0;

    case WM_DPICHANGED:
      if (IsIconic(hwnd) || IsZoomed(hwnd)) {
        fit_on_restore_ = true;
        break;
      }
      window_geometry::FitWindow(hwnd, reinterpret_cast<const RECT*>(lparam));
      return 0;

    case WM_DISPLAYCHANGE:
    case WM_SETTINGCHANGE:
      if (message == WM_DISPLAYCHANGE || wparam == SPI_SETWORKAREA) {
        fit_on_restore_ = IsIconic(hwnd) || IsZoomed(hwnd);
        if (!fit_on_restore_) {
          window_geometry::FitWindow(hwnd);
        }
      }
      break;

    case WM_SIZE: {
      if (wparam == SIZE_RESTORED && fit_on_restore_) {
        fit_on_restore_ = false;
        window_geometry::FitWindow(hwnd);
      }
      RECT rect = GetClientArea();''',
    'win32_window.cpp window messages',
  );
  final declarationText = replaceOnce(
    read(declaration),
    '  bool quit_on_close_ = false;',
    '  bool quit_on_close_ = false;\n  bool fit_on_restore_ = false;',
    'win32_window.h restore state',
  );
  final geometryText = File.fromUri(
    Platform.script.resolve('windows/window_geometry.h'),
  ).readAsStringSync();
  main.writeAsStringSync(mainText);
  window.writeAsStringSync(windowText);
  declaration.writeAsStringSync(declarationText);
  geometry.writeAsStringSync(geometryText);
}

void main(List<String> args) {
  if (args.length > 1) {
    stderr.writeln('Usage: dart tool/patch_windows.dart [project-root]');
    exitCode = 64;
    return;
  }
  try {
    patchWindows(
      args.isEmpty ? Directory.current : Directory(args.single).absolute,
    );
    stdout.writeln('Windows title, single instance and adaptive window '
        'configuration applied.');
  } on Object catch (error) {
    stderr.writeln('Windows runner patch failed: $error');
    exitCode = 1;
  }
}
