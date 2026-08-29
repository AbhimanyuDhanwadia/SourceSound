.PHONY: build test app dmg clean

build:
	swift build $(SWIFT_BUILD_FLAGS)

test:
	swift test $(SWIFT_BUILD_FLAGS)

app:
	swift build -c release $(SWIFT_BUILD_FLAGS)
	mkdir -p dist/SourceSound.app/Contents/MacOS
	cp .build/release/SourceSound dist/SourceSound.app/Contents/MacOS/SourceSound
	cp Resources/Info.plist dist/SourceSound.app/Contents/Info.plist
	codesign --force --deep --sign - dist/SourceSound.app

dmg: app
	hdiutil create -volname SourceSound -srcfolder dist/SourceSound.app -ov -format UDZO dist/SourceSound-1.9.dmg

clean:
	swift package clean
	rm -rf dist
