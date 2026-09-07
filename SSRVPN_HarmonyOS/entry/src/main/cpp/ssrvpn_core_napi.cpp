/**
 * SSRVPN HarmonyOS — Mihomo 内核 NAPI 桥
 * 职责对应 upstream: android/native/bridge/bridge.go + bridge/Bridge.kt
 *
 * 加载 libgojni.so（Mihomo c-shared 内核），向 ArkTS 暴露：
 *   startCore(configPath, tunFd) / stopCore() / isCoreAlive() / coreVersion() /
 *   lastError() / attachTunFd(fd, mtu)
 *
 * Go 侧 c-shared 接口（cshared_main.go 编译产物 libgojni.so 导出）：
 *   SsrvpnInit(homeDir, configFile)
 *   SsrvpnStart(configPath *C.char, tunFd C.longlong) C.int
 *   SsrvpnStop() / SsrvpnIsRunning() C.int / SsrvpnVersion() / SsrvpnLastError() *C.char
 */
#include "napi/native_api.h"
#include "hilog/log.h"
#include <dlfcn.h>
#include <string>
#include <atomic>

#ifndef NM_FLAG_NONE
#define NM_FLAG_NONE 0
#endif

// 通过系统动态链接器按库名解析同一 HAP 内的原生库，避免依赖设备和系统版本相关的绝对安装路径。
static constexpr const char *CORE_LIB_PATH = "libgojni.so";
static constexpr const char *NAPI_LOG_TAG = "SsrvpnCoreNapi";

typedef int (*InitFn)(const char *, const char *);
typedef int (*StartFn)(const char *, long long);
typedef void (*StopFn)();
typedef int (*AliveFn)();
typedef const char *(*VersionFn)();
typedef const char *(*LastErrorFn)();

static void *g_core_handle = nullptr;
static InitFn g_init = nullptr;
static StartFn g_start = nullptr;
static StopFn g_stop = nullptr;
static AliveFn g_alive = nullptr;
static VersionFn g_version = nullptr;
static LastErrorFn g_last_error = nullptr;
static std::atomic<int> g_tun_fd{-1};
static std::atomic<bool> g_running{false};

static bool loadCore() {
    if (g_core_handle != nullptr) {
        return true;
    }
    g_core_handle = dlopen(CORE_LIB_PATH, RTLD_NOW | RTLD_GLOBAL);
    if (g_core_handle == nullptr) {
        g_core_handle = dlopen(nullptr, RTLD_NOW);
    }
    if (g_core_handle == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, NAPI_LOG_TAG, "dlopen libgojni.so failed: %s", dlerror());
        return false;
    }
    g_init = reinterpret_cast<InitFn>(dlsym(g_core_handle, "SsrvpnInit"));
    g_start = reinterpret_cast<StartFn>(dlsym(g_core_handle, "SsrvpnStart"));
    g_stop = reinterpret_cast<StopFn>(dlsym(g_core_handle, "SsrvpnStop"));
    g_alive = reinterpret_cast<AliveFn>(dlsym(g_core_handle, "SsrvpnIsRunning"));
    g_version = reinterpret_cast<VersionFn>(dlsym(g_core_handle, "SsrvpnVersion"));
    g_last_error = reinterpret_cast<LastErrorFn>(dlsym(g_core_handle, "SsrvpnLastError"));
    if (g_start == nullptr || g_stop == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, NAPI_LOG_TAG, "missing SsrvpnStart/SsrvpnStop symbols");
        return false;
    }
    if (g_init != nullptr) {
        g_init("/data/storage/el2/base/haps/entry/cache", "mihomo_config.yaml");
    }
    return true;
}

static napi_value StartCore(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char configPath[1024];
    size_t pathLen = 0;
    int tunFd = -1;
    bool ok = false;
    if (argc >= 2
        && napi_get_value_string_utf8(env, args[0], configPath, sizeof(configPath), &pathLen) == napi_ok
        && napi_get_value_int32(env, args[1], &tunFd) == napi_ok
        && loadCore()) {
        int rc = g_start(configPath, static_cast<long long>(tunFd));
        g_running.store(rc == 0);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, NAPI_LOG_TAG, "SsrvpnStart rc=%d tunFd=%d path=%s", rc, tunFd, configPath);
        ok = (rc == 0);
    }
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

static napi_value StopCore(napi_env env, napi_callback_info info) {
    if (g_stop != nullptr) {
        g_stop();
    }
    g_running.store(false);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value IsCoreAlive(napi_env env, napi_callback_info info) {
    bool alive = g_running.load() && g_alive != nullptr && g_alive() == 1;
    napi_value result;
    napi_get_boolean(env, alive, &result);
    return result;
}

static napi_value CoreVersion(napi_env env, napi_callback_info info) {
    const char *v = (g_version != nullptr) ? g_version() : "unknown";
    napi_value result;
    napi_create_string_utf8(env, v, NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value LastError(napi_env env, napi_callback_info info) {
    const char *v = (g_last_error != nullptr) ? g_last_error() : "";
    napi_value result;
    napi_create_string_utf8(env, v, NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value AttachTunFd(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int fd = -1;
    int mtu = 1500;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &fd);
    }
    if (argc >= 2) {
        napi_get_value_int32(env, args[1], &mtu);
    }
    g_tun_fd.store(fd);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, NAPI_LOG_TAG, "tun fd attached=%d mtu=%d", fd, mtu);
    napi_value result;
    napi_get_boolean(env, fd >= 0, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"startCore", nullptr, StartCore, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopCore", nullptr, StopCore, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isCoreAlive", nullptr, IsCoreAlive, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coreVersion", nullptr, CoreVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lastError", nullptr, LastError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"attachTunFd", nullptr, AttachTunFd, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module ssrvpnCoreModule = {
    .nm_version = 1,
    .nm_flags = NM_FLAG_NONE,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "ssrvpn_core_napi",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterSsrvpnCoreModule(void) {
    napi_module_register(&ssrvpnCoreModule);
}
