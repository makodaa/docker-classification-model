#!/bin/bash

echo "======================================"
echo "  Centralized Logging Stack Tests"
echo "======================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function for test output
test_result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $2"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} $2"
        ((TESTS_FAILED++))
    fi
}

# Test 1: Check Loki container is running
echo "Test 1: Checking Loki container..."
if docker ps --format '{{.Names}}' | grep -q "^loki$"; then
    test_result 0 "Loki container is running"
else
    test_result 1 "Loki container is not running"
fi
echo ""

# Test 2: Check Promtail container is running
echo "Test 2: Checking Promtail container..."
if docker ps --format '{{.Names}}' | grep -q "^promtail$"; then
    test_result 0 "Promtail container is running"
else
    test_result 1 "Promtail container is not running"
fi
echo ""

# Test 3: Check Loki health endpoint
echo "Test 3: Checking Loki health endpoint..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3100/ready)
if [ "$HTTP_CODE" -eq 200 ]; then
    test_result 0 "Loki is ready (HTTP $HTTP_CODE)"
else
    test_result 1 "Loki is not ready (HTTP $HTTP_CODE)"
fi
echo ""

# Test 4: Check Loki metrics endpoint
echo "Test 4: Checking Loki metrics endpoint..."
if curl -s http://localhost:3100/metrics | grep -q "loki_ingester"; then
    test_result 0 "Loki metrics endpoint is working"
else
    test_result 1 "Loki metrics endpoint is not responding correctly"
fi
echo ""

# Test 5: Check Promtail is sending logs to Loki
echo "Test 5: Checking Promtail is sending logs to Loki..."
if docker logs promtail 2>&1 | grep -q "finished transferring logs"; then
    test_result 0 "Promtail is successfully transferring logs"
else
    test_result 1 "Promtail is not transferring logs"
fi
echo ""

# Test 6: Generate test logs by hitting backend
echo "Test 6: Generating test logs from backend..."
HEALTH_RESPONSE=$(curl -s http://localhost:8000/health)
if [ -n "$HEALTH_RESPONSE" ]; then
    test_result 0 "Generated test logs via backend health check"
    echo "   Waiting 3 seconds for logs to be ingested..."
    sleep 3
else
    test_result 1 "Failed to generate test logs"
fi
echo ""

# Test 7: Query logs from Loki API
echo "Test 7: Querying logs from Loki API..."
QUERY_RESPONSE=$(curl -s -G "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query={container="backend"}' \
  --data-urlencode 'limit=10')

if echo "$QUERY_RESPONSE" | jq -e '.data.result | length > 0' > /dev/null 2>&1; then
    LOG_COUNT=$(echo "$QUERY_RESPONSE" | jq '.data.result | length')
    test_result 0 "Loki has $LOG_COUNT log stream(s) from backend"
else
    test_result 1 "No logs found in Loki for backend container"
fi
echo ""

# Test 8: Check for backend logs with specific content
echo "Test 8: Checking for backend application logs..."
BACKEND_LOGS=$(curl -s -G "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query={container="backend"} |= "Health check"' \
  --data-urlencode 'limit=5')

if echo "$BACKEND_LOGS" | jq -e '.data.result | length > 0' > /dev/null 2>&1; then
    test_result 0 "Found backend health check logs"
else
    test_result 1 "No backend health check logs found"
fi
echo ""

# Test 9: Check Grafana Loki datasource
echo "Test 9: Checking Grafana Loki datasource..."
if command -v jq &> /dev/null; then
    DATASOURCE_CHECK=$(curl -s -u admin:admin http://localhost:3002/api/datasources 2>/dev/null | jq -e '.[] | select(.type=="loki")' 2>/dev/null)
    if [ -n "$DATASOURCE_CHECK" ]; then
        test_result 0 "Loki datasource is configured in Grafana"
    else
        test_result 1 "Loki datasource not found in Grafana"
    fi
else
    echo -e "${YELLOW}⚠${NC} jq not installed, skipping Grafana datasource check"
fi
echo ""

# Test 10: Verify backend is producing structured logs
echo "Test 10: Verifying backend log output..."
RECENT_LOG=$(docker logs backend --tail 20 2>&1 | grep -E '(INFO|ERROR|WARNING|DEBUG)' | head -1)
if [ -n "$RECENT_LOG" ]; then
    test_result 0 "Backend is outputting structured logs"
else
    test_result 1 "Backend logs are not structured"
fi
echo ""

# Test 11: Check log volume across all containers
echo "Test 11: Checking log volume across all containers..."
LOG_VOLUME=$(curl -s -G "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query=sum(count_over_time({container=~".+"}[1m])) by (container)')

if echo "$LOG_VOLUME" | jq -e '.data.result | length > 0' > /dev/null 2>&1; then
    CONTAINER_COUNT=$(echo "$LOG_VOLUME" | jq '.data.result | length')
    test_result 0 "Logs collected from $CONTAINER_COUNT container(s)"
else
    test_result 1 "No log volume data available"
fi
echo ""

# Test 12: Check for error logs (should be none or minimal)
echo "Test 12: Checking for error logs..."
ERROR_LOGS=$(curl -s -G "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query={container="backend"} |= "ERROR"' \
  --data-urlencode 'limit=5')

ERROR_COUNT=$(echo "$ERROR_LOGS" | jq -e '.data.result[0].values | length' 2>/dev/null || echo "0")
if [ "$ERROR_COUNT" -eq 0 ]; then
    test_result 0 "No error logs found (system is healthy)"
else
    echo -e "${YELLOW}⚠${NC} Found $ERROR_COUNT error log(s) - review manually"
fi
echo ""

# Final summary
echo "======================================"
echo "           Test Summary"
echo "======================================"
echo -e "${GREEN}Passed:${NC} $TESTS_PASSED"
echo -e "${RED}Failed:${NC} $TESTS_FAILED"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC} ✓"
    echo ""
    echo "You can now:"
    echo "  • View logs in Grafana: http://localhost:3002"
    echo "  • Use Explore tab and select 'Loki' datasource"
    echo "  • Open 'Centralized Logging Dashboard'"
    echo "  • Query logs with LogQL: {container=\"backend\"}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC} Please check the output above."
    echo ""
    echo "Troubleshooting:"
    echo "  • Check container logs: docker compose logs loki promtail"
    echo "  • Verify all services: docker compose ps"
    echo "  • Restart services: docker compose restart loki promtail grafana"
    exit 1
fi
