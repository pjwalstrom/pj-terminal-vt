.PHONY: lib clean project build run

# Build the libghostty-vt dynamic library from the vendored Ghostty source.
lib:
	cd vendor/ghostty && zig build lib-vt
	mkdir -p lib/include
	cp vendor/ghostty/zig-out/lib/libghostty-vt.0.1.0.dylib lib/libghostty-vt.dylib
	cp -R vendor/ghostty/zig-out/include/ghostty lib/include/ghostty
	install_name_tool -id @rpath/libghostty-vt.dylib lib/libghostty-vt.dylib

# Generate Xcode project from project.yml
project:
	xcodegen generate

# Build the app
build: project
	xcodebuild -scheme PJTerminalVT -configuration Debug build

# Run the built app
run:
	open ~/Library/Developer/Xcode/DerivedData/PJTerminalVT-*/Build/Products/Debug/PJTerminalVT.app

clean:
	rm -rf lib/libghostty-vt.dylib lib/include
	rm -rf PJTerminalVT.xcodeproj
