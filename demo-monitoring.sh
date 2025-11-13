#!/bin/bash
# Quick Demo Script - Monitoring Stack
# Run this to see the monitoring stack in action

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Monitoring & Observability Stack - Live Demo                 ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Check if services are running
echo "1️⃣  Checking Docker Services..."
CONTAINER_COUNT=$(docker ps --format "{{.Names}}" | grep -E "backend|prometheus|grafana" | wc -l | tr -d ' ')
if [ "$CONTAINER_COUNT" -ge 3 ]; then
    echo "   ✅ All monitoring services are running"
else
    echo "   ❌ Some services are missing. Run: docker compose up -d"
    exit 1
fi
echo ""

# Show current metrics
echo "2️⃣  Current Backend Metrics..."
TOTAL_REQUESTS=$(curl -s http://localhost:8000/metrics | grep "^prediction_requests_total" | awk '{print $2}')
echo "   📊 Total Predictions: $TOTAL_REQUESTS"
echo ""

# Make a test prediction
echo "3️⃣  Making a Test Prediction..."
if [ -f "backend/test_data/crasipes.jpg" ]; then
    RESULT=$(curl -s -X POST -F "image=@backend/test_data/crasipes.jpg" http://localhost:8000/predict | python3 -c "import sys, json; data=json.load(sys.stdin); print(f\"{data['predictions'][0]['label']} ({data['predictions'][0]['confidence']*100:.1f}%)\")" 2>/dev/null || echo "Success")
    echo "   ✅ Prediction: $RESULT"
else
    echo "   ⚠️  Test image not found, skipping"
fi
echo ""

# Show updated metrics
echo "4️⃣  Updated Metrics..."
sleep 1
NEW_TOTAL=$(curl -s http://localhost:8000/metrics | grep "^prediction_requests_total" | awk '{print $2}')
echo "   📊 Total Predictions: $NEW_TOTAL"
echo ""

# Check Prometheus
echo "5️⃣  Checking Prometheus..."
PROM_HEALTH=$(curl -s "http://localhost:9090/api/v1/query?query=up" | python3 -c "import sys, json; data=json.load(sys.stdin); print('OK' if data['status']=='success' else 'ERROR')" 2>/dev/null || echo "ERROR")
if [ "$PROM_HEALTH" = "OK" ]; then
    echo "   ✅ Prometheus is collecting metrics"
else
    echo "   ❌ Prometheus check failed"
fi
echo ""

# Show access information
echo "6️⃣  Access Your Dashboards:"
echo "   🌐 Prometheus:  http://localhost:9090"
echo "   📊 Grafana:     http://localhost:3002 (admin/admin)"
echo "   🔍 Metrics:     http://localhost:8000/metrics"
echo ""

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Next Steps:                                                   ║"
echo "║                                                                ║"
echo "║  1. Open Grafana: http://localhost:3002                       ║"
echo "║  2. Login with admin / admin                                  ║"
echo "║  3. Go to Dashboards → Backend ML Service Monitoring          ║"
echo "║  4. Generate more traffic with:                               ║"
echo "║     for i in {1..10}; do                                      ║"
echo "║       curl -X POST -F 'image=@backend/test_data/crasipes.jpg' ║"
echo "║         http://localhost:8000/predict; sleep 1; done          ║"
echo "║  5. Watch the dashboard update in real-time! 🎉               ║"
echo "╚════════════════════════════════════════════════════════════════╝"
