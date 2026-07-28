SHELL := /usr/bin/env bash

.PHONY: check observer
check:
	./tests/check.sh

observer:
	cmake -S native/observer -B build/observer -DCMAKE_BUILD_TYPE=Release
	cmake --build build/observer --parallel
	build/observer/palworld-observer --self-test
