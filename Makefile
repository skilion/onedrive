DC = dmd
DFLAGS = -ofonedrive -L-lcurl -L-lsqlite3 -L-ldl
DESTDIR = /usr/local/bin
CONFDIR = /usr/local/etc

ifneq (, $(shell which systemd))
SERVICE = systemd.service
SERVDIR = /usr/lib/systemd/user
SERVNAME = onedrive.service

else ifneq (, $(shell which initctl))
SERVICE = upstart.conf
SERVDIR = /etc/init
SERVNAME = onedrive.conf
SERVINIT = initctl reload-configuration

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

onedrive: $(SOURCES)
	$(DC) -O -release -inline -boundscheck=off $(DFLAGS) $(SOURCES)

debug: $(SOURCES)
	$(DC) -debug -g -gs $(DFLAGS) $(SOURCES)

unittest: $(SOURCES)
	$(DC) -unittest -debug -g -gs $(DFLAGS) $(SOURCES)

clean:
	rm -f onedrive.o onedrive

install: onedrive onedrive.conf
	install onedrive $(DESTDIR)/onedrive
	-install -m 644 services/$(SERVICE) $(SERVDIR)/$(SERVNAME)
	install -m 644 onedrive.conf $(CONFDIR)/onedrive.conf
	$(SERVINIT)

uninstall:
	rm -f $(DESTDIR)/onedrive
	rm -f $(CONFDIR)/onedrive.conf
	rm -f --preserve-root $(SERVDIR)/$(SERVNAME)
	$(SERVINIT)

