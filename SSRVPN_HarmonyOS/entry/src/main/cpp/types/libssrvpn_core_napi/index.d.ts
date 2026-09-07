/**
 * NAPI 内核桥模块的 ArkTS 类型声明
 * 实现: entry/src/main/cpp/ssrvpn_core_napi.cpp (libssrvpn_core_napi.so)
 */
export const startCore: (configPath: string, tunFd: number) => boolean;
export const stopCore: () => void;
export const isCoreAlive: () => boolean;
export const coreVersion: () => string;
export const lastError: () => string;
export const attachTunFd: (fd: number, mtu: number) => boolean;
