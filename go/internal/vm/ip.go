package vm

import gonet "net"

// PrimaryIP returns the VM's IPv4 LAN address — the one the workstation
// reaches and the vm.service DNS record points to. Read live, never
// recorded; empty when it cannot be determined. The 10.163.x container
// bridge is skipped: it is never the LAN address.
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
