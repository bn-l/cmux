package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestParseConfigContentsLaunchSettings(t *testing.T) {
	t.Parallel()

	cfg := &TerminalConfig{}
	theme := &ThemeConfig{}
	var themeName string

	parseConfigContents(`
working-directory = ~/code
shell-integration = none
`, cfg, theme, &themeName)

	if cfg.WorkingDirectory != "~/code" {
		t.Fatalf("working-directory = %q, want ~/code", cfg.WorkingDirectory)
	}
	if cfg.ShellIntegration != "none" {
		t.Fatalf("shell-integration = %q, want none", cfg.ShellIntegration)
	}
}

func TestResolveSessionWorkingDirectory(t *testing.T) {
	t.Parallel()

	env := map[string]string{
		"HOME": "/tmp/home",
	}

	if got := resolveSessionWorkingDirectory(&TerminalConfig{WorkingDirectory: "~/code"}, env, "/tmp/process"); got != "/tmp/home/code" {
		t.Fatalf("tilde expansion = %q, want /tmp/home/code", got)
	}
	if got := resolveSessionWorkingDirectory(&TerminalConfig{WorkingDirectory: "home"}, env, "/tmp/process"); got != "/tmp/home" {
		t.Fatalf("home working-directory = %q, want /tmp/home", got)
	}
	if got := resolveSessionWorkingDirectory(&TerminalConfig{WorkingDirectory: "inherit"}, env, "/tmp/process"); got != "/tmp/process" {
		t.Fatalf("inherit working-directory = %q, want /tmp/process", got)
	}

	env["PTY_CWD"] = "/override"
	if got := resolveSessionWorkingDirectory(&TerminalConfig{WorkingDirectory: "~/code"}, env, "/tmp/process"); got != "/override" {
		t.Fatalf("PTY_CWD override = %q, want /override", got)
	}
}

func TestConfigureShellLaunchEnvForZsh(t *testing.T) {
	t.Parallel()

	tmp := t.TempDir()
	ghosttyResources := filepath.Join(tmp, "ghostty", "share", "ghostty")
	cmuxIntegration := filepath.Join(tmp, "Resources", "shell-integration")
	if err := os.MkdirAll(filepath.Join(ghosttyResources, "shell-integration", "zsh"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(cmuxIntegration, "zsh"), 0o755); err != nil {
		t.Fatal(err)
	}

	env := map[string]string{
		"HOME":    "/tmp/home",
		"SHELL":   "/bin/zsh",
		"ZDOTDIR": "/tmp/original-zdotdir",
	}

	configureShellLaunchEnv(env, &TerminalConfig{}, launchPaths{
		ghosttyResourcesDir: ghosttyResources,
		cmuxIntegrationDir:  cmuxIntegration,
	})

	if got := env["TERM"]; got != "xterm-ghostty" {
		t.Fatalf("TERM = %q, want xterm-ghostty", got)
	}
	if got := env["TERM_PROGRAM"]; got != "ghostty" {
		t.Fatalf("TERM_PROGRAM = %q, want ghostty", got)
	}
	if got := env["GHOSTTY_RESOURCES_DIR"]; got != ghosttyResources {
		t.Fatalf("GHOSTTY_RESOURCES_DIR = %q, want %q", got, ghosttyResources)
	}
	if got := env["ZDOTDIR"]; got != cmuxIntegration {
		t.Fatalf("ZDOTDIR = %q, want %q", got, cmuxIntegration)
	}
	if got := env["GHOSTTY_ZSH_ZDOTDIR"]; got != "/tmp/original-zdotdir" {
		t.Fatalf("GHOSTTY_ZSH_ZDOTDIR = %q, want /tmp/original-zdotdir", got)
	}
	if _, ok := env["CMUX_ZSH_ZDOTDIR"]; ok {
		t.Fatalf("CMUX_ZSH_ZDOTDIR should be unset when Ghostty integration is enabled")
	}
	parent := filepath.Dir(ghosttyResources)
	if got := env["XDG_DATA_DIRS"]; got != "/usr/local/share:/usr/share:"+parent {
		t.Fatalf("XDG_DATA_DIRS = %q", got)
	}
	if got := env["MANPATH"]; got != filepath.Join(parent, "man") {
		t.Fatalf("MANPATH = %q", got)
	}
}

func TestConfigureShellLaunchEnvRespectsShellIntegrationNone(t *testing.T) {
	t.Parallel()

	tmp := t.TempDir()
	cmuxIntegration := filepath.Join(tmp, "Resources", "shell-integration")
	if err := os.MkdirAll(filepath.Join(cmuxIntegration, "zsh"), 0o755); err != nil {
		t.Fatal(err)
	}

	env := map[string]string{
		"HOME":    "/tmp/home",
		"SHELL":   "/bin/zsh",
		"ZDOTDIR": "/tmp/original-zdotdir",
	}

	configureShellLaunchEnv(env, &TerminalConfig{ShellIntegration: "none"}, launchPaths{
		cmuxIntegrationDir: cmuxIntegration,
	})

	if _, ok := env["GHOSTTY_ZSH_ZDOTDIR"]; ok {
		t.Fatalf("GHOSTTY_ZSH_ZDOTDIR should be unset when shell-integration=none")
	}
	if got := env["CMUX_ZSH_ZDOTDIR"]; got != "/tmp/original-zdotdir" {
		t.Fatalf("CMUX_ZSH_ZDOTDIR = %q, want /tmp/original-zdotdir", got)
	}
	if got := env["ZDOTDIR"]; got != cmuxIntegration {
		t.Fatalf("ZDOTDIR = %q, want %q", got, cmuxIntegration)
	}
}

func TestBuildSessionLaunchFallsBackToProcessCwd(t *testing.T) {
	t.Parallel()

	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	processCwd := filepath.Dir(file)

	dir, env := buildSessionLaunch(nil, processCwd, []string{"HOME=/tmp/home", "SHELL=/bin/zsh"})
	if dir != processCwd {
		t.Fatalf("dir = %q, want %q", dir, processCwd)
	}
	envMap := envSliceToMap(env)
	if got := envMap["TERM"]; got != "xterm-ghostty" {
		t.Fatalf("TERM = %q, want xterm-ghostty", got)
	}
}
