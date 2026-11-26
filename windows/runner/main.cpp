#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Pin media_kit (and media_kit_video's queryDecoders) to the libmpv-2.dll next
// to cinemakom.exe, overriding any LIBMPV_LIBRARY_PATH in the environment so
// two libmpv DLLs never load into one process (same guard as Linux AppRun).
void PinBundledLibmpv() {
  std::wstring exe_path(MAX_PATH, L'\0');
  DWORD len = 0;
  while (true) {
    len = ::GetModuleFileNameW(nullptr, exe_path.data(),
                               static_cast<DWORD>(exe_path.size()));
    if (len == 0) {
      return;
    }
    if (len < exe_path.size()) {
      exe_path.resize(len);
      break;
    }
    if (exe_path.size() >= 32768) {
      return;
    }
    exe_path.resize(exe_path.size() * 2);
  }
  const size_t slash = exe_path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return;
  }
  const std::wstring libmpv = exe_path.substr(0, slash + 1) + L"libmpv-2.dll";
  const DWORD attrs = ::GetFileAttributesW(libmpv.c_str());
  if (attrs != INVALID_FILE_ATTRIBUTES &&
      (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0) {
    ::SetEnvironmentVariableW(L"LIBMPV_LIBRARY_PATH", libmpv.c_str());
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
#ifndef _DEBUG
  // One instance per user in release builds (docs/PACKAGING.md §3): two
  // would run two download engines on one library. A second launch brings
  // the open window to the front and exits. The mutex lives as long as
  // this process. Debug builds skip it, so `flutter run` always starts.
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, TRUE, L"Local\\io.github.sharon_xa.cinemakom");
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // Match by our unique window class rather than title, so handoff works
    // in Arabic ("سينماكم") as well as English ("Cinemakom").
    HWND existing = ::FindWindowW(L"CINEMAKOM_WIN32_WINDOW", nullptr);
    if (existing != nullptr) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      } else {
        ::ShowWindow(existing, SW_SHOW);
      }
      ::SetForegroundWindow(existing);
    }
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }
#endif

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  PinBundledLibmpv();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Cinemakom", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

#ifndef _DEBUG
  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
#endif
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
