# Build the ridge NCC matcher evaluation tool (no libusb, no glib).
CC ?= gcc

CFLAGS ?= -O2 -g
CFLAGS += -Wall -Wextra -pthread -I.
LDFLAGS += -pthread
LDLIBS += -lm

.PHONY: all clean self-test

all: sf514-egis0570-ridge-eval

sf514-egis0570-ridge-eval: egis0570-ridge.c egis0570-ridge.h egis0570-ridge-eval.c
	$(CC) $(CFLAGS) -o $@ egis0570-ridge-eval.c egis0570-ridge.c $(LDFLAGS) $(LDLIBS)

self-test: sf514-egis0570-ridge-eval
	./sf514-egis0570-ridge-eval --self-test

clean:
	rm -f sf514-egis0570-ridge-eval
