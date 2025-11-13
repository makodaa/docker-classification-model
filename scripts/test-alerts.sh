#!/bin/bash

# Alert Rules Testing Script
# This script helps you test the Prometheus alert rules by simulating various conditions

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

BACKEND_URL="http://localhost:8000"
PROMETHEUS_URL="http://localhost:9090"
TEST_IMAGE="backend/test_data/crasipes.jpg"

echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Prometheus Alert Rules Testing Script            ║${NC}"
echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo ""

# Function to check if services are running
check_services() {
    echo -e "${YELLOW}[1] Checking if services are running...${NC}"
    
    if ! curl -s "${BACKEND_URL}/health" > /dev/null 2>&1; then
        echo -e "${RED}[FAIL] Backend is not running${NC}"
        echo "Please start with: docker compose up -d"
        exit 1
    fi
    
    if ! curl -s "${PROMETHEUS_URL}/-/healthy" > /dev/null 2>&1; then
        echo -e "${RED}[FAIL] Prometheus is not running${NC}"
        echo "Please start with: docker compose up -d"
        exit 1
    fi
    
    echo -e "${GREEN}[PASS] All services running${NC}"
    echo ""
}

# Function to check alert rules are loaded
check_alert_rules() {
    echo -e "${YELLOW}[2] Checking alert rules configuration...${NC}"
    
    response=$(curl -s "${PROMETHEUS_URL}/api/v1/rules")
    
    if echo "$response" | grep -q "ml_backend_alerts"; then
        echo -e "${GREEN}[PASS] Alert rules loaded successfully${NC}"
        
        # Count the number of alerts
        alert_count=$(echo "$response" | grep -o '"alert":' | wc -l | tr -d ' ')
        echo -e "  Found ${BLUE}${alert_count}${NC} alert rules"
    else
        echo -e "${RED}[FAIL] Alert rules not loaded${NC}"
        echo "Check prometheus logs: docker logs prometheus"
        exit 1
    fi
    echo ""
}

# Function to list all alerts
list_alerts() {
    echo -e "${YELLOW}[3] Listing configured alerts...${NC}"
    
    alerts=$(curl -s "${PROMETHEUS_URL}/api/v1/rules" | \
        grep -o '"alert":"[^"]*"' | \
        sed 's/"alert":"//g' | sed 's/"//g' | sort -u)
    
    echo "$alerts" | while read -r alert; do
        echo -e "  - ${BLUE}${alert}${NC}"
    done
    echo ""
}

# Function to check current alert state
check_alert_state() {
    echo -e "${YELLOW}[4] Checking current alert states...${NC}"
    
    response=$(curl -s "${PROMETHEUS_URL}/api/v1/alerts")
    
    # Check for pending alerts
    pending=$(echo "$response" | grep -o '"state":"pending"' | wc -l | tr -d ' ')
    firing=$(echo "$response" | grep -o '"state":"firing"' | wc -l | tr -d ' ')
    
    echo -e "  Pending alerts: ${YELLOW}${pending}${NC}"
    echo -e "  Firing alerts:  ${RED}${firing}${NC}"
    
    if [ "$firing" -gt 0 ]; then
        echo ""
        echo -e "${RED}[WARNING] FIRING ALERTS:${NC}"
        curl -s "${PROMETHEUS_URL}/api/v1/alerts" | \
            grep -A 5 '"state":"firing"' | \
            grep '"alertname"' | \
            sed 's/.*"alertname":"\([^"]*\)".*/  - \1/' | sort -u
    fi
    echo ""
}

# Function to test error metrics
test_error_metrics() {
    echo -e "${YELLOW}[5] Testing error rate metrics...${NC}"
    
    # Send a request without an image to trigger an error
    echo "  Sending invalid request to generate error..."
    curl -s -X POST "${BACKEND_URL}/predict" > /dev/null 2>&1 || true
    
    sleep 2
    
    # Check if error metric exists
    errors=$(curl -s "${BACKEND_URL}/metrics" | grep "prediction_errors_total")
    
    if [ -n "$errors" ]; then
        echo -e "${GREEN}[PASS] Error metrics are being recorded${NC}"
        echo "$errors" | head -n 3 | sed 's/^/    /'
    else
        echo -e "${RED}[FAIL] Error metrics not found${NC}"
    fi
    echo ""
}

# Function to generate load for latency testing
generate_load() {
    local count=$1
    local delay=$2
    
    echo -e "${YELLOW}[6] Generating load: ${count} requests with ${delay}s delay...${NC}"
    
    if [ ! -f "$TEST_IMAGE" ]; then
        echo -e "${RED}[FAIL] Test image not found: ${TEST_IMAGE}${NC}"
        return 1
    fi
    
    success_count=0
    error_count=0
    
    for i in $(seq 1 "$count"); do
        response=$(curl -s -w "\n%{http_code}" -X POST \
            -F "image=@${TEST_IMAGE}" \
            "${BACKEND_URL}/predict" 2>&1)
        
        http_code=$(echo "$response" | tail -n 1)
        
        if [ "$http_code" = "200" ]; then
            success_count=$((success_count + 1))
            echo -ne "  Progress: ${success_count}/${count} successful\r"
        else
            error_count=$((error_count + 1))
        fi
        
        if [ "$i" -lt "$count" ]; then
            sleep "$delay"
        fi
    done
    
    echo -e "\n${GREEN}[PASS] Load generation complete${NC}"
    echo "  Successful: ${success_count}"
    echo "  Errors: ${error_count}"
    echo ""
}

# Function to query metrics
query_metrics() {
    echo -e "${YELLOW}[7] Querying current metrics...${NC}"
    
    # Query total requests
    total_requests=$(curl -s "${PROMETHEUS_URL}/api/v1/query?query=prediction_requests_total" | \
        grep -o '"value":\[[^]]*\]' | grep -o '[0-9.]*"$' | sed 's/"$//')
    
    # Query error rate
    error_rate=$(curl -s "${PROMETHEUS_URL}/api/v1/query?query=sum(rate(prediction_errors_total[5m]))/sum(rate(prediction_requests_total[5m]))" | \
        grep -o '"value":\[[^]]*\]' | grep -o '[0-9.]*"$' | sed 's/"$//' || echo "0")
    
    # Query average latency
    avg_latency=$(curl -s "${PROMETHEUS_URL}/api/v1/query?query=rate(prediction_processing_time_ms_sum[5m])/rate(prediction_processing_time_ms_count[5m])" | \
        grep -o '"value":\[[^]]*\]' | grep -o '[0-9.]*"$' | sed 's/"$//' || echo "0")
    
    echo "  Total Requests: ${total_requests:-0}"
    echo "  Error Rate: $(echo "scale=4; ${error_rate:-0} * 100" | bc 2>/dev/null || echo "0")%"
    echo "  Avg Latency: ${avg_latency:-0} ms"
    echo ""
}

# Function to simulate high latency
simulate_high_latency() {
    echo -e "${YELLOW}[8] Simulating high latency scenario...${NC}"
    echo "  Sending many rapid requests to increase processing time..."
    
    # Send 20 requests rapidly to create queue and increase latency
    for i in {1..20}; do
        curl -s -X POST -F "image=@${TEST_IMAGE}" "${BACKEND_URL}/predict" > /dev/null 2>&1 &
    done
    
    wait
    
    echo -e "${GREEN}[PASS] Latency simulation complete${NC}"
    echo "  Wait 2-3 minutes to see if HighAverageLatency alert triggers"
    echo ""
}

# Function to simulate high error rate
simulate_high_error_rate() {
    echo -e "${YELLOW}[9] Simulating high error rate scenario...${NC}"
    echo "  Sending invalid requests to trigger errors..."
    
    # Send 50 invalid requests
    for i in {1..50}; do
        curl -s -X POST "${BACKEND_URL}/predict" > /dev/null 2>&1 || true
        if [ $((i % 10)) -eq 0 ]; then
            echo -ne "  Progress: ${i}/50\r"
        fi
    done
    
    echo -e "\n${GREEN}[PASS] Error simulation complete${NC}"
    echo "  Wait 2-3 minutes to see if HighErrorRate alert triggers"
    echo ""
}

# Function to watch alerts in real-time
watch_alerts() {
    echo -e "${YELLOW}[10] Watching alerts (Ctrl+C to stop)...${NC}"
    echo ""
    
    while true; do
        clear
        echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}           PROMETHEUS ALERTS - LIVE VIEW              ${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
        echo ""
        
        response=$(curl -s "${PROMETHEUS_URL}/api/v1/alerts")
        
        pending=$(echo "$response" | grep -o '"state":"pending"' | wc -l | tr -d ' ')
        firing=$(echo "$response" | grep -o '"state":"firing"' | wc -l | tr -d ' ')
        
        echo -e "Status: Pending: ${YELLOW}${pending}${NC} | Firing: ${RED}${firing}${NC}"
        echo ""
        
        if [ "$firing" -gt 0 ]; then
            echo -e "${RED}FIRING ALERTS:${NC}"
            echo "$response" | python3 -m json.tool 2>/dev/null | \
                grep -A 30 '"state": "firing"' | \
                grep -E '"alertname"|"severity"|"summary"' | \
                sed 's/^[ \t]*/  /'
            echo ""
        fi
        
        if [ "$pending" -gt 0 ]; then
            echo -e "${YELLOW}PENDING ALERTS:${NC}"
            echo "$response" | python3 -m json.tool 2>/dev/null | \
                grep -A 30 '"state": "pending"' | \
                grep -E '"alertname"|"severity"|"summary"' | \
                sed 's/^[ \t]*/  /'
            echo ""
        fi
        
        if [ "$firing" -eq 0 ] && [ "$pending" -eq 0 ]; then
            echo -e "${GREEN}[OK] No alerts firing${NC}"
        fi
        
        echo ""
        echo "Last updated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Press Ctrl+C to stop watching"
        
        sleep 5
    done
}

# Main menu
show_menu() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                    TEST MENU                         ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "1. Run basic checks (services, rules, state)"
    echo "2. Generate normal load (10 requests)"
    echo "3. Generate heavy load (50 requests)"
    echo "4. Simulate high latency"
    echo "5. Simulate high error rate"
    echo "6. Query current metrics"
    echo "7. Watch alerts in real-time"
    echo "8. Run full test suite"
    echo "9. Open Prometheus UI"
    echo "0. Exit"
    echo ""
    echo -n "Select an option: "
}

# Main execution
if [ "$#" -eq 0 ]; then
    # Interactive mode
    while true; do
        show_menu
        read -r choice
        echo ""
        
        case $choice in
            1)
                check_services
                check_alert_rules
                list_alerts
                check_alert_state
                ;;
            2)
                generate_load 10 1
                query_metrics
                ;;
            3)
                generate_load 50 0.5
                query_metrics
                ;;
            4)
                simulate_high_latency
                query_metrics
                ;;
            5)
                simulate_high_error_rate
                query_metrics
                ;;
            6)
                query_metrics
                ;;
            7)
                watch_alerts
                ;;
            8)
                check_services
                check_alert_rules
                list_alerts
                check_alert_state
                test_error_metrics
                generate_load 10 1
                query_metrics
                echo -e "${GREEN}[PASS] Full test suite complete${NC}"
                echo "Run option 7 to watch for alert changes"
                ;;
            9)
                echo "Opening Prometheus UI..."
                open "${PROMETHEUS_URL}" 2>/dev/null || xdg-open "${PROMETHEUS_URL}" 2>/dev/null || echo "Please open: ${PROMETHEUS_URL}"
                ;;
            0)
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo -e "${RED}[ERROR] Invalid option${NC}"
                ;;
        esac
        
        echo ""
        echo -e "${BLUE}Press Enter to continue...${NC}"
        read -r
        clear
    done
else
    # Non-interactive mode - run all checks
    check_services
    check_alert_rules
    list_alerts
    check_alert_state
    test_error_metrics
    generate_load 10 1
    query_metrics
fi
