import core.memory, core.time, core.thread;
import std.getopt, std.file, std.path, std.process, std.stdio;
import config, itemdb, monitor, onedrive, sync, util;

void main(string[] args)
{
	// Definitions
	bool debugHttp, localFirst, monitor, resync, synchronize, verbose;
	string singleDirectory;
	
	string configDirName = expandTilde(environment.get("XDG_CONFIG_HOME", "~/.config")) ~ "/onedrive";
	string configFile1Path = "/etc/onedrive.conf";
	string configFile2Path = "/usr/local/etc/onedrive.conf";
	string configFile3Path = configDirName ~ "/config";
	string refreshTokenFilePath = configDirName ~ "/refresh_token";
	string statusTokenFilePath = configDirName ~ "/status_token";
	string databaseFilePath = configDirName ~ "/items.db";
	
	// Read user input
	try {
		auto opt = getopt(
			args,
				"debug", "Debug OneDrive HTTP communication.", &debugHttp,
				"directory|d", "Specify a single local directory within the OneDrive root to sync.", &singleDirectory,
				"local-first|l", "Synchronize from the local directory source first, before downloading changes from OneDrive.", &localFirst,
				"monitor|m", "Keep monitoring for local and remote changes.", &monitor,
				"resync|r", "Forget the last saved state, perform a full resync from your OneDrive account.", &resync,
				"synchronize|s", "Perform a synchronization", &synchronize,
				"verbose|v", "Print more details, useful for debugging.", &verbose
		);
		if (opt.helpWanted) {
			defaultGetoptPrinter(
				"Usage: onedrive [OPTION]...\n\n" ~
				"no option    Sync and exit.",
				opt.options
			);
			return;
		}
	} catch (GetOptException e) {
		writeln(e.msg);
		writeln("Try 'onedrive -h' for more information.");
		return;
	}

	// Load the configuration files
	if (verbose) writeln("Loading config ...");
	auto cfg = config.Config(configFile1Path, configFile2Path, configFile3Path);
	string syncDir = expandTilde(cfg.get("sync_dir"));
	
	// Before attempting to perform any actions - are the application directories setup?
	//              ~/.config/onedrive
    //              ~/OneDrive
	
	if (!exists(configDirName)) mkdir(configDirName);
	if (!exists(syncDir)) mkdir(syncDir);

	if (resync) {
		if (verbose) writeln("Deleting the saved status ...");
		if (exists(databaseFilePath)) remove(databaseFilePath);
		if (exists(statusTokenFilePath)) remove(statusTokenFilePath);
	}

	if (verbose) writeln("Initializing the OneDrive API ...");
	bool online = testNetwork();
	if (!online && !monitor) {
		writeln("No network connection");
		return;
	}
	auto onedrive = new OneDriveApi(cfg, verbose, debugHttp);
	onedrive.onRefreshToken = (string refreshToken) {
		std.file.write(refreshTokenFilePath, refreshToken);
	};
	try {
		string refreshToken = readText(refreshTokenFilePath);
		onedrive.setRefreshToken(refreshToken);
	} catch (FileException e) {
		if (!onedrive.authorize()) {
			// workaround for segfault in std.net.curl.Curl.shutdown() on exit
			onedrive.http.shutdown();
			return;
		}
	}

	// Configure singleDirectory entry
	if (singleDirectory != ""){
		if (verbose){
			writeln("Single Directory Sync selected: ", singleDirectory);
		}
	}
	
	if ((synchronize) || (resync) || (monitor)) {
		// open up the database only if we are syncing or going into a monitor state
	
		if (verbose) writeln("Opening the item database ...");
		auto itemdb = new ItemDatabase(databaseFilePath);
		
		string operationsPath = syncDir;
		if (singleDirectory != ""){
			operationsPath = syncDir ~ "/" ~ singleDirectory;
		}
		
		if (verbose) writeln("All operations will be performed in: ", operationsPath);
		chdir(syncDir);

		if (verbose) writeln("Initializing the Synchronization Engine ...");
		auto sync = new SyncEngine(cfg, onedrive, itemdb, configDirName, verbose);
		sync.onStatusToken = (string statusToken) {
			std.file.write(statusTokenFilePath, statusToken);
		};
		string statusToken;
		try {
			statusToken = readText(statusTokenFilePath);
		} catch (FileException e) {
			// swallow exception
		}
		
		if ((synchronize) || (resync)) {
			if (online) performSync(sync, verbose, singleDirectory, localFirst, resync);
		}

		if (monitor) {
			if (verbose) writeln("Initializing monitor ...");
			Monitor m;
			m.onDirCreated = delegate(string path) {
				if (verbose) writeln("[M] Directory created: ", path);
				try {
					sync.scanForDifferences(path);
				} catch(SyncException e) {
					writeln(e.msg);
				}
			};
			m.onFileChanged = delegate(string path) {
				if (verbose) writeln("[M] File changed: ", path);
				try {
					sync.scanForDifferences(path);
				} catch(SyncException e) {
					writeln(e.msg);
				}
			};
			m.onDelete = delegate(string path) {
				if (verbose) writeln("[M] Item deleted: ", path);
				try {
					sync.deleteByPath(path);
				} catch(SyncException e) {
					writeln(e.msg);
				}
			};
			m.onMove = delegate(string from, string to) {
				if (verbose) writeln("[M] Item moved: ", from, " -> ", to);
				try {
					sync.uploadMoveItem(from, to);
				} catch(SyncException e) {
					writeln(e.msg);
				}
			};
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
						performSync(sync, verbose, singleDirectory, localFirst, resync);
						// discard all events that may have been generated by the sync
						m.update(false);
					}
					GC.collect();
				} else {
					Thread.sleep(dur!"msecs"(100));
				}
			}
		}

	}
	// workaround for segfault in std.net.curl.Curl.shutdown() on exit
	onedrive.http.shutdown();
}

// try to synchronize the folder three times
void performSync(SyncEngine sync, bool verbose, string singleDirectory, bool localFirst, bool resync)
{
	int count;
	string remotePath = "/";
    string localPath = ".";
	string statusToken;
	
	// At the start of the sync process, before this function is called, the client performs a chdir(syncDir) then the sync is done from there
	if (singleDirectory != ""){
		// Need two different path strings here
		remotePath = singleDirectory;
		localPath = "./" ~ singleDirectory;
		
		// Get the latest statusToken based on the path we are syncing
		statusToken = sync.updateStatusToken(remotePath);
	}
	
	// Initialize engine with the right status token
	sync.init(statusToken);
	
	do {
		try {
			if (!resync) {
				// we are not resysncing
				if (localFirst) {
					if (verbose) writeln("Syncing changes from local path first before downloading changes from OneDrive");

					// Scan local path first
					sync.scanForDifferences(localPath);
					sync.applyDifferences(remotePath);
					count = -1;
				} else {
					if (verbose) writeln("Syncing changes from OneDrive first before uploading local changes");

					// Scan OneDrive first
					sync.applyDifferences(remotePath);
					sync.scanForDifferences(localPath);
					count = -1;
					}
			} else {
				// resync == true
				if (verbose) writeln("Syncing changes from OneDrive first before uploading local changes");

				// Scan OneDrive first
				sync.applyDifferences(remotePath);
				sync.scanForDifferences(localPath);
				count = -1;
			}
		} catch (SyncException e) {
			if (++count == 3) throw e;
			else writeln(e.msg);
		}
	} while (count != -1);
}
