#!/bin/bash

case $0 in
/*)     D=`dirname $0`;;
*/*)    D=$PWD/`dirname $0`;;
*)      D=$PWD;;
esac

set -e

export NO_FLIPPER=1
export USE_HERMES=0

IOS_DEPLOYMENT_TARGET=15.1

function install_dummy_app() {
	cd "$D"
	if [ ! -e dummyapp ]; then
		npx react-native@0.77.3 init --template react-native@0.77.3 dummyapp
	fi
}

function insert_configuration() {
	cd "$D"
	local refresh_pod=0
	for f in `find dummyapp -type f -name RCTDefines.h`; do
		if grep -q "Inserted by react-native-framework" "$f"; then
			true
		else
			local DIR=`dirname "$f"`
			mv "$f" "$f.orig"
			touch "$DIR/RCTConfDefines.h"
			echo '// Inserted by react-native-framework' > "$f"
			echo '#import <React/RCTConfDefines.h>' >> "$f"
			echo '' >> "$f"
			cat "$f.orig" >> "$f"
			refresh_pod=1
		fi
	done

	if [ A$refresh_pod == A1 ]; then
		cd dummyapp/ios
		pod install
		cd ../..
	fi
}

function update_configuration() {
	cd "$D"
	local DEV=$1
	for f in `find dummyapp -type f -name RCTConfDefines.h`; do
		echo "#define RCT_DEV $DEV" > "$f"
		echo "#define RCT_DEBUG 0" >> "$f"
		echo "#define RCT_ENABLE_INSPECTOR $DEV" >> "$f"
		echo "#define RCT_DEV_SETTINGS_ENABLE_PACKAGER_CONNECTION $DEV" >> "$f"
	done
}

function create_ios_framework_info_plist() {
cat >"$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleExecutable</key>
	<string>${FRAMEWORK_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${FRAMEWORK_IDENTIFIER}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>${BUNDLE_VERSION}</string>
	<key>CFBundleShortVersionString</key>
	<string>${SHORT_VERSION_STRING}</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>${SDK_NAME}</string>
	</array>
	<key>MinimumOSVersion</key>
	<string>${IOS_DEPLOYMENT_TARGET}</string>
	<key>UIDeviceFamily</key>
	<array>
		<integer>1</integer>
		<integer>2</integer>
	</array>
</dict>
</plist>
EOF
}

function compile_dummy_app() {
	local NAME=$1
	local DEV=$2
	case $3 in
		ios)
			XCODE_SDK=iphoneos
			SDK_NAME=iPhoneOS
			LD_PLATFORM=ios
			TARGET=arm64-apple-ios$IOS_DEPLOYMENT_TARGET
			;;
		ios-simulator)
			XCODE_SDK=iphonesimulator
			SDK_NAME=iPhoneSimulator
			LD_PLATFORM=ios-simulator
			TARGET=arm64-apple-ios$IOS_DEPLOYMENT_TARGET-simulator
			;;
	esac

	echo "### build $NAME ###"

	if [ -d build/$NAME ]; then
		return
	fi

	XCODE_DEV=`xcode-select -p`

	cd "$D"
	mkdir -p build/$NAME/dist
	rm -rf build/$NAME
	mkdir -p build/$NAME/dist
	FRAMEWORK="build/$NAME/dist/React.framework"
	xcodebuild clean build -workspace dummyapp/ios/dummyapp.xcworkspace -scheme dummyapp -configuration Release -sdk $XCODE_SDK -arch arm64 -derivedDataPath build/$NAME \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO \
		IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"

	# to display all impvolved pods, add this in the Podfile, inside `post_install do |installer| ... end`:
	#    installer.pods_project.targets.each do |target|
	#      puts target.name
	#    end
	# then run these commands:
	# cd dummyapp/ios
	# pod install
	# cd ../..

	LIBS=`find build/$NAME/Build/Products/Release-$XCODE_SDK -name '*.a'`
	for LIB in $LIBS; do
		echo $LIB
	done

	mkdir -p $FRAMEWORK
	rm -rf $FRAMEWORK
	mkdir -p $FRAMEWORK/Headers
	mkdir -p $FRAMEWORK/Modules
	cp -r dummyapp/ios/Pods/Headers/Public/React-Core/React/*.h $FRAMEWORK/Headers
	rm $FRAMEWORK/Headers/*+Private.h
	cat >$FRAMEWORK/Headers/DummyYoga.h <<-EOF
	typedef int YGValue;
	typedef int YGOverflow;
	typedef int YGDisplay;
	typedef int YGFlexDirection;
	typedef int YGJustify;
	typedef int YGAlign;
	typedef int YGPositionType;
	typedef int YGWrap;
	typedef int YGDirection;
	typedef int YGNodeRef;
	typedef int YGConfigRef;
	EOF
	sed -i '' 's/<yoga\/Yoga.h>/<React\/DummyYoga.h>/g' $FRAMEWORK/Headers/*
	sed -i '' 's/<yoga\/YGEnums.h>/<React\/DummyYoga.h>/g' $FRAMEWORK/Headers/*

	cd $FRAMEWORK/Headers
	for file in $(ls); do
		echo '#import <React/'$file'>' >>React.h
	done
	cd "$D"

	cat > $FRAMEWORK/Modules/module.modulemap <<-EOF
	framework module React {
	  umbrella header "React.h"

	  export *
	  module * { export * }
	}
	EOF

	FRAMEWORK_NAME="React"
	FRAMEWORK_IDENTIFIER="ch.ijk.React"
	BUNDLE_VERSION="1"
	SHORT_VERSION_STRING="1.0.0"

	create_ios_framework_info_plist $FRAMEWORK/Info.plist

	echo "### link $NAME ###"

	"${XCODE_DEV}/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" \
		-Xlinker -reproducible \
		-target $TARGET \
		-dynamiclib \
		-isysroot "${XCODE_DEV}/Platforms/${SDK_NAME}.platform/Developer/SDKs/${SDK_NAME}.sdk" \
		-Os -lc++ \
		-Xlinker -ObjC \
		$LIBS \
		-install_name @rpath/React.framework/React \
		-Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -rpath -Xlinker @loader_path/Frameworks \
		-dead_strip \
		-fobjc-arc -fobjc-link-runtime -Xlinker -no_adhoc_codesign -compatibility_version 1 -current_version 1 \
		-framework JavaScriptCore \
		-framework AudioToolbox \
		-framework Accelerate \
		-framework MobileCoreServices \
		-o $FRAMEWORK/React
		#-Xlinker -object_path_lto -Xlinker /Users/gabriele/Library/Developer/Xcode/DerivedData/demo-bpyvxoqsookskebwxbzdpiaiigan/Build/Intermediates.noindex/ArchiveIntermediates/demo/IntermediateBuildFilesPath/demo.build/Release-iphoneos/demo.build/Objects-normal/arm64/demo_lto.o \
		#-Xlinker -dependency_info -Xlinker /Users/gabriele/Library/Developer/Xcode/DerivedData/demo-bpyvxoqsookskebwxbzdpiaiigan/Build/Intermediates.noindex/ArchiveIntermediates/demo/IntermediateBuildFilesPath/demo.build/Release-iphoneos/demo.build/Objects-normal/arm64/demo_dependency_info.dat \

	#	"/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/ld" \
	#		-no_deduplicate -dynamic -dylib -dylib_compatibility_version 1 -dylib_current_version 1 -arch arm64 -Os \
	#		-dylib_install_name @rpath/React.framework/React -platform_version $LD_PLATFORM 12.4.0 17.0 \
	#		-syslibroot /Applications/Xcode.app/Contents/Developer/Platforms/${SDK_NAME}.platform/Developer/SDKs/${SDK_NAME}17.0.sdk \
	#		-lto_library /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libLTO.dylib \
	#		$LIBS \
	#		-ObjC \
	#		-o $FRAMEWORK/React \
	#		-export_dynamic -demangle -dead_strip \
	#		-reproducible -rpath @executable_path/Frameworks -rpath @loader_path/Frameworks \
	#		-no_deduplicate -no_adhoc_codesign -framework Foundation -framework JavaScriptCore -lobjc -lSystem -lc++ \
	#		/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/15.0.0/lib/darwin/libclang_rt.ios.a
}

# download source code

install_dummy_app
insert_configuration

# compile

mkdir -p build
update_configuration 0
compile_dummy_app react-prod-ios-device 0 ios
compile_dummy_app react-prod-ios-simulator 0 ios-simulator
update_configuration 1
compile_dummy_app react-dev-ios-device 1 ios
compile_dummy_app react-dev-ios-simulator 1 ios-simulator

# create xcframeworks

mkdir -p dist/prod-apl
mkdir -p dist/dev-apl
xcodebuild -create-xcframework -framework build/react-prod-ios-device/dist/React.framework -framework build/react-prod-ios-simulator/dist/React.framework -output dist/prod-apl/React.xcframework
xcodebuild -create-xcframework -framework build/react-dev-ios-device/dist/React.framework  -framework build/react-dev-ios-simulator/dist/React.framework  -output dist/dev-apl/React.xcframework
