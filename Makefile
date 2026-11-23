# Builds kuroneko_ffs, the program behind Kuroneko.Gadget.FunctionFS, into
# the app's priv directory. elixir_make sets MIX_APP_PATH; Nerves sets CC,
# CFLAGS and LDFLAGS for the target.
#
# It needs Linux headers: on other hosts (macOS) nothing is built, so that
# the Elixir code still compiles and its tests run there.

PREFIX = $(MIX_APP_PATH)/priv
BUILD = $(MIX_APP_PATH)/obj

CFLAGS ?= -O2
CFLAGS += -Wall -Wextra -std=gnu11 -pthread

ifeq ($(CROSSCOMPILE)$(shell uname -s),Darwin)
all:
	@echo "kuroneko_gadget: skipping kuroneko_ffs (it needs Linux)"
else
all: $(PREFIX)/kuroneko_ffs
endif

$(PREFIX)/kuroneko_ffs: $(BUILD)/kuroneko_ffs.o
	@mkdir -p $(PREFIX)
	$(CC) $(LDFLAGS) -pthread -o $@ $^

$(BUILD)/%.o: c_src/%.c Makefile
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	$(RM) $(PREFIX)/kuroneko_ffs $(BUILD)/*.o

.PHONY: all clean
