---
name: metrics
description: "Show delivery pipeline metrics — throughput, costs, cycle times, agent performance"
---

# Delivery Metrics

Show pipeline health and performance metrics.

## Steps

1. **Run metrics script:**
   ```bash
   SCRIPTS="/Users/aaronmonick/.claude/plugins/cache/local/helix-delivery-loop/3.0.0/scripts"
   bash "$SCRIPTS/metrics.sh" 2>&1
   ```

2. **Summarize** key numbers: cards delivered, average cycle time, total cost, agent breakdown.
