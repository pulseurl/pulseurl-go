#!/bin/bash
# analyze-logs.sh - Analyze pod logs and cross-reference with PulseURL data
# Parses structured logs to validate middleware behavior

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
NAMESPACE="${NAMESPACE:-default}"
PULSEURL_API="${PULSEURL_API:-http://pulseurl:8080}"
SERVICE_NAME="${SERVICE_NAME:-pulseurl-gin-example}"
REPORT_FILE="${REPORT_FILE:-}"
TIME_WINDOW="${TIME_WINDOW:-10}" # minutes

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

log_section() {
    echo ""
    echo "=========================================="
    echo "$*"
    echo "=========================================="
}

# ============================================================================
# Log Retrieval Functions
# ============================================================================

# Get all logs from pods
get_pod_logs() {
    kubectl logs -n "$NAMESPACE" -l app=pulseurl-go-example --tail=10000 2>/dev/null || {
        log_error "Failed to retrieve pod logs"
        return 1
    }
}

# Get only debug logs
get_debug_logs() {
    get_pod_logs | grep 'level=DEBUG' 2>/dev/null || true
}

# Get warning logs
get_warn_logs() {
    get_pod_logs | grep 'level=WARN' 2>/dev/null || true
}

# Get error logs
get_error_logs() {
    get_pod_logs | grep 'level=ERROR' 2>/dev/null || true
}

# ============================================================================
# Log Parsing Functions
# ============================================================================

# Count occurrences of a pattern in logs
count_pattern() {
    local pattern="$1"
    local logs="${2:-$(get_pod_logs)}"

    echo "$logs" | grep -c "$pattern" 2>/dev/null || echo "0"
}

# Extract field value from structured logs
extract_field() {
    local field="$1"
    local logs="${2:-$(get_pod_logs)}"

    echo "$logs" | grep "$field=" | sed "s/.*$field=\([^ ]*\).*/\1/" 2>/dev/null || true
}

# Count unique URLs in logs
count_unique_urls() {
    local logs="${1:-$(get_debug_logs)}"

    echo "$logs" | grep 'url=' | sed 's/.*url=\([^ ]*\).*/\1/' | sort -u | wc -l
}

# ============================================================================
# Analysis Functions
# ============================================================================

# Analyze event flow through the system
analyze_event_flow() {
    log_section "Event Flow Analysis"

    local all_logs=$(get_pod_logs)
    local debug_logs=$(get_debug_logs)

    # Count different event states
    local sampled_out=$(count_pattern "event sampled out" "$debug_logs")
    local path_skipped=$(count_pattern "path skipped by filter" "$debug_logs")
    local events_created=$(count_pattern "event created" "$debug_logs")
    local events_queued=$(count_pattern "event queued" "$debug_logs")
    local events_sent=$(count_pattern "event sent to PulseURL" "$debug_logs")
    local buffer_full=$(count_pattern "event buffer full" "$all_logs")

    echo ""
    echo "Event Lifecycle:"
    echo "  Sampled Out:       $sampled_out"
    echo "  Path Skipped:      $path_skipped"
    echo "  Events Created:    $events_created"
    echo "  Events Queued:     $events_queued"
    echo "  Events Sent:       $events_sent"
    echo "  Buffer Full:       $buffer_full"
    echo ""

    # Validation
    local expected_sent=$((events_queued - buffer_full))
    if [ "$events_sent" -eq "$expected_sent" ]; then
        log_success "✓ Event flow is consistent"
        echo "  Queued ($events_queued) - Dropped ($buffer_full) = Sent ($events_sent)"
    elif [ "$events_sent" -gt 0 ]; then
        log_warn "⚠ Event flow has minor inconsistencies"
        echo "  Expected: $expected_sent sent, Actual: $events_sent"
        echo "  Note: This may be normal due to async processing"
    else
        log_error "✗ No events were sent to PulseURL"
        echo "  This indicates a problem with the client or PulseURL service"
    fi
    echo ""
}

# Analyze buffer usage patterns
analyze_buffer_usage() {
    log_section "Buffer Usage Analysis"

    local debug_logs=$(get_debug_logs)
    local buffer_logs=$(echo "$debug_logs" | grep "buffer_usage=" 2>/dev/null || true)

    if [ -z "$buffer_logs" ]; then
        log_warn "No buffer usage logs found"
        echo "  Debug logging may not be enabled"
        echo "  Enable with: PULSEURL_DEBUG=true"
        return
    fi

    # Extract buffer usage values
    local usage_values=$(echo "$buffer_logs" | grep -o 'buffer_usage=[0-9]*' | cut -d= -f2)
    local capacity_values=$(echo "$buffer_logs" | grep -o 'buffer_capacity=[0-9]*' | cut -d= -f2 | head -1)

    if [ -z "$usage_values" ]; then
        log_warn "Could not parse buffer usage values"
        return
    fi

    # Calculate statistics
    local avg=$(echo "$usage_values" | awk '{sum+=$1; count++} END {if(count>0) print int(sum/count); else print 0}')
    local max=$(echo "$usage_values" | sort -n | tail -1)
    local min=$(echo "$usage_values" | sort -n | head -1)
    local capacity="${capacity_values:-unknown}"

    echo ""
    echo "Buffer Statistics:"
    echo "  Capacity:    $capacity"
    echo "  Average:     $avg"
    echo "  Maximum:     $max"
    echo "  Minimum:     $min"

    if [ "$capacity" != "unknown" ] && [ "$max" -eq "$capacity" ]; then
        log_warn "⚠ Buffer reached full capacity"
        echo "  Consider increasing buffer size or reducing traffic"
    elif [ "$capacity" != "unknown" ] && [ "$max" -gt $((capacity * 80 / 100)) ]; then
        log_warn "⚠ Buffer usage exceeded 80%"
        echo "  Maximum usage: $max / $capacity ($(( max * 100 / capacity ))%)"
    else
        log_success "✓ Buffer usage is healthy"
    fi
    echo ""
}

# Analyze sampling behavior
analyze_sampling() {
    log_section "Sampling Analysis"

    local debug_logs=$(get_debug_logs)
    local sampled_out=$(count_pattern "event sampled out" "$debug_logs")
    local events_created=$(count_pattern "event created" "$debug_logs")

    if [ "$sampled_out" -eq 0 ]; then
        log_info "No sampling detected (sample rate likely 1.0)"
        echo "  All events are being logged"
    else
        local total_requests=$((events_created + sampled_out))
        local actual_rate=$(echo "scale=2; $events_created * 100 / $total_requests" | bc)

        echo ""
        echo "Sampling Statistics:"
        echo "  Total Requests:    $total_requests"
        echo "  Events Created:    $events_created"
        echo "  Sampled Out:       $sampled_out"
        echo "  Effective Rate:    ${actual_rate}%"
        echo ""

        log_success "✓ Sampling is active"
    fi
    echo ""
}

# Analyze filtered paths
analyze_filtered_paths() {
    log_section "Path Filtering Analysis"

    local debug_logs=$(get_debug_logs)
    local skipped_count=$(count_pattern "path skipped by filter" "$debug_logs")

    if [ "$skipped_count" -eq 0 ]; then
        log_info "No paths were filtered"
        echo "  SkipPaths may be empty or no filtered paths were accessed"
    else
        echo ""
        echo "Filtered Paths:"
        echo "  Total Skipped:     $skipped_count"
        echo ""

        # Show which paths were skipped
        local paths=$(echo "$debug_logs" | grep "path skipped" | grep -o 'path=[^ ]*' | cut -d= -f2 | sort | uniq -c | sort -rn)

        if [ -n "$paths" ]; then
            echo "  Path Breakdown:"
            echo "$paths" | while read -r count path; do
                echo "    $path: $count times"
            done
        fi

        log_success "✓ Path filtering is working"
    fi
    echo ""
}

# Analyze errors
analyze_errors() {
    log_section "Error Analysis"

    local error_logs=$(get_error_logs)
    local error_count=$(echo "$error_logs" | wc -l)

    if [ "$error_count" -eq 0 ]; then
        log_success "✓ No errors found"
        return
    fi

    echo ""
    echo "Errors Found: $error_count"
    echo ""

    # Categorize errors
    local grpc_errors=$(count_pattern "failed to send event" "$error_logs")
    local connection_errors=$(count_pattern "connection" "$error_logs")
    local timeout_errors=$(count_pattern "timeout\|deadline" "$error_logs")

    if [ "$grpc_errors" -gt 0 ]; then
        echo "  gRPC Send Errors:  $grpc_errors"
    fi

    if [ "$connection_errors" -gt 0 ]; then
        echo "  Connection Errors: $connection_errors"
    fi

    if [ "$timeout_errors" -gt 0 ]; then
        echo "  Timeout Errors:    $timeout_errors"
    fi

    # Show sample errors
    echo ""
    echo "Sample Errors (last 3):"
    echo "$error_logs" | tail -3 | sed 's/^/  /'

    if [ "$grpc_errors" -gt 0 ] || [ "$connection_errors" -gt 0 ]; then
        log_warn "⚠ Connection issues detected"
        echo "  Check PulseURL service availability"
    fi
    echo ""
}

# Cross-reference with PulseURL API
analyze_pulseurl_data() {
    log_section "PulseURL API Cross-Reference"

    # Query PulseURL for events
    local api_url="${PULSEURL_API}/api/stats/top?service=${SERVICE_NAME}&limit=100&window=${TIME_WINDOW}"
    local response=$(curl -sf "$api_url" 2>/dev/null)

    if [ -z "$response" ]; then
        log_warn "Could not query PulseURL API"
        echo "  URL: $api_url"
        echo "  Check if PulseURL service is accessible"
        return
    fi

    # Count events from API
    local api_event_count=$(echo "$response" | grep -o '"count":[0-9]*' | cut -d: -f2 | awk '{sum+=$1} END {print sum}')

    # Count events sent from logs
    local debug_logs=$(get_debug_logs)
    local log_event_count=$(count_pattern "event sent to PulseURL" "$debug_logs")

    echo ""
    echo "Event Counts:"
    echo "  From Logs (sent):  $log_event_count"
    echo "  From API (stored): $api_event_count"
    echo ""

    if [ "$api_event_count" -gt 0 ]; then
        log_success "✓ Events are being stored in PulseURL"

        # Show top URLs
        echo "Top URLs (from PulseURL):"
        echo "$response" | grep -o '"URL":"[^"]*","Service":"[^"]*","Count":[0-9]*' | head -5 | while IFS= read -r line; do
            local url=$(echo "$line" | sed 's/.*"URL":"\([^"]*\)".*/\1/')
            local count=$(echo "$line" | sed 's/.*"Count":\([0-9]*\).*/\1/')
            echo "  $url: $count events"
        done
    else
        log_warn "⚠ No events found in PulseURL"
        echo "  Events may not have been processed yet"
    fi
    echo ""
}

# Generate summary report
generate_summary() {
    log_section "Summary"

    local all_logs=$(get_pod_logs)
    local debug_logs=$(get_debug_logs)

    local events_created=$(count_pattern "event created" "$debug_logs")
    local events_sent=$(count_pattern "event sent to PulseURL" "$debug_logs")
    local errors=$(get_error_logs | wc -l)
    local warnings=$(get_warn_logs | wc -l)

    echo ""
    echo "Overall Statistics:"
    echo "  Events Created:    $events_created"
    echo "  Events Sent:       $events_sent"
    echo "  Warnings:          $warnings"
    echo "  Errors:            $errors"
    echo ""

    # Health assessment
    if [ "$errors" -eq 0 ] && [ "$events_sent" -gt 0 ]; then
        log_success "✓✓✓ Middleware is operating correctly"
    elif [ "$events_sent" -gt 0 ]; then
        log_warn "⚠ Middleware is working but has some issues"
    else
        log_error "✗ Middleware may not be functioning properly"
    fi
    echo ""
}

# ============================================================================
# Main Execution
# ============================================================================

show_help() {
    cat <<EOF
PulseURL Log Analysis Script

Analyzes pod logs and cross-references with PulseURL API to validate
middleware behavior and troubleshoot issues.

Usage: ./analyze-logs.sh [OPTIONS]

OPTIONS:
    --namespace <ns>      Kubernetes namespace (default: default)
    --pulseurl-api <url>  PulseURL API URL (default: http://pulseurl:8080)
    --service <name>      Service name (default: pulseurl-gin-example)
    --window <minutes>    Time window for queries (default: 10)
    --report <file>       Save report to file
    --help                Show this help message

ENVIRONMENT VARIABLES:
    NAMESPACE            Kubernetes namespace
    PULSEURL_API         PulseURL API base URL
    SERVICE_NAME         Service name to query
    TIME_WINDOW          Time window in minutes
    REPORT_FILE          Output file for report

EXAMPLES:
    # Basic analysis
    ./analyze-logs.sh

    # With custom namespace
    ./analyze-logs.sh --namespace test

    # Save report to file
    ./analyze-logs.sh --report analysis-report.txt

    # Analyze last 30 minutes
    ./analyze-logs.sh --window 30

PREREQUISITES:
    - kubectl configured and connected to cluster
    - App deployed with debug logging enabled (PULSEURL_DEBUG=true)
    - PulseURL service accessible for API queries

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
            --service)
                SERVICE_NAME="$2"
                shift 2
                ;;
            --window)
                TIME_WINDOW="$2"
                shift 2
                ;;
            --report)
                REPORT_FILE="$2"
                shift 2
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

    # Header
    log_section "PulseURL Middleware Log Analysis"
    echo ""
    echo "Configuration:"
    echo "  Namespace:     $NAMESPACE"
    echo "  Service:       $SERVICE_NAME"
    echo "  PulseURL API:  $PULSEURL_API"
    echo "  Time Window:   ${TIME_WINDOW}m"
    if [ -n "$REPORT_FILE" ]; then
        echo "  Report File:   $REPORT_FILE"
    fi
    echo ""

    # Execute analysis
    {
        analyze_event_flow
        analyze_buffer_usage
        analyze_sampling
        analyze_filtered_paths
        analyze_errors
        analyze_pulseurl_data
        generate_summary
    } | if [ -n "$REPORT_FILE" ]; then
        tee "$REPORT_FILE"
    else
        cat
    fi

    if [ -n "$REPORT_FILE" ]; then
        log_success "Report saved to: $REPORT_FILE"
    fi
}

main "$@"
