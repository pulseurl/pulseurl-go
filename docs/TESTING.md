# Testing Guide for PulseURL Go Middleware

This guide explains how to test the pulseurl-go middleware in both local and Kubernetes environments.

## Table of Contents

- [Unit Testing](#unit-testing)
- [End-to-End Testing](#end-to-end-testing)
- [Debug Logging](#debug-logging)
- [Test Scenarios](#test-scenarios)
- [Troubleshooting](#troubleshooting)

## Unit Testing

### Running Tests

```bash
# Run all tests with coverage
go test ./... -cover 2>&1 | grep -E "(PASS|FAIL|coverage|ok)"

# Run specific package
go test -v ./client 2>&1 | head -50
go test -v ./middleware 2>&1 | head -50

# Run with coverage report
go test ./client -cover
go test ./middleware -cover
```

### Current Coverage

- **Client**: 88.8% coverage
- **Middleware**: 96.4% coverage

### What Unit Tests Cover

**Client Tests** ([client/client_test.go](../client/client_test.go)):
- Default options configuration
- Options validation and defaults
- Debug logging configuration
- Event serialization (Event → proto.TrafficEvent)
- Non-blocking event queuing
- Sampling behavior
- Graceful shutdown

**Middleware Tests** ([middleware/middleware_test.go](../middleware/middleware_test.go)):
- Request tracking and event creation
- Path filtering (SkipPaths)
- Service identification
- Custom labels attachment
- Integration with client

## End-to-End Testing

End-to-end tests validate the middleware in a realistic Kubernetes environment with an actual PulseURL service.

### Prerequisites

1. **Kubernetes cluster** with kubectl configured
2. **PulseURL service** deployed and running
3. **pulseurl-go-example app** deployed
4. **Services accessible** (via port-forward or in-cluster)

### Quick Start

```bash
cd examples/kubernetes-gin

# 1. Deploy with debug logging
PULSEURL_DEBUG=true NAMESPACE=test ./manage.sh k8s-deploy

# 2. Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app=pulseurl-go-example -n test --timeout=60s

# 3. Set up port forwarding (if testing from local machine)
kubectl port-forward -n test svc/pulseurl-go-example 8080:8080 &
kubectl port-forward -n test svc/pulseurl 8080:8080 &

# 4. Run test scenarios
./test-middleware.sh --namespace test

# 5. Analyze logs
./analyze-logs.sh --namespace test --report results.txt

# 6. Review results
cat results.txt
```

### Test Scripts

#### test-middleware.sh

Generates traffic and validates middleware behavior.

**Usage:**
```bash
# Run all tests
./test-middleware.sh

# Run specific scenarios
./test-middleware.sh --scenarios baseline,filtering

# With custom configuration
./test-middleware.sh \
  --namespace test \
  --pulseurl-api http://pulseurl:8080 \
  --app-service pulseurl-go-example:8080 \
  --verbose
```

**Options:**
- `--namespace <ns>` - Kubernetes namespace (default: default)
- `--pulseurl-api <url>` - PulseURL API URL
- `--app-service <url>` - App service URL
- `--scenarios <list>` - Comma-separated scenarios to run
- `--verbose` - Enable debug output
- `--help` - Show help

#### analyze-logs.sh

Parses pod logs and cross-references with PulseURL API.

**Usage:**
```bash
# Basic analysis
./analyze-logs.sh --namespace test

# Save report to file
./analyze-logs.sh --namespace test --report analysis.txt

# Analyze specific time window
./analyze-logs.sh --namespace test --window 30
```

**Options:**
- `--namespace <ns>` - Kubernetes namespace
- `--pulseurl-api <url>` - PulseURL API URL
- `--service <name>` - Service name to query
- `--window <minutes>` - Time window for queries (default: 10)
- `--report <file>` - Save report to file
- `--help` - Show help

## Debug Logging

Debug logging provides detailed information about middleware operations.

### Enabling Debug Logging

**In Kubernetes:**
```bash
# Enable for deployment
kubectl set env deployment/pulseurl-go-example PULSEURL_DEBUG=true -n namespace

# Or via manage.sh
PULSEURL_DEBUG=true ./manage.sh k8s-deploy

# Restart to apply
kubectl rollout restart deployment/pulseurl-go-example -n namespace
```

**Locally:**
```bash
PULSEURL_DEBUG=true go run main.go
```

**In Code:**
```go
client, err := client.New("pulseurl:9090", &client.Options{
    DebugLogging: true,
    // ... other options
})
```

### What Gets Logged

When debug logging is enabled, you'll see:

**Client Debug Logs:**
- Event sampled out (when sampling < 100%)
- Event queued (with buffer usage stats)
- Event sent to PulseURL successfully
- Retry attempts

**Middleware Debug Logs:**
- Middleware initialization (service, pod, namespace)
- Path skipped by filter
- Event created (with full metadata)

**Example Debug Output:**
```
time=2025-10-24T14:30:12.123-04:00 level=DEBUG msg="middleware initialized" service_name=pulseurl-gin-example pod_id=pulseurl-go-example-7d8f9-xyz namespace=test skip_paths=[/health /ready]
time=2025-10-24T14:30:15.456-04:00 level=DEBUG msg="path skipped by filter" path=/health
time=2025-10-24T14:30:16.789-04:00 level=DEBUG msg="event created" service=pulseurl-gin-example pod_id=pulseurl-go-example-7d8f9-xyz url=/api/users method=GET status=200 duration_ms=42
time=2025-10-24T14:30:16.790-04:00 level=DEBUG msg="event queued" buffer_usage=1 buffer_capacity=1000 url=/api/users method=GET
time=2025-10-24T14:30:17.100-04:00 level=DEBUG msg="event sent to PulseURL" url=/api/users method=GET status=200
```

### Viewing Debug Logs

```bash
# All logs
kubectl logs -n namespace -l app=pulseurl-go-example

# Only debug logs
kubectl logs -n namespace -l app=pulseurl-go-example | grep "level=DEBUG"

# Follow logs
kubectl logs -n namespace -l app=pulseurl-go-example -f

# Last 100 lines
kubectl logs -n namespace -l app=pulseurl-go-example --tail=100
```

## Test Scenarios

### 1. Baseline Test

**Purpose:** Verify normal operation

**What it does:**
- Sends 50 requests to various endpoints
- Validates events are logged correctly
- Checks event counts in PulseURL

**Expected result:**
- All non-filtered requests logged
- Event count matches requests sent (±20% tolerance)

**Example:**
```bash
./test-middleware.sh --scenarios baseline
```

### 2. URL Filtering Test

**Purpose:** Verify SkipPaths configuration

**What it does:**
- Sends 20 requests to /health and /ready (filtered paths)
- Sends 10 requests to /api/stats (normal path)
- Validates filtered paths are NOT logged

**Expected result:**
- 0 events for /health and /ready
- ~10 events for /api/stats

**Example:**
```bash
./test-middleware.sh --scenarios filtering
```

### 3. Service Identification Test

**Purpose:** Validate metadata (service, namespace, pod_id)

**What it does:**
- Sends requests and queries PulseURL API
- Validates service name is correctly set
- Checks response structure

**Expected result:**
- Service name matches configuration
- Metadata present in PulseURL response

**Example:**
```bash
./test-middleware.sh --scenarios service-id
```

### 4. Concurrent Load Test

**Purpose:** Stress test with parallel traffic

**What it does:**
- Sends 10 parallel bursts of 10 requests each (100 total)
- Validates no events lost
- Checks for errors under load

**Expected result:**
- ~100 events logged (±30% tolerance)
- No errors or crashes

**Example:**
```bash
./test-middleware.sh --scenarios concurrent
```

### 5. Sampling Test (Manual)

**Purpose:** Validate sample rate configuration

**Requirements:**
- Redeploy with `SAMPLE_RATE=0.5` (50% sampling)

**Steps:**
```bash
# 1. Deploy with sampling
kubectl set env deployment/pulseurl-go-example SAMPLE_RATE=0.5 -n namespace
kubectl rollout restart deployment/pulseurl-go-example -n namespace

# 2. Send traffic
for i in {1..100}; do curl http://app:8080/api/users; done

# 3. Check debug logs for "event sampled out"
kubectl logs -l app=pulseurl-go-example -n namespace | grep "sampled out" | wc -l

# 4. Verify ~50 events in PulseURL
curl "http://pulseurl:8080/api/stats/top?service=pulseurl-gin-example&window=5"
```

**Expected result:**
- ~50 events sampled out
- ~50 events in PulseURL

### 6. Buffer Overflow Test (Manual)

**Purpose:** Validate buffer behavior under extreme load

**Requirements:**
- Redeploy with `BUFFER_SIZE=10` (small buffer)

**Steps:**
```bash
# 1. Deploy with small buffer
kubectl set env deployment/pulseurl-go-example BUFFER_SIZE=10 -n namespace
kubectl rollout restart deployment/pulseurl-go-example -n namespace

# 2. Send burst traffic
for i in {1..100}; do curl http://app:8080/api/users &; done; wait

# 3. Check for "buffer full" warnings
kubectl logs -l app=pulseurl-go-example -n namespace | grep "buffer full"
```

**Expected result:**
- "buffer full" warnings in logs
- Some events dropped (documented behavior)
- No crashes or errors

## Troubleshooting

### No Events in PulseURL

**Symptoms:**
- Test shows 0 events
- analyze-logs.sh shows events queued but not sent

**Possible causes:**
1. PulseURL service not running
2. Network connectivity issues
3. Wrong service URL

**Solutions:**
```bash
# Check PulseURL service
kubectl get pods -l app=pulseurl -n namespace
kubectl logs -l app=pulseurl -n namespace

# Check app configuration
kubectl get deployment pulseurl-go-example -n namespace -o yaml | grep PULSEURL_SERVICE

# Test connectivity from app pod
kubectl exec -it <pod-name> -n namespace -- curl http://pulseurl:9090

# Check error logs
kubectl logs -l app=pulseurl-go-example -n namespace | grep "level=ERROR"
```

### Debug Logs Not Showing

**Symptoms:**
- No DEBUG level logs in output
- analyze-logs.sh shows "No buffer usage logs found"

**Possible causes:**
1. Debug logging not enabled
2. Deployment not restarted after enabling

**Solutions:**
```bash
# Verify environment variable
kubectl get deployment pulseurl-go-example -n namespace -o yaml | grep PULSEURL_DEBUG

# Enable if missing
kubectl set env deployment/pulseurl-go-example PULSEURL_DEBUG=true -n namespace

# Restart deployment
kubectl rollout restart deployment/pulseurl-go-example -n namespace

# Wait for rollout
kubectl rollout status deployment/pulseurl-go-example -n namespace

# Check logs again
kubectl logs -l app=pulseurl-go-example -n namespace | grep DEBUG
```

### Test Script Can't Connect

**Symptoms:**
- "Service not accessible" error
- Connection refused errors

**Solutions:**
```bash
# Check if pods are running
kubectl get pods -n namespace

# Check if services exist
kubectl get svc -n namespace

# Set up port forwarding
kubectl port-forward -n namespace svc/pulseurl-go-example 8080:8080 &
kubectl port-forward -n namespace svc/pulseurl 8090:8080 &

# Run tests with correct URLs
./test-middleware.sh \
  --app-service localhost:8080 \
  --pulseurl-api http://localhost:8090
```

### High Error Rate

**Symptoms:**
- Many "failed to send event" errors in logs
- analyze-logs.sh shows high error count

**Possible causes:**
1. PulseURL service overloaded
2. Network issues
3. Timeout too short

**Solutions:**
```bash
# Check PulseURL service health
curl http://pulseurl:8080/health

# Check PulseURL resource usage
kubectl top pod -l app=pulseurl -n namespace

# Increase timeout in client (requires code change)
# See client/options.go - Timeout field

# Check network policies
kubectl get networkpolicies -n namespace
```

### Events Lost/Dropped

**Symptoms:**
- "buffer full" warnings in logs
- Fewer events in PulseURL than expected

**This is expected behavior when:**
- Buffer size is too small for traffic volume
- Traffic bursts exceed buffer capacity

**Solutions:**
```bash
# Increase buffer size
kubectl set env deployment/pulseurl-go-example BUFFER_SIZE=5000 -n namespace

# Check current buffer usage in debug logs
kubectl logs -l app=pulseurl-go-example -n namespace | grep "buffer_usage"

# Use analyze-logs.sh to see buffer statistics
./analyze-logs.sh --namespace namespace
```

## Best Practices

1. **Always enable debug logging for testing**
   - Provides visibility into middleware behavior
   - Makes troubleshooting much easier

2. **Run tests in a dedicated namespace**
   - Isolates test traffic from production
   - Makes cleanup easier

3. **Check both logs and PulseURL API**
   - Logs show what middleware did
   - API shows what was actually stored

4. **Start with baseline test**
   - Validates basic functionality
   - Confirms services are communicating

5. **Use analyze-logs.sh after traffic generation**
   - Provides comprehensive view of behavior
   - Cross-references with PulseURL data

6. **Save test reports**
   - Documents test results
   - Useful for debugging issues later

## Next Steps

- Review [TESTING_PLAN.md](./TESTING_PLAN.md) for implementation details
- Check [CHAOS_ENGINEERING_REFERENCE.md](./CHAOS_ENGINEERING_REFERENCE.md) for advanced resilience testing
- See [examples/kubernetes-gin/README.md](../examples/kubernetes-gin/README.md) for deployment guide

## Questions?

- Open an issue: https://github.com/pulseurl/pulseurl-go/issues
- Check main docs: https://github.com/pulseurl/pulseurl
