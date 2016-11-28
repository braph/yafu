PREFIX = /usr

build:
	true

install:
	install -m 0755 yafu.py $(PREFIX)/bin/yafu
