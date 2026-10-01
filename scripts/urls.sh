#!/usr/bin/env bash
# Prints the URLs for the services this lab exposes.
set -euo pipefail
cd "$(dirname "$0")/.."
ip=$(terraform -chdir=terraform output -raw server_ip)
echo "ley-khaa : http://$ip/"
if [ -f .secrets/grafana-admin ]; then echo "Grafana  : http://$ip/grafana  (admin / $(cat .secrets/grafana-admin))"; fi
