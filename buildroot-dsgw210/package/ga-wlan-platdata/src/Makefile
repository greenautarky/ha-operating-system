# OOT module: ga-wlan-platdata
#
# Build against a kernel tree:
#   make -C <kernel-build> M=$(pwd) modules
#
# Or via the buildroot package (buildroot-dsgw210/package/ga-wlan-platdata/).

obj-m += ga_wlan_platdata.o
ga_wlan_platdata-y := wlan_platdata.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
