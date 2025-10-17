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
- `SERVICE_NAME` - Service identifier (default: `pulseurl-gin-example`)
- `ENVIRONMENT` - Environment name (default: `production`)
- `HTTP_PORT` - HTTP server port (default: `8080`)

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

```bash
# Port forward to access locally
NAMESPACE=dev ./manage.sh k8s-port-forward 8080

# In another terminal, send requests
curl http://localhost:8080/
curl http://localhost:8080/api/users
curl http://localhost:8080/api/users/123
curl -X POST http://localhost:8080/api/users

# Check PulseURL for logged events
kubectl port-forward -n pulseurl svc/pulseurl 8080:8080
curl http://localhost:8080/api/stats/top
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

## Learn More

- [Main PulseURL repository](https://github.com/pulseurl/pulseurl)
- [PulseURL Go client documentation](../../README.md)
