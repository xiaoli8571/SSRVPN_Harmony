// Package bridge exposes the Mihomo lifecycle used by the Android JNI wrapper.
package bridge

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

var (
	coreMu               sync.Mutex
	running              bool
	protectRead          *os.File
	protectWrite         *os.File
	protectSessionMu     sync.Mutex
	activeProtectSession *protectSession
	protectStopRequests  atomic.Int32
)

const protectResultTimeout = 5 * time.Second

var (
	errProtectStopped  = errors.New("protect monitor stopped")
	errProtectTimedOut = errors.New("protect monitor timed out")
)

type protectSession struct {
	result     chan bool
	done       chan struct{}
	cancelOnce sync.Once
	requestMu  sync.Mutex
	writer     *os.File
}

func newProtectSession() *protectSession {
	return &protectSession{
		result: make(chan bool),
		done:   make(chan struct{}),
	}
}

func (session *protectSession) wait(timeout time.Duration) (bool, error) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case ok := <-session.result:
		return ok, nil
	case <-session.done:
		return false, errProtectStopped
	case <-timer.C:
		return false, errProtectTimedOut
	}
}

func (session *protectSession) report(ok bool) bool {
	select {
	case session.result <- ok:
		return true
	case <-session.done:
		return false
	}
}

func (session *protectSession) active() bool {
	select {
	case <-session.done:
		return false
	default:
		return true
	}
}

func (session *protectSession) cancel() {
	session.cancelOnce.Do(func() { close(session.done) })
}

func replaceProtectSession(next *protectSession) {
	protectSessionMu.Lock()
	previous := activeProtectSession
	activeProtectSession = next
	protectSessionMu.Unlock()
	if previous != nil && previous != next {
		previous.cancel()
	}
}

func installProtectSession(next *protectSession) bool {
	protectSessionMu.Lock()
	if protectStopRequests.Load() > 0 {
		protectSessionMu.Unlock()
		next.cancel()
		return false
	}
	previous := activeProtectSession
	activeProtectSession = next
	protectSessionMu.Unlock()
	if previous != nil && previous != next {
		previous.cancel()
	}
	return true
}

func currentProtectSession() *protectSession {
	protectSessionMu.Lock()
	defer protectSessionMu.Unlock()
	return activeProtectSession
}

func retireProtectSession(session *protectSession) {
	protectSessionMu.Lock()
	if activeProtectSession == session {
		activeProtectSession = nil
	}
	protectSessionMu.Unlock()
	session.cancel()
	if session.writer != nil {
		_ = session.writer.Close()
	}
}

func protectReadyForStart(tunFd int64) bool {
	if tunFd <= 0 {
		return true
	}
	if protectWrite == nil || protectRead == nil {
		return false
	}
	session := currentProtectSession()
	return session != nil && session.writer == protectWrite && session.active()
}

// releaseProtectLocked must be called while coreMu is held.
func releaseProtectLocked() {
	replaceProtectSession(nil)
	if protectWrite != nil {
		_ = protectWrite.Close()
		protectWrite = nil
	}
	if protectRead != nil {
		_ = protectRead.Close()
		protectRead = nil
	}
}

func Init(homeDir, configFile string) {
	C.SetHomeDir(homeDir)
	C.SetConfig(configFile)
	log.Infoln("Bridge: init homeDir=%s configFile=%s", homeDir, configFile)
}

func Start(configPath string, tunFd int64) (result string) {
	coreMu.Lock()
	defer coreMu.Unlock()
	defer func() {
		if recovered := recover(); recovered != nil {
			result = fmt.Sprintf("panic: %v", recovered)
			log.Errorln("Bridge: recovered from panic: %v", recovered)
		}
		if result != "" && !running {
			releaseProtectLocked()
		}
	}()

	if running {
		return "already running"
	}

	log.Infoln("Bridge: reading config %s", configPath)
	configBytes, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Sprintf("read config: %v", err)
	}
	log.Infoln("Bridge: read %d bytes of config", len(configBytes))

	cfg, err := config.Parse(configBytes)
	if err != nil {
		return fmt.Sprintf("parse config: %v", err)
	}
	log.Infoln(
		"Bridge: config parsed, %d proxies, external-controller=%s",
		len(cfg.Proxies),
		cfg.Controller.ExternalController,
	)
	if cfg.Controller.ExternalController == "" {
		cfg.Controller.ExternalController = "127.0.0.1:9090"
		log.Infoln("Bridge: set external-controller to 127.0.0.1:9090")
	}

	if tunFd > 0 {
		cfg.General.Tun.Enable = true
		// gvisor 栈（fd 注入唯一可用的栈: sing-tun 的 system 栈依赖
		// iptables/nftables REDIRECT, 应用沙箱无权限）。gvisor 的 fdbased
		// 端点对 VPN fd 执行 Fstat 会被 OHOS 拒绝(仅 readv/writev 可用),
		// 通过 go.mod replace 指向打过 isSocketFD 补丁的本地 gvisor 副本解决
		// (与 Hey 项目 docs/harmonyos-go-tls-wall.md 的做法一致)。
		// 地址/MTU 与 VpnExtensionAbility 的 VpnConfig 严格一致(对齐 NekoBox)。
		cfg.General.Tun.Stack = C.TunGvisor
		cfg.General.Tun.FileDescriptor = int(tunFd)
		cfg.General.Tun.DNSHijack = []string{"any:53"}
		cfg.General.Tun.AutoRoute = false
		cfg.General.Tun.AutoDetectInterface = false
		cfg.General.Tun.MTU = 1400
		cfg.General.Tun.Inet4Address = []netip.Prefix{
			netip.MustParsePrefix("172.19.0.1/30"),
		}
		log.Infoln("Bridge: TUN fd=%d, stack=gvisor(patched), address=172.19.0.1/30", tunFd)

		// ── 防回环双保险（对齐 NekoBox 的 route.default_interface）──
		// 1) 代理服务器域名在内核启动前用系统 resolver 预解析成真实 IP 写入
		//    hosts: 否则 TUN 的 fake-ip + dns-hijack 会把代理域名也解析成
		//    198.18.x.x, 内核拿假 IP 拨号代理服务器 → 全部 i/o timeout
		//    (真机 core.log: "dial tcp 198.18.0.5:443: i/o timeout" 实证)。
		pinProxyServerHosts(cfg)
		// 2) 出站 socket 强绑物理网卡(wlan0 等), 绕开 TUN 默认路由:
		//    应用访问代理服务器域名的连接会被 MATCH,PROXY 送进代理自身,
		//    绑网卡后即使规则误伤也能直连到达。
		cfg.General.Interface = defaultPhysicalInterface()
		log.Infoln("Bridge: outbound interface=%s", cfg.General.Interface)
	} else {
		log.Infoln("Bridge: no TUN fd (tunFd=%d), running without TUN", tunFd)
	}

	hub.ApplyConfig(cfg)

	// ApplyConfig may return before the REST controller has finished binding.
	// Do not report the core as running until the controller socket is actually
	// accepting connections; otherwise ArkTS can observe IsRunning=true while
	// every /version probe still races with controller startup.
	controllerAddress := cfg.Controller.ExternalController
	controllerDeadline := time.Now().Add(10 * time.Second)
	var controllerErr error
	for time.Now().Before(controllerDeadline) {
		conn, err := net.DialTimeout("tcp", controllerAddress, 300*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			controllerErr = nil
			break
		}
		controllerErr = err
		time.Sleep(100 * time.Millisecond)
	}
	if controllerErr != nil {
		executor.Shutdown()
		return fmt.Sprintf("controller %s not ready: %v", controllerAddress, controllerErr)
	}

	running = true
	log.Infoln("Bridge: started successfully, API on %s", controllerAddress)
	return ""
}

func Stop() {
	// Start holds coreMu while ApplyConfig may itself be waiting for a protect
	// response. Cancel that wait before attempting to take coreMu.
	protectStopRequests.Add(1)
	replaceProtectSession(nil)
	defer protectStopRequests.Add(-1)

	coreMu.Lock()
	defer coreMu.Unlock()

	releaseProtectLocked()
	if running {
		listener.ReCreateMixed(0, nil)
		listener.ReCreateSocks(0, nil)
		// Cleanup closes the active TUN listener but retains LastTunConf. Reset
		// it through the listener lock so a later start that reuses the same
		// numeric Android fd cannot be mistaken for an unchanged configuration.
		listener.ReCreateTun(LC.Tun{}, tunnel.Tunnel)
		executor.Shutdown()
		running = false
	}
	log.Infoln("Bridge: stopped")
}

func IsRunning() bool {
	coreMu.Lock()
	defer coreMu.Unlock()
	return running
}

func InitProtect() int64 {
	readPipe, writePipe, err := os.Pipe()
	if err != nil {
		log.Errorln("Bridge: pipe error: %v", err)
		return -1
	}

	coreMu.Lock()
	releaseProtectLocked()
	session := newProtectSession()
	session.writer = writePipe
	if !installProtectSession(session) {
		_ = readPipe.Close()
		_ = writePipe.Close()
		coreMu.Unlock()
		log.Errorln("Bridge: protect pipe rejected while stop is pending")
		return -1
	}
	protectRead = readPipe
	protectWrite = writePipe
	readFd := int(readPipe.Fd())
	transferFd, err := syscall.Dup(readFd)
	if err != nil || transferFd <= 0 {
		if err == nil {
			err = fmt.Errorf("invalid duplicated descriptor %d", transferFd)
			_ = syscall.Close(transferFd)
		}
		releaseProtectLocked()
		coreMu.Unlock()
		log.Errorln("Bridge: duplicate protect pipe error: %v", err)
		return -1
	}
	syscall.CloseOnExec(transferFd)
	coreMu.Unlock()

	// The raw duplicate is transferred to Kotlin. Go keeps and closes only the
	// original readPipe; Kotlin must adopt and eventually close transferFd.
	log.Infoln("Bridge: protect pipe ready, readFd=%d transferFd=%d", readFd, transferFd)
	return int64(transferFd)
}

func SetProtectResult(ok bool) {
	if session := currentProtectSession(); session != nil {
		session.report(ok)
	}
}

func init() {
	// OHOS 不装 Android 式 socket hook: Android 需要 VpnService.protect(fd) 逐个
	// 保护 socket, 而 OHOS 的防回环由 VpnExtensionAbility 的 protectProcessNet()
	// 进程级生效(NekoBox 同架构无 hook 也正常)。hook 的管道应答机制在 OHOS 上
	// 是纯故障点(真机日志实测过 "protect monitor is unavailable" 拖垮全部拨号)。
	runtime.GOMAXPROCS(runtime.NumCPU())
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			var dialer net.Dialer
			return dialer.DialContext(ctx, network, address)
		},
	}
}

// defaultPhysicalInterface 返回带默认路由且非 TUN 的物理网卡名(wlan0 等)。
// 出站 socket 绑定到它, 绕开 TUN 默认路由(对齐 NekoBox 的 route.default_interface)。
func defaultPhysicalInterface() string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		name := iface.Name
		// 跳过 TUN/VPN/虚拟网卡
		if strings.Contains(name, "tun") || strings.Contains(name, "vpn") || strings.Contains(name, "docker") {
			continue
		}
		addrs, addrErr := iface.Addrs()
		if addrErr != nil {
			continue
		}
		for _, addr := range addrs {
			if ipnet, ok := addr.(*net.IPNet); ok {
				ip := ipnet.IP
				// 找全局单播 IPv4(wlan0 的 192.168.x.x / rmnet 的运营商地址)
				if ip.To4() != nil && ip.IsGlobalUnicast() {
					return name
				}
			}
		}
	}
	return ""
}

// pinProxyServerHosts 把配置里所有代理服务器的域名预解析为真实 IP 并写入 cfg.Hosts,
// 让内核拨号代理服务器时完全绕开 fake-ip DNS(否则拿 198.18.x.x 假地址拨号, 全部超时)。
// 解析用纯净的系统 UDP DNS(此时 TUN 尚未接管, /etc/resolv.conf 指向系统 DNS)。
func pinProxyServerHosts(cfg *config.Config) {
	if cfg == nil || len(cfg.Proxies) == 0 || cfg.Hosts == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	pinned := 0
	for _, proxy := range cfg.Proxies {
		server := proxy.Addr()
		if len(server) == 0 {
			continue
		}
		// 跳过裸 IP
		if net.ParseIP(server) != nil {
			continue
		}
		ips, err := net.DefaultResolver.LookupIP(ctx, "ip4", server)
		if err != nil || len(ips) == 0 {
			log.Warnln("Bridge: pre-resolve proxy server %s failed: %v", server, err)
			continue
		}
		addr, ok := netip.AddrFromSlice(ips[0])
		if !ok {
			continue
		}
		hostValue, hvErr := resolver.NewHostValueByIPs([]netip.Addr{addr.Unmap()})
		if hvErr != nil {
			continue
		}
		if insertErr := cfg.Hosts.Insert(server, hostValue); insertErr != nil {
			log.Warnln("Bridge: insert host %s failed: %v", server, insertErr)
			continue
		}
		pinned++
		log.Infoln("Bridge: pinned %s -> %s", server, ips[0].String())
	}
	log.Infoln("Bridge: pinned %d proxy server hosts", pinned)
}
