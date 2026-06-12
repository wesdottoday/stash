APP_NAME    := stash
BUNDLE_ID   := com.wesdottoday.stash
BUILD_DIR   := build
APP_DIR     := $(BUILD_DIR)/$(APP_NAME).app
EXEC_DIR    := $(APP_DIR)/Contents/MacOS
RES_DIR     := $(APP_DIR)/Contents/Resources
EXEC        := $(EXEC_DIR)/$(APP_NAME)

# Minimum macOS. Bumped 13.0 → 26.0 for full SpeechAnalyzer parity with iOS
# (voice capture). Keep this in sync with Info.plist's LSMinimumSystemVersion.
MACOS_MIN   := 26.0
HOST_ARCH   := $(shell uname -m)

# Sources now live in subgroups (Voice/, Relay/, Enroll/) as well as the flat
# Sources/ root, so recurse rather than a flat wildcard.
SWIFT_FILES := $(shell find Sources -name '*.swift')

# Swift auto-links frameworks based on `import` statements, so we only need
# to list ones not implied by an `import` in our sources. (Carbon.HIToolbox is
# imported, so Carbon links automatically.)

# Base options shared by every build; the deployment -target is added per-rule
# so the universal slices can each pin their own arch at the same MACOS_MIN.
SWIFTC_OPTS := -O -whole-module-optimization \
               -module-name $(APP_NAME)

.PHONY: all clean run install universal codesign

all: $(EXEC)

$(EXEC): $(SWIFT_FILES) Resources/Info.plist
	@mkdir -p $(EXEC_DIR) $(RES_DIR)
	@cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist
	@test -f Resources/AppIcon.icns && cp Resources/AppIcon.icns $(RES_DIR)/ || true
	@printf 'APPL????' > $(APP_DIR)/Contents/PkgInfo
	swiftc $(SWIFTC_OPTS) -target $(HOST_ARCH)-apple-macos$(MACOS_MIN) -o $(EXEC) $(SWIFT_FILES)
	@strip -x $(EXEC) 2>/dev/null || true
	@codesign --force --sign - $(APP_DIR) 2>/dev/null || true
	@echo "Built $(APP_DIR)"

universal: $(SWIFT_FILES) Resources/Info.plist
	@mkdir -p $(EXEC_DIR) $(RES_DIR)
	@cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist
	@test -f Resources/AppIcon.icns && cp Resources/AppIcon.icns $(RES_DIR)/ || true
	@printf 'APPL????' > $(APP_DIR)/Contents/PkgInfo
	swiftc $(SWIFTC_OPTS) -target arm64-apple-macos$(MACOS_MIN) -o $(BUILD_DIR)/$(APP_NAME)-arm64 $(SWIFT_FILES)
	swiftc $(SWIFTC_OPTS) -target x86_64-apple-macos$(MACOS_MIN) -o $(BUILD_DIR)/$(APP_NAME)-x86_64 $(SWIFT_FILES)
	lipo -create $(BUILD_DIR)/$(APP_NAME)-arm64 $(BUILD_DIR)/$(APP_NAME)-x86_64 -output $(EXEC)
	@strip -x $(EXEC) 2>/dev/null || true
	@codesign --force --sign - $(APP_DIR)
	@echo "Built universal $(APP_DIR)"

clean:
	rm -rf $(BUILD_DIR)

run: $(EXEC)
	open $(APP_DIR)

install: $(EXEC)
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_DIR) /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"
