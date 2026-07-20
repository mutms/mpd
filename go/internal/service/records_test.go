package service

import "testing"

// A proxied service must NOT resolve to its own address: the portal
// terminates TLS for it, and pointing the name at the service itself
// would reach a plain-HTTP port with no certificate.
func TestProxiedServiceResolvesToThePortal(t *testing.T) {
	n := testNet(t, 150)
	portal := "10.163.150.4"

	got := map[string]string{}
	for _, r := range DNSRecords(n) {
		got[r.Host] = r.IP
	}

	if got["adminer.service.150.mpd.test"] != portal {
		t.Errorf("adminer → %q, want the portal at %q",
			got["adminer.service.150.mpd.test"], portal)
	}
	// Its own address is still where the portal proxies TO.
	d, _ := Find("adminer")
	if want := "http://10.163.150.6:8080"; d.Proxy.UpstreamURL(d.IP(n)) != want {
		t.Errorf("upstream = %q, want %q", d.Proxy.UpstreamURL(d.IP(n)), want)
	}
}

// Both portal names must answer: the apex is what a developer types,
// portal.service.<zone> is what the uniform naming implies.
func TestPortalPublishesApexAndServiceName(t *testing.T) {
	n := testNet(t, 150)
	want := map[string]bool{"150.mpd.test": false, "portal.service.150.mpd.test": false}
	for _, r := range DNSRecords(n) {
		if _, ok := want[r.Host]; ok {
			want[r.Host] = true
			if r.IP != "10.163.150.4" {
				t.Errorf("%s → %q, want the portal address", r.Host, r.IP)
			}
		}
	}
	for host, found := range want {
		if !found {
			t.Errorf("no record published for %s", host)
		}
	}
}

// Every service must publish at least its canonical name, or it becomes
// unreachable the moment someone adds one without an aliases func.
func TestEveryServiceIsReachableByItsCanonicalName(t *testing.T) {
	n := testNet(t, 150)
	published := map[string]bool{}
	for _, r := range DNSRecords(n) {
		published[r.Host] = true
	}
	for _, d := range All() {
		if !published[d.DNS(n)] {
			t.Errorf("service %q publishes no record for %q", d.Name, d.DNS(n))
		}
	}
}

func TestRecordsFollowTheVM(t *testing.T) {
	for _, octet := range []int{0, 150, 254} {
		n := testNet(t, octet)
		for _, r := range DNSRecords(n) {
			if !n.IsInZone(r.Host) {
				t.Errorf("octet %d: record %q is outside zone %s", octet, r.Host, n.Zone())
			}
		}
	}
}
