# Chaos Engineering Reference for PulseURL Middleware

- **Status**: Reference/Future Learning
- **Purpose**: Educational reference for implementing chaos testing
- **Implementation Priority**: Low (learn when ready)
- **Created**: 2025-10-24

> **Note**: This document is for future reference and learning. Chaos engineering is NOT required for the current testing plan. Implement these concepts only when you want to learn about system resilience testing.

## Table of Contents

- [What is Chaos Engineering?](#what-is-chaos-engineering)
- [Why Chaos Engineering?](#why-chaos-engineering)
- [Chaos Scenarios for PulseURL Middleware](#chaos-scenarios-for-pulseurl-middleware)
- [Tools & Setup](#tools--setup)
- [Example Implementations](#example-implementations)
- [Learning Resources](#learning-resources)

## What is Chaos Engineering?

**Chaos Engineering** is the discipline of experimenting on a system to build confidence in its ability to withstand turbulent conditions in production.

### Core Principles

1. **Build a Hypothesis**: Define normal/steady-state behavior
2. **Inject Real-World Failures**: Simulate realistic production failures
3. **Observe the System**: Monitor how it responds to chaos
4. **Learn & Improve**: Fix weaknesses discovered

### Origin Story

- **Created by**: Netflix (2010)
- **Tool**: Chaos Monkey - randomly terminates production instances
- **Goal**: Ensure Netflix could survive AWS instance failures
- **Result**: Massively improved system resilience

### Philosophy

> "The best way to avoid failure is to fail constantly." - Netflix

By intentionally breaking things in controlled ways, you discover weaknesses before they cause real outages.

## Why Chaos Engineering?

### For PulseURL Middleware Specifically

The middleware makes several **resilience promises**:

1. ✓ **Non-blocking**: Never slows down HTTP request handling
2. ✓ **Async buffering**: Handles traffic bursts gracefully
3. ✓ **Retry logic**: Recovers from transient PulseURL failures
4. ✓ **Graceful degradation**: Works even if PulseURL is down
5. ✓ **Graceful shutdown**: Drains buffer before closing

**Chaos engineering validates these promises** under real failure conditions.

### What You Learn

- How the system behaves when dependencies fail
- Whether your error handling actually works
- If your observability (logging) is sufficient
- Hidden race conditions or edge cases
- True capacity limits

### When to Use Chaos Engineering

✅ **Good Times to Use It**:
- After functional tests pass
- Before production deployments
- To understand system limits
- To validate resilience claims
- Learning about distributed systems

❌ **Don't Use It When**:
- Basic functionality doesn't work yet
- No monitoring/observability in place
- You're just getting started
- Testing in production without safeguards

## Chaos Scenarios for PulseURL Middleware

### Scenario 1: PulseURL Service Failure

**What Fails**: PulseURL gRPC service becomes unavailable

**How to Simulate**:
```bash
# Kill PulseURL service pod
kubectl delete pod -l app=pulseurl -n $NAMESPACE

# Or scale to zero
kubectl scale deployment pulseurl --replicas=0 -n $NAMESPACE
```

**Expected Behavior**:
- ✓ Events queue in buffer (up to `BufferSize`)
- ✓ HTTP requests continue processing (non-blocking)
- ✓ Client retries with exponential backoff
- ✓ Errors logged but no crashes
- ✓ When PulseURL recovers, buffered events are sent

**What You Learn**:
- Does the middleware truly not block HTTP requests?
- Does the buffer work as designed?
- Are retry backoffs reasonable?
- What happens when buffer fills up?

**Validation**:
```bash
# Send traffic during chaos
for i in {1..100}; do
  curl http://app:8080/api/users
done

# Check HTTP response times (should still be fast)
# Check logs for retry attempts
kubectl logs -l app=pulseurl-go-example | grep "retry"

# Verify events eventually sent after recovery
```

---

### Scenario 2: Network Latency

**What Fails**: Network between middleware and PulseURL is slow

**How to Simulate**:
```bash
# Using Chaos Mesh
kubectl apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: network-latency
  namespace: default
spec:
  action: delay
  mode: one
  selector:
    namespaces:
      - default
    labelSelectors:
      app: pulseurl-go-example
  delay:
    latency: "1000ms"
    correlation: "100"
    jitter: "0ms"
  duration: "2m"
  direction: to
  target:
    selector:
      namespaces:
        - default
      labelSelectors:
        app: pulseurl
    mode: one
EOF
```

**Expected Behavior**:
- ✓ gRPC calls timeout (after configured timeout: 2s default)
- ✓ Retry logic engages
- ✓ Buffer may fill if latency persists
- ✓ HTTP requests remain fast (not blocked by slow gRPC)

**What You Learn**:
- Are timeouts configured appropriately?
- Does the async design truly isolate HTTP from gRPC?
- How does the buffer behave under sustained slow connections?

---

### Scenario 3: Pod Crashes/Restarts

**What Fails**: Middleware pod crashes during operation

**How to Simulate**:
```bash
# Force kill pod
kubectl delete pod -l app=pulseurl-go-example --force --grace-period=0

# Or send OOM signal
kubectl exec -it $POD_NAME -- kill -9 1
```

**Expected Behavior**:
- ✓ Events in buffer at crash time are lost (acceptable trade-off)
- ✓ Kubernetes restarts pod via deployment
- ✓ New pod processes new requests
- ✓ No cascading failures
- ✓ Lost events are minimal (only in-flight buffer)

**What You Learn**:
- How much data is lost during crashes?
- How fast does recovery happen?
- Are graceful shutdown handlers working?

**Note**: This scenario reveals the trade-off of in-memory buffering vs. persistence.

---

### Scenario 4: Resource Exhaustion

**What Fails**: CPU or memory limits are hit

**How to Simulate**:
```bash
# Set very restrictive limits
kubectl set resources deployment pulseurl-go-example \
  --limits=cpu=50m,memory=64Mi \
  --requests=cpu=50m,memory=64Mi

# Generate high load
hey -n 10000 -c 100 http://app:8080/api/users
```

**Expected Behavior**:
- ✓ CPU throttling may slow processing
- ✓ Memory limit may cause OOM kills
- ✓ Buffer drops events when full (documented behavior)
- ✓ System remains stable (no memory leaks)
- ✓ Logs show buffer pressure warnings

**What You Learn**:
- What are realistic resource requirements?
- Are there memory leaks?
- How does the system degrade under pressure?

---

### Scenario 5: Partial Service Degradation

**What Fails**: PulseURL returns errors intermittently (50% failure rate)

**How to Simulate**:
```bash
# Using Chaos Mesh HTTP fault injection
kubectl apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: HTTPChaos
metadata:
  name: pulseurl-errors
spec:
  mode: one
  selector:
    namespaces:
      - default
    labelSelectors:
      app: pulseurl
  target: Request
  port: 9090
  abort: true
  duration: "2m"
EOF
```

**Expected Behavior**:
- ✓ Retries engage for failed requests
- ✓ Successful requests complete normally
- ✓ Max retries limit prevents infinite loops
- ✓ Appropriate errors logged

**What You Learn**:
- Is retry logic working correctly?
- Are exponential backoffs reasonable?
- Should you implement circuit breakers?

---

### Scenario 6: DNS Resolution Failures

**What Fails**: Service discovery breaks (can't resolve `pulseurl:9090`)

**How to Simulate**:
```bash
# Deploy with wrong service URL
helm upgrade pulseurl-go-example . \
  --set env.PULSEURL_SERVICE=nonexistent-service:9090

# Or use NetworkChaos to break DNS
```

**Expected Behavior**:
- ✓ gRPC connection fails immediately
- ✓ Errors logged with clear messages
- ✓ HTTP requests continue (non-blocking)
- ✓ No crashes or panics

**What You Learn**:
- How quickly do connection failures surface?
- Are error messages helpful for debugging?
- Does the client handle DNS failures gracefully?

---

### Scenario 7: Clock Skew

**What Fails**: System clocks are out of sync

**How to Simulate**:
```bash
# Using Chaos Mesh TimeChaos
kubectl apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: TimeChaos
metadata:
  name: clock-skew
spec:
  mode: one
  selector:
    namespaces:
      - default
    labelSelectors:
      app: pulseurl-go-example
  timeOffset: "-1h"
  duration: "5m"
EOF
```

**Expected Behavior**:
- ✓ Timestamps remain accurate (captured at event creation)
- ✓ No time-based logic breaks
- ✓ Events still correlate correctly in PulseURL

**What You Learn**:
- Are you using correct time sources?
- Is there any time-dependent logic that could break?

---

### Scenario 8: High Buffer Pressure

**What Fails**: Sustained traffic exceeds buffer capacity

**How to Simulate**:
```bash
# Deploy with small buffer
helm upgrade pulseurl-go-example . \
  --set env.BUFFER_SIZE=10

# Generate sustained high traffic
hey -n 100000 -c 50 -q 100 http://app:8080/api/users
```

**Expected Behavior**:
- ✓ Buffer fills quickly
- ✓ "buffer full" warnings logged
- ✓ Events dropped (documented behavior)
- ✓ No memory leaks
- ✓ System remains stable

**What You Learn**:
- What buffer size is needed for your traffic patterns?
- How does the system behave at capacity?
- Are warnings/metrics sufficient for observability?

---

## Tools & Setup

### Tool Comparison

| Tool | Best For | Complexity | K8s Native |
|------|----------|------------|------------|
| **Chaos Mesh** | Kubernetes chaos | Medium | ✓ Yes |
| **Litmus** | K8s workflows | Medium | ✓ Yes |
| **Toxiproxy** | Network conditions | Low | ✗ No |
| **Gremlin** | Enterprise chaos | Low | ✓ Yes (paid) |
| **Manual Scripts** | Learning/simple | Low | ✗ No |

### Recommended: Chaos Mesh

**Why Chaos Mesh?**
- Free and open source
- Kubernetes-native (CRDs)
- Rich failure scenarios
- Good documentation
- Web UI for visualization
- Active community

#### Installing Chaos Mesh

```bash
# Install Chaos Mesh via Helm
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update

# Create namespace
kubectl create ns chaos-mesh

# Install
helm install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace=chaos-mesh \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set dashboard.create=true

# Verify installation
kubectl get pods -n chaos-mesh

# Access dashboard
kubectl port-forward -n chaos-mesh svc/chaos-dashboard 2333:2333
# Open http://localhost:2333
```

#### Chaos Mesh Quick Start

```bash
# Create a simple pod kill experiment
kubectl apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: kill-pulseurl-go
  namespace: default
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces:
      - default
    labelSelectors:
      app: pulseurl-go-example
  duration: "30s"
  scheduler:
    cron: "@every 2m"
EOF

# Check status
kubectl describe podchaos kill-pulseurl-go

# Delete experiment
kubectl delete podchaos kill-pulseurl-go
```

### Alternative: Manual Bash Scripts

For learning, you can start with simple bash scripts:

```bash
#!/bin/bash
# simple-chaos.sh - Basic chaos testing

NAMESPACE="${NAMESPACE:-default}"
APP_LABEL="app=pulseurl-go-example"

chaos_pod_kill() {
    echo "🔥 Chaos: Killing random pod..."
    kubectl delete pod -l $APP_LABEL -n $NAMESPACE --force --grace-period=0
}

chaos_network_delay() {
    echo "🐌 Chaos: Injecting network delay..."
    POD=$(kubectl get pod -l $APP_LABEL -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}')
    kubectl exec -n $NAMESPACE $POD -- tc qdisc add dev eth0 root netem delay 500ms
    sleep 30
    kubectl exec -n $NAMESPACE $POD -- tc qdisc del dev eth0 root
}

chaos_resource_pressure() {
    echo "💾 Chaos: Memory pressure..."
    POD=$(kubectl get pod -l $APP_LABEL -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}')
    # Fill memory (careful!)
    kubectl exec -n $NAMESPACE $POD -- stress --vm 1 --vm-bytes 100M --timeout 30s
}

# Run chaos scenarios
while true; do
    chaos_pod_kill
    sleep 120
done
```

## Example Implementations

### Complete Chaos Test Suite

Create directory structure:
```
examples/kubernetes-gin/
├── chaos-tests/
│   ├── 01-pod-failure.yaml
│   ├── 02-network-latency.yaml
│   ├── 03-network-partition.yaml
│   ├── 04-resource-stress.yaml
│   └── 05-combined-chaos.yaml
├── chaos-test.sh
└── README-CHAOS.md
```

### Example: Pod Failure Test

**File**: `examples/kubernetes-gin/chaos-tests/01-pod-failure.yaml`

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: pulseurl-go-pod-failure
  namespace: default
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces:
      - default
    labelSelectors:
      app: pulseurl-go-example
  duration: "30s"
  scheduler:
    cron: "@every 5m"
```

### Example: Network Latency Test

**File**: `examples/kubernetes-gin/chaos-tests/02-network-latency.yaml`

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: pulseurl-network-latency
  namespace: default
spec:
  action: delay
  mode: one
  selector:
    namespaces:
      - default
    labelSelectors:
      app: pulseurl-go-example
  delay:
    latency: "1000ms"
    correlation: "100"
    jitter: "200ms"
  duration: "2m"
  direction: to
  target:
    selector:
      namespaces:
        - default
      labelSelectors:
        app: pulseurl
    mode: one
```

### Example: Orchestration Script

**File**: `examples/kubernetes-gin/chaos-test.sh`

```bash
#!/bin/bash
# chaos-test.sh - Orchestrate chaos experiments

set -e

NAMESPACE="${NAMESPACE:-default}"
CHAOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/chaos-tests" && pwd)"
DURATION="${DURATION:-5m}"

log_info() {
    echo -e "\033[0;32m[INFO]\033[0m $*"
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $*"
}

check_chaos_mesh() {
    if ! kubectl get ns chaos-mesh &>/dev/null; then
        log_error "Chaos Mesh not installed"
        log_info "Install with: helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh"
        exit 1
    fi
}

run_chaos_experiment() {
    local experiment_file="$1"
    local name=$(basename "$experiment_file" .yaml)

    log_info "Running chaos experiment: $name"

    # Apply experiment
    kubectl apply -f "$experiment_file" -n "$NAMESPACE"

    # Wait for duration
    log_info "Chaos running for $DURATION..."
    sleep $(echo $DURATION | sed 's/m/*60/;s/s//')

    # Cleanup
    kubectl delete -f "$experiment_file" -n "$NAMESPACE" --ignore-not-found=true

    log_info "Experiment $name completed"
}

run_all_experiments() {
    log_info "Running all chaos experiments in sequence..."

    for experiment in "$CHAOS_DIR"/*.yaml; do
        run_chaos_experiment "$experiment"
        log_info "Waiting 60s before next experiment..."
        sleep 60
    done

    log_info "All chaos experiments completed"
}

generate_traffic() {
    log_info "Generating background traffic..."

    while true; do
        kubectl run traffic-generator-$RANDOM \
            --image=curlimages/curl:latest \
            --rm -i --restart=Never \
            --command -- sh -c \
            "for i in {1..100}; do curl -sf http://pulseurl-go-example:8080/api/users; done" \
            &>/dev/null || true
        sleep 5
    done
}

show_status() {
    log_info "System Status:"
    kubectl get pods -n "$NAMESPACE" -l app=pulseurl-go-example
    kubectl get podchaos,networkchaos -n "$NAMESPACE"
}

main() {
    local command="${1:-help}"

    case "$command" in
        check)
            check_chaos_mesh
            log_info "Chaos Mesh is installed"
            ;;
        run)
            check_chaos_mesh
            run_experiment="$2"
            if [ -z "$run_experiment" ]; then
                run_all_experiments
            else
                run_chaos_experiment "$CHAOS_DIR/$run_experiment"
            fi
            ;;
        traffic)
            generate_traffic
            ;;
        status)
            show_status
            ;;
        cleanup)
            kubectl delete podchaos,networkchaos --all -n "$NAMESPACE"
            log_info "Cleaned up all chaos experiments"
            ;;
        help|*)
            cat <<EOF
Chaos Testing for PulseURL Middleware

Usage: ./chaos-test.sh [COMMAND]

Commands:
    check       Check if Chaos Mesh is installed
    run [FILE]  Run chaos experiments (all if no file specified)
    traffic     Generate background traffic
    status      Show current chaos experiments and pod status
    cleanup     Remove all chaos experiments
    help        Show this message

Environment Variables:
    NAMESPACE   Kubernetes namespace (default: default)
    DURATION    Experiment duration (default: 5m)

Examples:
    # Run all experiments
    ./chaos-test.sh run

    # Run specific experiment
    ./chaos-test.sh run 01-pod-failure.yaml

    # Generate traffic in background while testing
    ./chaos-test.sh traffic &
    ./chaos-test.sh run
EOF
            ;;
    esac
}

main "$@"
```

### Usage Example

```bash
# 1. Install Chaos Mesh (one-time setup)
helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace

# 2. Deploy your app
NAMESPACE=test ./manage.sh k8s-deploy

# 3. Start background traffic
./chaos-test.sh traffic &

# 4. Run chaos experiments
./chaos-test.sh run

# 5. Observe results
kubectl logs -n test -l app=pulseurl-go-example -f

# 6. Query PulseURL to verify events
curl "http://pulseurl:8080/api/stats/top?service=pulseurl-gin-example&window=10"

# 7. Cleanup
./chaos-test.sh cleanup
```

## Learning Resources

### Books
- **"Chaos Engineering"** by Casey Rosenthal & Nora Jones (O'Reilly)
- **"Site Reliability Engineering"** by Google (free online)
- **"Release It!"** by Michael Nygard

### Online Courses
- [Chaos Engineering with Gremlin](https://www.gremlin.com/community/tutorials/)
- [Linux Foundation: Chaos Engineering](https://training.linuxfoundation.org/)

### Articles & Papers
- [Netflix Chaos Engineering](https://netflixtechblog.com/tagged/chaos-engineering)
- [Principles of Chaos Engineering](https://principlesofchaos.org/)
- [Google SRE Book - Testing](https://sre.google/sre-book/testing-reliability/)

### Tools Documentation
- [Chaos Mesh Docs](https://chaos-mesh.org/docs/)
- [Litmus Docs](https://docs.litmuschaos.io/)
- [Toxiproxy](https://github.com/Shopify/toxiproxy)

### Video Tutorials
- [KubeCon Chaos Engineering talks](https://www.youtube.com/results?search_query=kubecon+chaos+engineering)
- [Chaos Mesh Tutorial](https://www.youtube.com/watch?v=HxXFAuVzaVc)

### Practice Environments
- [Kubernetes The Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way)
- [Minikube](https://minikube.sigs.k8s.io/) - Local K8s for practice
- [Kind](https://kind.sigs.k8s.io/) - K8s in Docker

## Getting Started Guide

### Week 1: Foundations
1. Read "Principles of Chaos Engineering"
2. Understand distributed systems basics
3. Set up local Kubernetes (minikube/kind)
4. Deploy PulseURL middleware locally

### Week 2: Simple Chaos
1. Install Chaos Mesh in local cluster
2. Try pod kill experiments
3. Observe system behavior
4. Read logs and understand recovery

### Week 3: Network Chaos
1. Experiment with network latency
2. Test network partition
3. Understand timeout behavior
4. Tune client retry settings

### Week 4: Advanced Scenarios
1. Combine multiple chaos types
2. Test under realistic traffic
3. Measure recovery times
4. Document findings

## Key Takeaways

### When to Start Learning
- ✓ After basic E2E tests work
- ✓ When you want to understand resilience
- ✓ Before production deployments
- ✓ When you have time to experiment

### What You'll Gain
- 🎓 Understanding of distributed system failure modes
- 🛡️ Confidence in system resilience
- 🔍 Better observability and monitoring
- 🐛 Discovery of hidden bugs
- 📈 Realistic capacity planning

### Remember
> "Chaos Engineering is not about breaking things randomly. It's about learning how systems fail so you can build them better."

Start small, learn continuously, and gradually increase complexity.

---

## Appendix: Chaos Experiment Template

```yaml
# Template for creating new chaos experiments
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos  # or NetworkChaos, StressChaos, etc.
metadata:
  name: my-chaos-experiment
  namespace: default
spec:
  # What action to take
  action: pod-kill  # or pod-failure, network-delay, stress-cpu, etc.

  # How many pods to target
  mode: one  # or all, fixed, fixed-percent, random-max-percent

  # Which pods to target
  selector:
    namespaces:
      - default
    labelSelectors:
      app: pulseurl-go-example

  # How long to run
  duration: "30s"

  # Optional: Run on schedule
  # scheduler:
  #   cron: "@every 5m"
```

---

**Document Version**: 1.0
**Last Updated**: 2025-10-24
**Maintained By**: PulseURL Team

**Questions?** Open an issue or consult the [Chaos Mesh documentation](https://chaos-mesh.org/docs/).
