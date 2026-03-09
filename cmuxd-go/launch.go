package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type launchPaths struct {
	ghosttyResourcesDir string
	cmuxIntegrationDir  string
}

func envSliceToMap(env []string) map[string]string {
	out := make(map[string]string, len(env))
	for _, kv := range env {
		if kv == "" {
			continue
		}
		key, value, ok := strings.Cut(kv, "=")
		if !ok || key == "" {
			continue
		}
		out[key] = value
	}
	return out
}

func envMapToSlice(env map[string]string) []string {
	keys := make([]string, 0, len(env))
	for key := range env {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	out := make([]string, 0, len(keys))
	for _, key := range keys {
		out = append(out, key+"="+env[key])
	}
	return out
}

func pathExists(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func existingFirst(paths ...string) string {
	for _, path := range paths {
		if pathExists(path) {
			return path
		}
	}
	return ""
}

func resolveLaunchPaths(cwd string, baseEnv map[string]string) launchPaths {
	exePath, _ := os.Executable()
	exeDir := filepath.Dir(exePath)
	home := baseEnv["HOME"]

	ghosttyResourcesDir := baseEnv["GHOSTTY_RESOURCES_DIR"]
	if !pathExists(ghosttyResourcesDir) {
		ghosttyResourcesDir = existingFirst(
			filepath.Join(cwd, "..", "ghostty", "zig-out", "share", "ghostty"),
			filepath.Join(cwd, "ghostty", "zig-out", "share", "ghostty"),
			filepath.Join(cwd, "..", "ghostty", "src"),
			filepath.Join(cwd, "ghostty", "src"),
			filepath.Join(exeDir, "..", "share", "ghostty"),
			filepath.Join(exeDir, "..", "ghostty"),
			"/Applications/Ghostty.app/Contents/Resources/ghostty",
			filepath.Join(home, "Applications", "Ghostty.app", "Contents", "Resources", "ghostty"),
		)
	}

	cmuxIntegrationDir := baseEnv["CMUX_SHELL_INTEGRATION_DIR"]
	if !pathExists(cmuxIntegrationDir) {
		cmuxIntegrationDir = existingFirst(
			filepath.Join(cwd, "..", "Resources", "shell-integration"),
			filepath.Join(cwd, "Resources", "shell-integration"),
			filepath.Join(exeDir, "..", "Resources", "shell-integration"),
			filepath.Join(exeDir, "shell-integration"),
		)
	}

	return launchPaths{
		ghosttyResourcesDir: ghosttyResourcesDir,
		cmuxIntegrationDir:  cmuxIntegrationDir,
	}
}

func appendEnvPathIfMissing(env map[string]string, key, path, defaultValue string) {
	if path == "" {
		return
	}
	current := env[key]
	if current == "" {
		current = defaultValue
	}
	for _, part := range strings.Split(current, ":") {
		if part == path {
			env[key] = current
			return
		}
	}
	if current == "" {
		env[key] = path
		return
	}
	env[key] = current + ":" + path
}

func shellIntegrationEnabled(cfg *TerminalConfig) bool {
	if cfg == nil {
		return true
	}
	return !strings.EqualFold(strings.TrimSpace(cfg.ShellIntegration), "none")
}

func configureShellLaunchEnv(env map[string]string, cfg *TerminalConfig, paths launchPaths) {
	env["TERM"] = "xterm-ghostty"
	env["TERM_PROGRAM"] = "ghostty"

	if paths.ghosttyResourcesDir != "" {
		env["GHOSTTY_RESOURCES_DIR"] = paths.ghosttyResourcesDir
		parent := filepath.Dir(paths.ghosttyResourcesDir)
		appendEnvPathIfMissing(env, "XDG_DATA_DIRS", parent, "/usr/local/share:/usr/share")
		appendEnvPathIfMissing(env, "MANPATH", filepath.Join(parent, "man"), "")
	}

	if paths.cmuxIntegrationDir == "" {
		return
	}

	env["CMUX_SHELL_INTEGRATION"] = "1"
	env["CMUX_SHELL_INTEGRATION_DIR"] = paths.cmuxIntegrationDir

	shellPath := env["SHELL"]
	if shellPath == "" {
		shellPath = "/bin/zsh"
	}
	if filepath.Base(shellPath) != "zsh" {
		return
	}

	originalZdotdir := env["ZDOTDIR"]
	if shellIntegrationEnabled(cfg) {
		restoreZdotdir := originalZdotdir
		if restoreZdotdir == "" {
			restoreZdotdir = env["HOME"]
		}
		if restoreZdotdir != "" {
			env["GHOSTTY_ZSH_ZDOTDIR"] = restoreZdotdir
		}
		delete(env, "CMUX_ZSH_ZDOTDIR")
	} else if originalZdotdir != "" {
		env["CMUX_ZSH_ZDOTDIR"] = originalZdotdir
		delete(env, "GHOSTTY_ZSH_ZDOTDIR")
	} else {
		delete(env, "CMUX_ZSH_ZDOTDIR")
		delete(env, "GHOSTTY_ZSH_ZDOTDIR")
	}

	env["ZDOTDIR"] = paths.cmuxIntegrationDir
}

func resolveSessionWorkingDirectory(cfg *TerminalConfig, env map[string]string, processCwd string) string {
	if cwd := strings.TrimSpace(env["PTY_CWD"]); cwd != "" {
		return expandWorkingDirectory(cwd, env["HOME"], processCwd)
	}

	if cfg != nil {
		switch wd := strings.TrimSpace(cfg.WorkingDirectory); wd {
		case "":
		case "inherit":
			if processCwd != "" {
				return processCwd
			}
		case "home":
			if home := strings.TrimSpace(env["HOME"]); home != "" {
				return home
			}
		default:
			return expandWorkingDirectory(wd, env["HOME"], processCwd)
		}
	}

	if processCwd != "" {
		return processCwd
	}
	return env["HOME"]
}

func expandWorkingDirectory(wd, home, processCwd string) string {
	if wd == "" {
		return ""
	}
	switch wd {
	case "home":
		return home
	case "inherit":
		return processCwd
	}
	if wd == "~" {
		return home
	}
	if strings.HasPrefix(wd, "~/") && home != "" {
		return filepath.Join(home, wd[2:])
	}
	return wd
}

func buildSessionLaunch(cfg *TerminalConfig, cwd string, baseEnv []string) (string, []string) {
	env := envSliceToMap(baseEnv)
	paths := resolveLaunchPaths(cwd, env)
	configureShellLaunchEnv(env, cfg, paths)
	return resolveSessionWorkingDirectory(cfg, env, cwd), envMapToSlice(env)
}
