#!/bin/bash
# test-middleware.sh - Comprehensive middleware testing
# Tests sampling, filtering, buffer overflow, and service identification

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
NAMESPACE="${NAMESPACE:-default}"
PULSEURL_API="${PULSEURL_API:-http://pulseurl:8080}"
APP_SERVICE="${APP_SERVICE:-pulseurl-go-example:8080}"
VERBOSE="${VERBOSE:-false}"
SCENARIOS="${SCENARIOS:-all}"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Test results tracking
declare -a PASSED_TESTS
declare -a FAILED_TESTS

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
    if [ "$VERBOSE" = "true" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
}

# ============================================================================
# Utility Functions
# ============================================================================

# Clear PulseURL data before testing
clear_pulseurl_data() {
    local service="${1:-pulseurl-gin-example}"

    log_info "Clearing PulseURL data for service: $service"

    local response=$(curl -sf -X DELETE \
        "${PULSEURL_API}/api/admin/data?confirm=true&service=${service}" 2>/dev/null)

    if [ $? -eq 0 ]; then
        local deleted=$(echo "$response" | grep -o '"deleted_count":[0-9]*' | cut -d: -f2)
        if [ -n "$deleted" ]; then
            log_success "Cleared $deleted events"
        else
            log_success "Data cleared"
        fi
        sleep 2  # Allow Redis to process
        return 0
    else
        log_warn "Data clear endpoint not available or failed"
        log_info "Tests will run with existing data (may affect results)"
        return 1
    fi
}

# Send HTTP request to app
send_request() {
    local endpoint="$1"
    local method="${2:-GET}"
    local app_url="http://${APP_SERVICE}${endpoint}"

    log_debug "Sending $method request to $app_url"

    if ! curl -sf -X "$method" "$app_url" >/dev/null 2>&1; then
        log_warn "Request to $endpoint failed"
        return 1
    fi
    return 0
}

# Send burst of requests in parallel
send_burst() {
    local count="$1"
    local endpoint="${2:-/api/users}"

    log_debug "Sending burst of $count requests to $endpoint"

    for i in $(seq 1 "$count"); do
        send_request "$endpoint/$i" &
    done
    wait
}

# Wait for events to be processed
wait_for_events() {
    local seconds="${1:-5}"
    log_debug "Waiting ${seconds}s for events to be processed..."
    sleep "$seconds"
}

# ============================================================================
# PulseURL API Query Functions
# ============================================================================

# Query top URLs for a service
query_service_events() {
    local service="$1"
    local window="${2:-5}" # minutes
    local limit="${3:-100}"

    local url="${PULSEURL_API}/api/stats/top?service=${service}&limit=${limit}&window=${window}"
    log_debug "Querying PulseURL: $url"

    curl -sf "$url" 2>/dev/null
}

# Get count for specific URL
get_url_count() {
    local url_path="$1"
    local service="${2:-pulseurl-gin-example}"
    local window="${3:-5}"

    local api_url="${PULSEURL_API}/api/stats/url?url=${url_path}&service=${service}&window=${window}"
    log_debug "Getting URL count: $api_url"

    local response=$(curl -sf "$api_url" 2>/dev/null)
    if [ -n "$response" ]; then
        echo "$response" | grep -o '"count":[0-9]*' | cut -d: -f2
    else
        echo "0"
    fi
}

# Get total count across all URLs for a service
get_total_count() {
    local service="${1:-pulseurl-gin-example}"
    local window="${2:-5}"
    local url_prefix="${3:-}"  # Optional filter by URL prefix

    local response=$(query_service_events "$service" "$window" 1000)

    if [ -z "$response" ]; then
        echo "0"
        return
    fi

    # Sum all counts, optionally filtering by URL prefix
    local total=0
    while IFS= read -r count; do
        if [ -n "$count" ]; then
            total=$((total + count))
        fi
    done < <(echo "$response" | grep -o '"Count":[0-9]*' | cut -d: -f2)

    echo "$total"
}

# ============================================================================
# Validation Functions
# ============================================================================

# Validate event count is within expected range
validate_event_count() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    local tolerance="${4:-0.1}" # 10% default tolerance

    if [ "$actual" -eq 0 ] && [ "$expected" -gt 0 ]; then
        log_error "[$test_name] No events received (expected ~$expected)"
        FAILED_TESTS+=("$test_name")
        return 1
    fi

    # Calculate acceptable range using integer math
    local min=$(echo "scale=0; ($expected * (1 - $tolerance))/1" | bc)
    local max=$(echo "scale=0; ($expected * (1 + $tolerance))/1" | bc)

    if [ "$actual" -ge "$min" ] && [ "$actual" -le "$max" ]; then
        log_success "[$test_name] PASS - Event count: $actual (expected: $expected ±${tolerance})"
        PASSED_TESTS+=("$test_name")
        return 0
    else
        log_error "[$test_name] FAIL - Event count: $actual (expected: $expected ±${tolerance}, range: $min-$max)"
        FAILED_TESTS+=("$test_name")
        return 1
    fi
}

# Check if service is accessible
check_service() {
    log_info "Checking if services are accessible..."

    if ! curl -sf "http://${APP_SERVICE}/health" >/dev/null 2>&1; then
        log_error "App service not accessible at http://${APP_SERVICE}"
        log_info "Try port-forwarding: kubectl port-forward -n $NAMESPACE svc/pulseurl-go-example 8080:8080"
        return 1
    fi

    if ! curl -sf "${PULSEURL_API}/health" >/dev/null 2>&1; then
        log_error "PulseURL service not accessible at ${PULSEURL_API}"
        log_info "Try port-forwarding: kubectl port-forward -n $NAMESPACE svc/pulseurl 8080:8080"
        return 1
    fi

    log_success "Services are accessible"
    return 0
}

# ============================================================================
# Test Scenarios
# ============================================================================

# Scenario 1: Baseline Test
test_baseline() {
    log_info "===== Test 1: Baseline Test ====="
    log_info "Purpose: Verify normal operation"

    local service="pulseurl-gin-example"

    # Send requests to various endpoints
    log_info "Sending 50 requests to various endpoints..."
    for i in $(seq 1 10); do
        send_request "/" &
        send_request "/api/users" &
        send_request "/api/users/$i" &
        send_request "/api/stats" &
        send_request "/health" &  # Should be filtered
    done
    wait

    wait_for_events 10

    # Query PulseURL for events (use 2 minute window to avoid old data)
    log_info "Querying PulseURL for events..."
    local count=$(get_url_count "/" "$service" 2)

    # We sent 10 requests to /, should see ~10 events (health is filtered)
    # Allow higher tolerance since timing can vary
    validate_event_count "Baseline" 10 "$count" 0.5
}

# Scenario 2: Sampling Test
test_sampling() {
    log_info "===== Test 2: Sampling Test ====="
    log_info "Purpose: Validate sample rate (assumes SAMPLE_RATE=0.5 deployment)"

    local service="pulseurl-gin-example"

    log_warn "PREREQUISITE: Deploy with SAMPLE_RATE=0.5 before running this test"
    log_warn "  kubectl set env deployment/pulseurl-go-example SAMPLE_RATE=0.5 -n $NAMESPACE"
    log_warn "  kubectl rollout restart deployment/pulseurl-go-example -n $NAMESPACE"
    echo ""

    # Clear data to isolate this test
    clear_pulseurl_data "$service"

    # Send 100 requests
    log_info "Sending 100 requests to /api/users/:id..."
    for i in $(seq 1 100); do
        send_request "/api/users/$i" &
    done
    wait

    wait_for_events 10

    # Query for events
    log_info "Querying PulseURL for events..."
    local count=$(get_total_count "$service" 5)

    log_info "Total events received: $count (out of 100 sent)"

    # With 50% sampling, expect ~50 events (±30% tolerance due to randomness)
    # Expected range: 35-65 events
    validate_event_count "Sampling" 50 "$count" 0.3

    # Additional check: Query pod logs for "sampled out" messages (if accessible)
    if command -v kubectl &> /dev/null && [ -n "$NAMESPACE" ]; then
        log_info "Checking pod logs for sampling activity..."
        local sampled_out=$(kubectl logs -n "$NAMESPACE" -l app=pulseurl-go-example --tail=500 2>/dev/null | grep -c "sampled out" || echo "0")
        log_info "Events sampled out: ~$sampled_out (from recent logs)"
    fi
}

# Scenario 3: URL Filtering Test
test_filtering() {
    log_info "===== Test 3: URL Filtering Test ====="
    log_info "Purpose: Verify SkipPaths (/health, /ready) are not logged"

    local service="pulseurl-gin-example"

    # Clear data to isolate this test
    clear_pulseurl_data "$service"

    # Send requests to filtered paths
    log_info "Sending 20 requests to /health and /ready (should be filtered)..."
    for i in $(seq 1 10); do
        send_request "/health" &
        send_request "/ready" &
    done
    wait

    # Send requests to normal paths
    log_info "Sending 10 requests to /api/stats (should be logged)..."
    for i in $(seq 1 10); do
        send_request "/api/stats" &
    done
    wait

    wait_for_events 10

    # Query PulseURL
    log_info "Querying PulseURL for events..."
    local health_count=$(get_url_count "/health" "$service")
    local ready_count=$(get_url_count "/ready" "$service")
    local stats_count=$(get_url_count "/api/stats" "$service")

    log_info "Results: /health=$health_count, /ready=$ready_count, /api/stats=$stats_count"

    # Validate: health and ready should have 0 events
    if [ "$health_count" -eq 0 ] && [ "$ready_count" -eq 0 ]; then
        log_success "[Filtering] PASS - Filtered paths not logged"
        PASSED_TESTS+=("Filtering")
    else
        log_error "[Filtering] FAIL - Filtered paths were logged (health=$health_count, ready=$ready_count)"
        FAILED_TESTS+=("Filtering")
    fi

    # Validate: stats should have ~10 events
    validate_event_count "Filtering-Stats" 10 "$stats_count" 0.3
}

# Scenario 4: Buffer Overflow Test
test_buffer_overflow() {
    log_info "===== Test 4: Buffer Overflow Test ====="
    log_info "Purpose: Validate buffer behavior under burst traffic (assumes BUFFER_SIZE=10)"

    local service="pulseurl-gin-example"

    log_warn "PREREQUISITE: Deploy with BUFFER_SIZE=10 before running this test"
    log_warn "  kubectl set env deployment/pulseurl-go-example BUFFER_SIZE=10 -n $NAMESPACE"
    log_warn "  kubectl rollout restart deployment/pulseurl-go-example -n $NAMESPACE"
    echo ""

    # Clear data to isolate this test
    clear_pulseurl_data "$service"

    # Send 100 concurrent requests to overflow the buffer
    log_info "Sending 100 concurrent requests (burst) to overflow buffer..."
    for i in $(seq 1 100); do
        send_request "/api/stats" &
    done
    wait

    wait_for_events 10

    # Query for events
    log_info "Querying PulseURL for events..."
    local count=$(get_total_count "$service" 5)

    log_info "Total events received: $count (out of 100 sent)"

    # With buffer size 10, expect significant event loss under burst
    # We should see fewer than 100 events (some were dropped)
    if [ "$count" -lt 100 ]; then
        log_success "[Buffer-Overflow] PASS - Buffer overflow occurred ($count events logged, $((100 - count)) likely dropped)"
        PASSED_TESTS+=("Buffer-Overflow")
    else
        log_warn "[Buffer-Overflow] UNEXPECTED - All 100 events logged (buffer may not have overflowed)"
        FAILED_TESTS+=("Buffer-Overflow")
    fi

    # Check pod logs for buffer warnings (if kubectl is available)
    if command -v kubectl &> /dev/null && [ -n "$NAMESPACE" ]; then
        log_info "Checking pod logs for buffer warnings..."
        local buffer_warnings=$(kubectl logs -n "$NAMESPACE" -l app=pulseurl-go-example --tail=500 2>/dev/null | grep -i "buffer" | grep -c "full\|overflow\|dropped" || echo "0")

        if [ "$buffer_warnings" -gt 0 ]; then
            log_success "Found $buffer_warnings buffer-related warnings in logs"
        else
            log_warn "No buffer warnings found in recent logs"
        fi

        # Show sample of buffer logs
        log_info "Sample buffer logs:"
        kubectl logs -n "$NAMESPACE" -l app=pulseurl-go-example --tail=500 2>/dev/null | grep -i "buffer" | head -5 || log_info "  (none found)"
    fi
}

# Scenario 5: Service Identification Test
test_service_id() {
    log_info "===== Test 5: Service Identification Test ====="
    log_info "Purpose: Validate service name, namespace, pod_id metadata"

    local service="pulseurl-gin-example"

    # Clear data to isolate this test
    clear_pulseurl_data "$service"

    # Send some requests
    log_info "Sending 5 requests..."
    for i in $(seq 1 5); do
        send_request "/api/users/$i"
    done

    wait_for_events 10

    # Query PulseURL and check response structure
    log_info "Querying PulseURL for service metadata..."
    local response=$(query_service_events "$service" 5 10)

    if echo "$response" | grep -q "\"service\":\"$service\""; then
        log_success "[Service-ID] PASS - Service name correctly set"
        PASSED_TESTS+=("Service-ID")
    else
        log_error "[Service-ID] FAIL - Service name not found in response"
        FAILED_TESTS+=("Service-ID")
        log_debug "Response: $response"
    fi
}

# Scenario 6: Concurrent Load Test
test_concurrent() {
    log_info "===== Test 6: Concurrent Load Test ====="
    log_info "Purpose: Stress test with parallel traffic"

    local service="pulseurl-gin-example"

    # Clear data to isolate this test
    clear_pulseurl_data "$service"

    # Send concurrent bursts
    log_info "Sending 10 parallel bursts of 10 requests each (100 total)..."
    for batch in $(seq 1 10); do
        send_burst 10 "/api/users" &
    done
    wait

    wait_for_events 15

    # Query for total events across all URLs
    log_info "Querying PulseURL for events..."
    local count=$(get_total_count "$service" 5)

    # Should see most of the 100 events (allowing for some loss)
    validate_event_count "Concurrent" 100 "$count" 0.3
}

# ============================================================================
# Main Execution
# ============================================================================

run_all_tests() {
    log_info "Running all test scenarios..."
    echo ""

    test_baseline
    echo ""

    test_filtering
    echo ""

    test_service_id
    echo ""

    test_concurrent
    echo ""

    # Sampling and buffer tests require redeployment
    test_sampling
    echo ""

    test_buffer_overflow
    echo ""
}

generate_report() {
    echo ""
    echo "=========================================="
    echo "           TEST REPORT"
    echo "=========================================="
    echo ""

    local total_passed=${#PASSED_TESTS[@]}
    local total_failed=${#FAILED_TESTS[@]}
    local total=$((total_passed + total_failed))

    if [ $total_passed -gt 0 ]; then
        echo -e "${GREEN}PASSED ($total_passed):${NC}"
        for test in "${PASSED_TESTS[@]}"; do
            echo "  ✓ $test"
        done
        echo ""
    fi

    if [ $total_failed -gt 0 ]; then
        echo -e "${RED}FAILED ($total_failed):${NC}"
        for test in "${FAILED_TESTS[@]}"; do
            echo "  ✗ $test"
        done
        echo ""
    fi

    echo "=========================================="
    echo -e "Total: $total | ${GREEN}Passed: $total_passed${NC} | ${RED}Failed: $total_failed${NC}"
    echo "=========================================="
    echo ""

    if [ $total_failed -gt 0 ]; then
        return 1
    fi
    return 0
}

show_help() {
    cat <<EOF
PulseURL Middleware Testing Script

Usage: ./test-middleware.sh [OPTIONS]

OPTIONS:
    --namespace <ns>      Kubernetes namespace (default: default)
    --pulseurl-api <url>  PulseURL API URL (default: http://pulseurl:8080)
    --app-service <url>   App service URL (default: pulseurl-go-example:8080)
    --scenarios <list>    Comma-separated scenarios to run (default: all)
                         Options: baseline,filtering,service-id,concurrent,sampling,buffer,all
    --verbose            Enable verbose debug output
    --help               Show this help message

ENVIRONMENT VARIABLES:
    NAMESPACE            Kubernetes namespace
    PULSEURL_API         PulseURL API base URL
    APP_SERVICE          App service URL
    VERBOSE              Enable verbose mode (true/false)

EXAMPLES:
    # Run all tests (except sampling and buffer which need special deployment)
    ./test-middleware.sh

    # Run specific tests
    ./test-middleware.sh --scenarios baseline,filtering

    # Run sampling test (after deploying with SAMPLE_RATE=0.5)
    kubectl set env deployment/pulseurl-go-example SAMPLE_RATE=0.5 -n nathan
    kubectl rollout restart deployment/pulseurl-go-example -n nathan
    ./test-middleware.sh --scenarios sampling --namespace nathan

    # Run buffer overflow test (after deploying with BUFFER_SIZE=10)
    kubectl set env deployment/pulseurl-go-example BUFFER_SIZE=10 -n nathan
    kubectl rollout restart deployment/pulseurl-go-example -n nathan
    ./test-middleware.sh --scenarios buffer --namespace nathan

    # Verbose mode
    ./test-middleware.sh --verbose

PREREQUISITES:
    - App deployed to Kubernetes
    - PulseURL service running and accessible
    - Services accessible via port-forward or in-cluster
    - For sampling test: Deploy with SAMPLE_RATE=0.5
    - For buffer test: Deploy with BUFFER_SIZE=10

EOF
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --pulseurl-api)
                PULSEURL_API="$2"
                shift 2
                ;;
            --app-service)
                APP_SERVICE="$2"
                shift 2
                ;;
            --scenarios)
                SCENARIOS="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE="true"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    log_info "PulseURL Middleware Testing"
    log_info "Namespace: $NAMESPACE"
    log_info "PulseURL API: $PULSEURL_API"
    log_info "App Service: $APP_SERVICE"
    echo ""

    # Check services
    if ! check_service; then
        exit 1
    fi
    echo ""

    # Clear PulseURL data for clean test run
    clear_pulseurl_data "pulseurl-gin-example"
    echo ""

    # Run tests
    if [ "$SCENARIOS" = "all" ]; then
        run_all_tests
    else
        IFS=',' read -ra SCENARIO_LIST <<< "$SCENARIOS"
        for scenario in "${SCENARIO_LIST[@]}"; do
            case "$scenario" in
                baseline) test_baseline ;;
                filtering) test_filtering ;;
                service-id) test_service_id ;;
                concurrent) test_concurrent ;;
                sampling) test_sampling ;;
                buffer) test_buffer_overflow ;;
                *) log_error "Unknown scenario: $scenario" ;;
            esac
            echo ""
        done
    fi

    # Generate report
    generate_report
}

main "$@"
