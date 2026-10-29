package nodehost

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/arnozeng98/subflow/internal/state"
)

// QueryStats speaks the V2Ray QueryStats protobuf RPC over native HTTP/2.
// reset=false is essential: retries must not destroy uncommitted counters.
func QueryStats(ctx context.Context, address string) ([]Stat, error) {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return nil, errors.New("invalid stats address")
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return nil, errors.New("stats endpoint must be loopback")
	}
	protocols := new(http.Protocols)
	protocols.SetUnencryptedHTTP2(true)
	transport := &http.Transport{Protocols: protocols}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 8 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	message := append([]byte{0x0a, 7}, []byte("user>>>")...)
	frame := make([]byte, 5, len(message)+5)
	binary.BigEndian.PutUint32(frame[1:], uint32(len(message)))
	frame = append(frame, message...)
	req, err := http.NewRequestWithContext(ctx, "POST", "http://"+address+"/v2ray.core.app.stats.command.StatsService/QueryStats", bytes.NewReader(frame))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/grpc")
	req.Header.Set("TE", "trailers")
	resp, err := client.Do(req)
	if err != nil {
		return nil, errors.New("stats RPC connection failed")
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, errors.New("stats RPC read failed")
	}
	status := resp.Trailer.Get("Grpc-Status")
	if status == "" {
		status = resp.Header.Get("Grpc-Status")
	}
	if resp.StatusCode != 200 || resp.ProtoMajor != 2 || status != "0" {
		return nil, errors.New("stats RPC returned failure or missing status")
	}
	if len(body) < 5 || body[0] != 0 || int(binary.BigEndian.Uint32(body[1:5])) != len(body)-5 {
		return nil, errors.New("invalid stats gRPC frame")
	}
	return decodeStats(body[5:])
}

func wire(b []byte) (field int, value []byte, integer uint64, rest []byte, err error) {
	tag, n := binary.Uvarint(b)
	if n <= 0 {
		return 0, nil, 0, nil, errors.New("invalid protobuf tag")
	}
	b = b[n:]
	field = int(tag >> 3)
	switch tag & 7 {
	case 0:
		v, n := binary.Uvarint(b)
		if n <= 0 {
			return 0, nil, 0, nil, errors.New("invalid protobuf integer")
		}
		return field, nil, v, b[n:], nil
	case 2:
		l, n := binary.Uvarint(b)
		if n <= 0 || l > uint64(len(b)-n) {
			return 0, nil, 0, nil, errors.New("invalid protobuf string")
		}
		return field, b[n : n+int(l)], 0, b[n+int(l):], nil
	case 1:
		if len(b) < 8 {
			return 0, nil, 0, nil, io.ErrUnexpectedEOF
		}
		return field, nil, 0, b[8:], nil
	case 5:
		if len(b) < 4 {
			return 0, nil, 0, nil, io.ErrUnexpectedEOF
		}
		return field, nil, 0, b[4:], nil
	default:
		return 0, nil, 0, nil, errors.New("unsupported protobuf wire type")
	}
}

func decodeStats(data []byte) ([]Stat, error) {
	stats := []Stat{}
	for len(data) > 0 {
		field, b, _, rest, err := wire(data)
		if err != nil {
			return nil, err
		}
		data = rest
		if field != 1 {
			continue
		}
		var s Stat
		for len(b) > 0 {
			f, v, i, r, e := wire(b)
			if e != nil {
				return nil, e
			}
			b = r
			switch f {
			case 1:
				s.Name = string(v)
			case 2:
				if i > uint64(maxSafe) {
					return nil, errors.New("invalid counter")
				}
				s.Value = int64(i)
			}
		}
		if s.Name == "" {
			return nil, errors.New("unnamed counter")
		}
		stats = append(stats, s)
	}
	return stats, nil
}

func (h *host) hasOrdinary() bool {
	for name, u := range h.db.Users {
		if name != "admin" && len(u.Credentials) > 0 {
			return true
		}
	}
	return false
}

func (h *host) sample(ctx context.Context) error {
	if !h.hasOrdinary() || h.db.RuntimeStopped {
		return nil
	}
	stats, err := h.readStats(ctx)
	if err != nil {
		h.db.StatsBlocked = true
		quarantine(&h.db, nil)
		fmt.Fprintln(h.errOut, "ERROR: traffic accounting unavailable; stopping ordinary-user access")
		// Stop first: even if disk is full, no unmetered service is left running.
		stopErr := h.command(ctx, "stop")
		if stopErr == nil {
			h.db.RuntimeStopped = true
		}
		return errors.Join(errors.New("traffic statistics failed (fail closed)"), stopErr, state.WriteJSON(h.opts.Config.UserDBPath, h.db))
	}
	if raw, e := h.execute(ctx, "systemctl", "show", "sing-box.service", "--property=MainPID", "--value"); e == nil {
		id := strings.TrimSpace(string(raw))
		if pid, e := strconv.ParseInt(id, 10, 64); e == nil && pid > 0 {
			if h.db.RuntimeID != "" && h.db.RuntimeID != id {
				h.db.Counters = map[string]int64{}
				quarantine(&h.db, nil)
				fmt.Fprintln(h.errOut, "ERROR: unexpected runtime restart; current ordinary periods quarantined")
			}
			h.db.RuntimeID = id
		}
	}
	seen := map[string]bool{}
	owners := h.credentialOwners()
	for _, s := range stats {
		if s.Value < 0 || s.Value > maxSafe || seen[s.Name] {
			return h.statsInvalid(ctx)
		}
		seen[s.Name] = true
		if !strings.HasPrefix(s.Name, "user>>>") {
			continue
		}
		rest := strings.TrimPrefix(s.Name, "user>>>")
		index := strings.LastIndex(rest, ">>>traffic>>>")
		if index < 0 {
			continue
		}
		identity, direction := rest[:index], rest[index+len(">>>traffic>>>"):]
		name, ok := owners[identity]
		if !ok || name == "admin" {
			continue
		}
		u := h.db.Users[name]
		if u == nil {
			continue
		}
		if direction != "uplink" && direction != "downlink" {
			return h.statsInvalid(ctx)
		}
		last := h.db.Counters[s.Name]
		delta := s.Value - last
		if delta < 0 {
			delta = s.Value
		}
		if direction == "uplink" {
			u.Up = sum(u.Up, delta)
		} else {
			u.Down = sum(u.Down, delta)
		}
		h.db.Counters[s.Name] = s.Value
	}
	h.db.StatsBlocked = false
	h.db.ProbeRequired = false
	if err := state.WriteJSON(h.opts.Config.UserDBPath, h.db); err != nil {
		fmt.Fprintln(h.errOut, "ERROR: accounting persistence failed; stopping service")
		return errors.Join(err, h.command(ctx, "stop"))
	}
	return nil
}

func (h *host) statsInvalid(ctx context.Context) error {
	h.db.StatsBlocked = true
	quarantine(&h.db, nil)
	fmt.Fprintln(h.errOut, "ERROR: invalid traffic counters; stopping service fail closed")
	err := h.command(ctx, "stop")
	if err == nil {
		h.db.RuntimeStopped = true
	}
	return errors.Join(errors.New("invalid traffic statistics"), err, state.WriteJSON(h.opts.Config.UserDBPath, h.db))
}

func (h *host) readStats(ctx context.Context) ([]Stat, error) {
	if !h.db.ProbeRequired {
		return h.opts.Stats(ctx, "127.0.0.1:10085")
	}
	probeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	for {
		stats, err := h.opts.Stats(probeCtx, "127.0.0.1:10085")
		if err == nil {
			return stats, nil
		}
		select {
		case <-probeCtx.Done():
			return nil, errors.New("restricted runtime statistics probe failed")
		case <-time.After(100 * time.Millisecond):
		}
	}
}
