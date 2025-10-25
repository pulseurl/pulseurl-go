# Kubernetes Middleware Testing Infrastructure - Implementation Plan

- **Status**: Planning
- **Estimated Effort**: 4.5-6.5 hours
- **Complexity**: Medium
- **Priority**: High
- **Owner**: TBD
- **Created**: 2025-10-24

## Executive Summary

This document outlines the plan to implement comprehensive end-to-end testing infrastructure for the pulseurl-go middleware in Kubernetes environments. The testing will validate critical features (sampling, URL filtering, buffer overflow handling) using traffic generation scripts and automated log analysis.

## Problem Statement

Currently, the pulseurl-go library has >90% unit test coverage but lacks end-to-end validation in realistic Kubernetes deployments. Critical features like sampling, buffer overflow behavior, and URL filtering need validation against actual PulseURL service instances to ensure production readiness.

### Gaps
- No automated E2E testing in k8s environment
- Limited observability for debugging middleware behavior
- No validation that events reach PulseURL service correctly
- No buffer overflow testing under load
- No sampling rate validation

## Goals

1. **Automated Testing**: Create scripts that generate traffic and validate middleware behavior
2. **Configurable Debug Logging**: Add optional verbose logging for troubleshooting (off by default)
3. **Log Analysis**: Tools to parse logs and cross-reference with PulseURL queries
4. **Test Scenarios**: Cover all critical middleware features
5. **Production Safe**: Ensure debug logging can be disabled for production deployments

## Non-Goals

- Performance/load testing (out of scope for this phase)
- Multi-cluster testing
- Chaos engineering scenarios

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────┐
│                  Test Infrastructure                      │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  ┌─────────────────┐         ┌──────────────────┐      │
│  │ test-middleware │────────▶│  K8s Deployment   │      │
│  │      .sh        │         │  (pulseurl-go)    │      │
│  │                 │         │                   │      │
│  │ - Traffic Gen   │         │  - Debug Logging  │      │
│  │ - Scenarios     │         │  - Configurable   │      │
│  │ - Validation    │         └──────────┬───────┘      │
│  └────────┬────────┘                    │              │
│           │                             │              │
│           │                             ▼              │
│           │                    ┌─────────────────┐     │
│           │                    │ Pod Logs        │     │
│           │                    │ (structured)    │     │
│           │                    └────────┬────────┘     │
│           │                             │              │
│           │         ┌───────────────────┘              │
│           │         │                                  │
│           ▼         ▼                                  │
│  ┌──────────────────────────┐                         │
│  │   analyze-logs.sh        │                         │
│  │                          │                         │
│  │  - Parse logs            │                         │
│  │  - Query PulseURL API    │                         │
│  │  - Generate report       │                         │
│  └──────────────────────────┘                         │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Test Flow

1. Deploy pulseurl-go app to k8s with test configuration
2. Run test-middleware.sh to generate traffic scenarios
3. Query PulseURL API to validate events
4. Collect pod logs with debug information
5. Run analyze-logs.sh to cross-reference and validate
6. Generate pass/fail report

## Implementation Plan

### Phase 1: Configurable Debug Logging (1-1.5 hours)

#### 1.1 Add DebugLogging Option to Client

**File**: [client/options.go](../client/options.go)

**Changes**:
```go
type Options struct {
    // ... existing fields ...

    // DebugLogging enables verbose debug output for troubleshooting.
    // If true and Logger is nil, a debug-level logger will be created automatically.
    // Default: false
    DebugLogging bool
}
```

Update `DefaultOptions()`:
```go
func DefaultOptions() *Options {
    return &Options{
        // ... existing defaults ...
        DebugLogging: false,
    }
}
```

Update `applyDefaults()`:
```go
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
    // ... rest of defaults ...
}
```

#### 1.2 Add Debug Logging to Client

**File**: [client/client.go](../client/client.go)

**Locations to add debug logs**:

1. **Event Sampling** (line ~74-76):
```go
if c.opts.SampleRate < 1.0 && rand.Float64() > c.opts.SampleRate {
    c.logger.Debug("event sampled out",
        "sample_rate", c.opts.SampleRate,
        "url", event.Url,
        "method", event.HttpMethod)
    return
}
```

2. **Event Queued** (line ~80-81):
```go
select {
case c.eventChan <- event:
    c.logger.Debug("event queued",
        "buffer_usage", len(c.eventChan),
        "buffer_capacity", cap(c.eventChan),
        "url", event.Url,
        "method", event.HttpMethod)
default:
    // Buffer full, drop event
    c.logger.Warn("event buffer full, dropping event",
        "url", event.Url,
        "method", event.HttpMethod)
}
```

3. **Event Sent Successfully** (line ~153-156):
```go
_, err := c.grpcClient.LogEvent(ctx, event)
if err == nil {
    c.logger.Debug("event sent to PulseURL",
        "url", event.Url,
        "method", event.HttpMethod,
        "status", event.StatusCode)
    return nil
}
```

4. **Periodic Buffer Status** (new function):
```go
// Add to worker() function - log buffer status periodically
func (c *Client) logBufferStatus() {
    usage := len(c.eventChan)
    capacity := cap(c.eventChan)
    percentage := float64(usage) / float64(capacity) * 100

    c.logger.Debug("buffer status",
        "usage", usage,
        "capacity", capacity,
        "percentage", fmt.Sprintf("%.1f%%", percentage))
}
```

#### 1.3 Add Debug Logging to Middleware

**File**: [middleware/middleware.go](../middleware/middleware.go)

**Approach**: The middleware already has a `Logger` field in `Config`. When users enable `DebugLogging` in the client, they should pass the same logger to the middleware. No separate config needed.

**Locations to add debug logs**:

1. **Path Skipped** (line ~69-72):
```go
if skipPathMap[path] {
    logger.Debug("path skipped by filter",
        "path", path)
    c.Next()
    return
}
```

2. **Event Created** (line ~84-100):
```go
event := &proto.TrafficEvent{
    // ... event fields ...
}

logger.Debug("event created",
    "service", serviceName,
    "pod_id", podID,
    "namespace", config.Namespace,
    "url", path,
    "route", c.FullPath(),
    "method", c.Request.Method,
    "status", c.Writer.Status(),
    "duration_ms", duration.Milliseconds())

config.Client.LogEvent(event)
```

3. **Service Identification** (during initialization in New function):
```go
logger.Debug("middleware initialized",
    "service_name", serviceName,
    "pod_id", podID,
    "namespace", config.Namespace,
    "skip_paths", config.SkipPaths)
```

#### 1.4 Update Examples to Support Debug Flag

**File**: [examples/kubernetes-gin/main.go](../examples/kubernetes-gin/main.go)

Add environment variable support:
```go
// Get debug logging from environment
debugLogging := os.Getenv("PULSEURL_DEBUG") == "true"

// Create client with debug logging option
// This configures the logger with appropriate level
pulseClient, err := client.New(serviceURL, &client.Options{
    BufferSize:   1000,
    SampleRate:   1.0,
    DebugLogging: debugLogging,
})

// ...

// Use the same logger from the client for middleware
// This ensures consistent log levels across both components
router.Use(middleware.New(middleware.Config{
    Client:  pulseClient,
    Logger:  pulseClient.Logger(), // Use same logger as client
    // ... other config ...
}))
```

**Note**: We need to add a `Logger()` getter method to the client so middleware can access it.


#### 1.5 Add Logger() Getter to Client

**File**: [client/client.go](../client/client.go)

Add a public getter method so middleware can access the logger:
```go
// Logger returns the client's logger instance
func (c *Client) Logger() *slog.Logger {
    return c.logger
}
```

#### 1.6 Update Tests

- Update [client/client_test.go](../client/client_test.go) to test DebugLogging option
- Update [middleware/middleware_test.go](../middleware/middleware_test.go) to verify debug logs work
- Verify debug logs appear/don't appear based on logger level

### Phase 2: Traffic Generation Script (2-3 hours)

#### 2.1 Create Script Structure

**File**: `examples/kubernetes-gin/test-middleware.sh`

**Features**:
- Multiple test scenarios
- Traffic generation with curl/bombardier
- PulseURL API queries for validation
- Pass/fail reporting
- Configurable namespace, service URL
- JSON output option for CI/CD

**Script Outline**:
```bash
#!/bin/bash
# test-middleware.sh - Comprehensive middleware testing

# Configuration
NAMESPACE="${NAMESPACE:-default}"
PULSEURL_API="${PULSEURL_API:-http://pulseurl:8080}"
APP_SERVICE="${APP_SERVICE:-pulseurl-go-example:8080}"
VERBOSE="${VERBOSE:-false}"

# Test scenarios
run_baseline_test()       # Normal operation
run_sampling_test()       # Validate sample rate
run_filtering_test()      # Validate SkipPaths
run_buffer_overflow_test() # Small buffer + burst traffic
run_service_id_test()     # Validate metadata
run_concurrent_test()     # Parallel traffic

# Validation functions
query_pulseurl()          # Query API for events
validate_event_count()    # Check expected vs actual
validate_metadata()       # Check service/namespace/pod

# Reporting
generate_report()         # Summary output
```

#### 2.2 Test Scenarios

**Scenario 1: Baseline Test**
- Purpose: Verify normal operation
- Traffic: 100 requests to various endpoints
- Validation: All non-filtered events appear in PulseURL
- Expected: ~100 events (minus /health, /ready)

**Scenario 2: Sampling Test**
- Purpose: Validate sample rate
- Configuration: `SAMPLE_RATE=0.5`
- Traffic: 1000 requests
- Validation: ~500 events logged (±5% tolerance)
- Expected: Statistical validation of sampling

**Scenario 3: URL Filtering Test**
- Purpose: Verify SkipPaths
- Traffic: 100 requests to /health, /ready; 100 to normal endpoints
- Validation: Only normal endpoints logged
- Expected: 100 events (none from /health or /ready)

**Scenario 4: Buffer Overflow Test**
- Purpose: Validate buffer behavior
- Configuration: `BUFFER_SIZE=10`
- Traffic: Burst of 100 rapid requests (<1s)
- Validation: "buffer full" warnings in logs; some events logged
- Expected: Warnings present, no crashes

**Scenario 5: Service Identification Test**
- Purpose: Validate metadata
- Traffic: 10 requests
- Validation: Query PulseURL, check service/namespace/pod_id fields
- Expected: All metadata correct

**Scenario 6: Concurrent Load Test**
- Purpose: Stress test with parallel traffic
- Traffic: 10 parallel streams, 100 requests each
- Validation: No lost events, no errors
- Expected: ~1000 events, no errors

#### 2.3 Implementation Details

**Traffic Generation**:
```bash
# Simple requests with curl
send_request() {
    local endpoint="$1"
    local method="${2:-GET}"
    curl -sf -X "$method" "http://${APP_SERVICE}${endpoint}"
}

# Burst traffic for buffer test
send_burst() {
    local count="$1"
    for i in $(seq 1 $count); do
        send_request "/api/users/$i" &
    done
    wait
}
```

**PulseURL API Queries**:
```bash
# Query for service events
query_service_events() {
    local service="$1"
    local window="${2:-5}" # minutes

    curl -sf "${PULSEURL_API}/api/stats/top?service=${service}&limit=100&window=${window}"
}

# Get URL count
get_url_count() {
    local url="$1"
    local service="$2"

    curl -sf "${PULSEURL_API}/api/stats/url?url=${url}&service=${service}&window=5"
}
```

**Validation**:
```bash
validate_event_count() {
    local expected="$1"
    local actual="$2"
    local tolerance="${3:-0.05}" # 5% default

    local diff=$(echo "scale=2; ($actual - $expected) / $expected" | bc -l)
    local abs_diff=$(echo "${diff#-}" | bc -l) # absolute value

    if (( $(echo "$abs_diff <= $tolerance" | bc -l) )); then
        echo "PASS"
    else
        echo "FAIL"
    fi
}
```

### Phase 3: Log Analysis Script (1-2 hours)

#### 3.1 Create Analysis Script

**File**: `examples/kubernetes-gin/analyze-logs.sh`

**Features**:
- Parse pod logs for debug events
- Extract structured log data
- Query PulseURL API
- Cross-reference logs with PulseURL data
- Detect anomalies
- Generate report

**Script Outline**:
```bash
#!/bin/bash
# analyze-logs.sh - Analyze pod logs and PulseURL data

# Parse logs
parse_debug_logs()        # Extract debug entries
count_sampled_events()    # Count "sampled out" logs
count_buffer_warnings()   # Count "buffer full" logs
count_queued_events()     # Count "event queued" logs
count_sent_events()       # Count "event sent" logs

# Cross-reference
compare_with_pulseurl()   # Compare log counts with API
detect_anomalies()        # Find mismatches

# Report
generate_analysis_report() # Detailed analysis output
```

#### 3.2 Log Parsing

**Parse structured logs**:
```bash
# Extract debug logs
get_debug_logs() {
    kubectl logs -n "$NAMESPACE" -l app=pulseurl-go-example \
        | grep 'level=DEBUG'
}

# Count specific events
count_pattern() {
    local pattern="$1"
    get_debug_logs | grep -c "$pattern" || echo "0"
}

# Parse JSON structured logs
parse_log_field() {
    local field="$1"
    get_debug_logs | grep "$field" | sed 's/.*'"$field"'=\([^ ]*\).*/\1/'
}
```

#### 3.3 Analysis Functions

**Event tracking**:
```bash
analyze_event_flow() {
    local queued=$(count_pattern "event queued")
    local sampled=$(count_pattern "event sampled out")
    local sent=$(count_pattern "event sent")
    local dropped=$(count_pattern "buffer full")

    echo "Event Flow Analysis:"
    echo "  Queued:  $queued"
    echo "  Sampled: $sampled"
    echo "  Sent:    $sent"
    echo "  Dropped: $dropped"

    # Validation
    local expected_sent=$((queued - dropped))
    if [ "$sent" -eq "$expected_sent" ]; then
        echo "  Status: ✓ PASS"
    else
        echo "  Status: ✗ FAIL (expected $expected_sent, got $sent)"
    fi
}
```

**Buffer analysis**:
```bash
analyze_buffer_usage() {
    # Extract buffer usage percentages
    get_debug_logs | grep "buffer status" | \
        sed 's/.*percentage=\([0-9.]*\)%.*/\1/' | \
        awk '{
            sum+=$1; count++
            if($1>max) max=$1
            if(min=="" || $1<min) min=$1
        }
        END {
            print "Buffer Usage Statistics:"
            print "  Average: " sum/count "%"
            print "  Max:     " max "%"
            print "  Min:     " min "%"
        }'
}
```

### Phase 4: Documentation (30 min)

#### 4.1 Update Main README

**File**: [README.md](../README.md)

Add section on testing:
```markdown
## Testing

### Unit Tests

```bash
go test ./...
go test ./... -cover
```

### End-to-End Testing in Kubernetes

For comprehensive E2E testing in Kubernetes, see the [kubernetes-gin example](./examples/kubernetes-gin).

```bash
cd examples/kubernetes-gin

# Deploy with debug logging
PULSEURL_DEBUG=true NAMESPACE=test ./manage.sh k8s-deploy

# Run test scenarios
./test-middleware.sh --namespace test --scenarios all

# Analyze results
./analyze-logs.sh --namespace test --report results.txt
```

For detailed testing documentation, see [TESTING.md](./docs/TESTING.md).
```

#### 4.2 Create Testing Documentation

**File**: `docs/TESTING.md`

Content:
- Overview of testing approach
- Test scenarios explained
- How to run tests
- Interpreting results
- Troubleshooting common issues
- Debug logging usage

#### 4.3 Update Example README

**File**: `examples/kubernetes-gin/README.md`

Add testing section with:
- How to enable debug logging
- Running test scenarios
- Understanding test output
- Common test failures and solutions

### Phase 5: Integration & Validation (30-60 min)

#### 5.1 Test the Testing Infrastructure

- Deploy to test namespace
- Run all test scenarios
- Verify scripts work end-to-end
- Fix any issues

#### 5.2 Documentation Review

- Ensure all docs are accurate
- Add examples
- Verify instructions work

#### 5.3 Code Review Preparation

- Ensure code follows project style
- Add comments
- Update CHANGELOG if needed

## File Changes Summary

### New Files
- `docs/TESTING_PLAN.md` (this document)
- `docs/TESTING.md` (user-facing testing guide)
- `examples/kubernetes-gin/test-middleware.sh` (traffic generation script)
- `examples/kubernetes-gin/analyze-logs.sh` (log analysis script)

### Modified Files
- `client/options.go` - Add DebugLogging field
- `client/client.go` - Add debug log statements and Logger() getter method
- `middleware/middleware.go` - Add debug log statements (no config changes needed)
- `examples/kubernetes-gin/main.go` - Support PULSEURL_DEBUG env var and pass logger to middleware
- `README.md` - Add testing section
- `examples/kubernetes-gin/README.md` - Add testing documentation

### Test Files to Update
- `client/client_test.go` - Test DebugLogging option
- `middleware/middleware_test.go` - Test DebugLogging option

## Environment Variables

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `PULSEURL_DEBUG` | Enable debug logging | `false` | `true` |
| `PULSEURL_SERVICE` | PulseURL gRPC endpoint | `pulseurl:9090` | `localhost:9090` |
| `NAMESPACE` | K8s namespace | `default` | `test` |
| `BUFFER_SIZE` | Client buffer size (testing) | `1000` | `10` |
| `SAMPLE_RATE` | Sample rate (testing) | `1.0` | `0.5` |

## Test Scenarios Matrix

| Scenario | Config | Traffic | Expected Events | Validation |
|----------|--------|---------|----------------|------------|
| Baseline | Default | 100 requests | ~95 | All logged |
| Sampling | SampleRate=0.5 | 1000 requests | ~500 | ±5% tolerance |
| Filtering | SkipPaths=/health | 100 filtered + 100 normal | 100 | None filtered |
| Buffer Overflow | BufferSize=10 | 100 burst | <100 | Warnings present |
| Service ID | Default | 10 requests | 10 | Metadata correct |
| Concurrent | Default | 1000 parallel | ~1000 | No errors |

## Success Criteria

- [ ] Debug logging is configurable (on/off)
- [ ] Debug logs provide useful troubleshooting information
- [ ] Debug logging is OFF by default (production safe)
- [ ] test-middleware.sh runs all 6 scenarios successfully
- [ ] analyze-logs.sh cross-references logs with PulseURL API
- [ ] All tests pass with expected results
- [ ] Documentation is clear and complete
- [ ] Scripts work in clean k8s environment
- [ ] No breaking changes to existing API

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Debug logs too verbose | Medium | Use structured logging, filter by level |
| Performance impact of logging | Low | Only log when DebugLogging=true |
| Script dependencies (curl, jq, bc) | Medium | Document prerequisites, check in script |
| Timing issues in tests | Medium | Add configurable delays, retry logic |
| PulseURL API changes | Low | Version check, graceful degradation |

## Dependencies

### Go Dependencies
- No new dependencies needed (using existing slog)

### Script Dependencies
- `kubectl` - Kubernetes CLI
- `curl` - HTTP requests
- `jq` - JSON parsing (optional, nice-to-have)
- `bc` - Calculations
- `grep`, `sed`, `awk` - Log parsing

## Timeline

| Phase | Duration | Dependencies |
|-------|----------|-------------|
| 1. Debug Logging | 1-1.5 hours | None |
| 2. Traffic Script | 2-3 hours | Phase 1 complete |
| 3. Analysis Script | 1-2 hours | Phase 1, 2 complete |
| 4. Documentation | 30 min | All phases complete |
| 5. Integration | 30-60 min | All phases complete |
| **Total** | **4.5-6.5 hours** | Sequential execution |

## Future Enhancements (Out of Scope)

- Performance benchmarking
- Multi-cluster testing
- Chaos engineering integration
- Grafana dashboards for test results
- CI/CD integration
- Automated regression testing
- Load testing with k6/bombardier
- Distributed tracing integration

## References

- PulseURL API: `http://pulseurl:8080/api/stats/*`
- Go slog documentation: https://pkg.go.dev/log/slog
- Kubernetes testing best practices: https://kubernetes.io/blog/2019/03/22/kubernetes-end-to-end-testing-for-everyone/

## Approval

- [ ] Plan reviewed
- [ ] Effort estimate approved
- [ ] Ready to implement

---

**Document Version**: 1.0
**Last Updated**: 2025-10-24
