#ifndef SONGBOX_WINDOW_GEOMETRY_H_
#define SONGBOX_WINDOW_GEOMETRY_H_

#include <windows.h>

#include <algorithm>

namespace window_geometry {

inline LONG Width(const RECT& rect) { return rect.right - rect.left; }
inline LONG Height(const RECT& rect) { return rect.bottom - rect.top; }

inline LONG StartupLimit(LONG available) {
  return (std::max)(1L, available * 9 / 10);
}

inline RECT StartupBounds(const RECT& work, UINT dpi, const SIZE& logical) {
  const LONG width = (std::min)(StartupLimit(Width(work)),
                                static_cast<LONG>(MulDiv(logical.cx, dpi, 96)));
  const LONG height =
      (std::min)(StartupLimit(Height(work)),
                 static_cast<LONG>(MulDiv(logical.cy, dpi, 96)));
  const LONG left = work.left + (Width(work) - width) / 2;
  const LONG top = work.top + (Height(work) - height) / 2;
  return {left, top, left + width, top + height};
}

inline RECT ClampToWorkArea(const RECT& bounds, const RECT& work) {
  const LONG width = std::clamp(Width(bounds), 1L, Width(work));
  const LONG height = std::clamp(Height(bounds), 1L, Height(work));
  const LONG left = std::clamp(bounds.left, work.left, work.right - width);
  const LONG top = std::clamp(bounds.top, work.top, work.bottom - height);
  return {left, top, left + width, top + height};
}

inline SIZE MinimumTrackSize(const RECT& work, UINT dpi, const SIZE& frame) {
  return {(std::min)(StartupLimit(Width(work)),
                     static_cast<LONG>(MulDiv(360, dpi, 96)) + frame.cx),
          (std::min)(StartupLimit(Height(work)),
                     static_cast<LONG>(MulDiv(480, dpi, 96)) + frame.cy)};
}

inline bool SameBounds(const RECT& a, const RECT& b) {
  return a.left == b.left && a.top == b.top && a.right == b.right &&
         a.bottom == b.bottom;
}

inline bool GetWorkArea(HMONITOR monitor, RECT* work) {
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfo(monitor, &info) || Width(info.rcWork) <= 0 ||
      Height(info.rcWork) <= 0) {
    return false;
  }
  *work = info.rcWork;
  return true;
}

inline void FitWindow(HWND hwnd, const RECT* suggested = nullptr) {
  if (IsIconic(hwnd) || IsZoomed(hwnd)) {
    return;
  }
  RECT current;
  if (!GetWindowRect(hwnd, &current)) {
    return;
  }
  RECT bounds = suggested ? *suggested : current;
  RECT work;
  if (!GetWorkArea(MonitorFromRect(&bounds, MONITOR_DEFAULTTONEAREST), &work)) {
    return;
  }
  const RECT fitted = ClampToWorkArea(bounds, work);
  if (!SameBounds(current, fitted)) {
    // Do not let the old monitor's tracking minimum enlarge the fitted RECT.
    SetWindowPos(hwnd, nullptr, fitted.left, fitted.top, Width(fitted),
                 Height(fitted),
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOSENDCHANGING);
  }
}

inline void SetMinimumTrackSize(HWND hwnd, MINMAXINFO* limits) {
  RECT work;
  if (!GetWorkArea(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &work)) {
    return;
  }
  UINT dpi = GetDpiForWindow(hwnd);
  if (dpi == 0) {
    dpi = 96;
  }
  RECT frame{};
  if (!AdjustWindowRectExForDpi(
          &frame, static_cast<DWORD>(GetWindowLongPtr(hwnd, GWL_STYLE)),
          GetMenu(hwnd) != nullptr,
          static_cast<DWORD>(GetWindowLongPtr(hwnd, GWL_EXSTYLE)), dpi)) {
    return;
  }
  const SIZE minimum =
      MinimumTrackSize(work, dpi, {Width(frame), Height(frame)});
  limits->ptMinTrackSize = {minimum.cx, minimum.cy};
}

}

#endif
