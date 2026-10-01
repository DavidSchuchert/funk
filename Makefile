# Funk: Menüleisten-Gegensprechanlage für zwei Macs
#
#   make install     bauen, signieren, nach /Applications, starten
#   make dmg         build/Funk-<Version>.dmg erzeugen (macht der Release-Workflow)
#   make             nur bauen (build/Funk.app)
#   make run         bauen und direkt aus build/ starten
#   make uninstall   App, Einstellungen und Freigaben entfernen
#   make plugin      Stream-Deck-Plugin neu bauen (braucht Node.js)

APP_NAME    := Funk
BUNDLE_ID   := de.schuchert.funk
BUNDLE      := build/$(APP_NAME).app
INSTALL_DIR := /Applications
IDENTITY    := Funk Signing
VERSION     := $(or $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//'),dev)
BUILD_NUM   := $(or $(shell git rev-list --count HEAD 2>/dev/null),0)

.PHONY: all app dmg run install uninstall plugin clean check-tools

all: app

check-tools:
	@xcode-select -p >/dev/null 2>&1 || { echo "Xcode Command Line Tools fehlen: xcode-select --install"; exit 1; }

app: check-tools
	@scripts/signing-identity.sh "$(IDENTITY)"
	@echo "==> Kompiliere $(APP_NAME) $(VERSION)"
	swift build -c release
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	@cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" "$(BUNDLE)/Contents/MacOS/"
	@cp Resources/Info.plist "$(BUNDLE)/Contents/"
	@cp Resources/Funk.icns Resources/Funk.streamDeckPlugin "$(BUNDLE)/Contents/Resources/"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUM)" "$(BUNDLE)/Contents/Info.plist"
	@echo "==> Signiere mit \"$(IDENTITY)\""
	codesign --force --sign "$(IDENTITY)" --identifier "$(BUNDLE_ID)" "$(BUNDLE)"
	@codesign --verify "$(BUNDLE)" && echo "==> $(BUNDLE) fertig"

dmg: app
	@echo "==> Packe DMG"
	@rm -rf build/dmg "build/$(APP_NAME)-$(VERSION).dmg"
	@mkdir -p build/dmg
	@cp -R "$(BUNDLE)" build/dmg/
	@ln -s /Applications build/dmg/Programme
	hdiutil create -volname "$(APP_NAME) $(VERSION)" -srcfolder build/dmg -ov -format UDZO \
		"build/$(APP_NAME)-$(VERSION).dmg"
	@# Das DMG bewusst NICHT signieren: Ein signiertes DMG prüft Gatekeeper wie eine App
	@# und blockt es, weil das Zertifikat nicht von Apple ist. Unsigniert wird es einfach
	@# geöffnet, geprüft wird dann nur die (signierte) App beim ersten Start.
	@rm -rf build/dmg
	@echo "==> build/$(APP_NAME)-$(VERSION).dmg fertig"

run: app
	-@pkill -x $(APP_NAME); sleep 0.5
	open "$(BUNDLE)"

install: app
	@scripts/cleanup-legacy.sh
	-@pkill -x $(APP_NAME); sleep 0.5
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(BUNDLE)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo
	@echo "Funk läuft in der Menüleiste. Beim ersten Start Mikrofon und lokales Netzwerk erlauben,"
	@echo "dann im Menü auf \"Plugin installieren\" klicken."

uninstall:
	-@pkill -x $(APP_NAME)
	@scripts/cleanup-legacy.sh
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	-@defaults delete $(BUNDLE_ID) 2>/dev/null
	-@tccutil reset Microphone $(BUNDLE_ID) >/dev/null 2>&1
	@echo "Entfernt. Das Stream-Deck-Plugin per Rechtsklick in der Stream-Deck-App deinstallieren."
	@echo "Das Signaturzertifikat \"$(IDENTITY)\" bleibt im Schlüsselbund."

plugin:
	cd plugin && npm ci && npm run build && npx streamdeck validate de.schuchert.funk.sdPlugin
	cd plugin && npx streamdeck pack de.schuchert.funk.sdPlugin -o ../build -f
	mv build/de.schuchert.funk.streamDeckPlugin Resources/Funk.streamDeckPlugin
	@echo "==> Resources/Funk.streamDeckPlugin aktualisiert"

clean:
	rm -rf build .build
