import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE;
import core.memory, core.time, core.thread;
import std.getopt, std.file, std.path, std.process;
import config, itemdb, monitor, onedrive, sync, util;
static import log;

int main(string[] args)
{
	// configuration directory
	string configDirName = expandTilde(environment.get("XDG_CONFIG_HOME", "~/.config")) ~ "/onedrive";
	// enable monitor mode
	bool monitor;
	// force a full resync
	bool resync;
	// remove the current user and sync state
	bool logout;
	// enable verbose logging
	bool verbose;

	try {
		auto opt = getopt(
			args,
			std.getopt.config.bundling,
			"monitor|m", "Keep monitoring for local and remote changes.", &monitor,
			"resync", "Forget the last saved state, perform a full sync.", &resync,
			"logout", "Logout the current user.", &logout,
			"confdir", "Set the directory to use to store the configuration files.", &configDirName,
			"verbose|v", "Print more details, useful for debugging.", &log.verbose
		);
		if (opt.helpWanted) {
			defaultGetoptPrinter(
				"Usage: onedrive [OPTION]...\n\n" ~
				"no option    Sync and exit.",
				opt.options
			);
			return EXIT_SUCCESS;
		}
	} catch (GetOptException e) {
		log.log(e.msg);
		log.log("Try 'onedrive -h' for more information.");
		return EXIT_FAILURE;
	}

	log.vlog("Loading config ...");
	configDirName = expandTilde(configDirName);
	if (!exists(configDirName)) mkdir(configDirName);
	auto cfg = new config.Config(configDirName);
	cfg.init();
        bool ignore_local_changes = false;
        if(cfg.getValue("ignore_local_changes") == "yes"){
                ignore_local_changes = true;
        }
	if (resync || logout) {
		log.log("Deleting the saved status ...");
		safeRemove(cfg.databaseFilePath);
		safeRemove(cfg.statusTokenFilePath);
		safeRemove(cfg.uploadStateFilePath);
		if (logout) {
			safeRemove(cfg.refreshTokenFilePath);
		}
	}

	log.vlog("Initializing the OneDrive API ...");
	bool online = testNetwork();
	if (!online && !monitor) {
		log.log("No network connection");
		return EXIT_FAILURE;
	}
	auto onedrive = new OneDriveApi(cfg);
	if (!onedrive.init()) {
		log.log("Could not initialize the OneDrive API");
		// workaround for segfault in std.net.curl.Curl.shutdown() on exit
		onedrive.http.shutdown();
		return EXIT_FAILURE;
	}

	log.vlog("Opening the item database ...");
	auto itemdb = new ItemDatabase(cfg.databaseFilePath);

	string syncDir = expandTilde(cfg.getValue("sync_dir"));
	log.vlog("All operations will be performed in: ", syncDir);
	if (!exists(syncDir)) mkdir(syncDir);
	chdir(syncDir);

	log.vlog("Initializing the Synchronization Engine ...");
	auto sync = new SyncEngine(cfg, onedrive, itemdb);
	sync.init();
	if (online) performSync(sync, ignore_local_changes);

	if (monitor) {
		log.vlog("Initializing monitor ...");
		Monitor m;
                if(!ignore_local_changes){
                        m.onDirCreated = delegate(string path) {
                                log.vlog("[M] Directory created: ", path);
                                try {
                                        sync.scanForDifferences(path);
                                } catch(SyncException e) {
                                        log.log(e.msg);
                                }
                        };
                        m.onFileChanged = delegate(string path) {
                                log.vlog("[M] File changed: ", path);
                                try {
                                        sync.scanForDifferences(path);
                                } catch(SyncException e) {
                                        log.log(e.msg);
                                }
                        };
                        m.onDelete = delegate(string path) {
                                log.vlog("[M] Item deleted: ", path);
                                try {
                                        sync.deleteByPath(path);
                                } catch(SyncException e) {
                                        log.log(e.msg);
                                }
                        };
                        m.onMove = delegate(string from, string to) {
                                log.vlog("[M] Item moved: ", from, " -> ", to);
                                try {
                                        sync.uploadMoveItem(from, to);
                                } catch(SyncException e) {
                                        log.log(e.msg);
                                }
                        };
                }
		m.init(cfg, verbose);
		// monitor loop
		immutable auto checkInterval = dur!"seconds"(45);
		auto lastCheckTime = MonoTime.currTime();
		while (true) {
			m.update(online);
			auto currTime = MonoTime.currTime();
			if (currTime - lastCheckTime > checkInterval) {
				lastCheckTime = currTime;
				online = testNetwork();
				if (online) {
					performSync(sync, ignore_local_changes);
					// discard all events that may have been generated by the sync
					m.update(false);
				}
				GC.collect();
			} else {
				Thread.sleep(dur!"msecs"(100));
			}
		}
	}

	// workaround for segfault in std.net.curl.Curl.shutdown() on exit
	onedrive.http.shutdown();
	return EXIT_SUCCESS;
}

// try to synchronize the folder three times
void performSync(SyncEngine sync, bool ignore_local_changes )
{
	int count;
	do {
		try {
			sync.applyDifferences();
                        if(!ignore_local_changes){
                                sync.scanForDifferences(".");
                        }
			count = -1;
		} catch (SyncException e) {
			if (++count == 3) throw e;
			else log.log(e.msg);
		}
	} while (count != -1);
}
