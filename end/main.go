package main

import (
	"fmt"
	_ "time/tzdata" // 内嵌时区库：Android 上没有 /usr/share/zoneinfo，避免时间全部变成 UTC
	"ohome/buildinfo"
	"ohome/cmd"
)

// ohome main
func main() {
	setupDNSServers() // Android/Termux 上补齐 DNS（见 android_dns.go）
	fmt.Printf("ohome server version=%s commit=%s buildTime=%s channel=%s\n", buildinfo.CleanVersion(), buildinfo.Commit, buildinfo.BuildTime, buildinfo.CleanChannel())
	cmd.Start()
}
