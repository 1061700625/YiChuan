#include "flutter_window.h"

#include <optional>
#include <filesystem>
#include <vector>

#include <commdlg.h>
#include <shlobj.h>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

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

  file_picker_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.localmesh/filepicker",
          &flutter::StandardMethodCodec::GetInstance());
  file_picker_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "pickFile") {
          std::vector<wchar_t> path_buffer(32768, L'\0');
          OPENFILENAMEW dialog = {};
          dialog.lStructSize = sizeof(dialog);
          dialog.hwndOwner = GetHandle();
          dialog.lpstrFile = path_buffer.data();
          dialog.nMaxFile = static_cast<DWORD>(path_buffer.size());
          dialog.lpstrFilter = L"All Files\0*.*\0\0";
          dialog.nFilterIndex = 1;
          dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST |
                         OFN_NOCHANGEDIR | OFN_EXPLORER;
          if (!GetOpenFileNameW(&dialog)) {
            result->Success();
            return;
          }
          const std::filesystem::path path(path_buffer.data());
          std::error_code error;
          const auto size = std::filesystem::file_size(path, error);
          if (error) {
            result->Error("FILE_INFO_ERROR", error.message());
            return;
          }
          flutter::EncodableMap value;
          value[flutter::EncodableValue("path")] =
              flutter::EncodableValue(Utf8FromUtf16(path.c_str()));
          value[flutter::EncodableValue("name")] =
              flutter::EncodableValue(Utf8FromUtf16(path.filename().c_str()));
          value[flutter::EncodableValue("size")] =
              flutter::EncodableValue(static_cast<int64_t>(size));
          result->Success(flutter::EncodableValue(value));
          return;
        }

        if (call.method_name() == "getDownloadDir") {
          PWSTR downloads_path = nullptr;
          const HRESULT status = SHGetKnownFolderPath(
              FOLDERID_Downloads, KF_FLAG_CREATE, nullptr, &downloads_path);
          if (FAILED(status) || downloads_path == nullptr) {
            result->Error("DOWNLOAD_DIR_ERROR",
                          "Unable to locate the Downloads directory.");
            return;
          }
          std::filesystem::path directory(downloads_path);
          CoTaskMemFree(downloads_path);
          directory /= L"驿传";
          std::error_code error;
          std::filesystem::create_directories(directory, error);
          if (error) {
            result->Error("DOWNLOAD_DIR_ERROR", error.message());
            return;
          }
          result->Success(
              flutter::EncodableValue(Utf8FromUtf16(directory.c_str())));
          return;
        }

        if (call.method_name() == "openLocalFile") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("INVALID_ARGS", "path required");
            return;
          }
          const auto entry = arguments->find(flutter::EncodableValue("path"));
          if (entry == arguments->end()) {
            result->Error("INVALID_ARGS", "path required");
            return;
          }
          const auto* utf8_path = std::get_if<std::string>(&entry->second);
          if (utf8_path == nullptr) {
            result->Error("INVALID_ARGS", "path required");
            return;
          }
          const auto path = std::filesystem::u8path(*utf8_path).wstring();
          const auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(
              GetHandle(), L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
          if (opened <= 32) {
            result->Error("OPEN_ERROR", "Windows could not open the file.");
          } else {
            result->Success(flutter::EncodableValue(true));
          }
          return;
        }

        if (call.method_name() == "openExternalUrl") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("INVALID_URL", "url required");
            return;
          }
          const auto entry = arguments->find(flutter::EncodableValue("url"));
          if (entry == arguments->end()) {
            result->Error("INVALID_URL", "url required");
            return;
          }
          const auto* utf8_url = std::get_if<std::string>(&entry->second);
          if (utf8_url == nullptr || utf8_url->rfind("https://", 0) != 0) {
            result->Error("INVALID_URL", "A valid HTTPS URL is required");
            return;
          }
          const auto url = std::filesystem::u8path(*utf8_url).wstring();
          const auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(
              GetHandle(), L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
          if (opened <= 32) {
            result->Error("OPEN_URL_ERROR", "Windows could not open the URL.");
          } else {
            result->Success(flutter::EncodableValue(true));
          }
          return;
        }

        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  if (flutter_controller_) {
    file_picker_channel_.reset();
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
