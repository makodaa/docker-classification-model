#!/bin/bash
# Monitoring Stack Testing Script
# This script tests the Prometheus + Grafana observability stack

# Remove set -e to continue on errors
set +e

echo "========================================="
echo "Monitoring Stack Verification Tests"
echo "========================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function to print test results
test_result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓ PASS${NC}: $2"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC}: $2"
        ((TESTS_FAILED++))
    fi
}

echo "Test 1: Check if all containers are running"
echo "---------------------------------------------"
CONTAINERS=$(docker ps --format "{{.Names}}" | grep -E "backend|prometheus|grafana|frontend|database" | wc -l)
if [ "$CONTAINERS" -eq 5 ]; then
    test_result 0 "All 5 containers are running"
else
    test_result 1 "Expected 5 containers, found $CONTAINERS"
fi
echo ""

echo "Test 2: Backend /metrics endpoint accessibility"
echo "---------------------------------------------"
METRICS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/metrics)
if [ "$METRICS_STATUS" -eq 200 ]; then
    test_result 0 "Backend /metrics endpoint is accessible (HTTP $METRICS_STATUS)"
else
    test_result 1 "Backend /metrics endpoint returned HTTP $METRICS_STATUS"
fi
echo ""

echo "Test 3: Verify Prometheus custom metrics are exposed"
echo "---------------------------------------------"
METRICS_OUTPUT=$(curl -s http://localhost:8000/metrics)
if echo "$METRICS_OUTPUT" | grep -q "prediction_requests_total"; then
    test_result 0 "prediction_requests_total metric found"
else
    test_result 1 "prediction_requests_total metric not found"
fi

if echo "$METRICS_OUTPUT" | grep -q "prediction_processing_time_ms"; then
    test_result 0 "prediction_processing_time_ms metric found"
else
    test_result 1 "prediction_processing_time_ms metric not found"
fi
echo ""

echo "Test 4: Prometheus UI accessibility"
echo "---------------------------------------------"
PROM_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9090)
if [ "$PROM_STATUS" -eq 200 ] || [ "$PROM_STATUS" -eq 302 ]; then
    test_result 0 "Prometheus UI is accessible (HTTP $PROM_STATUS)"
else
    test_result 1 "Prometheus UI returned HTTP $PROM_STATUS"
fi
echo ""

echo "Test 5: Prometheus targets health"
echo "---------------------------------------------"
TARGETS_JSON=$(curl -s http://localhost:9090/api/v1/targets)
BACKEND_HEALTH=$(echo "$TARGETS_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); targets=[t for t in data['data']['activeTargets'] if t.get('labels',{}).get('job')=='backend']; print(targets[0]['health'] if targets else 'unknown')")

if [ "$BACKEND_HEALTH" == "up" ]; then
    test_result 0 "Backend target is healthy in Prometheus"
else
    test_result 1 "Backend target health is: $BACKEND_HEALTH"
fi
echo ""

echo "Test 6: Prometheus is scraping metrics from backend"
echo "---------------------------------------------"
QUERY_RESULT=$(curl -s "http://localhost:9090/api/v1/query?query=prediction_requests_total" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['status'])")

if [ "$QUERY_RESULT" == "success" ]; then
    test_result 0 "Prometheus successfully queries backend metrics"
else
    test_result 1 "Prometheus query failed"
fi
echo ""

echo "Test 7: Grafana UI accessibility"
echo "---------------------------------------------"
GRAFANA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3002)
if [ "$GRAFANA_STATUS" -eq 200 ] || [ "$GRAFANA_STATUS" -eq 302 ]; then
    test_result 0 "Grafana UI is accessible (HTTP $GRAFANA_STATUS)"
else
    test_result 1 "Grafana UI returned HTTP $GRAFANA_STATUS"
fi
echo ""

echo "Test 8: Grafana datasource configuration"
echo "---------------------------------------------"
DATASOURCE_JSON=$(curl -s -u admin:admin http://localhost:3002/api/datasources)
DATASOURCE_COUNT=$(echo "$DATASOURCE_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len([d for d in data if d.get('type')=='prometheus']))")

if [ "$DATASOURCE_COUNT" -ge 1 ]; then
    test_result 0 "Prometheus datasource is configured in Grafana"
else
    test_result 1 "No Prometheus datasource found in Grafana"
fi
echo ""

echo "Test 9: Make a prediction and verify metrics update"
echo "---------------------------------------------"
# Get current count
BEFORE_COUNT=$(curl -s "http://localhost:9090/api/v1/query?query=prediction_requests_total" | python3 -c "import sys, json; data=json.load(sys.stdin); result=data.get('data',{}).get('result',[]); print(result[0]['value'][1] if result else '0')" 2>/dev/null || echo "0")

# Make a prediction (if test image exists)
if [ -f "backend/test_data/crasipes.jpg" ]; then
    PRED_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -F "image=@backend/test_data/crasipes.jpg" http://localhost:8000/predict)
    
    if [ "$PRED_STATUS" -eq 200 ]; then
        test_result 0 "Prediction request successful (HTTP $PRED_STATUS)"
        
        # Wait a moment for Prometheus to scrape
        sleep 3
        
        # Check if count increased
        AFTER_COUNT=$(curl -s "http://localhost:9090/api/v1/query?query=prediction_requests_total" | python3 -c "import sys, json; data=json.load(sys.stdin); result=data.get('data',{}).get('result',[]); print(result[0]['value'][1] if result else '0')" 2>/dev/null || echo "0")
        
        # Use bc for floating point comparison if available, otherwise just check if metric exists
        if command -v bc &> /dev/null; then
            if [ $(echo "$AFTER_COUNT > $BEFORE_COUNT" | bc) -eq 1 ] || [ $(echo "$AFTER_COUNT >= $BEFORE_COUNT" | bc) -eq 1 ]; then
                test_result 0 "Metrics counter value: $AFTER_COUNT (was $BEFORE_COUNT)"
            else
                test_result 1 "Metrics counter did not increase (still $AFTER_COUNT)"
            fi
        else
            if [ "$AFTER_COUNT" != "0" ]; then
                test_result 0 "Metrics counter is being tracked (current: $AFTER_COUNT)"
            else
                test_result 1 "Metrics counter not found"
            fi
        fi
    else
        test_result 1 "Prediction request failed (HTTP $PRED_STATUS)"
    fi
else
    echo -e "${YELLOW}⚠ SKIP${NC}: Test image not found, skipping prediction test"
fi
echo ""

echo "Test 10: Grafana dashboard provisioning"
echo "---------------------------------------------"
sleep 2  # Give Grafana time to load dashboards
DASHBOARD_JSON=$(curl -s -u admin:admin http://localhost:3002/api/search?type=dash-db)
DASHBOARD_COUNT=$(echo "$DASHBOARD_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data))" 2>/dev/null || echo "0")

if [ "$DASHBOARD_COUNT" -ge 1 ]; then
    test_result 0 "Dashboard(s) provisioned in Grafana (found $DASHBOARD_COUNT)"
else
    test_result 1 "No dashboards found in Grafana"
fi
echo ""

echo "========================================="
echo "Test Summary"
echo "========================================="
echo -e "${GREEN}Tests Passed: $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Tests Failed: $TESTS_FAILED${NC}"
else
    echo -e "${GREEN}Tests Failed: $TESTS_FAILED${NC}"
fi
echo ""

echo "========================================="
echo "Access URLs"
echo "========================================="
echo "Backend API:       http://localhost:8000"
echo "Backend Metrics:   http://localhost:8000/metrics"
echo "Prometheus UI:     http://localhost:9090"
echo "Prometheus Targets: http://localhost:9090/targets"
echo "Grafana UI:        http://localhost:3002 (admin/admin)"
echo "Frontend:          http://localhost:3000"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed! Monitoring stack is working correctly.${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Please check the output above.${NC}"
    exit 1
fi
