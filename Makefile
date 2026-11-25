SHELL := /bin/bash

NAMESPACE := monitoring
KPS_CHART := prometheus-community/kube-prometheus-stack
KPS_VERSION := 93.10.1
KPS_VALUES := values/kube-prometheus-stack.yaml
MONITORING_CHART := charts/brewq-monitoring
RULES := $(MONITORING_CHART)/files/brewq-slo.rules.yaml
KUBE_VERSION := 1.34.0
PROMETHEUS_URL ?= http://prometheus.localtest.me

KUBE_SCHEMAS := https://raw.githubusercontent.com/yannh/kubernetes-json-schema/0c4dd99d9873f7b4c2da24c008476f5841adbe2d
CRD_SCHEMAS := https://raw.githubusercontent.com/datreeio/CRDs-catalog/04af58d740718c4dc719441bf39fb284c784f4a8
VALIDATE := kubeconform -strict -summary -kubernetes-version $(KUBE_VERSION) -cache .cache/kubeconform \
	-schema-location '$(KUBE_SCHEMAS)/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json' \
	-schema-location '$(CRD_SCHEMAS)/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

.PHONY: help install uninstall lint grafana-password urls alerts helm-repo \
	port-forward-grafana port-forward-prometheus port-forward-alertmanager

help: ## Show available targets
	@awk -F ':.*## ' '/^[a-zA-Z0-9_-]+:.*## / { printf "  %-26s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

helm-repo:
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

install: helm-repo ## Install the monitoring stack using the current Kubernetes context
	@set -eu -o pipefail; \
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -; \
	secret=$$(kubectl -n $(NAMESPACE) get secret grafana-admin --ignore-not-found -o name); \
	if [ -z "$$secret" ]; then \
		password=$$(openssl rand -hex 24); \
		printf 'admin-user=admin\nadmin-password=%s\n' "$$password" | \
			kubectl -n $(NAMESPACE) create secret generic grafana-admin --from-env-file=/dev/stdin; \
	fi
	helm upgrade --install kps $(KPS_CHART) --version $(KPS_VERSION) \
		--namespace $(NAMESPACE) --values $(KPS_VALUES) --wait --timeout 10m --hide-notes
	kubectl wait --for=condition=Established --timeout=120s \
		crd/servicemonitors.monitoring.coreos.com crd/prometheusrules.monitoring.coreos.com
	helm upgrade --install brewq-monitoring $(MONITORING_CHART) \
		--namespace $(NAMESPACE) --wait --timeout 5m

uninstall: ## Remove both Helm releases
	helm uninstall brewq-monitoring --namespace $(NAMESPACE) --ignore-not-found --wait
	helm uninstall kps --namespace $(NAMESPACE) --ignore-not-found --wait

lint: helm-repo ## Validate Helm, Kubernetes manifests, Prometheus rules and Grafana dashboards
	helm lint --strict $(MONITORING_CHART)
	@mkdir -p .cache/kubeconform
	@set -eu -o pipefail; \
	helm template brewq-monitoring $(MONITORING_CHART) --namespace $(NAMESPACE) \
		--kube-version $(KUBE_VERSION) | $(VALIDATE)
	@set -eu -o pipefail; \
	helm template kps $(KPS_CHART) --version $(KPS_VERSION) --namespace $(NAMESPACE) \
		--kube-version $(KUBE_VERSION) --values $(KPS_VALUES) | $(VALIDATE)
	promtool check rules $(RULES)
	promtool test rules tests/*.test.yaml
	@set -eu; \
	for dashboard in $(MONITORING_CHART)/dashboards/*.json; do \
		uid=$${dashboard##*/}; \
		jq -e --arg uid "$${uid%.json}" \
			'type == "object" and .uid == $$uid and (.panels | type == "array" and length > 0)' \
			"$$dashboard" > /dev/null; \
	done; \
	jq -es 'map(.uid) | sort == ["brewq-overview", "brewq-slo"]' \
		$(MONITORING_CHART)/dashboards/*.json > /dev/null
	@echo "Grafana dashboard JSON and UIDs validated."

grafana-password: ## Print the generated Grafana admin password
	@set -eu -o pipefail; \
	kubectl -n $(NAMESPACE) get secret grafana-admin -o jsonpath='{.data.admin-password}' | \
		openssl base64 -d -A; \
	printf '\n'

urls: ## Print the Gateway URLs
	@printf '%s\n' http://grafana.localtest.me http://prometheus.localtest.me http://alertmanager.localtest.me

alerts: ## List firing alert names, severities and activation times
	@set -eu -o pipefail; \
	curl --fail --silent --show-error --max-time 10 \
		--noproxy 'prometheus.localtest.me,localhost,127.0.0.1' "$(PROMETHEUS_URL)/api/v1/alerts" | \
		jq -r 'if .status == "success" then .data.alerts[] | select(.state == "firing") | [.labels.alertname, (.labels.severity // ""), .activeAt] | @tsv else error(.error // "Prometheus API request failed") end'

port-forward-grafana: ## Forward Grafana to localhost:3000
	kubectl -n $(NAMESPACE) port-forward service/kps-grafana 3000:80

port-forward-prometheus: ## Forward Prometheus to localhost:9090
	kubectl -n $(NAMESPACE) port-forward service/kps-prometheus 9090:9090

port-forward-alertmanager: ## Forward Alertmanager to localhost:9093
	kubectl -n $(NAMESPACE) port-forward service/kps-alertmanager 9093:9093
