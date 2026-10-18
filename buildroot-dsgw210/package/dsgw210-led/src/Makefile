# dsgw-led — built with buildroot's target toolchain (CC/CFLAGS/LDFLAGS
# via TARGET_CONFIGURE_OPTS). Linked statically: the coordinator can copy
# the single binary onto a running unit without matching its libc.

dsgw-led: dsgw-led.c
	$(CC) $(CFLAGS) -Wall -Wextra -o $@ $< $(LDFLAGS) -static

# Host unit test with the mock I2C backend: `make test`
HOSTCC ?= cc
test: test-dsgw-led.c dsgw-led.c
	$(HOSTCC) -O1 -g -Wall -Wextra -Werror -o test-dsgw-led test-dsgw-led.c
	./test-dsgw-led

clean:
	rm -f dsgw-led test-dsgw-led

.PHONY: clean test
