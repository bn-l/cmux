package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
)

const defaultPort = 3778

func main() {
	port := defaultPort

	// Parse --port flag
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		if args[i] == "--port" && i+1 < len(args) {
			if p, err := strconv.Atoi(args[i+1]); err == nil {
				port = p
			}
			i++
		}
	}

	// Load Ghostty config
	cfg, err := LoadGhosttyConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmuxd: failed to load ghostty config: %v\n", err)
	}
	srv := NewServer(cfg)
	if cfg != nil {
		if data, err := json.Marshal(cfg); err == nil && string(data) != "{}" {
			srv.terminalConfig = data
			fmt.Fprintf(os.Stderr, "cmuxd: loaded ghostty config (%d bytes)\n", len(data))
		}
	}

	// Handle signals for clean shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Fprintf(os.Stderr, "\ncmuxd: shutting down\n")
		srv.sessions.DestroyAll()
		os.Exit(0)
	}()

	// HTTP handler
	http.HandleFunc("/terminal-config", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if len(srv.terminalConfig) == 0 {
			_, _ = w.Write([]byte("{}"))
			return
		}
		_, _ = w.Write(srv.terminalConfig)
	})
	http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.RawQuery, "mode=mux") {
			HandleMux(srv, w, r)
		} else {
			HandleLegacy(w, r)
		}
	})

	addr := fmt.Sprintf(":%d", port)
	fmt.Fprintf(os.Stderr, "cmuxd listening on %s\n", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		fmt.Fprintf(os.Stderr, "cmuxd: %v\n", err)
		os.Exit(1)
	}
}
