
kafka-setup: # setup kafka cluster resources
	kubectl apply -f ./kafka/kraft-cluster.yaml

load-test: kafka-setup # load test
	./bench/scripts/run_all.sh
