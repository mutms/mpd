package vm

import gonet "net"

// PrimaryIP returns the VM's own IPv4 address on its primary interface —
// the LAN address the workstation reaches it at, and the one DNS's
// vm.service record points to.
//
// The address is a fact about the running VM, so it is read live rather
// than recorded. Empty when it can't be determined (e.g. a DHCP-less
// sandbox mid-boot), which callers render as "—".
//
// The mpd container bridge (10.163.x) is skipped: that is the VM as
// containers see it, never the LAN address.
func PrimaryIP() string {
	ifaces, err := gonet.Interfaces()
	if err != nil {
		return ""
	}
	for _, ifc := range ifaces {
		if ifc.Flags&gonet.FlagUp == 0 || ifc.Flags&gonet.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipnet, ok := a.(*gonet.IPNet)
			if !ok {
				continue
			}
			ip4 := ipnet.IP.To4()
			if ip4 == nil || !ip4.IsGlobalUnicast() {
				continue
			}
			if ip4[0] == 10 && ip4[1] == 163 { // mpd container bridge
				continue
			}
			return ip4.String()
		}
	}
	return ""
}
