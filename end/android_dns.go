package main

// android_dns.go —— 为 Android / Termux 环境补齐 DNS 解析能力。
//
// 背景：本项目以 CGO_ENABLED=0 编译，DNS 走 Go 的纯 Go 解析器，它依赖 POSIX 的
// /etc/resolv.conf。Android 没有这个文件（DNS 由系统 netd 提供），于是所有域名解析
// 都会退化成 "[::1]:53 connection refused"。
//
// 处理策略（不改动原有行为）：
//  1. 若设置环境变量 WPAN_DNS（如 WPAN_DNS="192.168.1.1 223.5.5.5"），强制使用这些 DNS；
//  2. 否则若能读到可用 resolv.conf（/etc/resolv.conf、$PREFIX/etc/resolv.conf），保持 Go 默认行为；
//  3. 否则（典型 Android 情况）退回到内置的公共 DNS 列表，轮询使用。

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"
)

var defaultDNSServers = []string{"223.5.5.5:53", "119.29.29.29:53", "8.8.8.8:53"}

var dnsCounter int64

func setupDNSServers() {
	servers := parseDNSServers(os.Getenv("WPAN_DNS"))
	if len(servers) == 0 {
		if resolvConfUsable() {
			return
		}
		servers = defaultDNSServers
	}
	if len(servers) == 0 {
		return
	}

	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			proto := "udp"
			if strings.HasPrefix(network, "tcp") {
				proto = "tcp"
			}
			idx := int(atomic.AddInt64(&dnsCounter, 1)-1) % len(servers)
			d := net.Dialer{Timeout: 6 * time.Second}
			return d.DialContext(ctx, proto, servers[idx])
		},
	}
}

func parseDNSServers(raw string) []string {
	fields := strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == ';' || r == ' ' || r == '\t' || r == '\n'
	})
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		f = strings.TrimSpace(f)
		if f == "" {
			continue
		}
		if _, _, err := net.SplitHostPort(f); err != nil {
			f = net.JoinHostPort(strings.Trim(f, "[]"), "53")
		}
		out = append(out, f)
	}
	return out
}

func resolvConfUsable() bool {
	candidates := []string{
		os.Getenv("WPAN_RESOLV_CONF"),
		"/etc/resolv.conf",
	}
	if p := strings.TrimSpace(os.Getenv("PREFIX")); p != "" {
		candidates = append(candidates, filepath.Join(p, "etc", "resolv.conf"))
	}
	if p := strings.TrimSpace(os.Getenv("TMPDIR")); p != "" {
		candidates = append(candidates, filepath.Join(p, "resolv.conf"))
	}

	for _, path := range candidates {
		if path == "" {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "nameserver") && len(strings.Fields(line)) >= 2 {
				return true
			}
		}
	}
	return false
}
