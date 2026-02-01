# Kubernetes Gin Example

A complete Kubernetes deployment example demonstrating PulseURL middleware integration with Gin.

## Prerequisites

- Go 1.21 or higher
- Docker
- kubectl
- Kubernetes cluster (minikube, kind, or cloud provider)
- Running PulseURL service in Kubernetes

## Quick Start

### 1. Deploy PulseURL service

First, deploy the main PulseURL service to your cluster:

```bash
# In the main pulseurl repository
NAMESPACE=pulseurl ./manage.sh k8s-deploy
```

### 2. Build and deploy this example

```bash
# Build Docker image
./manage.sh build

# Deploy to Kubernetes
PULSEURL_SERVICE=pulseurl.pulseurl.svc.cluster.local:9090 NAMESPACE=dev ./manage.sh k8s-deploy
```

### 3. Test the deployment

```bash
# Check status
NAMESPACE=dev ./manage.sh k8s-status

# View logs
NAMESPACE=dev ./manage.sh k8s-logs -f

# Run tests
NAMESPACE=dev ./manage.sh test
```

## Configuration

The `manage.sh` script follows the same pattern as the main pulseurl repository for consistency.

### Environment Variables

- `REGISTRY` - Docker registry URL (e.g., `myregistry.io/myorg`)
- `NAMESPACE` - Kubernetes namespace (default: `default`)
- `IMAGE_NAME` - Docker image name (default: `pulseurl-go-example`)
- `IMAGE_TAG` - Image tag (default: `latest`)
- `PULSEURL_SERVICE` - PulseURL gRPC endpoint (default: `pulseurl:9090`)
- `PULSEURL_API_KEY` - API key for authentication (optional, from secret)
- `PULSEURL_DEBUG` - Enable debug logging (`true`/`false`)
- `SERVICE_NAME` - Service identifier (default: `pulseurl-gin-example`)
- `ENVIRONMENT` - Environment name (default: `production`)
- `HTTP_PORT` - HTTP server port (default: `8080`)

### Authentication

If your PulseURL server requires API key authentication, create a secret with the API key:

```bash
kubectl create secret generic pulseurl-secrets \
  --from-literal=api-key=your-secret-api-key \
  -n <namespace>
```

The deployment automatically reads from this secret (optional - deployment works without it).

## Available Commands

```bash
./manage.sh help
```

### Docker Commands
- `build` - Build Docker image
- `push` - Push to registry (requires REGISTRY env var)

### Local Development
- `run` - Run example locally with go run

### Kubernetes
- `k8s-deploy` - Deploy to Kubernetes
- `k8s-undeploy` - Remove from Kubernetes
- `k8s-status` - Show deployment status
- `k8s-logs [-f]` - View logs
- `k8s-port-forward [PORT]` - Port forward to local
- `k8s-restart` - Restart deployment

### Testing
- `test` - Test deployed application

## Usage Examples

### Local Development

```bash
# Run locally (requires PulseURL service running)
PULSEURL_SERVICE=localhost:9090 ./manage.sh run
```

### Development Deployment

```bash
# Build and deploy to dev namespace
./manage.sh build
NAMESPACE=dev PULSEURL_SERVICE=pulseurl.pulseurl.svc.cluster.local:9090 ./manage.sh k8s-deploy

# Monitor
NAMESPACE=dev ./manage.sh k8s-status
NAMESPACE=dev ./manage.sh k8s-logs -f

# Test
NAMESPACE=dev ./manage.sh test
```

### Production Deployment

```bash
# Build, tag, push, and deploy
REGISTRY=myregistry.io/myorg \
  IMAGE_TAG=v1.0.0 \
  NAMESPACE=production \
  PULSEURL_SERVICE=pulseurl.pulseurl.svc.cluster.local:9090 \
  ENVIRONMENT=production \
  ./manage.sh build push k8s-deploy
```

### Cross-Namespace Communication

If PulseURL is in a different namespace:

```bash
# PulseURL in 'pulseurl' namespace, example in 'apps' namespace
NAMESPACE=apps \
  PULSEURL_SERVICE=pulseurl.pulseurl.svc.cluster.local:9090 \
  ./manage.sh k8s-deploy
```

## API Endpoints

Once deployed, the example exposes:

- `GET /health` - Health check (not logged)
- `GET /ready` - Readiness check (not logged)
- `GET /` - Root endpoint with service info
- `GET /api/users` - List users
- `GET /api/users/:id` - Get specific user
- `POST /api/users` - Create user
- `GET /api/stats` - Get stats

## Testing the Integration

### Automated Test Suite

The example includes a comprehensive test suite (`test-middleware.sh`) that validates all middleware features:

#### Basic Tests (Run Anytime)

```bash
# Port forward to access services
kubectl port-forward -n nathan svc/pulseurl-go-example 8080:8080 &
kubectl port-forward -n nathan svc/pulseurl 8090:8080 &

# Run all basic tests
./test-middleware.sh \
  --namespace nathan \
  --app-service localhost:8080 \
  --pulseurl-api http://localhost:8090

# Run specific tests
./test-middleware.sh --scenarios baseline,filtering --namespace nathan --verbose
```

**Available basic tests:**
- `baseline` - Verify normal operation
- `filtering` - Verify SkipPaths (health checks not logged)
- `service-id` - Validate service metadata
- `concurrent` - Stress test with 100 parallel requests

#### Sampling Test (Requires Redeployment)

Tests that sample rate configuration works correctly:

```bash
# Step 1: Deploy with 50% sampling
kubectl set env deployment/pulseurl-go-example SAMPLE_RATE=0.5 -n nathan
kubectl rollout restart deployment/pulseurl-go-example -n nathan
kubectl rollout status deployment/pulseurl-go-example -n nathan

# Step 2: Run sampling test
./test-middleware.sh \
  --scenarios sampling \
  --namespace nathan \
  --app-service localhost:8080 \
  --pulseurl-api http://localhost:8090

# Step 3: Restore to 100% sampling
kubectl set env deployment/pulseurl-go-example SAMPLE_RATE=1.0 -n nathan
kubectl rollout restart deployment/pulseurl-go-example -n nathan
```

**Expected results:**
- ~50 events logged to PulseURL (out of 100 sent)
- ~50 events "sampled out" (visible in debug logs)

#### Buffer Overflow Test (Requires Redeployment)

Tests buffer behavior under extreme concurrent load:

```bash
# Step 1: Deploy with small buffer
kubectl set env deployment/pulseurl-go-example BUFFER_SIZE=10 -n nathan
kubectl rollout restart deployment/pulseurl-go-example -n nathan
kubectl rollout status deployment/pulseurl-go-example -n nathan

# Step 2: Run buffer test
./test-middleware.sh \
  --scenarios buffer \
  --namespace nathan \
  --app-service localhost:8080 \
  --pulseurl-api http://localhost:8090

# Step 3: Restore normal buffer size
kubectl set env deployment/pulseurl-go-example BUFFER_SIZE=1000 -n nathan
kubectl rollout restart deployment/pulseurl-go-example -n nathan
```

**Expected results:**
- Less than 100 events logged (some dropped due to buffer overflow)
- "buffer full" warnings in pod logs
- Pod remains healthy (no crashes)

#### Log Analysis

Analyze pod logs to understand middleware behavior:

```bash
./analyze-logs.sh --namespace nathan --service pulseurl-go-example
```

This will show:
- Event queuing and sending patterns
- Buffer usage statistics
- Sampling decisions
- URL filtering behavior
- Errors and warnings

### Manual Testing

```bash
# Port forward to access locally
kubectl port-forward -n nathan svc/pulseurl-go-example 8080:8080 &
kubectl port-forward -n nathan svc/pulseurl 8090:8080 &

# Send requests
curl http://localhost:8080/
curl http://localhost:8080/api/users
curl http://localhost:8080/api/users/123
curl -X POST http://localhost:8080/api/users

# Check PulseURL for logged events
curl http://localhost:8090/api/stats/top?service=pulseurl-gin-example

# View debug logs
kubectl logs -n nathan -l app=pulseurl-go-example | grep DEBUG
```

## Cleanup

```bash
NAMESPACE=dev ./manage.sh k8s-undeploy
```

## Troubleshooting

### Events not appearing in PulseURL

1. Check connectivity between namespaces:
```bash
kubectl exec -n dev deployment/pulseurl-go-example -- \
  nc -zv pulseurl.pulseurl.svc.cluster.local 9090
```

2. Check logs for errors:
```bash
NAMESPACE=dev ./manage.sh k8s-logs
```

3. Verify PulseURL service is running:
```bash
kubectl get pods -n pulseurl -l app=pulseurl
```

### Image pull errors

1. For private registries, create pull secret:
```bash
kubectl create secret docker-registry regcred \
  --docker-server=<your-registry> \
  --docker-username=<username> \
  --docker-password=<password> \
  -n <namespace>
```

2. Add imagePullSecrets to deployment:
```yaml
spec:
  imagePullSecrets:
  - name: regcred
```

## Comprehensive Testing

This example includes comprehensive end-to-end testing scripts that validate middleware behavior in Kubernetes.

### Quick Test

```bash
# Deploy with debug logging
PULSEURL_DEBUG=true NAMESPACE=test ./manage.sh k8s-deploy

# Run test scenarios
./test-middleware.sh --namespace test

# Analyze results
./analyze-logs.sh --namespace test --report results.txt
```

### Testing Scripts

#### test-middleware.sh

Generates traffic and validates middleware behavior through 6 different scenarios.

**Test Scenarios:**
1. **Baseline** - Normal operation with varied traffic
2. **Filtering** - Validates /health and /ready are not logged
3. **Service ID** - Validates service name, namespace, pod_id metadata
4. **Concurrent** - 100 parallel requests stress test
5. **Sampling** - Validates sample rate (requires config)
6. **Buffer Overflow** - Validates buffer behavior (requires config)

**Usage:**
```bash
# Run all tests
./test-middleware.sh --namespace test

# Run specific scenarios
./test-middleware.sh --scenarios baseline,filtering --namespace test

# Verbose mode
./test-middleware.sh --verbose --namespace test
```

**Options:**
- `--namespace <ns>` - Kubernetes namespace
- `--pulseurl-api <url>` - PulseURL API URL (default: http://pulseurl:8080)
- `--app-service <url>` - App service URL (default: pulseurl-go-example:8080)
- `--scenarios <list>` - Comma-separated scenarios (default: all)
- `--verbose` - Enable debug output
- `--help` - Show help

#### analyze-logs.sh

Parses pod logs and cross-references with PulseURL API data.

**What it analyzes:**
- Event flow (sampled → created → queued → sent)
- Buffer usage statistics (avg, max, capacity)
- Sampling behavior
- Filtered paths
- Error analysis and categorization
- PulseURL API cross-reference

**Usage:**
```bash
# Basic analysis
./analyze-logs.sh --namespace test

# Save report
./analyze-logs.sh --namespace test --report analysis.txt

# Analyze last 30 minutes
./analyze-logs.sh --namespace test --window 30
```

**Options:**
- `--namespace <ns>` - Kubernetes namespace
- `--pulseurl-api <url>` - PulseURL API URL
- `--service <name>` - Service name (default: pulseurl-gin-example)
- `--window <minutes>` - Time window for queries (default: 10)
- `--report <file>` - Save report to file
- `--help` - Show help

### Debug Logging

Enable verbose debug output for troubleshooting:

```bash
# Deploy with debug logging
PULSEURL_DEBUG=true NAMESPACE=test ./manage.sh k8s-deploy

# Or enable on running deployment
kubectl set env deployment/pulseurl-go-example PULSEURL_DEBUG=true -n test
kubectl rollout restart deployment/pulseurl-go-example -n test
```

**Debug logs show:**
- Middleware initialization
- Paths skipped by filter
- Events created with full metadata
- Events queued with buffer usage
- Events sent to PulseURL
- Sampling decisions

**View debug logs:**
```bash
# All logs
kubectl logs -n test -l app=pulseurl-go-example

# Only debug level
kubectl logs -n test -l app=pulseurl-go-example | grep "level=DEBUG"

# Follow live
kubectl logs -n test -l app=pulseurl-go-example -f
```

### Advanced Testing

#### Sampling Test

Test with 50% sampling rate:

```bash
# 1. Deploy with sampling
kubectl set env deployment/pulseurl-go-example SAMPLE_RATE=0.5 -n test
kubectl rollout restart deployment/pulseurl-go-example -n test

# 2. Send 100 requests
for i in {1..100}; do curl http://localhost:8080/api/users; done

# 3. Check logs
kubectl logs -l app=pulseurl-go-example -n test | grep "sampled out" | wc -l

# 4. Verify ~50 events in PulseURL
curl "http://pulseurl:8080/api/stats/top?service=pulseurl-gin-example&window=5"
```

#### Buffer Overflow Test

Test with small buffer under load:

```bash
# 1. Deploy with small buffer
kubectl set env deployment/pulseurl-go-example BUFFER_SIZE=10 -n test
kubectl rollout restart deployment/pulseurl-go-example -n test

# 2. Send burst traffic
for i in {1..100}; do curl http://localhost:8080/api/users &; done; wait

# 3. Check for buffer warnings
kubectl logs -l app=pulseurl-go-example -n test | grep "buffer full"
```

### Port Forwarding for Local Testing

If testing from your local machine, set up port forwarding first:

```bash
# Forward app service
kubectl port-forward -n test svc/pulseurl-go-example 8080:8080 &

# Forward PulseURL service
kubectl port-forward -n test svc/pulseurl 8090:8080 &

# Run tests with local URLs
./test-middleware.sh \
  --namespace test \
  --app-service localhost:8080 \
  --pulseurl-api http://localhost:8090
```

### Troubleshooting Tests

**No events in PulseURL:**
```bash
# Check app logs
kubectl logs -l app=pulseurl-go-example -n test | grep ERROR

# Check PulseURL service
kubectl get pods -l app=pulseurl -n test

# Test connectivity
kubectl exec -it <pod-name> -n test -- curl http://pulseurl:9090
```

**Debug logs not showing:**
```bash
# Verify debug flag
kubectl get deployment pulseurl-go-example -n test -o yaml | grep PULSEURL_DEBUG

# Enable if missing
kubectl set env deployment/pulseurl-go-example PULSEURL_DEBUG=true -n test
kubectl rollout restart deployment/pulseurl-go-example -n test
```

**Test scripts can't connect:**
```bash
# Check services
kubectl get svc -n test

# Set up port forwarding
kubectl port-forward -n test svc/pulseurl-go-example 8080:8080 &
kubectl port-forward -n test svc/pulseurl 8090:8080 &
```

### Test Report Example

After running tests, you'll get a report like this:

```
==========================================
           TEST REPORT
==========================================

PASSED (4):
  ✓ Baseline
  ✓ Filtering
  ✓ Filtering-Stats
  ✓ Service-ID
  ✓ Concurrent

FAILED (0):

==========================================
Total: 5 | Passed: 5 | Failed: 0
==========================================
```

### Complete Testing Guide

For comprehensive testing documentation, see:
- [docs/TESTING.md](../../docs/TESTING.md) - Complete testing guide
- [docs/TESTING_PLAN.md](../../docs/TESTING_PLAN.md) - Implementation plan
- [docs/CHAOS_ENGINEERING_REFERENCE.md](../../docs/CHAOS_ENGINEERING_REFERENCE.md) - Advanced resilience testing

## Learn More

- [Main PulseURL repository](https://github.com/pulseurl/pulseurl)
- [PulseURL Go client documentation](../../README.md)
