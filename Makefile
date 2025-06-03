OPERATOR_IMAGE ?= quay.io/jpolo/oci-autoscaling-operator-bash:latest

.PHONY: operator
operator: operator-build operator-push

.PHONY: operator-build
operator-build:
	podman build . -f oci-autoscaling-operator/Containerfile -t ${OPERATOR_IMAGE}

.PHONY: operator-push
operator-push:
	podman push ${OPERATOR_IMAGE}
