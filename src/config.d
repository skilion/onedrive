import std.file, std.regex, std.stdio;
static import log;

final class Config
{
	public string refreshTokenFilePath;
	public string statusTokenFilePath;
	public string databaseFilePath;
	public string uploadStateFilePath;

	private string userConfigFilePath;
	// hashmap for the values found in the user config file
	private string[string] values;

	this(string configDirName)
	{
		refreshTokenFilePath = configDirName ~ "/refresh_token";
		statusTokenFilePath = configDirName ~ "/status_token";
		databaseFilePath = configDirName ~ "/items.db";
		uploadStateFilePath = configDirName ~ "/resume_upload";
		userConfigFilePath = configDirName ~ "/config";
	}

	void init()
	{
		bool found = false;
		found |= load("/etc/onedrive.conf");
		found |= load("/usr/local/etc/onedrive.conf");
		found |= load(userConfigFilePath);
		if (!found) throw new Exception("No config file found");
	}

	string getValue(string key)
	{
		auto p = key in values;
		if (p) {
			return *p;
		} else {
			throw new Exception("Missing config value: " ~ key);
		}
	}

	private bool load(string filename)
	{
		scope(failure) return false;
		auto file = File(filename, "r");
		auto r = regex(`^\s*(\w+)\s*=\s*"(.*)"\s*$`);
		foreach (line; file.byLine()) {
			auto c = line.matchFirst(r);
			if (!c.empty) {
				c.popFront(); // skip the whole match
				string key = c.front.dup;
				c.popFront();
				values[key] = c.front.dup;
			} else {
				log.log("Malformed config line: ", line);
			}
		}
		return true;
	}
}

unittest
{
	auto cfg = new Config("");
	cfg.load("onedrive.conf");
	assert(cfg.getValue("sync_dir") == "~/OneDrive");
}
