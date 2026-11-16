CONFIG ?= release

.PHONY: build test clean daemon cli

build:
	swift build -c $(CONFIG)

daemon: build
	swift run -c $(CONFIG) DDService

cli: build
	swift run -c $(CONFIG) drobo

test:
	swift test

clean:
	swift package clean
	rm -rf .build
