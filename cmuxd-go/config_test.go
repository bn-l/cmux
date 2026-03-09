package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveThemeUsesGhosttyResourcesDirAndBuiltinCandidate(t *testing.T) {
	t.Parallel()

	tmp := t.TempDir()
	home := filepath.Join(tmp, "home")
	resources := filepath.Join(tmp, "ghostty", "share", "ghostty")
	if err := os.MkdirAll(filepath.Join(resources, "themes"), 0o755); err != nil {
		t.Fatal(err)
	}
	themePath := filepath.Join(resources, "themes", "Dracula")
	if err := os.WriteFile(themePath, []byte("foreground = #f8f8f2\nbackground = #282a36\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	var theme ThemeConfig
	err := resolveThemeFromPaths(
		"Dracula (builtin)",
		&theme,
		themeSearchPaths(home, "Dracula (builtin)", filepath.Join(tmp, "cwd"), filepath.Join(tmp, "exe"), map[string]string{
			"GHOSTTY_RESOURCES_DIR": resources,
		}),
	)
	if err != nil {
		t.Fatalf("resolveThemeFromPaths: %v", err)
	}
	if theme.Foreground != "#f8f8f2" {
		t.Fatalf("foreground = %q, want #f8f8f2", theme.Foreground)
	}
	if theme.Background != "#282a36" {
		t.Fatalf("background = %q, want #282a36", theme.Background)
	}
}

func TestThemeSearchPathsIncludesXDGDataDirs(t *testing.T) {
	t.Parallel()

	paths := themeSearchPaths("/tmp/home", "Nord", "/tmp/cwd", "/tmp/exe", map[string]string{
		"XDG_DATA_DIRS": "/opt/share:/usr/local/share",
	})

	want := filepath.Join("/opt/share", "ghostty", "themes", "Nord")
	found := false
	for _, path := range paths {
		if path == want {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("missing XDG theme path %q in %#v", want, paths)
	}
}

func TestResolveThemeNameChoosesPreferredVariant(t *testing.T) {
	t.Parallel()

	raw := "light:3024 Day,dark:Monokai Classic"
	if got := resolveThemeName(raw, colorSchemeDark); got != "Monokai Classic" {
		t.Fatalf("dark theme = %q, want Monokai Classic", got)
	}
	if got := resolveThemeName(raw, colorSchemeLight); got != "3024 Day" {
		t.Fatalf("light theme = %q, want 3024 Day", got)
	}
}

func TestLoadGhosttyConfigReadsConfigGhosttyAndResolvesDarkTheme(t *testing.T) {
	tmp := t.TempDir()
	home := filepath.Join(tmp, "home")
	configDir := filepath.Join(home, "Library", "Application Support", "com.mitchellh.ghostty")
	resources := filepath.Join(tmp, "ghostty", "share", "ghostty")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(resources, "themes"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(configDir, "config.ghostty"),
		[]byte("font-family = \"Menlo\"\ntheme = \"light:3024 Day,dark:Monokai Classic\"\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(resources, "themes", "3024 Day"),
		[]byte("background = #f7f7f7\nforeground = #090300\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(resources, "themes", "Monokai Classic"),
		[]byte("background = #272822\nforeground = #f8f8f2\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	t.Setenv("HOME", home)
	t.Setenv("GHOSTTY_RESOURCES_DIR", resources)
	t.Setenv("CMUX_COLOR_SCHEME", "dark")

	cfg, err := LoadGhosttyConfig()
	if err != nil {
		t.Fatalf("LoadGhosttyConfig: %v", err)
	}
	if cfg.Theme == nil {
		t.Fatal("expected resolved theme")
	}
	if cfg.Theme.Background != "#272822" {
		t.Fatalf("background = %q, want #272822", cfg.Theme.Background)
	}
	if cfg.Theme.Foreground != "#f8f8f2" {
		t.Fatalf("foreground = %q, want #f8f8f2", cfg.Theme.Foreground)
	}
}
