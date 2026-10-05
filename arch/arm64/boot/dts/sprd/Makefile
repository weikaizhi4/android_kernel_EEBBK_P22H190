# SPDX-License-Identifier: GPL-2.0

dtbo-$(CONFIG_ARCH_SPRD) += \
	RMX3265-overlay.dtbo \
	ums512-1h180-overlay.dtbo \
	ums512-1h170-overlay.dtbo \

RMX3265-overlay.dtbo-base := ums512.dtb
ums512-1h180-overlay.dtbo-base := ums512.dtb
ums512-1h170-overlay.dtbo-base := ums512.dtb

dtb-$(CONFIG_ARCH_SPRD) += \
	ums512.dtb

always		:= $(dtb-y) $(dtbo-y)
subdir-y	:= $(dts-dirs)
clean-files	:= *.dtb *.dtbo
