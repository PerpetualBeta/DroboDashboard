# Builds the DroboDext system extension without an Xcode project.
#
# Everything needed ships with Xcode: the complete DriverKit SDK (framework
# headers AND USBDriverKit) lives at Platforms/DriverKit.platform/Developer/
# SDKs/DriverKit.sdk. The 27.2-suffixed SDK next to it is a stripped duplicate
# without the frameworks. No separate download is required.
#
#   make -f dext/Makefile IDENTITY="<Developer ID Application: ...>"
#
# iig recipe verified on this Xcode (27A225b, DriverKit 27.2):
#   iig --def <file.iig> --header <out.h> --impl <out.cpp> -- \
#       -D__IIG=1 -isysroot <DriverKit sdk> -F <frameworks> -x c++
# The .iig must include the frameworks' .iig variants
# (<DriverKit/IOService.iig>); the plain .h files have no virtuals, so
# `override` fails without this. iig also expects per-class shim headers
# (DroboDextDriver.h, DroboUserClient.h); we emit one-line shims that include
# the combined header.

TOOLCHAIN := /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
DK_SDK    := /Applications/Xcode.app/Contents/Developer/Platforms/DriverKit.platform/Developer/SDKs/DriverKit.sdk
FW        := $(DK_SDK)/System/DriverKit/System/Library/Frameworks
IDENTITY  ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $$2; exit}')
PROFILE   ?= $(HOME)/Downloads/ccjorvikdrobodext-6.provisionprofile

CC       := $(TOOLCHAIN)/clang++
IIG      := $(TOOLCHAIN)/iig

BUILDDIR := .build/dext
NAME     := DroboDext
GEN      := $(BUILDDIR)/gen

CXXFLAGS := -x c++ -std=gnu++17 -fno-exceptions -fno-rtti -fno-threadsafe-statics \
            -isysroot $(DK_SDK) -F $(FW) -I $(GEN)
LDFLAGS  := -isysroot $(DK_SDK) -F $(FW) \
            -framework SCSIPeripheralsDriverKit -framework DriverKit -framework USBDriverKit

DEXT     ?= $(BUILDDIR)/$(NAME).dext

.PHONY: all clean

all: $(DEXT)

$(GEN)/DroboDext.h $(GEN)/DroboDext.cpp &: dext/DroboDext/DroboDext.iig
	@mkdir -p $(GEN)
	$(IIG) --def dext/DroboDext/DroboDext.iig \
	    --header $(GEN)/DroboDext.h --impl $(GEN)/DroboDext.cpp -- \
	    -D__IIG=1 -isysroot $(DK_SDK) -F $(FW) -x c++
	@echo '#include "DroboDext.h"' > $(GEN)/DroboDextDriver.h
	@echo '#include "DroboDext.h"' > $(GEN)/DroboUserClient.h
	@echo '#include "DroboDext.h"' > $(GEN)/DroboUSBProbe.h
	@echo '#pragma once' > $(GEN)/DroboDext.h.tmp && cat $(GEN)/DroboDext.h >> $(GEN)/DroboDext.h.tmp && mv $(GEN)/DroboDext.h.tmp $(GEN)/DroboDext.h

$(DEXT): $(GEN)/DroboDext.cpp $(GEN)/DroboDext.h dext/DroboDext/DroboDext.cpp dext/DroboDext/DroboUSBProbe.cpp dext/DroboDext/Info.plist dext/DroboDext/Entitlements.plist
	@mkdir -p $(DEXT)/Contents/MacOS
	$(CC) $(CXXFLAGS) $(GEN)/DroboDext.cpp dext/DroboDext/DroboDext.cpp dext/DroboDext/DroboUSBProbe.cpp \
	    -o $(DEXT)/Contents/MacOS/$(NAME) $(LDFLAGS)
	cp dext/DroboDext/Info.plist $(DEXT)/Contents/Info.plist
ifdef PROFILE
	@if [ -f "$(PROFILE)" ]; then cp "$(PROFILE)" $(DEXT)/Contents/embedded.provisionprofile; \
	else echo "profile $(PROFILE) not found; signing without it (activation will fail)"; fi
endif
ifdef IDENTITY
	# Hardened runtime needs the inner binary signed before the bundle.
	codesign --force --timestamp --options runtime --sign "$(IDENTITY)" \
	    --entitlements dext/DroboDext/Entitlements.plist $(DEXT)/Contents/MacOS/$(NAME)
	codesign --force --timestamp --options runtime --sign "$(IDENTITY)" \
	    --entitlements dext/DroboDext/Entitlements.plist $(DEXT)
else
	codesign --force --sign - \
	    --entitlements dext/DroboDext/Entitlements.plist $(DEXT)
endif

clean:
	rm -rf $(BUILDDIR)
