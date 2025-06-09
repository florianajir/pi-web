# pi-web

Raspberry pi docker compose stack

Exposed: 
- monitoring: grafana.pi-a11r
- proxy: pi-a11r:8080

Stacks docker compose:
- proxy: Traeffik
- monitoring
  - grafana (:3000)
  - cadvisor 
  - node-exporter
  - prometheus
