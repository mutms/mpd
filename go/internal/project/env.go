package project

import (
	"fmt"
	"strings"
)

// EnvMutation is one KEY=VALUE pair destined for a project's mpd.env.
type EnvMutation struct{ Key, Value string }

// ParseMutations validates positional KEY=VALUE arguments.
//
// This is the CLI's boundary against shell injection into mpd.env. The
// file is read by a whitelist parser rather than sourced, so a bad value
// could not execute anyway — but it could still corrupt the file or
// smuggle a value past the parser, so it is rejected here where the
// error can name the argument.
func ParseMutations(args []string, validateDBTag func(string) error) ([]EnvMutation, error) {
	var out []EnvMutation
	for _, arg := range args {
		if strings.HasPrefix(arg, "--type=") {
			return nil, fmt.Errorf(
				"'--type' is not supported in configure. Choose project type at create time.")
		}
		if strings.HasPrefix(arg, "--") {
			return nil, fmt.Errorf(
				"Unknown flag '%s'. Configure takes KEY=VALUE pairs "+
					"(e.g. MPD_DB=postgres:18, MPD_PHP_VERSION=8.4).", arg)
		}
		key, value, found := strings.Cut(arg, "=")
		if !found {
			return nil, fmt.Errorf(
				"Argument '%s' is not KEY=VALUE. "+
					"Configure takes positional pairs like MPD_DB=postgres:18.", arg)
		}
		if err := validateKey(key); err != nil {
			return nil, err
		}
		if err := validateValue(key, value, validateDBTag); err != nil {
			return nil, err
		}
		out = append(out, EnvMutation{Key: key, Value: value})
	}
	return out, nil
}

func validateKey(key string) error {
	if key == "" {
		return fmt.Errorf("Empty key in KEY=VALUE argument.")
	}
	if !strings.HasPrefix(key, "MPD_") {
		return fmt.Errorf("Key '%s' must start with 'MPD_'.", key)
	}
	const allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
	for _, r := range key {
		if !strings.ContainsRune(allowed, r) {
			return fmt.Errorf("Key '%s' must match ^MPD_[A-Z0-9_]+$.", key)
		}
	}
	return nil
}

// validateValue applies a strict validator to keys with known shapes and
// a conservative charset to everything else.
//
// An empty value is always allowed: it means "delete the line", which is
// how a project drops back to the inherited default.
func validateValue(key, value string, validateDBTag func(string) error) error {
	if value == "" {
		return nil
	}
	if key == "MPD_DB" {
		return validateDBTag(value)
	}
	// Deliberately narrow: alphanumerics plus . _ - : / , @ = +. Every
	// shell metacharacter is excluded — whitespace, quotes, $, `, ;, &,
	// |, <, >, parens, braces, brackets, newline.
	const allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-:/,@=+"
	for _, r := range value {
		if !strings.ContainsRune(allowed, r) {
			return fmt.Errorf(
				"Value for '%s' contains disallowed characters. "+
					"Only [A-Za-z0-9._:/,@=+-] are accepted via the CLI; "+
					"edit /srv/projects/<project>/mpd.env directly for free-form values.", key)
		}
	}
	return nil
}
