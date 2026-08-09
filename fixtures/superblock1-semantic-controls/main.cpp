#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "advapi32.lib")

namespace {
constexpr UINT kPresentCount = 128;
constexpr std::size_t kLoopbackBytes = 64u * 1024u;
constexpr std::size_t kFileBytes = 64u * 1024u;
constexpr DWORD kWorkerIterations = 250000;
constexpr long kSocketTimeoutMilliseconds = 5000;

enum class FixtureMode {
    AllOn,
    GpuOff,
    NetworkOff,
    KernelOff,
    Minimal
};

struct StimulusConfig {
    bool gpu = false;
    bool network = false;
    bool explicit_kernel = false;
};

struct Result {
    bool hardware_device_created = false;
    UINT presents_attempted = 0;
    UINT presents_succeeded = 0;
    bool dns_lookup_executed = false;
    bool loopback_completed = false;
    std::size_t bytes_sent = 0;
    std::size_t bytes_received = 0;
    bool network_server_thread_created = false;
    bool network_server_thread_joined = false;
    bool registry_read_executed = false;
    bool temp_file_roundtrip = false;
    bool kernel_worker_thread_created = false;
    bool kernel_worker_thread_joined = false;
};

const char* ModeName(FixtureMode mode) {
    switch (mode) {
        case FixtureMode::AllOn: return "all_on";
        case FixtureMode::GpuOff: return "gpu_off";
        case FixtureMode::NetworkOff: return "network_off";
        case FixtureMode::KernelOff: return "kernel_off";
        case FixtureMode::Minimal: return "minimal";
    }
    return "invalid";
}

bool ParseMode(const std::wstring& value, FixtureMode& mode) {
    if (value == L"all_on") {
        mode = FixtureMode::AllOn;
        return true;
    }
    if (value == L"gpu_off") {
        mode = FixtureMode::GpuOff;
        return true;
    }
    if (value == L"network_off") {
        mode = FixtureMode::NetworkOff;
        return true;
    }
    if (value == L"kernel_off") {
        mode = FixtureMode::KernelOff;
        return true;
    }
    if (value == L"minimal") {
        mode = FixtureMode::Minimal;
        return true;
    }
    return false;
}

StimulusConfig ConfigForMode(FixtureMode mode) {
    switch (mode) {
        case FixtureMode::AllOn: return {true, true, true};
        case FixtureMode::GpuOff: return {false, true, true};
        case FixtureMode::NetworkOff: return {true, false, true};
        case FixtureMode::KernelOff: return {true, true, false};
        case FixtureMode::Minimal: return {false, false, false};
    }
    return {};
}

LRESULT CALLBACK FixtureWndProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_CLOSE) {
        DestroyWindow(hwnd);
        return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

bool WriteUtf8File(const std::wstring& path, const std::string& text) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    DWORD written = 0;
    const BOOL ok = WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
    CloseHandle(file);
    return ok != FALSE && static_cast<std::size_t>(written) == text.size();
}

std::string BuildReceipt(
    FixtureMode mode,
    const StimulusConfig& config,
    const Result& result,
    const char* status,
    DWORD error_code) {
    std::ostringstream out;
    out << "{\n"
        << "  \"schema_version\": 2,\n"
        << "  \"status\": \"" << status << "\",\n"
        << "  \"mode\": \"" << ModeName(mode) << "\",\n"
        << "  \"pid\": " << GetCurrentProcessId() << ",\n"
        << "  \"stimulus_enabled\": {\n"
        << "    \"gpu\": " << (config.gpu ? "true" : "false") << ",\n"
        << "    \"network\": " << (config.network ? "true" : "false") << ",\n"
        << "    \"explicit_kernel\": " << (config.explicit_kernel ? "true" : "false") << "\n"
        << "  },\n"
        << "  \"gpu\": {\n"
        << "    \"hardware_device_created\": " << (result.hardware_device_created ? "true" : "false") << ",\n"
        << "    \"present_calls_attempted\": " << result.presents_attempted << ",\n"
        << "    \"present_calls_succeeded\": " << result.presents_succeeded << ",\n"
        << "    \"warp_fallback_used\": false\n"
        << "  },\n"
        << "  \"network\": {\n"
        << "    \"dns_lookup_executed\": " << (result.dns_lookup_executed ? "true" : "false") << ",\n"
        << "    \"loopback_completed\": " << (result.loopback_completed ? "true" : "false") << ",\n"
        << "    \"external_network_used\": false,\n"
        << "    \"bytes_sent\": " << result.bytes_sent << ",\n"
        << "    \"bytes_received\": " << result.bytes_received << ",\n"
        << "    \"server_thread_created\": " << (result.network_server_thread_created ? "true" : "false") << ",\n"
        << "    \"server_thread_joined\": " << (result.network_server_thread_joined ? "true" : "false") << "\n"
        << "  },\n"
        << "  \"kernel_stimulus\": {\n"
        << "    \"registry_read_executed\": " << (result.registry_read_executed ? "true" : "false") << ",\n"
        << "    \"registry_write_executed\": false,\n"
        << "    \"temp_file_roundtrip\": " << (result.temp_file_roundtrip ? "true" : "false") << ",\n"
        << "    \"worker_thread_created\": " << (result.kernel_worker_thread_created ? "true" : "false") << ",\n"
        << "    \"worker_thread_joined\": " << (result.kernel_worker_thread_joined ? "true" : "false") << "\n"
        << "  },\n"
        << "  \"claims\": {\n"
        << "    \"etw_event_mapping_validated\": false,\n"
        << "    \"present_semantics_validated\": false,\n"
        << "    \"network_semantics_validated\": false,\n"
        << "    \"kernel_semantics_validated\": false,\n"
        << "    \"causal_relationship_validated\": false\n"
        << "  },\n"
        << "  \"error_code\": " << error_code << "\n"
        << "}\n";
    return out.str();
}

bool RunD3D11(Result& result) {
    const wchar_t* class_name = L"NxbSuperblock1SemanticControlWindow";
    WNDCLASSW wc{};
    wc.lpfnWndProc = FixtureWndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = class_name;
    if (RegisterClassW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return false;
    }

    HWND hwnd = CreateWindowExW(
        0, class_name, L"NXB SUPERBLOCK 1 semantic control", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 96, 96, nullptr, nullptr, wc.hInstance, nullptr);
    if (hwnd == nullptr) {
        return false;
    }
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);

    DXGI_SWAP_CHAIN_DESC desc{};
    desc.BufferDesc.Width = 64;
    desc.BufferDesc.Height = 64;
    desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.OutputWindow = hwnd;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    IDXGISwapChain* swap_chain = nullptr;
    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    const HRESULT create_hr = D3D11CreateDeviceAndSwapChain(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
        D3D11_SDK_VERSION, &desc, &swap_chain, &device, nullptr, &context);
    if (FAILED(create_hr)) {
        DestroyWindow(hwnd);
        UnregisterClassW(class_name, wc.hInstance);
        return false;
    }
    result.hardware_device_created = true;

    ID3D11Texture2D* back_buffer = nullptr;
    ID3D11RenderTargetView* rtv = nullptr;
    HRESULT hr = swap_chain->GetBuffer(0, __uuidof(ID3D11Texture2D), reinterpret_cast<void**>(&back_buffer));
    if (SUCCEEDED(hr)) {
        hr = device->CreateRenderTargetView(back_buffer, nullptr, &rtv);
    }
    if (SUCCEEDED(hr)) {
        const float clear_color[4] = {0.125f, 0.25f, 0.5f, 1.0f};
        for (UINT i = 0; i < kPresentCount; ++i) {
            ++result.presents_attempted;
            context->OMSetRenderTargets(1, &rtv, nullptr);
            context->ClearRenderTargetView(rtv, clear_color);
            if (SUCCEEDED(swap_chain->Present(0, 0))) {
                ++result.presents_succeeded;
            }
            MSG message{};
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }

    if (rtv != nullptr) rtv->Release();
    if (back_buffer != nullptr) back_buffer->Release();
    if (context != nullptr) context->Release();
    if (device != nullptr) device->Release();
    if (swap_chain != nullptr) swap_chain->Release();
    DestroyWindow(hwnd);
    UnregisterClassW(class_name, wc.hInstance);
    return SUCCEEDED(hr) && result.presents_attempted == kPresentCount && result.presents_succeeded == kPresentCount;
}

bool RunLoopback(Result& result) {
    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        return false;
    }

    addrinfoW hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    addrinfoW* resolved = nullptr;
    if (GetAddrInfoW(L"localhost", nullptr, &hints, &resolved) == 0) {
        result.dns_lookup_executed = true;
        FreeAddrInfoW(resolved);
    }

    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) {
        WSACleanup();
        return false;
    }
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    const int address_size = static_cast<int>(sizeof(address));
    if (bind(listener, reinterpret_cast<sockaddr*>(&address), address_size) == SOCKET_ERROR ||
        listen(listener, 1) == SOCKET_ERROR) {
        closesocket(listener);
        WSACleanup();
        return false;
    }
    int address_len = address_size;
    if (getsockname(listener, reinterpret_cast<sockaddr*>(&address), &address_len) == SOCKET_ERROR) {
        closesocket(listener);
        WSACleanup();
        return false;
    }

    std::atomic<bool> server_ok{false};
    result.network_server_thread_created = true;
    std::thread server([&]() {
        fd_set read_set{};
        FD_ZERO(&read_set);
        FD_SET(listener, &read_set);
        timeval timeout{};
        timeout.tv_sec = kSocketTimeoutMilliseconds / 1000;
        timeout.tv_usec = (kSocketTimeoutMilliseconds % 1000) * 1000;
        const int selected = select(0, &read_set, nullptr, nullptr, &timeout);
        if (selected <= 0 || !FD_ISSET(listener, &read_set)) return;
        SOCKET peer = accept(listener, nullptr, nullptr);
        if (peer == INVALID_SOCKET) return;
        DWORD socket_timeout = static_cast<DWORD>(kSocketTimeoutMilliseconds);
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&socket_timeout), sizeof(socket_timeout));
        setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&socket_timeout), sizeof(socket_timeout));
        std::vector<char> buffer(kLoopbackBytes);
        std::size_t total = 0;
        while (total < buffer.size()) {
            const int got = recv(peer, buffer.data() + total, static_cast<int>(buffer.size() - total), 0);
            if (got <= 0) break;
            total += static_cast<std::size_t>(got);
        }
        std::size_t sent = 0;
        while (sent < total) {
            const int n = send(peer, buffer.data() + sent, static_cast<int>(total - sent), 0);
            if (n <= 0) break;
            sent += static_cast<std::size_t>(n);
        }
        server_ok = total == kLoopbackBytes && sent == kLoopbackBytes;
        shutdown(peer, SD_BOTH);
        closesocket(peer);
    });

    SOCKET client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    bool client_ok = false;
    if (client != INVALID_SOCKET) {
        DWORD socket_timeout = static_cast<DWORD>(kSocketTimeoutMilliseconds);
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&socket_timeout), sizeof(socket_timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&socket_timeout), sizeof(socket_timeout));
    }
    if (client != INVALID_SOCKET && connect(client, reinterpret_cast<sockaddr*>(&address), address_size) == 0) {
        std::vector<char> payload(kLoopbackBytes);
        for (std::size_t i = 0; i < payload.size(); ++i) payload[i] = static_cast<char>(i % 251u);
        std::size_t sent = 0;
        while (sent < payload.size()) {
            const int n = send(client, payload.data() + sent, static_cast<int>(payload.size() - sent), 0);
            if (n <= 0) break;
            sent += static_cast<std::size_t>(n);
        }
        std::vector<char> echoed(kLoopbackBytes);
        std::size_t received = 0;
        while (received < echoed.size()) {
            const int n = recv(client, echoed.data() + received, static_cast<int>(echoed.size() - received), 0);
            if (n <= 0) break;
            received += static_cast<std::size_t>(n);
        }
        result.bytes_sent = sent;
        result.bytes_received = received;
        client_ok = sent == payload.size() && received == echoed.size() && payload == echoed;
        shutdown(client, SD_BOTH);
        closesocket(client);
    } else if (client != INVALID_SOCKET) {
        closesocket(client);
    }

    server.join();
    result.network_server_thread_joined = true;
    closesocket(listener);
    WSACleanup();
    result.loopback_completed = client_ok && server_ok.load();
    return result.dns_lookup_executed && result.loopback_completed;
}

bool RunRegistryRead(Result& result) {
    HKEY current_user = nullptr;
    if (RegOpenCurrentUser(KEY_READ, &current_user) != ERROR_SUCCESS) {
        return false;
    }
    DWORD subkeys = 0;
    DWORD values = 0;
    const LONG rc = RegQueryInfoKeyW(
        current_user, nullptr, nullptr, nullptr, &subkeys, nullptr, nullptr,
        &values, nullptr, nullptr, nullptr, nullptr);
    RegCloseKey(current_user);
    result.registry_read_executed = rc == ERROR_SUCCESS;
    return result.registry_read_executed;
}

bool RunTempFile(Result& result) {
    wchar_t temp_path[MAX_PATH]{};
    wchar_t temp_file[MAX_PATH]{};
    if (GetTempPathW(MAX_PATH, temp_path) == 0 ||
        GetTempFileNameW(temp_path, L"nxb", 0, temp_file) == 0) {
        return false;
    }
    std::vector<unsigned char> payload(kFileBytes);
    for (std::size_t i = 0; i < payload.size(); ++i) {
        payload[i] = static_cast<unsigned char>((i * 17u) % 251u);
    }
    HANDLE file = CreateFileW(
        temp_file, GENERIC_WRITE | GENERIC_READ, 0, nullptr,
        CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        DeleteFileW(temp_file);
        return false;
    }
    DWORD written = 0;
    bool ok = WriteFile(file, payload.data(), static_cast<DWORD>(payload.size()), &written, nullptr) != FALSE &&
              static_cast<std::size_t>(written) == payload.size();
    if (ok) {
        LARGE_INTEGER zero{};
        ok = SetFilePointerEx(file, zero, nullptr, FILE_BEGIN) != FALSE;
    }
    std::vector<unsigned char> readback(kFileBytes);
    DWORD read = 0;
    if (ok) {
        ok = ReadFile(file, readback.data(), static_cast<DWORD>(readback.size()), &read, nullptr) != FALSE &&
             static_cast<std::size_t>(read) == readback.size() && readback == payload;
    }
    CloseHandle(file);
    DeleteFileW(temp_file);
    result.temp_file_roundtrip = ok;
    return ok;
}

bool RunExtraWorker(Result& result) {
    std::atomic<std::uint64_t> checksum{0};
    result.kernel_worker_thread_created = true;
    std::thread worker([&]() {
        std::uint64_t local = 0;
        for (DWORD i = 0; i < kWorkerIterations; ++i) {
            local = (local * 1315423911ull) ^ static_cast<std::uint64_t>(i + 0x9e3779b9u);
        }
        checksum = local;
    });
    worker.join();
    result.kernel_worker_thread_joined = true;
    return checksum.load() != 0;
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
    if ((argc != 2 && argc != 3) || argv[1] == nullptr || argv[1][0] == L'\0') {
        return 64;
    }

    std::wstring receipt_path = argv[1];
    if (receipt_path.size() >= 2 && receipt_path.front() == L'"' && receipt_path.back() == L'"') {
        receipt_path = receipt_path.substr(1, receipt_path.size() - 2);
    }

    FixtureMode mode = FixtureMode::AllOn;
    if (argc == 3 && (argv[2] == nullptr || !ParseMode(argv[2], mode))) {
        return 66;
    }
    const StimulusConfig config = ConfigForMode(mode);

    Result result{};
    DWORD error_code = ERROR_SUCCESS;
    bool ok = true;

    if (config.gpu && !RunD3D11(result)) {
        ok = false;
        error_code = ERROR_NOT_SUPPORTED;
    }
    if (config.network && !RunLoopback(result)) {
        ok = false;
        if (error_code == ERROR_SUCCESS) error_code = ERROR_NETWORK_UNREACHABLE;
    }
    if (config.explicit_kernel) {
        if (!RunRegistryRead(result)) {
            ok = false;
            if (error_code == ERROR_SUCCESS) error_code = ERROR_ACCESS_DENIED;
        }
        if (!RunTempFile(result)) {
            ok = false;
            if (error_code == ERROR_SUCCESS) error_code = ERROR_WRITE_FAULT;
        }
        if (!RunExtraWorker(result)) {
            ok = false;
            if (error_code == ERROR_SUCCESS) error_code = ERROR_GEN_FAILURE;
        }
    }

    const std::string receipt = BuildReceipt(mode, config, result, ok ? "passed" : "failed", error_code);
    if (!WriteUtf8File(receipt_path, receipt)) {
        return 65;
    }
    return ok ? 0 : 1;
}
