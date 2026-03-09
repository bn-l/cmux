package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

type colorSchemePreference string

const (
	colorSchemeLight colorSchemePreference = "light"
	colorSchemeDark  colorSchemePreference = "dark"
)

// TerminalConfig holds parsed Ghostty config values.
type TerminalConfig struct {
	FontFamily       string       `json:"fontFamily,omitempty"`
	FontSize         *uint16      `json:"fontSize,omitempty"`
	CursorStyle      string       `json:"cursorStyle,omitempty"`
	CursorBlink      *bool        `json:"cursorBlink,omitempty"`
	Scrollback       *uint32      `json:"scrollback,omitempty"`
	Renderer         string       `json:"renderer,omitempty"`
	WorkingDirectory string       `json:"workingDirectory,omitempty"`
	ShellIntegration string       `json:"shellIntegration,omitempty"`
	Theme            *ThemeConfig `json:"theme,omitempty"`
}

type ThemeConfig struct {
	Foreground          string `json:"foreground,omitempty"`
	Background          string `json:"background,omitempty"`
	Cursor              string `json:"cursor,omitempty"`
	CursorAccent        string `json:"cursorAccent,omitempty"`
	SelectionBackground string `json:"selectionBackground,omitempty"`
	SelectionForeground string `json:"selectionForeground,omitempty"`
	// Palette colors
	Black         string `json:"black,omitempty"`
	Red           string `json:"red,omitempty"`
	Green         string `json:"green,omitempty"`
	Yellow        string `json:"yellow,omitempty"`
	Blue          string `json:"blue,omitempty"`
	Magenta       string `json:"magenta,omitempty"`
	Cyan          string `json:"cyan,omitempty"`
	White         string `json:"white,omitempty"`
	BrightBlack   string `json:"brightBlack,omitempty"`
	BrightRed     string `json:"brightRed,omitempty"`
	BrightGreen   string `json:"brightGreen,omitempty"`
	BrightYellow  string `json:"brightYellow,omitempty"`
	BrightBlue    string `json:"brightBlue,omitempty"`
	BrightMagenta string `json:"brightMagenta,omitempty"`
	BrightCyan    string `json:"brightCyan,omitempty"`
	BrightWhite   string `json:"brightWhite,omitempty"`
}

func (t *ThemeConfig) isEmpty() bool {
	return t.Foreground == "" && t.Background == "" &&
		t.Cursor == "" && t.CursorAccent == "" &&
		t.SelectionBackground == "" && t.SelectionForeground == "" &&
		t.Black == "" && t.Red == "" && t.Green == "" &&
		t.Yellow == "" && t.Blue == "" && t.Magenta == "" &&
		t.Cyan == "" && t.White == "" &&
		t.BrightBlack == "" && t.BrightRed == "" && t.BrightGreen == "" &&
		t.BrightYellow == "" && t.BrightBlue == "" && t.BrightMagenta == "" &&
		t.BrightCyan == "" && t.BrightWhite == ""
}

// setPalette sets a palette color by index.
func (t *ThemeConfig) setPalette(idx int, color string) {
	switch idx {
	case 0:
		t.Black = color
	case 1:
		t.Red = color
	case 2:
		t.Green = color
	case 3:
		t.Yellow = color
	case 4:
		t.Blue = color
	case 5:
		t.Magenta = color
	case 6:
		t.Cyan = color
	case 7:
		t.White = color
	case 8:
		t.BrightBlack = color
	case 9:
		t.BrightRed = color
	case 10:
		t.BrightGreen = color
	case 11:
		t.BrightYellow = color
	case 12:
		t.BrightBlue = color
	case 13:
		t.BrightMagenta = color
	case 14:
		t.BrightCyan = color
	case 15:
		t.BrightWhite = color
	}
}

// getPalette gets a palette color by index.
func (t *ThemeConfig) getPalette(idx int) string {
	switch idx {
	case 0:
		return t.Black
	case 1:
		return t.Red
	case 2:
		return t.Green
	case 3:
		return t.Yellow
	case 4:
		return t.Blue
	case 5:
		return t.Magenta
	case 6:
		return t.Cyan
	case 7:
		return t.White
	case 8:
		return t.BrightBlack
	case 9:
		return t.BrightRed
	case 10:
		return t.BrightGreen
	case 11:
		return t.BrightYellow
	case 12:
		return t.BrightBlue
	case 13:
		return t.BrightMagenta
	case 14:
		return t.BrightCyan
	case 15:
		return t.BrightWhite
	}
	return ""
}

// LoadGhosttyConfig loads the user's Ghostty config.
func LoadGhosttyConfig() (*TerminalConfig, error) {
	cfg := &TerminalConfig{}
	theme := &ThemeConfig{}
	var themeName string

	home := os.Getenv("HOME")
	if home == "" {
		return cfg, nil
	}

	found := false

	for _, path := range configSearchPaths(home, envSliceToMap(os.Environ())) {
		if err := parseConfigFile(path, cfg, theme, &themeName); err == nil {
			found = true
		}
	}

	// Resolve theme if specified
	if themeName != "" {
		resolvedThemeName := resolveThemeName(themeName, currentColorSchemePreference())
		if err := resolveTheme(home, resolvedThemeName, theme); err != nil {
			fmt.Fprintf(os.Stderr, "cmuxd: failed to resolve theme '%s': %v\n", themeName, err)
		}
	}

	if !theme.isEmpty() {
		cfg.Theme = theme
	}
	if !found && cfg.Theme == nil {
		return cfg, nil
	}
	return cfg, nil
}

func configSearchPaths(home string, env map[string]string) []string {
	var paths []string

	appendUnique := func(path string) {
		path = strings.TrimSpace(path)
		if path == "" {
			return
		}
		path = filepath.Clean(os.ExpandEnv(path))
		for _, existing := range paths {
			if existing == path {
				return
			}
		}
		paths = append(paths, path)
	}

	appendConfigPair := func(root string) {
		if root == "" {
			return
		}
		appendUnique(filepath.Join(root, "ghostty", "config"))
		appendUnique(filepath.Join(root, "ghostty", "config.ghostty"))
	}

	if xdg := env["XDG_CONFIG_HOME"]; xdg != "" {
		appendConfigPair(xdg)
	}
	appendConfigPair(filepath.Join(home, ".config"))

	macRoot := filepath.Join(home, "Library", "Application Support", "com.mitchellh.ghostty")
	appendUnique(filepath.Join(macRoot, "config"))
	appendUnique(filepath.Join(macRoot, "config.ghostty"))

	return paths
}

func parseConfigFile(path string, cfg *TerminalConfig, theme *ThemeConfig, themeName *string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	parseConfigContents(string(data), cfg, theme, themeName)
	return nil
}

func parseConfigContents(contents string, cfg *TerminalConfig, theme *ThemeConfig, themeName *string) {
	for _, line := range strings.Split(contents, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		eqIdx := strings.Index(line, "=")
		if eqIdx < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eqIdx])
		value := strings.TrimSpace(line[eqIdx+1:])
		if value == "" {
			continue
		}
		value = stripQuotes(value)

		switch key {
		case "font-family":
			cfg.FontFamily = value
		case "font-size":
			if v, err := strconv.ParseUint(value, 10, 16); err == nil {
				u := uint16(v)
				cfg.FontSize = &u
			}
		case "cursor-style":
			cfg.CursorStyle = value
		case "cursor-style-blink":
			b := value == "true"
			cfg.CursorBlink = &b
		case "scrollback-limit":
			if v, err := strconv.ParseUint(value, 10, 32); err == nil {
				u := uint32(v)
				cfg.Scrollback = &u
			}
		case "working-directory":
			cfg.WorkingDirectory = value
		case "shell-integration":
			cfg.ShellIntegration = value
		case "web-renderer":
			cfg.Renderer = value
		case "foreground":
			theme.Foreground = value
		case "background":
			theme.Background = value
		case "cursor-color":
			theme.Cursor = value
		case "cursor-text":
			theme.CursorAccent = value
		case "selection-background":
			theme.SelectionBackground = value
		case "selection-foreground":
			theme.SelectionForeground = value
		case "theme":
			if themeName != nil {
				*themeName = value
			}
		case "palette":
			// Format: "N=#rrggbb" or "N=rrggbb"
			sepIdx := strings.Index(value, "=")
			if sepIdx < 0 {
				continue
			}
			idxStr := strings.TrimSpace(value[:sepIdx])
			color := strings.TrimSpace(value[sepIdx+1:])
			idx, err := strconv.Atoi(idxStr)
			if err != nil || idx < 0 || idx >= 16 {
				continue
			}
			theme.setPalette(idx, color)
		}
	}
}

func resolveTheme(home, name string, theme *ThemeConfig) error {
	cwd, _ := os.Getwd()
	exePath, _ := os.Executable()
	exeDir := filepath.Dir(exePath)

	return resolveThemeFromPaths(
		name,
		theme,
		themeSearchPaths(home, name, cwd, exeDir, envSliceToMap(os.Environ())),
	)
}

func resolveThemeFromPaths(name string, theme *ThemeConfig, paths []string) error {
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		applyThemeUserWins(string(data), theme)
		return nil
	}

	return fmt.Errorf("theme not found: %s", name)
}

func resolveThemeName(rawThemeValue string, preferredColorScheme colorSchemePreference) string {
	var fallbackTheme string
	var lightTheme string
	var darkTheme string

	for _, token := range strings.Split(rawThemeValue, ",") {
		entry := strings.TrimSpace(token)
		if entry == "" {
			continue
		}

		parts := strings.SplitN(entry, ":", 2)
		if len(parts) != 2 {
			if fallbackTheme == "" {
				fallbackTheme = entry
			}
			continue
		}

		key := strings.ToLower(strings.TrimSpace(parts[0]))
		value := strings.TrimSpace(parts[1])
		if value == "" {
			continue
		}

		switch key {
		case string(colorSchemeLight):
			if lightTheme == "" {
				lightTheme = value
			}
		case string(colorSchemeDark):
			if darkTheme == "" {
				darkTheme = value
			}
		default:
			if fallbackTheme == "" {
				fallbackTheme = value
			}
		}
	}

	switch preferredColorScheme {
	case colorSchemeLight:
		if lightTheme != "" {
			return lightTheme
		}
	case colorSchemeDark:
		if darkTheme != "" {
			return darkTheme
		}
	}

	if fallbackTheme != "" {
		return fallbackTheme
	}
	if darkTheme != "" {
		return darkTheme
	}
	if lightTheme != "" {
		return lightTheme
	}
	return strings.TrimSpace(rawThemeValue)
}

func currentColorSchemePreference() colorSchemePreference {
	if override := strings.ToLower(strings.TrimSpace(os.Getenv("CMUX_COLOR_SCHEME"))); override == "light" {
		return colorSchemeLight
	} else if override == "dark" {
		return colorSchemeDark
	}

	if runtime.GOOS == "darwin" {
		out, err := exec.Command("defaults", "read", "-g", "AppleInterfaceStyle").Output()
		if err == nil && strings.Contains(strings.ToLower(string(out)), "dark") {
			return colorSchemeDark
		}
	}

	return colorSchemeLight
}

func themeNameCandidates(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}

	candidates := []string{raw}
	lower := strings.ToLower(raw)
	if strings.HasSuffix(lower, " (builtin)") {
		stripped := strings.TrimSpace(raw[:len(raw)-len(" (builtin)")])
		if stripped != "" && stripped != raw {
			candidates = append(candidates, stripped)
		}
	}
	return candidates
}

func themeSearchPaths(home, name, cwd, exeDir string, env map[string]string) []string {
	var paths []string

	appendUniquePath := func(path string) {
		path = strings.TrimSpace(path)
		if path == "" {
			return
		}
		expanded := filepath.Clean(os.ExpandEnv(path))
		for _, existing := range paths {
			if existing == expanded {
				return
			}
		}
		paths = append(paths, expanded)
	}

	appendThemePath := func(root, candidate string) {
		if root == "" || candidate == "" {
			return
		}
		appendUniquePath(filepath.Join(root, "themes", candidate))
	}

	for _, candidate := range themeNameCandidates(name) {
		appendThemePath(env["GHOSTTY_RESOURCES_DIR"], candidate)

		if xdgDataDirs := env["XDG_DATA_DIRS"]; xdgDataDirs != "" {
			for _, dataDir := range strings.Split(xdgDataDirs, ":") {
				dataDir = strings.TrimSpace(dataDir)
				if dataDir == "" {
					continue
				}
				appendUniquePath(filepath.Join(dataDir, "ghostty", "themes", candidate))
			}
		}

		if xdg := env["XDG_CONFIG_HOME"]; xdg != "" {
			appendUniquePath(filepath.Join(xdg, "ghostty", "themes", candidate))
		}

		appendUniquePath(filepath.Join(home, ".config", "ghostty", "themes", candidate))
		appendUniquePath(filepath.Join(home, "Library", "Application Support", "com.mitchellh.ghostty", "themes", candidate))
		appendUniquePath(filepath.Join(home, "Applications", "Ghostty.app", "Contents", "Resources", "ghostty", "themes", candidate))
		appendUniquePath(filepath.Join("/Applications", "Ghostty.app", "Contents", "Resources", "ghostty", "themes", candidate))

		if exeDir != "" {
			appendUniquePath(filepath.Join(exeDir, "..", "share", "ghostty", "themes", candidate))
			appendUniquePath(filepath.Join(exeDir, "..", "ghostty", "themes", candidate))
		}
		if cwd != "" {
			appendUniquePath(filepath.Join(cwd, "ghostty", "zig-out", "share", "ghostty", "themes", candidate))
			appendUniquePath(filepath.Join(cwd, "..", "ghostty", "zig-out", "share", "ghostty", "themes", candidate))
		}
	}

	return paths
}

// applyThemeUserWins applies theme values only where not already set by user config.
func applyThemeUserWins(contents string, theme *ThemeConfig) {
	for _, line := range strings.Split(contents, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eqIdx := strings.Index(line, "=")
		if eqIdx < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eqIdx])
		value := strings.TrimSpace(line[eqIdx+1:])
		if value == "" {
			continue
		}
		value = stripQuotes(value)

		// Only set if not already set (user wins)
		switch key {
		case "foreground":
			if theme.Foreground == "" {
				theme.Foreground = value
			}
		case "background":
			if theme.Background == "" {
				theme.Background = value
			}
		case "cursor-color":
			if theme.Cursor == "" {
				theme.Cursor = value
			}
		case "cursor-text":
			if theme.CursorAccent == "" {
				theme.CursorAccent = value
			}
		case "selection-background":
			if theme.SelectionBackground == "" {
				theme.SelectionBackground = value
			}
		case "selection-foreground":
			if theme.SelectionForeground == "" {
				theme.SelectionForeground = value
			}
		case "palette":
			sepIdx := strings.Index(value, "=")
			if sepIdx < 0 {
				continue
			}
			idxStr := strings.TrimSpace(value[:sepIdx])
			color := strings.TrimSpace(value[sepIdx+1:])
			idx, err := strconv.Atoi(idxStr)
			if err != nil || idx < 0 || idx >= 16 {
				continue
			}
			if theme.getPalette(idx) == "" {
				theme.setPalette(idx, color)
			}
		}
	}
}

func stripQuotes(s string) string {
	if len(s) >= 2 {
		if (s[0] == '"' && s[len(s)-1] == '"') || (s[0] == '\'' && s[len(s)-1] == '\'') {
			return s[1 : len(s)-1]
		}
	}
	return s
}

// SerializeConfig converts TerminalConfig to JSON bytes.
func SerializeConfig(cfg *TerminalConfig) ([]byte, error) {
	return json.Marshal(cfg)
}
