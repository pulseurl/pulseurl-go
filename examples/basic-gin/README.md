# Basic Gin Example

A simple example demonstrating PulseURL middleware integration with Gin.

## Prerequisites

- Go 1.21 or higher
- Running PulseURL service (see main repo)

## Running

### 1. Start PulseURL service

In the main `pulseurl` repository:

```bash
docker-compose up -d
```

### 2. Run the example

```bash
# From pulseurl-go/examples/basic-gin directory
go run main.go
```

Or with custom PulseURL service URL:

```bash
PULSEURL_SERVICE=pulseurl:9090 go run main.go
```

### 3. Send requests

```bash
# Root endpoint
curl http://localhost:8080/

# List users
curl http://localhost:8080/users

# Get specific user
curl http://localhost:8080/users/123

# Create user
curl -X POST http://localhost:8080/users

# Health check (not logged)
curl http://localhost:8080/health
```

## Configuration

Environment variables:

- `PULSEURL_SERVICE` - PulseURL gRPC endpoint (default: `localhost:9090`)
- `PORT` - HTTP server port (default: `8080`)

## What's Logged

The middleware logs all HTTP requests except:
- `/health`
- `/metrics`

Each logged event includes:
- Timestamp
- URL path and route pattern
- HTTP method
- Status code
- Duration in milliseconds
- Client IP
- User agent
- Custom labels (app, environment)
