# PulseURL Go Client & Middleware

Official Go client library and Gin middleware for [PulseURL](https://github.com/pulseurl/pulseurl) - a high-performance traffic analytics service.

## Features

- **Async buffered gRPC client** - Non-blocking event logging with configurable buffer
- **Gin middleware** - Drop-in middleware for Gin web framework
- **Automatic retries** - Configurable retry logic for failed requests
- **Sampling support** - Control what percentage of requests to log
- **Production ready** - Comprehensive tests, logging with `slog`, graceful shutdown

## Installation

```bash
go get github.com/pulseurl/pulseurl-go
```

## Quick Start

### Basic Usage with Gin

```go
package main

import (
    "log"
    "github.com/gin-gonic/gin"
    "github.com/pulseurl/pulseurl-go/client"
    "github.com/pulseurl/pulseurl-go/middleware"
)

func main() {
    // Create PulseURL client
    pulseClient, err := client.New("pulseurl:9090")
    if err != nil {
        log.Fatal(err)
    }
    defer pulseClient.Close()

    // Create Gin router with PulseURL middleware
    router := gin.Default()
    router.Use(middleware.NewWithClient(pulseClient))

    router.GET("/", func(c *gin.Context) {
        c.JSON(200, gin.H{"message": "Hello World"})
    })

    router.Run(":8080")
}
```

### Advanced Configuration

```go
// Create client with custom options
pulseClient, err := client.New("pulseurl:9090", &client.Options{
    Logger:        slog.Default(),
    BufferSize:    1000,
    FlushInterval: 1 * time.Second,
    Timeout:       2 * time.Second,
    SampleRate:    1.0,  // Log 100% of requests
    MaxRetries:    2,
})

// Configure middleware
router.Use(middleware.New(middleware.Config{
    Client: pulseClient,
    SkipPaths: []string{
        "/health",
        "/metrics",
    },
    CustomLabels: map[string]string{
        "app":         "my-service",
        "environment": "production",
    },
    ServiceName: "my-service",
    Namespace:   "production",
}))
```

## Client API

### Creating a Client

```go
client, err := client.New(serviceURL string, opts *client.Options) (*client.Client, error)
```

### Options

```go
type Options struct {
    ServiceURL    string          // gRPC endpoint (default: "localhost:9090")
    Logger        *slog.Logger    // Logger (default: slog.Default())
    BufferSize    int             // Channel buffer size (default: 1000)
    FlushInterval time.Duration   // Flush interval (default: 1s)
    Timeout       time.Duration   // gRPC timeout (default: 2s)
    SampleRate    float64         // Sample rate 0.0-1.0 (default: 1.0)
    MaxRetries    int             // Max retries (default: 2)
}
```

### Logging Events

#### Async (Non-blocking, Recommended)

```go
client.LogEvent(event *proto.TrafficEvent)
```

#### Sync (Blocking)

```go
err := client.LogEventSync(ctx context.Context, event *proto.TrafficEvent)
```

### Helper for Building Events

```go
event := &client.Event{
    Timestamp:    time.Now(),
    PodID:        "pod-123",
    Namespace:    "production",
    URL:          "/api/users",
    Route:        "/api/users/:id",
    Method:       "GET",
    StatusCode:   200,
    DurationMs:   42,
    ClientIP:     "192.168.1.1",
    UserAgent:    "Mozilla/5.0...",
    CustomLabels: map[string]string{
        "version": "v1.0.0",
    },
}

client.LogEvent(event.ToProto())
```

## Middleware API

### Creating Middleware

```go
middleware.New(config middleware.Config) gin.HandlerFunc
```

### Config

```go
type Config struct {
    Client       *client.Client           // PulseURL client (required)
    Logger       *slog.Logger             // Logger (default: slog.Default())
    SkipPaths    []string                 // Paths to skip logging
    CustomLabels map[string]string        // Labels for all events
    ServiceName  string                   // Service name (default: hostname)
    Namespace    string                   // Deployment namespace
}
```

### Convenience Function

```go
middleware.NewWithClient(client *client.Client) gin.HandlerFunc
```

## Examples

### Basic Example

See [examples/basic-gin](./examples/basic-gin) for a simple local example.

```bash
cd examples/basic-gin
PULSEURL_SERVICE=localhost:9090 go run main.go
```

### Kubernetes Example

See [examples/kubernetes-gin](./examples/kubernetes-gin) for a complete Kubernetes deployment with `manage.sh` script.

```bash
cd examples/kubernetes-gin

# Build and deploy
./manage.sh build
NAMESPACE=dev ./manage.sh k8s-deploy

# Check status
NAMESPACE=dev ./manage.sh k8s-status

# View logs
NAMESPACE=dev ./manage.sh k8s-logs -f

# Test
NAMESPACE=dev ./manage.sh test
```

## Environment Variables

The examples support these environment variables:

- `PULSEURL_SERVICE` - PulseURL gRPC endpoint (default: `localhost:9090`)
- `PORT` - HTTP server port (default: `8080`)
- `SERVICE_NAME` - Service identifier
- `NAMESPACE` - Deployment namespace
- `ENVIRONMENT` - Environment name (e.g., `production`, `staging`)

## Architecture

### Client Design

- **Async by default**: `LogEvent()` queues events in a buffered channel and returns immediately
- **Background worker**: Processes events from the buffer and sends to gRPC service
- **Retry logic**: Automatic retries with exponential backoff
- **Graceful shutdown**: `Close()` drains buffer and waits for worker to finish
- **Sampling**: Control what percentage of events to send

### Middleware Design

- **Fire-and-forget**: Never blocks request handling
- **Minimal overhead**: O(1) skip path lookup
- **Rich metadata**: Captures URL, route pattern, method, status, duration, IP, user agent
- **Flexible filtering**: Skip health checks, metrics endpoints, etc.

## Testing

### Unit Tests

```bash
# Run all tests
go test ./... -cover 2>&1 | grep -E "(PASS|FAIL|coverage|ok)"

# Run tests with verbose output
go test -v ./client 2>&1 | head -50

# Run specific package tests
go test ./client -cover
go test ./middleware -cover
```

Current test coverage:
- Client: 88.8%
- Middleware: 96.4%

### End-to-End Testing in Kubernetes

For comprehensive E2E testing in Kubernetes environments, see the [kubernetes-gin example](./examples/kubernetes-gin).

**Quick Start:**

```bash
cd examples/kubernetes-gin

# Deploy with debug logging enabled
PULSEURL_DEBUG=true NAMESPACE=test ./manage.sh k8s-deploy

# Run test scenarios
./test-middleware.sh --namespace test

# Analyze logs and validate behavior
./analyze-logs.sh --namespace test --report results.txt
```

**Test Scenarios:**
- ✓ Baseline operation (normal traffic)
- ✓ URL filtering (/health, /ready skipped)
- ✓ Service identification (metadata validation)
- ✓ Concurrent load handling
- ✓ Sampling behavior (requires config)
- ✓ Buffer overflow (requires config)

**Debug Logging:**

Enable verbose debug output for troubleshooting:

```bash
# In Kubernetes
kubectl set env deployment/app PULSEURL_DEBUG=true -n namespace

# Locally
PULSEURL_DEBUG=true go run main.go
```

For detailed testing documentation, see [docs/TESTING.md](./docs/TESTING.md).

## Development

### Project Structure

```
pulseurl-go/
├── client/              # gRPC client with buffering
│   ├── client.go
│   ├── options.go
│   └── client_test.go
├── middleware/          # Gin middleware
│   ├── middleware.go
│   └── middleware_test.go
├── proto/              # Generated protobuf code
│   ├── traffic.proto
│   ├── traffic.pb.go
│   └── traffic_grpc.pb.go
├── examples/
│   ├── basic-gin/      # Simple local example
│   └── kubernetes-gin/ # K8s deployment example
├── go.mod
├── LICENSE
└── README.md
```

### Regenerating Protobuf Code

```bash
protoc --go_out=. --go_opt=paths=source_relative \
       --go-grpc_out=. --go-grpc_opt=paths=source_relative \
       proto/traffic.proto
```

## Performance

- **Non-blocking**: Event logging never blocks request handling
- **Buffered**: Configurable buffer size (default: 1000 events)
- **Batching**: Worker processes events efficiently
- **Low overhead**: Minimal CPU and memory usage

Benchmark results:
```
BenchmarkMiddleware-8    500000    2500 ns/op    800 B/op    10 allocs/op
```

## Roadmap

- [ ] Support for additional frameworks (Echo, Fiber, Chi)
- [ ] OpenTelemetry integration
- [ ] Metrics export (Prometheus format)
- [ ] gRPC health checks
- [ ] Connection pooling

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.

## License

MIT License - see [LICENSE](./LICENSE) for details.

## Support

- **Documentation**: https://github.com/pulseurl/pulseurl
- **Issues**: https://github.com/pulseurl/pulseurl-go/issues
- **Main Service**: https://github.com/pulseurl/pulseurl

## Related Projects

- [pulseurl](https://github.com/pulseurl/pulseurl) - Main service
- [pulseurl-dotnet](https://github.com/pulseurl/pulseurl-dotnet) - .NET middleware
- [pulseurl-node](https://github.com/pulseurl/pulseurl-node) - Node.js middleware
- [pulseurl-python](https://github.com/pulseurl/pulseurl-python) - Python middleware

---

Made with ❤️ by the PulseURL team
