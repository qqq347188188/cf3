include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = CFPatchLoader

CFPatchLoader_FILES = CFPatchLoader.m
CFPatchLoader_FRAMEWORKS = Foundation UIKit
CFPatchLoader_CFLAGS = -fobjc-arc -Wno-unused-variable

include $(THEOS_MAKE_PATH)/library.mk
