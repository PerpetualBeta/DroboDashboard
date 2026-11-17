CONFIG ?= release
IDENTITY ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $$2; exit}')
PROFILE   ?= $(HOME)/Downloads/ccjorvikdrobodext-6.provisionprofile
HOST_PROFILE ?= $(HOME)/Downloads/ccjorvikdroboservice-2.provisionprofile

APP := .build/DroboService.app

.PHONY: build test clean daemon cli host dashboard agent dext icon

icon: Resources/AppIcon.png
	rm -rf .build/icon/AppIcon.iconset
	swift tools/make-icon.swift $< .build/icon/AppIcon.iconset
	iconutil -c icns .build/icon/AppIcon.iconset -o Resources/AppIcon.icns

build:
	swift build -c $(CONFIG)

daemon: build
	swift run -c $(CONFIG) DDService

cli: build
	swift run -c $(CONFIG) drobo

host: build dext icon
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Library/SystemExtensions $(APP)/Contents/Resources
	cp .build/$(CONFIG)/DroboServiceHost $(APP)/Contents/MacOS/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	@gmake -f dext/Makefile all DEXT=$(APP)/Contents/Library/SystemExtensions/cc.jorvik.drobodext.dext
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>CFBundleIdentifier</key>\n\t<string>cc.jorvik.droboservice</string>\n\t<key>CFBundleName</key>\n\t<string>DroboService</string>\n\t<key>CFBundleExecutable</key>\n\t<string>DroboServiceHost</string>\n\t<key>CFBundlePackageType</key>\n\t<string>APPL</string>\n\t<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>\n\t<key>CFBundleShortVersionString</key>\n\t<string>0.1.0</string>\n\t<key>CFBundleVersion</key>\n\t<string>1</string>\n\t<key>LSUIElement</key>\n\t<true/>\n\t<key>NSSystemExtensionUsageDescription</key>\n\t<string>Installs the DroboDext driver that manages Drobo enclosures.</string>\n</dict>\n</plist>\n' > $(APP)/Contents/Info.plist
	@if [ -f "$(HOST_PROFILE)" ]; then cp "$(HOST_PROFILE)" $(APP)/Contents/embedded.provisionprofile; \
	else echo "host profile $(HOST_PROFILE) not found"; fi
	codesign --force --timestamp --options runtime --sign "$(IDENTITY)" \
	    --entitlements dext/DroboServiceHost.entitlements $(APP)
	@echo "Built and signed $(APP). Install with: open $(APP)"

DASH := .build/DroboDashboard.app

AGENT := .build/DroboHealth.app

agent: build icon
	@rm -rf $(AGENT)
	@mkdir -p $(AGENT)/Contents/MacOS $(AGENT)/Contents/Resources
	cp .build/$(CONFIG)/DroboHealthAgent $(AGENT)/Contents/MacOS/DroboHealth
	cp Resources/AppIcon.icns $(AGENT)/Contents/Resources/
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>CFBundleIdentifier</key>\n\t<string>cc.jorvik.drobohealth</string>\n\t<key>CFBundleName</key>\n\t<string>DroboHealth</string>\n\t<key>CFBundleExecutable</key>\n\t<string>DroboHealth</string>\n\t<key>CFBundlePackageType</key>\n\t<string>APPL</string>\n\t<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>\n\t<key>CFBundleShortVersionString</key>\n\t<string>0.1.0</string>\n\t<key>CFBundleVersion</key>\n\t<string>1</string>\n\t<key>LSUIElement</key>\n\t<true/>\n\t<key>NSPrincipalClass</key>\n\t<string>NSApplication</string>\n</dict>\n</plist>\n' > $(AGENT)/Contents/Info.plist
	codesign --force --timestamp --options runtime --sign "$(IDENTITY)" $(AGENT)
	@echo "Built and signed $(AGENT). Install with: open $(AGENT)"

dashboard: build icon
	@rm -rf $(DASH)
	@mkdir -p $(DASH)/Contents/MacOS $(DASH)/Contents/Resources
	cp .build/$(CONFIG)/DroboDashboardUI $(DASH)/Contents/MacOS/DroboDashboard
	cp Resources/AppIcon.icns $(DASH)/Contents/Resources/
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>CFBundleIdentifier</key>\n\t<string>cc.jorvik.drobodashboard</string>\n\t<key>CFBundleName</key>\n\t<string>DroboDashboard</string>\n\t<key>CFBundleExecutable</key>\n\t<string>DroboDashboard</string>\n\t<key>CFBundlePackageType</key>\n\t<string>APPL</string>\n\t<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>\n\t<key>CFBundleShortVersionString</key>\n\t<string>0.1.0</string>\n\t<key>CFBundleVersion</key>\n\t<string>1</string>\n\t<key>NSHumanReadableCopyright</key>\n\t<string></string>\n\t<key>NSPrincipalClass</key>\n\t<string>NSApplication</string>\n</dict>\n</plist>\n' > $(DASH)/Contents/Info.plist
	codesign --force --timestamp --options runtime --sign "$(IDENTITY)" $(DASH)
	@echo "Built and signed $(DASH). Run with: open $(DASH)"

dext:
	@gmake -f dext/Makefile all

test:
	swift test

clean:
	swift package clean
	rm -rf .build
