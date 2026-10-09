# Build the EgisTec 1c7a:0570 capture tool against system libusb.
CC ?= gcc
PKG_CONFIG ?= pkg-config
LIBUSB_CFLAGS := $(shell $(PKG_CONFIG) --cflags libusb-1.0)
LIBUSB_LIBS := $(shell $(PKG_CONFIG) --libs libusb-1.0)

CFLAGS ?= -O2 -g
CFLAGS += -Wall -Wextra -pthread $(LIBUSB_CFLAGS)
LDFLAGS += -pthread
LDLIBS += $(LIBUSB_LIBS) -lm

.PHONY: all clean

all: sf514-egis0570-capture

sf514-egis0570-capture: sf514_egis0570_capture.c sf514_egis0570_protocol.h
	$(CC) $(CFLAGS) -o $@ sf514_egis0570_capture.c $(LDFLAGS) $(LDLIBS)

clean:
	rm -f sf514-egis0570-capture
