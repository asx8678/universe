# Built by elixir_make as part of `mix compile`.
PREFIX = $(MIX_APP_PATH)/priv/bin
CFLAGS ?= -O2 -Wall -Wextra -Werror -std=c99 -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE

all: $(PREFIX)/universe_run

$(PREFIX)/universe_run: c_src/universe_run.c
	@mkdir -p $(PREFIX)
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(PREFIX)/universe_run

.PHONY: all clean
