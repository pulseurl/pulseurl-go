package middleware

import (
	"log/slog"
	"os"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/pulseurl/pulseurl-go/client"
	"github.com/pulseurl/pulseurl-go/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Config configures the PulseURL middleware
type Config struct {
	// Client is the PulseURL gRPC client (required)
	Client *client.Client

	// Logger for middleware operations. If nil, uses slog.Default()
	Logger *slog.Logger

	// SkipPaths is a list of paths to skip logging (e.g., /health, /metrics)
	SkipPaths []string

	// CustomLabels are labels attached to all events
	CustomLabels map[string]string

	// ServiceName identifies this service (defaults to hostname)
	ServiceName string

	// Namespace identifies the deployment namespace (e.g., "production", "staging")
	Namespace string
}

// New creates a new Gin middleware for PulseURL traffic tracking
func New(config Config) gin.HandlerFunc {
	logger := config.Logger
	if logger == nil {
		logger = slog.Default()
	}

	// Set default service name to hostname if not provided
	serviceName := config.ServiceName
	if serviceName == "" {
		if hostname, err := os.Hostname(); err == nil {
			serviceName = hostname
		} else {
			serviceName = "unknown"
		}
	}

	// Create skip path lookup map for O(1) lookup
	skipPathMap := make(map[string]bool)
	for _, path := range config.SkipPaths {
		skipPathMap[path] = true
	}

	return func(c *gin.Context) {
		// Skip certain paths
		path := c.Request.URL.Path
		if skipPathMap[path] {
			c.Next()
			return
		}

		// Record start time
		start := time.Now()

		// Process request
		c.Next()

		// Calculate duration
		duration := time.Since(start)

		// Build traffic event
		event := &proto.TrafficEvent{
			Timestamp:    timestamppb.New(start),
			PodId:        serviceName,
			Namespace:    config.Namespace,
			Url:          path,
			Route:        c.FullPath(), // Gin route pattern (e.g., /users/:id)
			HttpMethod:   c.Request.Method,
			StatusCode:   int32(c.Writer.Status()),
			DurationMs:   int32(duration.Milliseconds()),
			ClientIp:     c.ClientIP(),
			UserAgent:    c.Request.UserAgent(),
			CustomLabels: config.CustomLabels,
		}

		// Log event asynchronously (fire-and-forget)
		config.Client.LogEvent(event)
	}
}

// NewWithClient is a convenience function that creates middleware with just a client
func NewWithClient(client *client.Client) gin.HandlerFunc {
	return New(Config{
		Client: client,
	})
}
