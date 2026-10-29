package api

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/arnozeng98/subflow/internal/settings"
)

type Handler struct {
	config settings.Config
	logger *slog.Logger
}

func NewHandler(config settings.Config, logger *slog.Logger) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return &Handler{config: config, logger: logger}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	expected := sha256.Sum256([]byte("Bearer " + h.config.APIToken))
	actual := sha256.Sum256([]byte(r.Header.Get("Authorization")))
	if h.config.APIToken == "" || subtle.ConstantTimeCompare(expected[:], actual[:]) != 1 {
		writeText(w, http.StatusForbidden, "forbidden")
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeText(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if r.URL.Path == "/healthz" {
		writeText(w, http.StatusOK, "ok")
		return
	}
	const prefix = "/internal/raw/"
	if !strings.HasPrefix(r.URL.Path, prefix) {
		writeText(w, http.StatusNotFound, "not found")
		return
	}
	username, valid := NormalizeUsername(strings.TrimPrefix(r.URL.Path, prefix))
	if !valid {
		writeText(w, http.StatusNotFound, "not found")
		return
	}
	payload, err := BuildPayload(r.Context(), h.config, username)
	if errors.Is(err, ErrNotFound) {
		writeText(w, http.StatusNotFound, "not found")
		return
	}
	if err != nil {
		h.logger.ErrorContext(r.Context(), "read subscription state", "error", err)
		writeText(w, http.StatusServiceUnavailable, "upstream state unavailable")
		return
	}
	body, err := json.Marshal(payload)
	if err != nil {
		h.logger.ErrorContext(r.Context(), "encode subscription", "error", err)
		writeText(w, http.StatusInternalServerError, "internal error")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if _, err := w.Write(body); err != nil {
		h.logger.WarnContext(r.Context(), "write subscription response", "error", err)
	}
}

func writeText(w http.ResponseWriter, status int, text string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	// There is no recovery after the peer has disconnected.
	_, _ = w.Write([]byte(text))
}

func Serve(ctx context.Context, config settings.Config, logger *slog.Logger) error {
	if strings.TrimSpace(config.APIToken) == "" {
		return errors.New("SUBFLOW_API_TOKEN is required; refusing to start an unusable API")
	}
	listener, err := net.Listen("tcp", config.Address())
	if err != nil {
		return fmt.Errorf("listen for data API: %w", err)
	}
	return ServeListener(ctx, listener, config, logger)
}

func ServeListener(ctx context.Context, listener net.Listener, config settings.Config, logger *slog.Logger) error {
	if logger == nil {
		logger = slog.Default()
	}
	server := &http.Server{
		Handler:           NewHandler(config, logger),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    32 * 1024,
		BaseContext:       func(net.Listener) context.Context { return ctx },
	}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	logger.Info("data API started", "address", listener.Addr().String())
	select {
	case err := <-done:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			return errors.Join(err, server.Close())
		}
		if err := <-done; err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}
