package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"sync"

	"github.com/coder/websocket"
)

// HandleLegacy handles a legacy mode WebSocket connection (one PTY per WS).
func HandleLegacy(w http.ResponseWriter, r *http.Request) {
	cols := parseQueryUint16(r, "cols", 80)
	rows := parseQueryUint16(r, "rows", 24)

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
	})
	if err != nil {
		return
	}

	// Use a context independent of the request so the reader goroutine
	// can finish cleanly even after the handler returns.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sess, err := SpawnSession(0, cols, rows, nil)
	if err != nil {
		conn.Close(websocket.StatusInternalError, "failed to spawn PTY")
		conn.CloseNow()
		return
	}

	// Protect conn writes from concurrent access between reader goroutine
	// and the deferred close.
	var writeMu sync.Mutex
	var readerDone sync.WaitGroup
	readerDone.Add(1)

	// PTY reader goroutine: reads from PTY, sends binary frames to client
	go func() {
		defer readerDone.Done()
		buf := make([]byte, 8192)
		for sess.alive.Load() {
			n, err := sess.ptmx.Read(buf)
			if err != nil || n == 0 {
				break
			}
			writeMu.Lock()
			conn.Write(ctx, websocket.MessageBinary, buf[:n])
			writeMu.Unlock()
		}
	}()

	// WS read loop: reads from client, writes to PTY
	for {
		msgType, data, err := conn.Read(ctx)
		if err != nil {
			break
		}
		switch msgType {
		case websocket.MessageText:
			// Check for resize JSON message
			if len(data) > 0 && data[0] == '{' {
				var msg LegacyResizeMsg
				if json.Unmarshal(data, &msg) == nil && msg.Type == "resize" {
					sess.Resize(msg.Cols, msg.Rows)
					continue
				}
			}
			// Otherwise treat as input
			sess.WriteInput(data)
		case websocket.MessageBinary:
			sess.WriteInput(data)
		}
	}

	// Clean shutdown: kill PTY first so reader goroutine exits, then close WS.
	sess.Kill()
	readerDone.Wait()
	conn.Close(websocket.StatusNormalClosure, "")
	conn.CloseNow()
}

func parseQueryUint16(r *http.Request, key string, defaultVal uint16) uint16 {
	s := r.URL.Query().Get(key)
	if s == "" {
		return defaultVal
	}
	v, err := strconv.ParseUint(s, 10, 16)
	if err != nil {
		return defaultVal
	}
	return uint16(v)
}
