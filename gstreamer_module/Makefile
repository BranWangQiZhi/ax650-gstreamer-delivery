MKFILE_PATH         := $(abspath $(lastword $(MAKEFILE_LIST)))
CUR_PATH            := $(abspath $(dir $(MKFILE_PATH)))
HOME_PATH           := $(abspath $(CUR_PATH)/../..)
ROOTFS_TARGET_PATH ?= $(HOME_PATH)/rootfs/rootfs/usr/local

CROSS	     := aarch64-none-linux-gnu-
CC            = $(CROSS)gcc
CPP           = $(CROSS)g++
LD            = $(CROSS)ld
AR            = $(CROSS)ar -rcs
OBJCPOY       = $(CROSS)objcopy
STRIP         = $(CROSS)strip

VERB          = @
RM            = rm -rf
MKDIR         = mkdir -p
ECHO          = echo
MV            = mv
LN            = ln -sf
CP            = cp -f
TAR           = tar
TOUCH         = touch
ARCH          = arm64

BUILD_SCRIPT = ./build.sh

include $(HOME_PATH)/build/color.mk

.PHONY: install clean all

all:
	@$(ECHO) -e $(CYAN)"Building gstreamer (this may take 30~60 min) ..." $(DONE)
	@bash $(BUILD_SCRIPT)
	@$(ECHO) -e $(GREEN)"\nBuild gstreamer success!!\n"  $(DONE)

install:
	@bash $(BUILD_SCRIPT) install
	@$(ECHO) -e $(GREEN)"\nInstall gstreamer success!!\n"  $(DONE)

clean:
	@bash $(BUILD_SCRIPT) clean
	@$(ECHO) -e $(GREEN)"\nClean gstreamer success!!\n"  $(DONE)
