.PHONY: all clean test zig-core macos android

# ── Build targets ──────────────────────────────────────────────

all: zig-core macos android

zig-core:
	cd zig-core && zig build

macos: zig-core
	cd macos && swift build

android: zig-core
	cd android && ./gradlew assembleDebug

# ── Test targets ───────────────────────────────────────────────

test: test-zig test-swift test-android

test-zig:
	cd zig-core && zig build test

test-swift:
	cd macos && swift test

test-android:
	cd android && ./gradlew test

# ── Clean ──────────────────────────────────────────────────────

clean:
	cd zig-core && rm -rf zig-out zig-cache .zig-cache
	cd macos && swift package clean
	cd android && ./gradlew clean
