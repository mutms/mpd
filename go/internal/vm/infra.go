package vm

// InfraService is one VM-integral piece of infrastructure: it runs on
// the VM under systemd, always on, at the gateway address. Deliberately
// distinct from the optional extra service containers (internal/service)
// — "service" is reserved for those; these are infra.
type InfraService struct {
	// Name is the short display name ("dnsmasq", "portal").
	Name string
	// Unit is the systemd unit backing it.
	Unit string
	// UnitUser distinguishes a `systemctl --user` unit from a system one.
	UnitUser bool
}

// InfraServices lists the VM-integral infrastructure, in display order.
// (caddy and the bridge/firewall oneshots are deliberately absent: they
// are plumbing below even this level, diagnosed via systemctl directly.)
func InfraServices() []InfraService {
	return []InfraService{
		{Name: "dnsmasq", Unit: DnsmasqUnit},
		{Name: "portal", Unit: WebUnitName, UnitUser: true},
	}
}
