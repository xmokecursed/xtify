#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr int kMinClientWidth = 920;
constexpr int kMinClientHeight = 600;

UINT DpiOf(HWND hwnd) {
  const UINT dpi = GetDpiForWindow(hwnd);
  return dpi != 0 ? dpi : 96;
}

struct FrameInsets {
  int x;
  int y;
};

FrameInsets InsetsOf(HWND hwnd) {
  const UINT dpi = DpiOf(hwnd);
  const int padding = GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
  return {GetSystemMetricsForDpi(SM_CXFRAME, dpi) + padding,
          GetSystemMetricsForDpi(SM_CYFRAME, dpi) + padding};
}

LRESULT CalculateClientArea(HWND hwnd, RECT* proposed) {
  if (IsZoomed(hwnd)) {
    MONITORINFO monitor_info = {};
    monitor_info.cbSize = sizeof(monitor_info);
    HMONITOR monitor = MonitorFromRect(proposed, MONITOR_DEFAULTTONEAREST);
    RECT visible;
    if (monitor != nullptr && GetMonitorInfo(monitor, &monitor_info) &&
        IntersectRect(&visible, proposed, &monitor_info.rcWork)) {
      *proposed = visible;
    }
    return 0;
  }
  const FrameInsets insets = InsetsOf(hwnd);
  proposed->left += insets.x;
  proposed->right -= insets.x;
  proposed->bottom -= insets.y;
  proposed->top += 1;
  return 0;
}

WPARAM ResizeHitTest(int edge) {
  switch (edge) {
    case 0:
      return HTTOP;
    case 1:
      return HTTOPLEFT;
    case 2:
      return HTTOPRIGHT;
    case 3:
      return HTLEFT;
    case 4:
      return HTRIGHT;
    case 5:
      return HTBOTTOM;
    case 6:
      return HTBOTTOMLEFT;
    case 7:
      return HTBOTTOMRIGHT;
    default:
      return 0;
  }
}

}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  SetWindowPos(GetHandle(), nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "xtify/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleWindowCall(call, std::move(result)); });
  SetWindowText(GetHandle(), L"Xtify");

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (window_channel_) {
    window_channel_->SetMethodCallHandler(nullptr);
    window_channel_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleWindowCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    result->Error("no_window", "The window is no longer available");
    return;
  }
  const std::string& method = call.method_name();
  if (method == "minimize") {
    ShowWindow(hwnd, SW_MINIMIZE);
    result->Success();
  } else if (method == "toggleMaximize") {
    ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
    result->Success();
  } else if (method == "close") {
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    result->Success();
  } else if (method == "isMaximized") {
    result->Success(flutter::EncodableValue(IsZoomed(hwnd) != FALSE));
  } else if (method == "startDrag") {
    ReleaseCapture();
    SendMessage(hwnd, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
    result->Success();
  } else if (method == "startResize") {
    const auto* edge = std::get_if<int32_t>(call.arguments());
    const WPARAM hit_test = edge != nullptr ? ResizeHitTest(*edge) : 0;
    if (hit_test == 0) {
      result->Error("bad_edge", "Unknown window edge");
      return;
    }
    POINT cursor;
    GetCursorPos(&cursor);
    ReleaseCapture();
    PostMessage(hwnd, WM_NCLBUTTONDOWN, hit_test,
                MAKELPARAM(cursor.x, cursor.y));
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void FlutterWindow::NotifyMaximized(bool maximized) {
  if (maximized_ == maximized) {
    return;
  }
  maximized_ = maximized;
  if (window_channel_) {
    window_channel_->InvokeMethod(
        "maximized", std::make_unique<flutter::EncodableValue>(maximized));
  }
}

void FlutterWindow::ReleasePointer() {
  if (!flutter_controller_ || !flutter_controller_->view()) {
    return;
  }
  HWND content = flutter_controller_->view()->GetNativeWindow();
  POINT cursor;
  if (content == nullptr || !GetCursorPos(&cursor)) {
    return;
  }
  ScreenToClient(content, &cursor);
  PostMessage(content, WM_LBUTTONUP, 0, MAKELPARAM(cursor.x, cursor.y));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_NCCALCSIZE:
      if (wparam != FALSE) {
        return CalculateClientArea(
            hwnd, &reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam)->rgrc[0]);
      }
      return CalculateClientArea(hwnd, reinterpret_cast<RECT*>(lparam));
    case WM_NCACTIVATE:
      return TRUE;
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const int dpi = static_cast<int>(DpiOf(hwnd));
      const FrameInsets insets = InsetsOf(hwnd);
      info->ptMinTrackSize.x = MulDiv(kMinClientWidth, dpi, 96) + 2 * insets.x;
      info->ptMinTrackSize.y = MulDiv(kMinClientHeight, dpi, 96) + insets.y + 1;
      return 0;
    }
    case WM_SIZE:
      if (wparam == SIZE_MAXIMIZED) {
        NotifyMaximized(true);
      } else if (wparam == SIZE_RESTORED) {
        NotifyMaximized(false);
      }
      break;
    case WM_EXITSIZEMOVE:
      ReleasePointer();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
