package services

import "os"

// concat joins RunArg slices left to right. A later -e for the same key
// wins in podman, so an override slice placed after a base slice takes
// effect.
func concat(parts ...[]string) []string {
	var out []string
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

// envDefault returns the environment variable value, or fallback when it
// is unset or empty.
func envDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
