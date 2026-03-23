package compat

import (
	"testing"
)

func TestHelloFixtureAgainstUnixSocketBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	client := newUnixJSONRPCClient(t, socketPath)
	resp := client.Call(t, map[string]any{
		"id":     "1",
		"method": "hello",
		"params": map[string]any{},
	})

	if ok, _ := resp["ok"].(bool); !ok {
		t.Fatalf("hello should succeed: %+v", resp)
	}
}

func TestTerminalEchoFixtureAgainstUnixSocketBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)
	client := newUnixJSONRPCClient(t, socketPath)

	open := client.Call(t, map[string]any{
		"id": "1",
		"method": "terminal.open",
		"params": map[string]any{
			"session_id": "dev",
			"command":    "cat",
			"cols":       80,
			"rows":       24,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}

	write := client.Call(t, map[string]any{
		"id": "2",
		"method": "terminal.write",
		"params": map[string]any{
			"session_id": "dev",
			"data":       "aGVsbG8K",
		},
	})
	if ok, _ := write["ok"].(bool); !ok {
		t.Fatalf("terminal.write should succeed: %+v", write)
	}
}
