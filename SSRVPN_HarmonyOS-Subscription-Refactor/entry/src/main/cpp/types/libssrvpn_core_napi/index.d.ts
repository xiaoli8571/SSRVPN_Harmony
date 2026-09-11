/**
 * NAPI 内核桥模块的 ArkTS 类型声明
 * 实现: entry/src/main/cpp/ssrvpn_core_napi.cpp (libssrvpn_core_napi.so)
 */
export const startCore: (configPath: string, tunFd: number) => boolean;
export const initProtect: () => number;
/** 返回 [socketFd, seq]；无请求时 socketFd 为 -1（seq 为 -1）。 */
export const readProtectSocketFd: () => number[];
/** 旧版无 seq 回执，仅保留兼容，不再唤醒等待者。 */
export const setProtectResult: (ok: boolean) => void;
/** 按 seq 回传 protect 结果，精确唤醒对应拨号协程。 */
export const setProtectResultForFd: (fd: number, seq: number, ok: boolean) => void;
export const stopCore: () => void;
export const isCoreAlive: () => boolean;
export const coreVersion: () => string;
export const lastError: () => string;
export const attachTunFd: (fd: number, mtu: number) => boolean;
