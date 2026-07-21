package cli

import (
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/mutms/mpd/go/internal/ui"
	"github.com/mutms/mpd/go/internal/vm"
)

// InstallCompletion installs the shell-side completion shim for the
// user's $SHELL.
//
// The shim is small and stable — it forwards every Tab press to `mpd
// --complete`, which is where the real candidate logic lives. That split
// means adding a verb never requires reinstalling completion.
//
// Operates on the user's shell config rather than on mpd state: this is
// per-user ergonomics, so a failure warns and setup continues.
func InstallCompletion(out io.Writer) {
	shell := os.Getenv("SHELL")
	switch {
	case strings.HasSuffix(shell, "/zsh"):
		installZshCompletion(out)
	case strings.HasSuffix(shell, "/bash"):
		installBashCompletion(out)
	default:
		if shell == "" {
			shell = "(unset)"
		}
		ui.Note(out, "Completion skipped — SHELL=%s.", shell)
	}
}

func installZshCompletion(out io.Writer) {
	home := vm.Home()
	dir := filepath.Join(home, ".zsh", "completions")
	script, ok := completionShim(out, "_mpd")
	if !ok {
		return
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		ui.Warn(out, "cannot create %s: %v", dir, err)
		return
	}
	target := filepath.Join(dir, "_mpd")
	if err := os.WriteFile(target, script, 0o644); err != nil {
		ui.Warn(out, "cannot write %s: %v", target, err)
		return
	}
	ui.OK(out, "zsh completion installed at ~/.zsh/completions/_mpd")

	// zsh caches compiled completion definitions; a stale dump would
	// keep serving the previous shim until it happened to expire.
	if entries, err := os.ReadDir(home); err == nil {
		for _, e := range entries {
			if strings.HasPrefix(e.Name(), ".zcompdump") {
				os.Remove(filepath.Join(home, e.Name()))
			}
		}
	}

	zshrc := filepath.Join(home, ".zshrc")
	current := readOrEmpty(zshrc)
	if strings.Contains(current, "~/.zsh/completions") {
		ui.Note(out, "~/.zshrc already includes ~/.zsh/completions in fpath.")
	} else {
		block := "\n# mpd completions (added by mpd --vm-setup)\nfpath=(~/.zsh/completions $fpath)\n"
		// compinit must run after fpath is set, but only add it when the
		// user's own config does not already call it — a second compinit
		// is slow and can print warnings.
		if !strings.Contains(current, "compinit") {
			block += "autoload -Uz compinit && compinit\n"
		}
		appendOrCreate(out, zshrc, block)
		ui.OK(out, "Updated ~/.zshrc with fpath=(~/.zsh/completions $fpath)")
	}
	ui.Note(out, "Run 'exec zsh' to activate completions.")
}

func installBashCompletion(out io.Writer) {
	home := vm.Home()
	dir := filepath.Join(home, ".bash_completion.d")
	script, ok := completionShim(out, "mpd.bash")
	if !ok {
		return
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		ui.Warn(out, "cannot create %s: %v", dir, err)
		return
	}
	target := filepath.Join(dir, "mpd")
	if err := os.WriteFile(target, script, 0o644); err != nil {
		ui.Warn(out, "cannot write %s: %v", target, err)
		return
	}
	ui.OK(out, "bash completion installed at ~/.bash_completion.d/mpd")

	// The sentinel comment is what makes the append idempotent — bash
	// has no fpath equivalent to test for.
	const sentinel = "# mpd completions (added by mpd --vm-setup)"
	bashrc := filepath.Join(home, ".bashrc")
	if strings.Contains(readOrEmpty(bashrc), sentinel) {
		ui.Note(out, "~/.bashrc already sources ~/.bash_completion.d/mpd.")
	} else {
		appendOrCreate(out, bashrc, "\n"+sentinel+
			"\nif [ -f ~/.bash_completion.d/mpd ]; then . ~/.bash_completion.d/mpd; fi\n\n")
		ui.OK(out, "Updated ~/.bashrc to source ~/.bash_completion.d/mpd")
	}
	ui.Note(out, "Run 'exec bash' (or open a new shell) to activate completions.")
}

func completionShim(out io.Writer, name string) ([]byte, bool) {
	path := filepath.Join(vm.AssetsDir, "completions", name)
	data, err := os.ReadFile(path)
	if err != nil {
		ui.Warn(out, "completion shim not found at %s", path)
		return nil, false
	}
	return data, true
}

func readOrEmpty(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(data)
}

// appendOrCreate appends to an rc file, creating it when absent. Append
// rather than rewrite: this is the user's own shell config and mpd owns
// only the block it adds.
func appendOrCreate(out io.Writer, path, content string) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		ui.Warn(out, "cannot update %s: %v", path, err)
		return
	}
	defer f.Close()
	if _, err := f.WriteString(content); err != nil {
		ui.Warn(out, "cannot update %s: %v", path, err)
	}
}
