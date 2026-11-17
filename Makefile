.PHONY: build test app install

build:
	swift build

test:
	swift test

app:
	scripts/bundle.sh

install: app
	-pkill -x ClaudeUsageBar
	rm -rf /Applications/ClaudeUsageBar.app
	cp -R dist/ClaudeUsageBar.app /Applications/
	open /Applications/ClaudeUsageBar.app
