package vm

// InfraService is one VM-integral piece of infrastructure, run under
// systemd on the VM. Distinct from the optional service containers
// (internal/service).
type InfraService struct {
	// Name is the short display name ("dnsmasq", "portal").
	Name string
	// Unit is the systemd unit backing it.
	Unit string
	// UnitUser distinguishes a `systemctl --user` unit from a system one.
	UnitUser bool
}

// InfraServices lists the VM-integral infrastructure, in display order.
// The apex caddy and the bridge/firewall oneshots are deliberately
// absent; diagnose those via systemctl.
func InfraServices() []InfraService {
	return []InfraService{
		{Name: "dnsmasq", Unit: DnsmasqUnit},
		{Name: "portal", Unit: WebUnitName, UnitUser: true},
		{Name: "projects", Unit: ProjectCaddyUnitName},
	}
}
