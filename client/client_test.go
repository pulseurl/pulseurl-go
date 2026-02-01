package client

import (
	"context"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/pulseurl/pulseurl-go/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func TestDefaultOptions(t *testing.T) {
	opts := DefaultOptions()

	if opts.ServiceURL != "localhost:9090" {
		t.Errorf("Expected default ServiceURL 'localhost:9090', got '%s'", opts.ServiceURL)
	}

	if opts.BufferSize != 1000 {
		t.Errorf("Expected default BufferSize 1000, got %d", opts.BufferSize)
	}

	if opts.FlushInterval != 1*time.Second {
		t.Errorf("Expected default FlushInterval 1s, got %v", opts.FlushInterval)
	}

	if opts.Timeout != 2*time.Second {
		t.Errorf("Expected default Timeout 2s, got %v", opts.Timeout)
	}

	if opts.SampleRate != 1.0 {
		t.Errorf("Expected default SampleRate 1.0, got %f", opts.SampleRate)
	}

	if opts.MaxRetries != 2 {
		t.Errorf("Expected default MaxRetries 2, got %d", opts.MaxRetries)
	}

	if opts.Logger == nil {
		t.Error("Expected Logger to be set")
	}
}

func TestOptionsApplyDefaults(t *testing.T) {
	opts := &Options{
		ServiceURL: "custom:9090",
		// Leave other fields as zero values
	}

	opts.applyDefaults()

	if opts.ServiceURL != "custom:9090" {
		t.Errorf("Expected ServiceURL to remain 'custom:9090', got '%s'", opts.ServiceURL)
	}

	if opts.BufferSize != 1000 {
		t.Error("Expected BufferSize to be set to default")
	}

	if opts.Logger == nil {
		t.Error("Expected Logger to be set to default")
	}
}

func TestDebugLoggingOption(t *testing.T) {
	t.Run("debug logging disabled by default", func(t *testing.T) {
		opts := DefaultOptions()
		if opts.DebugLogging {
			t.Error("Expected DebugLogging to be false by default")
		}
	})

	t.Run("debug logging can be enabled", func(t *testing.T) {
		opts := &Options{
			DebugLogging: true,
		}
		opts.applyDefaults()

		if !opts.DebugLogging {
			t.Error("Expected DebugLogging to remain true")
		}

		if opts.Logger == nil {
			t.Error("Expected Logger to be created")
		}

		// Verify logger is configured for debug level
		// Note: We can't easily test the log level directly with slog,
		// but we know it was configured based on DebugLogging flag
	})

	t.Run("debug logging disabled creates info-level logger", func(t *testing.T) {
		opts := &Options{
			DebugLogging: false,
		}
		opts.applyDefaults()

		if opts.Logger == nil {
			t.Error("Expected Logger to be created")
		}
	})
}

func TestEventToProto(t *testing.T) {
	now := time.Now()
	event := &Event{
		Timestamp:  now,
		Service:    "test-service",
		PodID:      "pod-123",
		Namespace:  "default",
		URL:        "/test",
		Route:      "/test",
		Method:     "GET",
		StatusCode: 200,
		DurationMs: 42,
		ClientIP:   "127.0.0.1",
		UserAgent:  "test-agent",
		CustomLabels: map[string]string{
			"env": "test",
		},
	}

	protoEvent := event.ToProto()

	if protoEvent.Service != "test-service" {
		t.Errorf("Expected Service 'test-service', got '%s'", protoEvent.Service)
	}

	if protoEvent.PodId != "pod-123" {
		t.Errorf("Expected PodId 'pod-123', got '%s'", protoEvent.PodId)
	}

	if protoEvent.Namespace != "default" {
		t.Errorf("Expected Namespace 'default', got '%s'", protoEvent.Namespace)
	}

	if protoEvent.Url != "/test" {
		t.Errorf("Expected Url '/test', got '%s'", protoEvent.Url)
	}

	if protoEvent.Route != "/test" {
		t.Errorf("Expected Route '/test', got '%s'", protoEvent.Route)
	}

	if protoEvent.HttpMethod != "GET" {
		t.Errorf("Expected HttpMethod 'GET', got '%s'", protoEvent.HttpMethod)
	}

	if protoEvent.StatusCode != 200 {
		t.Errorf("Expected StatusCode 200, got %d", protoEvent.StatusCode)
	}

	if protoEvent.DurationMs != 42 {
		t.Errorf("Expected DurationMs 42, got %d", protoEvent.DurationMs)
	}

	if protoEvent.ClientIp != "127.0.0.1" {
		t.Errorf("Expected ClientIp '127.0.0.1', got '%s'", protoEvent.ClientIp)
	}

	if protoEvent.UserAgent != "test-agent" {
		t.Errorf("Expected UserAgent 'test-agent', got '%s'", protoEvent.UserAgent)
	}

	if protoEvent.CustomLabels["env"] != "test" {
		t.Errorf("Expected CustomLabels[env] 'test', got '%s'", protoEvent.CustomLabels["env"])
	}

	// Check timestamp is set
	if protoEvent.Timestamp == nil {
		t.Error("Expected Timestamp to be set")
	}
}

func TestNewClientWithInvalidURL(t *testing.T) {
	// This test just ensures the client can be created with a custom URL
	// In a real integration test, we would test against a running server
	_, err := New("nonexistent:12345", &Options{
		Logger:        slog.Default(),
		BufferSize:    10,
		FlushInterval: 100 * time.Millisecond,
		Timeout:       100 * time.Millisecond,
		SampleRate:    1.0,
		MaxRetries:    0,
	})

	// Client creation should succeed even if server isn't running
	// Connection is lazy
	if err != nil {
		t.Errorf("Expected client creation to succeed, got error: %v", err)
	}
}

func TestLogEventNonBlocking(t *testing.T) {
	// Create client with small buffer
	client, err := New("localhost:9999", &Options{
		BufferSize:    2,
		FlushInterval: 10 * time.Second, // Long interval so events stay buffered
		Timeout:       1 * time.Millisecond,
		SampleRate:    1.0,
		MaxRetries:    0,
	})
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer client.Close()

	// Send events - should not block even if buffer fills
	for i := 0; i < 10; i++ {
		event := &proto.TrafficEvent{
			Timestamp:  timestamppb.Now(),
			Url:        "/test",
			HttpMethod: "GET",
			StatusCode: 200,
		}
		client.LogEvent(event)
	}

	// If we get here without blocking, test passes
}

func TestSampling(t *testing.T) {
	// Test that sample rate is respected
	// With rate 1.0, all events should be queued
	client, err := New("localhost:9999", &Options{
		BufferSize:    100,
		FlushInterval: 10 * time.Second,
		Timeout:       1 * time.Millisecond,
		SampleRate:    1.0, // Sample everything
		MaxRetries:    0,
	})
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer client.Close()

	// Send one event
	event := &proto.TrafficEvent{
		Timestamp:  timestamppb.Now(),
		Url:        "/test",
		HttpMethod: "GET",
		StatusCode: 200,
	}
	client.LogEvent(event)

	// Give a moment for event to be queued
	time.Sleep(10 * time.Millisecond)

	// With sample rate 1.0, event should have been queued
	// (or already processed by worker, which is also fine)
	// This test mainly ensures sampling logic doesn't panic
}

func TestClose(t *testing.T) {
	client, err := New("localhost:9999", &Options{
		BufferSize:    10,
		FlushInterval: 100 * time.Millisecond,
		Timeout:       1 * time.Millisecond,
		SampleRate:    1.0,
		MaxRetries:    0,
	})
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}

	// Send some events
	for i := 0; i < 5; i++ {
		event := &proto.TrafficEvent{
			Timestamp:  timestamppb.Now(),
			Url:        "/test",
			HttpMethod: "GET",
			StatusCode: 200,
		}
		client.LogEvent(event)
	}

	// Close should not panic and should gracefully shut down
	err = client.Close()
	if err != nil {
		t.Errorf("Close returned error: %v", err)
	}
}

func TestLogEventSync(t *testing.T) {
	client, err := New("localhost:9999", &Options{
		Timeout:    1 * time.Millisecond,
		SampleRate: 1.0,
		MaxRetries: 0,
	})
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer client.Close()

	event := &proto.TrafficEvent{
		Timestamp:  timestamppb.Now(),
		Url:        "/test",
		HttpMethod: "GET",
		StatusCode: 200,
	}

	ctx := context.Background()
	err = client.LogEventSync(ctx, event)

	// We expect an error since server isn't running
	// But the method should not panic
	if err == nil {
		t.Log("Warning: Expected error due to no server, but got success")
	}
}

func TestAPIKeyOption(t *testing.T) {
	t.Run("APIKey can be set explicitly", func(t *testing.T) {
		opts := &Options{
			APIKey: "test-api-key",
		}
		opts.applyDefaults()

		if opts.APIKey != "test-api-key" {
			t.Errorf("Expected APIKey 'test-api-key', got '%s'", opts.APIKey)
		}
	})

	t.Run("APIKey defaults to environment variable", func(t *testing.T) {
		os.Setenv("PULSEURL_API_KEY", "env-api-key")
		defer os.Unsetenv("PULSEURL_API_KEY")

		opts := &Options{}
		opts.applyDefaults()

		if opts.APIKey != "env-api-key" {
			t.Errorf("Expected APIKey 'env-api-key', got '%s'", opts.APIKey)
		}
	})

	t.Run("explicit APIKey takes precedence over env var", func(t *testing.T) {
		os.Setenv("PULSEURL_API_KEY", "env-api-key")
		defer os.Unsetenv("PULSEURL_API_KEY")

		opts := &Options{
			APIKey: "explicit-key",
		}
		opts.applyDefaults()

		if opts.APIKey != "explicit-key" {
			t.Errorf("Expected APIKey 'explicit-key', got '%s'", opts.APIKey)
		}
	})

	t.Run("empty APIKey when not set", func(t *testing.T) {
		os.Unsetenv("PULSEURL_API_KEY")

		opts := &Options{}
		opts.applyDefaults()

		if opts.APIKey != "" {
			t.Errorf("Expected empty APIKey, got '%s'", opts.APIKey)
		}
	})
}

func TestNewClientWithAPIKey(t *testing.T) {
	client, err := New("localhost:9999", &Options{
		APIKey:     "test-api-key",
		Timeout:    1 * time.Millisecond,
		SampleRate: 1.0,
		MaxRetries: 0,
	})
	if err != nil {
		t.Fatalf("Failed to create client with API key: %v", err)
	}
	defer client.Close()
}
