#!/bin/bash
# PulseURL Go Middleware - Kubernetes Example Manager
# Follows nginx-dev-gateway pattern for consistency

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration from environment
REGISTRY="${REGISTRY:-}"                       # e.g., myregistry.io/myorg
NAMESPACE="${NAMESPACE:-default}"              # K8s namespace
IMAGE_NAME="${IMAGE_NAME:-pulseurl-go-example}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
PULSEURL_SERVICE="${PULSEURL_SERVICE:-pulseurl:9090}"  # PulseURL gRPC endpoint
SERVICE_NAME="${SERVICE_NAME:-pulseurl-gin-example}"
ENVIRONMENT="${ENVIRONMENT:-production}"

# Service port
HTTP_PORT="${HTTP_PORT:-8080}"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_debug() {
    if [ "${DEBUG:-0}" = "1" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
    fi
}

# Build full image name
get_full_image() {
    if [ -n "$REGISTRY" ]; then
        echo "$REGISTRY/$IMAGE_NAME:$IMAGE_TAG"
    else
        echo "$IMAGE_NAME:$IMAGE_TAG"
    fi
}

# Check prerequisites
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi
}

check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed"
        exit 1
    fi
}

check_go() {
    if ! command -v go &> /dev/null; then
        log_error "Go is not installed"
        exit 1
    fi
}

# ============================================================================
# Docker Commands
# ============================================================================

cmd_build() {
    check_docker
    log_info "Building Docker image: $(get_full_image)"
    # Build from parent directory (pulseurl-go) to include the module
    docker build -f "$SCRIPT_DIR/Dockerfile" -t "$(get_full_image)" "$SCRIPT_DIR/../.."
    log_success "Build complete"
}

cmd_push() {
    check_docker
    if [ -z "$REGISTRY" ]; then
        log_error "REGISTRY environment variable required for push"
        exit 1
    fi
    log_info "Pushing image: $(get_full_image)"
    docker push "$(get_full_image)"
    log_success "Push complete"
}

# ============================================================================
# Local Development Commands
# ============================================================================

cmd_run() {
    check_go
    log_info "Running example locally..."
    log_info "PulseURL service: $PULSEURL_SERVICE"
    cd "$SCRIPT_DIR" && go run main.go
}

# ============================================================================
# Kubernetes Commands
# ============================================================================

cmd_k8s_deploy() {
    check_kubectl
    log_info "Deploying to namespace: $NAMESPACE"

    # Create namespace if needed
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Create temporary manifests directory
    local temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT

    # Generate manifests with environment substitution
    export FULL_IMAGE=$(get_full_image)
    export PULSEURL_SERVICE SERVICE_NAME ENVIRONMENT HTTP_PORT

    # Check if k8s directory exists
    if [ ! -d "$SCRIPT_DIR/k8s" ]; then
        log_error "k8s/ directory not found"
        exit 1
    fi

    # Apply manifests
    for file in "$SCRIPT_DIR/k8s"/*.yaml; do
        if [ -f "$file" ]; then
            cat "$file" | envsubst > "$temp_dir/$(basename $file)"
            kubectl apply -f "$temp_dir/$(basename $file)" -n "$NAMESPACE"
        fi
    done

    log_success "Deployment complete"
    log_info "Check status: ./manage.sh k8s-status"
    log_info "View logs: ./manage.sh k8s-logs -f"
}

cmd_k8s_undeploy() {
    check_kubectl
    log_info "Removing from namespace: $NAMESPACE"

    if [ -d "$SCRIPT_DIR/k8s" ]; then
        kubectl delete -f "$SCRIPT_DIR/k8s/" -n "$NAMESPACE" --ignore-not-found=true
    fi

    log_success "Undeployment complete"
}

cmd_k8s_status() {
    check_kubectl
    log_info "Status in namespace: $NAMESPACE"
    kubectl get pods,svc,deploy -n "$NAMESPACE" -l app=pulseurl-go-example
}

cmd_k8s_logs() {
    check_kubectl
    local follow="${1:-}"
    if [ "$follow" = "-f" ] || [ "$follow" = "--follow" ]; then
        kubectl logs -n "$NAMESPACE" -l app=pulseurl-go-example -f
    else
        kubectl logs -n "$NAMESPACE" -l app=pulseurl-go-example --tail=100
    fi
}

cmd_k8s_port_forward() {
    check_kubectl
    local local_port="${1:-8080}"

    log_info "Port forwarding..."
    log_info "  HTTP: localhost:$local_port -> $HTTP_PORT"
    log_info "Press Ctrl+C to stop"

    kubectl port-forward -n "$NAMESPACE" svc/pulseurl-go-example "$local_port:$HTTP_PORT"
}

cmd_k8s_restart() {
    check_kubectl
    log_info "Restarting deployment in namespace: $NAMESPACE"
    kubectl rollout restart deployment/pulseurl-go-example -n "$NAMESPACE"
    kubectl rollout status deployment/pulseurl-go-example -n "$NAMESPACE"
    log_success "Restart complete"
}

# ============================================================================
# Testing Commands
# ============================================================================

cmd_test() {
    log_info "Testing deployed application..."

    # Check if running locally or need port-forward
    local test_url="http://localhost:$HTTP_PORT"

    log_info "Checking if service is accessible..."
    if ! curl -sf "$test_url/health" > /dev/null 2>&1; then
        log_warn "Service not accessible locally, trying port-forward..."

        # Start port-forward in background
        kubectl port-forward -n "$NAMESPACE" svc/pulseurl-go-example 8080:$HTTP_PORT &
        local pf_pid=$!
        trap "kill $pf_pid 2>/dev/null || true" EXIT

        sleep 3
        test_url="http://localhost:8080"
    fi

    log_info "Sending test requests..."

    echo ""
    log_info "Test 1: Health check"
    curl -s "$test_url/health" | jq . || curl -s "$test_url/health"

    echo ""
    log_info "Test 2: Root endpoint"
    curl -s "$test_url/" | jq . || curl -s "$test_url/"

    echo ""
    log_info "Test 3: List users"
    curl -s "$test_url/api/users" | jq . || curl -s "$test_url/api/users"

    echo ""
    log_info "Test 4: Get specific user"
    curl -s "$test_url/api/users/42" | jq . || curl -s "$test_url/api/users/42"

    echo ""
    log_info "Test 5: Create user"
    curl -s -X POST "$test_url/api/users" | jq . || curl -s -X POST "$test_url/api/users"

    echo ""
    log_success "Test complete. Check PulseURL service for logged events."
}

# ============================================================================
# Help
# ============================================================================

cmd_help() {
    cat << EOF
PulseURL Go Middleware - Kubernetes Example Manager

Usage: ./manage.sh [COMMAND] [OPTIONS]

DOCKER COMMANDS:
    build              Build Docker image
    push               Push to registry (requires REGISTRY env var)

LOCAL DEVELOPMENT:
    run                Run example locally with go run

KUBERNETES:
    k8s-deploy         Deploy to Kubernetes
    k8s-undeploy       Remove from Kubernetes
    k8s-status         Show deployment status
    k8s-logs [-f]      View logs (optional: -f to follow)
    k8s-port-forward [PORT]  Port forward to local (default: 8080)
    k8s-restart        Restart deployment

TESTING:
    test               Test deployed application

OTHER:
    help               Show this help message

ENVIRONMENT VARIABLES:
    REGISTRY           Docker registry URL (e.g., myregistry.io/myorg)
    NAMESPACE          Kubernetes namespace (default: default)
    IMAGE_NAME         Docker image name (default: pulseurl-go-example)
    IMAGE_TAG          Image tag (default: latest)
    PULSEURL_SERVICE   PulseURL gRPC endpoint (default: pulseurl:9090)
    SERVICE_NAME       Service identifier (default: pulseurl-gin-example)
    ENVIRONMENT        Environment name (default: production)
    HTTP_PORT          HTTP server port (default: 8080)
    DEBUG              Enable debug output (0/1)

EXAMPLES:
    # Local development
    PULSEURL_SERVICE=localhost:9090 ./manage.sh run

    # Build and deploy locally
    ./manage.sh build
    NAMESPACE=dev ./manage.sh k8s-deploy

    # Build, push, deploy to production
    REGISTRY=myregistry.io/myorg IMAGE_TAG=v1.0.0 NAMESPACE=prod ./manage.sh build push k8s-deploy

    # Check status and logs
    NAMESPACE=dev ./manage.sh k8s-status
    NAMESPACE=dev ./manage.sh k8s-logs -f

    # Test the deployment
    NAMESPACE=dev ./manage.sh test

    # Port forward for local access
    NAMESPACE=dev ./manage.sh k8s-port-forward 8080

For more information, see: https://github.com/pulseurl/pulseurl-go

EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        # Docker
        build)              cmd_build ;;
        push)               cmd_push ;;

        # Local dev
        run)                cmd_run ;;

        # Kubernetes
        k8s-deploy)         cmd_k8s_deploy ;;
        k8s-undeploy)       cmd_k8s_undeploy ;;
        k8s-status)         cmd_k8s_status ;;
        k8s-logs)           cmd_k8s_logs "$@" ;;
        k8s-port-forward|k8s-pf) cmd_k8s_port_forward "$@" ;;
        k8s-restart)        cmd_k8s_restart ;;

        # Testing
        test)               cmd_test ;;

        # Help
        help|--help|-h)     cmd_help ;;

        *)
            log_error "Unknown command: $command"
            echo "Run './manage.sh help' for usage information"
            exit 1
            ;;
    esac
}

main "$@"
