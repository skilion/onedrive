DC = dmd
DFLAGS = -ofbin/onedrive -L-lcurl -L-lsqlite3 -L-ldl
DESTDIR = /usr/local/bin
CONFDIR = /usr/local/etc

ifneq (, $(shell which systemd))
SERVICE = systemd.service
SERVNAME = onedrive.service
SERVDIR = /usr/lib/systemd/user

else ifneq (, $(shell which initctl))
SERVICE = upstart.conf
SERVNAME = onedrive.conf
SERVDIR = /etc/init
SERVINIT = echo "manual" > $(SERVDIR)/onedrive.override && initctl reload-configuration
SERVDEINIT = rm -f $(SERVDIR)/onedrive.override && initctl reload-configuration

endif

SOURCES = \
	src/config.d \
	src/itemdb.d \
	src/log.d \
	src/main.d \
	src/monitor.d \
	src/onedrive.d \
	src/sqlite.d \
	src/sync.d \
	src/upload.d \
	src/util.d

.PHONY: setup clean all
all: bin/onedrive

setup: bin

clean:
	rm -rf bin

bin:
	mkdir -p bin

bin/onedrive: $(SOURCES) | setup
	$(DC) -O -release -inline -boundscheck=off $(DFLAGS) $(SOURCES)


.PHONY: debug unittest
debug: $(SOURCES)
	$(DC) -debug -g -gs $(DFLAGS) $(SOURCES)

unittest: $(SOURCES)
	$(DC) -unittest -debug -g -gs $(DFLAGS) $(SOURCES)


.PHONY: install uninstall
install: bin/onedrive config/onedrive.conf
	install bin/onedrive $(DESTDIR)/onedrive
	-install -m 644 services/$(SERVICE) $(SERVDIR)/$(SERVNAME)
	install -m 644 config/onedrive.conf $(CONFDIR)/onedrive.conf
	$(SERVINIT)

uninstall:
	rm -f $(DESTDIR)/onedrive
	rm -f $(CONFDIR)/onedrive.conf
	rm -f --preserve-root $(SERVDIR)/$(SERVNAME)
	$(SERVDEINIT)

