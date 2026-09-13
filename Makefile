NS      := agent-boundary
CLUSTER := agent-boundary
CALICO  := https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml

.DEFAULT_GOAL := help

help: ## show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

cluster: ## create the kind cluster and install Calico (NetworkPolicy enforcement)
	kind create cluster --config kind-config.yaml
	kubectl apply -f $(CALICO)
	@echo "waiting for Calico..."
	kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
	kubectl wait --for=condition=Ready nodes --all --timeout=300s

deploy: ## apply the platform, tools, broker and agent
	kubectl apply -f k8s/
	kubectl -n $(NS) rollout status deploy/claims-api   --timeout=180s
	kubectl -n $(NS) rollout status deploy/payments-api --timeout=180s
	kubectl -n $(NS) rollout status deploy/tool-broker  --timeout=180s
	kubectl -n $(NS) rollout status deploy/claims-agent --timeout=180s

demo: ## run the agent and show what it was and wasn't allowed to do
	kubectl -n $(NS) delete pod -l app=claims-agent --ignore-not-found
	kubectl -n $(NS) rollout status deploy/claims-agent --timeout=180s
	@sleep 12
	@kubectl -n $(NS) logs -l app=claims-agent --tail=-1

audit: ## show the broker's audit stream — every decision, allow and deny
	@kubectl -n $(NS) logs -l app=tool-broker --tail=-1 | grep '^AUDIT ' | sed 's/^AUDIT //'

denials: ## show only the refusals
	@kubectl -n $(NS) logs -l app=tool-broker --tail=-1 | grep '^AUDIT ' | sed 's/^AUDIT //' | grep '"DENY"'

rbac: ## prove the agent's service account cannot read secrets
	@echo "can claims-agent read secrets?"
	@kubectl -n $(NS) auth can-i get secrets \
		--as=system:serviceaccount:$(NS):claims-agent || true
	@echo "can claims-agent list pods?"
	@kubectl -n $(NS) auth can-i list pods \
		--as=system:serviceaccount:$(NS):claims-agent || true

breach: ## remove the network boundary and re-run — watch the bypass succeed
	kubectl -n $(NS) delete networkpolicy --all
	@$(MAKE) demo

restore: ## put the network boundary back
	kubectl apply -f k8s/50-networkpolicy.yaml

clean: ## delete the cluster
	kind delete cluster --name $(CLUSTER)

.PHONY: help cluster deploy demo audit denials rbac breach restore clean
