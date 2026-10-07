.PHONY: build test app run

build:
	swift build --arch arm64

test:
	swift test --arch arm64

app:
	./scripts/build-app.sh

run: app
	open "build/LLM Meter.app"
