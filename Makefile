.PHONY: build test app run screenshots

build:
	swift build --arch arm64

test:
	swift test --arch arm64

app:
	./scripts/build-app.sh

run: app
	open "build/LLM Meter.app"

screenshots: app
	"build/LLM Meter.app/Contents/MacOS/LLMMeter" --export-screenshot docs/images/usage-panel.png
	"build/LLM Meter.app/Contents/MacOS/LLMMeter" --export-screenshot docs/images/usage-panel-dark.png --dark
