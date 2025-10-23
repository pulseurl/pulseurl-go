package client

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand"
	"sync"
	"time"

	"github.com/pulseurl/pulseurl-go/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Client is a gRPC client for the PulseURL service with async buffering
type Client struct {
	opts       *Options
	conn       *grpc.ClientConn
	grpcClient proto.TrafficLoggerClient
	eventChan  chan *proto.TrafficEvent
	stopChan   chan struct{}
	wg         sync.WaitGroup
	logger     *slog.Logger
}

// New creates a new PulseURL client
func New(serviceURL string, opts ...*Options) (*Client, error) {
	var options *Options
	if len(opts) > 0 {
		options = opts[0]
	} else {
		options = DefaultOptions()
	}

	// Override serviceURL if provided
	if serviceURL != "" {
		options.ServiceURL = serviceURL
	}

	options.applyDefaults()

	// Create gRPC connection
	conn, err := grpc.NewClient(
		options.ServiceURL,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to PulseURL service at %s: %w", options.ServiceURL, err)
	}

	client := &Client{
		opts:       options,
		conn:       conn,
		grpcClient: proto.NewTrafficLoggerClient(conn),
		eventChan:  make(chan *proto.TrafficEvent, options.BufferSize),
		stopChan:   make(chan struct{}),
		logger:     options.Logger,
	}

	// Start background worker
	client.wg.Add(1)
	go client.worker()

	client.logger.Info("PulseURL client connected", "service_url", options.ServiceURL)

	return client, nil
}

// LogEvent queues a traffic event for async processing (non-blocking)
func (c *Client) LogEvent(event *proto.TrafficEvent) {
	// Apply sampling
	if c.opts.SampleRate < 1.0 && rand.Float64() > c.opts.SampleRate {
		return
	}

	// Non-blocking send
	select {
	case c.eventChan <- event:
		// Event queued successfully
	default:
		// Buffer full, drop event
		c.logger.Warn("event buffer full, dropping event")
	}
}

// LogEventSync logs an event synchronously (blocking)
func (c *Client) LogEventSync(ctx context.Context, event *proto.TrafficEvent) error {
	// Apply sampling
	if c.opts.SampleRate < 1.0 && rand.Float64() > c.opts.SampleRate {
		return nil
	}

	return c.sendEvent(ctx, event)
}

// worker processes events from the buffer
func (c *Client) worker() {
	defer c.wg.Done()

	ticker := time.NewTicker(c.opts.FlushInterval)
	defer ticker.Stop()

	for {
		select {
		case event := <-c.eventChan:
			ctx, cancel := context.WithTimeout(context.Background(), c.opts.Timeout)
			if err := c.sendEvent(ctx, event); err != nil {
				c.logger.Error("failed to send event", "error", err)
			}
			cancel()

		case <-ticker.C:
			// Flush any remaining events
			c.flushEvents()

		case <-c.stopChan:
			// Drain remaining events
			c.flushEvents()
			return
		}
	}
}

// flushEvents drains all pending events from the buffer
func (c *Client) flushEvents() {
	for {
		select {
		case event := <-c.eventChan:
			ctx, cancel := context.WithTimeout(context.Background(), c.opts.Timeout)
			if err := c.sendEvent(ctx, event); err != nil {
				c.logger.Error("failed to send event during flush", "error", err)
			}
			cancel()
		default:
			return
		}
	}
}

// sendEvent sends a single event to the gRPC service with retry
func (c *Client) sendEvent(ctx context.Context, event *proto.TrafficEvent) error {
	var lastErr error

	for attempt := 0; attempt <= c.opts.MaxRetries; attempt++ {
		if attempt > 0 {
			// Exponential backoff
			backoff := time.Duration(attempt) * 100 * time.Millisecond
			time.Sleep(backoff)
		}

		_, err := c.grpcClient.LogEvent(ctx, event)
		if err == nil {
			return nil
		}

		lastErr = err
		c.logger.Debug("retry sending event", "attempt", attempt+1, "error", err)
	}

	return fmt.Errorf("failed after %d retries: %w", c.opts.MaxRetries, lastErr)
}

// Close gracefully shuts down the client
func (c *Client) Close() error {
	c.logger.Info("shutting down PulseURL client")

	// Signal worker to stop
	close(c.stopChan)

	// Wait for worker to finish
	c.wg.Wait()

	// Close gRPC connection
	if err := c.conn.Close(); err != nil {
		return fmt.Errorf("failed to close gRPC connection: %w", err)
	}

	c.logger.Info("PulseURL client closed")
	return nil
}

// Event is a convenience struct for building TrafficEvent protobuf messages
type Event struct {
	Timestamp    time.Time
	Service      string
	PodID        string
	Namespace    string
	URL          string
	Route        string
	Method       string
	StatusCode   int32
	DurationMs   int32
	ClientIP     string
	UserAgent    string
	CustomLabels map[string]string
}

// ToProto converts Event to proto.TrafficEvent
func (e *Event) ToProto() *proto.TrafficEvent {
	return &proto.TrafficEvent{
		Timestamp:    timestamppb.New(e.Timestamp),
		Service:      e.Service,
		PodId:        e.PodID,
		Namespace:    e.Namespace,
		Url:          e.URL,
		Route:        e.Route,
		HttpMethod:   e.Method,
		StatusCode:   e.StatusCode,
		DurationMs:   e.DurationMs,
		ClientIp:     e.ClientIP,
		UserAgent:    e.UserAgent,
		CustomLabels: e.CustomLabels,
	}
}
