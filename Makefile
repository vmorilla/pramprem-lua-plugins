EXTENSION = pramprem.aseprite-extension
FILES     = package.json pramprem.lua color-swap.lua noise-texture.lua

.PHONY: all clean

all: $(EXTENSION)

$(EXTENSION): $(FILES)
	zip -j $@ $(FILES)

clean:
	rm -f $(EXTENSION)
