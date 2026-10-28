#include <flutter_windows.h>
#include <window_geometry.h>

#include <cassert>
#include <iostream>

#include "win32_window.h"

using namespace window_geometry;

bool Inside(const RECT& bounds, const RECT& work) {
  return Width(bounds) > 0 && Height(bounds) > 0 && bounds.left >= work.left &&
         bounds.top >= work.top && bounds.right <= work.right &&
         bounds.bottom <= work.bottom;
}

RECT Bounds(HWND hwnd) {
  RECT rect{};
  assert(GetWindowRect(hwnd, &rect));
  return rect;
}

void GeometryTests() {
  const SIZE resolutions[] = {
      {800, 600},   {1024, 768},  {1280, 720}, {1366, 768}, {1920, 1080},
      {2560, 1440}, {3840, 2160}, {320, 400},  {200, 160},  {1, 1}};
  const POINT origins[] = {{0, 0}, {-3840, 0}, {-1920, -1080}, {1920, 240}};
  const UINT dpis[] = {96, 120, 144, 168, 192};
  int samples = 0;
  for (const auto& resolution : resolutions) {
    for (const auto& origin : origins) {
      for (int taskbar = 0; taskbar < 5; ++taskbar) {
        RECT work{origin.x, origin.y, origin.x + resolution.cx,
                  origin.y + resolution.cy};
        const LONG inset =
            (std::min)(40L, (std::min)(resolution.cx, resolution.cy) / 4);
        if (taskbar == 1) work.bottom -= inset;
        if (taskbar == 2) work.left += inset;
        if (taskbar == 3) work.top += inset;
        if (taskbar == 4) work.right -= inset;
        for (const UINT dpi : dpis) {
          const RECT start = StartupBounds(work, dpi, {1280, 720});
          assert(Inside(start, work));
          assert(Width(start) <= StartupLimit(Width(work)));
          assert(Height(start) <= StartupLimit(Height(work)));
          assert(Width(start) <= MulDiv(1280, dpi, 96));
          assert(Height(start) <= MulDiv(720, dpi, 96));
          assert(start.left - work.left == (Width(work) - Width(start)) / 2);
          assert(start.top - work.top == (Height(work) - Height(start)) / 2);
          RECT frame{};
          assert(AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0,
                                          dpi));
          const SIZE minimum =
              MinimumTrackSize(work, dpi, {Width(frame), Height(frame)});
          assert(minimum.cx > 0 && minimum.cx <= Width(start));
          assert(minimum.cy > 0 && minimum.cy <= Height(start));
          assert(minimum.cx <= MulDiv(360, dpi, 96) + Width(frame));
          assert(minimum.cy <= MulDiv(480, dpi, 96) + Height(frame));
          const RECT suggestions[] = {start,
                                      work,
                                      {work.left - 500, work.top - 300,
                                       work.right + 900, work.bottom + 600},
                                      {work.right + 20, work.bottom + 20,
                                       work.right + 420, work.bottom + 320},
                                      {work.left - 600, work.top - 500,
                                       work.left - 200, work.top - 200}};
          for (const auto& suggestion : suggestions) {
            const RECT fitted = ClampToWorkArea(suggestion, work);
            assert(Inside(fitted, work));
            assert(SameBounds(fitted, ClampToWorkArea(fitted, work)));
            assert(Width(fitted) == (std::min)(Width(suggestion), Width(work)));
            assert(Height(fitted) ==
                   (std::min)(Height(suggestion), Height(work)));
          }
          assert(SameBounds(start, ClampToWorkArea(start, work)));
          assert(SameBounds(work, ClampToWorkArea(work, work)));
          ++samples;
        }
      }
    }
  }
  assert(SameBounds(StartupBounds({0, 0, 1920, 1040}, 96, {1280, 720}),
                    {320, 160, 1600, 880}));
  assert(SameBounds(StartupBounds({-1920, 40, 0, 1080}, 144, {1280, 720}),
                    {-1824, 92, -96, 1028}));
  assert(SameBounds(StartupBounds({0, 0, 800, 560}, 192, {1280, 720}),
                    {40, 28, 760, 532}));
  assert(SameBounds(StartupBounds({0, 0, 3840, 2120}, 192, {1280, 720}),
                    {640, 340, 3200, 1780}));
  const SIZE minimum = MinimumTrackSize({0, 0, 3840, 2160}, 192, {32, 78});
  assert(minimum.cx == 752 && minimum.cy == 1038);
  std::cout << "Geometry: " << samples << " work-area/DPI samples passed\n";
}

void WindowTests() {
  Win32Window window;
  assert(window.Create(L"window geometry test", {10, 10}, {1280, 720}));
  const HWND hwnd = window.GetHandle();
  const HMONITOR monitor = MonitorFromPoint({10, 10}, MONITOR_DEFAULTTONEAREST);
  RECT work;
  assert(GetWorkArea(monitor, &work));
  const UINT dpi = GetDpiForWindow(hwnd);
  std::cout << "Native monitor: " << Width(work) << "x" << Height(work)
            << " at (" << work.left << "," << work.top << "), DPI " << dpi
            << std::endl;
  assert(SameBounds(Bounds(hwnd),
                    StartupBounds(work, FlutterDesktopGetDpiForMonitor(monitor),
                                  {1280, 720})));
  const LONG_PTR style = GetWindowLongPtr(hwnd, GWL_STYLE);
  assert((style & WS_THICKFRAME) && (style & WS_MAXIMIZEBOX));

  MINMAXINFO expected{};
  DefWindowProc(hwnd, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&expected));
  MINMAXINFO actual{};
  SendMessage(hwnd, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&actual));
  assert(actual.ptMaxSize.x == expected.ptMaxSize.x);
  assert(actual.ptMaxSize.y == expected.ptMaxSize.y);
  assert(actual.ptMaxPosition.x == expected.ptMaxPosition.x);
  assert(actual.ptMaxPosition.y == expected.ptMaxPosition.y);
  assert(actual.ptMaxTrackSize.x == expected.ptMaxTrackSize.x);
  assert(actual.ptMaxTrackSize.y == expected.ptMaxTrackSize.y);
  RECT frame{};
  assert(AdjustWindowRectExForDpi(&frame, static_cast<DWORD>(style), FALSE, 0,
                                  GetDpiForWindow(hwnd)));
  const SIZE minimum = MinimumTrackSize(work, GetDpiForWindow(hwnd),
                                        {Width(frame), Height(frame)});
  assert(actual.ptMinTrackSize.x == minimum.cx);
  assert(actual.ptMinTrackSize.y == minimum.cy);

  const HWND foreground = GetForegroundWindow();
  RECT suggested{work.left - 300, work.top - 100, work.right + 500,
                 work.bottom + 300};
  SendMessage(hwnd, WM_DPICHANGED, MAKELONG(192, 192),
              reinterpret_cast<LPARAM>(&suggested));
  RECT targetWork;
  assert(GetWorkArea(MonitorFromRect(&suggested, MONITOR_DEFAULTTONEAREST),
                     &targetWork));
  assert(SameBounds(Bounds(hwnd), ClampToWorkArea(suggested, targetWork)));
  assert(GetForegroundWindow() == foreground);

  RECT inside = StartupBounds(work, dpi, {1100, 700});
  SendMessage(hwnd, WM_DPICHANGED, MAKELONG(dpi, dpi),
              reinterpret_cast<LPARAM>(&inside));
  assert(SameBounds(Bounds(hwnd), inside));
  RECT smaller{inside.left, inside.top, inside.left + minimum.cx / 2,
               inside.top + minimum.cy / 2};
  SetWindowPos(hwnd, nullptr, smaller.left, smaller.top, Width(smaller),
               Height(smaller), SWP_NOZORDER | SWP_NOACTIVATE);
  assert(Width(Bounds(hwnd)) == minimum.cx);
  assert(Height(Bounds(hwnd)) == minimum.cy);
  SendMessage(hwnd, WM_DPICHANGED, MAKELONG(96, 96),
              reinterpret_cast<LPARAM>(&smaller));
  assert(SameBounds(Bounds(hwnd), smaller));

  for (const UINT message : {WM_DISPLAYCHANGE, WM_SETTINGCHANGE}) {
    SetWindowPos(hwnd, nullptr, work.right - 20, work.bottom - 20, 900, 700,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    const RECT before = Bounds(hwnd);
    assert(GetWorkArea(MonitorFromRect(&before, MONITOR_DEFAULTTONEAREST),
                       &targetWork));
    if (message == WM_SETTINGCHANGE) {
      SendMessage(hwnd, message, SPI_SETMOUSE, 0);
      assert(SameBounds(Bounds(hwnd), before));
    }
    SendMessage(hwnd, message,
                message == WM_SETTINGCHANGE ? SPI_SETWORKAREA : 32, 0);
    assert(SameBounds(Bounds(hwnd), ClampToWorkArea(before, targetWork)));
    const RECT fitted = Bounds(hwnd);
    SendMessage(hwnd, message, SPI_SETWORKAREA, 0);
    assert(SameBounds(Bounds(hwnd), fitted));
  }

  for (const int command : {SW_SHOWMAXIMIZED, SW_MINIMIZE}) {
    ShowWindow(hwnd, SW_RESTORE);
    SetWindowPos(hwnd, nullptr, work.right - 20, work.bottom - 20, 900, 700,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    ShowWindow(hwnd, command);
    const RECT before = Bounds(hwnd);
    SendMessage(hwnd, WM_DPICHANGED, MAKELONG(192, 192),
                reinterpret_cast<LPARAM>(&suggested));
    SendMessage(hwnd, WM_DISPLAYCHANGE, 32, 0);
    SendMessage(hwnd, WM_SETTINGCHANGE, SPI_SETWORKAREA, 0);
    assert(command == SW_MINIMIZE ? IsIconic(hwnd) : IsZoomed(hwnd));
    assert(SameBounds(Bounds(hwnd), before));
    ShowWindow(hwnd, SW_RESTORE);
    const RECT restored = Bounds(hwnd);
    assert(GetWorkArea(MonitorFromRect(&restored, MONITOR_DEFAULTTONEAREST),
                       &targetWork));
    assert(Inside(restored, targetWork));
  }

  SetWindowPos(hwnd, nullptr, work.left, work.top, Width(work), Height(work),
               SWP_NOZORDER | SWP_NOACTIVATE);
  assert(SameBounds(Bounds(hwnd), work));
  assert(!IsZoomed(hwnd) && !IsIconic(hwnd));
  window.Destroy();
  std::cout
      << "Generated Win32 runner: startup, DPI, work-area changes, minimum, "
         "manual resize, maximize/minimize and restore passed"
      << std::endl;
}

int main() {
  assert(SetProcessDpiAwarenessContext(
      DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2));
  GeometryTests();
  WindowTests();
  return 0;
}
