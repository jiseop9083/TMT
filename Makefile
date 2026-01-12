
kafka-setup: # setup kafka cluster resources
	kubectl apply -f ./kafka/kraft-cluster.yaml

load-test: kafka-setup # load test
	./bench/scripts/run_all.sh

auto-topic-test: # test topic auto-creation
	kubectl apply -f bench/manifests/topic-autocreate-config.yaml
	kubectl apply -f bench/manifests/topic-autocreate-cm.yaml
	kubectl apply -f bench/manifests/topic-autocreate-job.yaml
	$(MAKE) auto-topic-collect

auto-topic-collect: # collect auto-topic test outputs to local out/
	./bench/scripts/collect_autocreate.sh

auto-topic-image: # build local image with async-profiler
	docker build -f bench/dockerfile/Dockerfile.autocreate -t kafka-autocreate:local .

auto-topic-clean: # clean up auto-topic test resources
	kubectl delete job -n kafka topic-autocreate
	kubectl delete -f bench/manifests/topic-autocreate-job.yaml
	kubectl delete -f bench/manifests/topic-autocreate-cm.yaml
	kubectl delete -f bench/manifests/topic-autocreate-config.yaml
