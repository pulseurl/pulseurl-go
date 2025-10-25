package client

import (
	"log/slog"
	"os"
	"time"
)

// Options configures the PulseURL client
type Options struct {
	// ServiceURL is the gRPC endpoint (e.g., "pulseurl:9090")
	ServiceURL string

	// Logger for client operations. If nil, uses slog.Default()
	Logger *slog.Logger

	// BufferSize is the channel buffer size for async events
	// Default: 1000
	BufferSize int

	// FlushInterval is how often to flush buffered events
	// Default: 1s
	FlushInterval time.Duration

	// Timeout for gRPC calls
	// Default: 2s
	Timeout time.Duration

	// SampleRate determines what percentage of events to send (0.0 to 1.0)
	// Default: 1.0 (send all events)
	SampleRate float64

	// MaxRetries for failed requests
	// Default: 2
	MaxRetries int

	// DebugLogging enables verbose debug output for troubleshooting.
	// If true and Logger is nil, a debug-level logger will be created automatically.
	// Default: false
	DebugLogging bool
}

// DefaultOptions returns options with sensible defaults
func DefaultOptions() *Options {
	return &Options{
		ServiceURL:    "localhost:9090",
		Logger:        slog.Default(),
		BufferSize:    1000,
		FlushInterval: 1 * time.Second,
		Timeout:       2 * time.Second,
		SampleRate:    1.0,
		MaxRetries:    2,
		DebugLogging:  false,
	}
}

// applyDefaults fills in any missing options with defaults
func (o *Options) applyDefaults() {
	if o.Logger == nil {
		level := slog.LevelInfo
		if o.DebugLogging {
			level = slog.LevelDebug
		}
		o.Logger = slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
			Level: level,
		}))
	}
	if o.BufferSize == 0 {
		o.BufferSize = 1000
	}
	if o.FlushInterval == 0 {
		o.FlushInterval = 1 * time.Second
	}
	if o.Timeout == 0 {
		o.Timeout = 2 * time.Second
	}
	if o.SampleRate == 0 {
		o.SampleRate = 1.0
	}
	if o.MaxRetries == 0 {
		o.MaxRetries = 2
	}
}
