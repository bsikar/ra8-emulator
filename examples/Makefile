PYTHON ?= python3
ZIG ?= zig
OUTPUT ?= build
IMAGES ?=
.DEFAULT_GOAL := all
.PHONY: all build list
all build:
	$(PYTHON) build.py --zig "$(ZIG)" --output "$(OUTPUT)" $(IMAGES)
list:
	$(PYTHON) build.py --list

APP ?= uart
FW ?=
ARM_BIN ?=
.PHONY: firmware
firmware:
	$(PYTHON) firmware.py "$(APP)" --firmware "$(FW)" --arm-bin "$(ARM_BIN)" --zig "$(ZIG)" --output "$(OUTPUT)"
